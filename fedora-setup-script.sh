#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Fedora KDE post-install / maintenance setup
#
# Run as the normal desktop user:
#   bash ~/Downloads/fedora-setup-script.sh
#
# Goals:
#   - Safe to rerun
#   - Never abort because an optional package is unavailable
#   - Continue after non-critical network/package/configuration failures
#   - Preserve existing user configuration where practical
#   - Install Google Chrome Beta when available
#   - Fall back to Google's official Chrome Beta RPM if the repo package
#     cannot be resolved
###############################################################################

readonly SCRIPT_NAME="${0##*/}"
readonly REAL_USER="$(id -un)"
readonly REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly FEDORA_VERSION="$(rpm -E %fedora)"

###############################################################################
# Logging
###############################################################################

log()  {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

ok() {
    printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fail() {
    printf '\033[1;31m[FAILED]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

###############################################################################
# Failure tracking
###############################################################################

WARNINGS=()
SUCCESSES=()

record_warning() {
    WARNINGS+=("$*")
}

record_success() {
    SUCCESSES+=("$*")
}

run_optional() {
    local description="$1"
    shift

    if "$@"; then
        return 0
    fi

    warn "$description"
    record_warning "$description"
    return 0
}

run_optional_shell() {
    local description="$1"
    local command="$2"

    if bash -c "$command"; then
        return 0
    fi

    warn "$description"
    record_warning "$description"
    return 0
}

###############################################################################
# Basic checks
###############################################################################

if (( EUID == 0 )); then
    die "Run $SCRIPT_NAME as your normal user, not with sudo."
fi

[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || \
    die "Could not determine the home directory for $REAL_USER."

command -v sudo >/dev/null 2>&1 || \
    die "sudo is not installed."

command -v dnf >/dev/null 2>&1 || \
    die "dnf is not installed."

command -v rpm >/dev/null 2>&1 || \
    die "rpm is not installed."

###############################################################################
# Sudo authentication
###############################################################################

log "Authenticating administrator access"

sudo -v || die "Could not authenticate with sudo."

(
    while sudo -n -v >/dev/null 2>&1; do
        sleep 45
    done
) &

SUDO_KEEPALIVE_PID=$!

cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]]; then
        if kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
            kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
            wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT INT TERM

###############################################################################
# 1. Remove unwanted applications
###############################################################################

log "Removing unwanted Fedora/KDE applications"

UNWANTED_PACKAGES=(
    kamoso
    dragonplayer
    elisa-player
    kmines
    kmahjongg
    kpat
    akregator
    kmail
    kontact
    korganizer
    kaddressbook
    krdc
    krfb
    krdp
    kfind
    kdebugsettings
    okular
    skanpage
    kcharselect
    kmouth
    kwrite
    qrca
    kcalc
    kolourpaint
    'libreoffice*'
    'libreoffice-langpack-*'
    firefox
    firefox-langpacks
    fedora-bookmarks
    neochat
)

if sudo dnf remove -y --skip-unavailable "${UNWANTED_PACKAGES[@]}"; then
    ok "Unwanted package cleanup completed."
else
    warn "Some unwanted packages could not be removed. Continuing."
    record_warning "Some unwanted packages could not be removed."
fi

###############################################################################
# 2. Refresh and upgrade
###############################################################################

log "Refreshing Fedora repositories"

if sudo dnf --refresh makecache; then
    ok "Repository metadata refreshed."
else
    warn "Repository metadata refresh failed; continuing with existing metadata."
    record_warning "Repository metadata refresh failed."
fi

log "Upgrading Fedora"

if sudo dnf upgrade -y --refresh; then
    ok "Fedora upgrade completed."
else
    warn "Fedora upgrade failed or was incomplete; continuing."
    record_warning "Fedora upgrade failed or was incomplete."
fi

###############################################################################
# 3. RPM Fusion
###############################################################################

log "Ensuring RPM Fusion repositories are installed"

RPMFUSION_RPMS=()

if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    RPMFUSION_RPMS+=(
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm"
    )
fi

if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    RPMFUSION_RPMS+=(
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
    )
fi

if ((${#RPMFUSION_RPMS[@]})); then
    if sudo dnf install -y --skip-unavailable "${RPMFUSION_RPMS[@]}"; then
        ok "RPM Fusion repositories installed."
    else
        warn "RPM Fusion installation failed; continuing."
        record_warning "RPM Fusion installation failed."
    fi
else
    ok "RPM Fusion Free and Nonfree are already installed."
fi

###############################################################################
# 4. Microsoft VS Code repository
###############################################################################

log "Ensuring the Visual Studio Code repository is configured"

VSCODE_REPO_FILE="/etc/yum.repos.d/vscode.repo"

if [[ ! -f "$VSCODE_REPO_FILE" ]]; then
    if sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc; then
        if sudo tee "$VSCODE_REPO_FILE" >/dev/null <<'EOF_REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF_REPO
        then
            ok "Visual Studio Code repository configured."
        else
            warn "Could not create the VS Code repository file."
            record_warning "Could not create the VS Code repository file."
        fi
    else
        warn "Could not import Microsoft's repository signing key."
        record_warning "Could not import Microsoft's repository signing key."
    fi
else
    ok "Visual Studio Code repository already configured."
fi

###############################################################################
# 5. Google Chrome repository
###############################################################################

log "Ensuring the official Google Chrome RPM repository is configured"

GOOGLE_CHROME_REPO_FILE="/etc/yum.repos.d/google-chrome.repo"

if [[ ! -f "$GOOGLE_CHROME_REPO_FILE" ]]; then
    if sudo rpm --import https://dl.google.com/linux/linux_signing_key.pub; then
        if sudo tee "$GOOGLE_CHROME_REPO_FILE" >/dev/null <<'EOF_GOOGLE_REPO'
[google-chrome]
name=google-chrome
baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOF_GOOGLE_REPO
        then
            ok "Google Chrome RPM repository configured."
        else
            warn "Could not create the Google Chrome repository file."
            record_warning "Could not create the Google Chrome repository file."
        fi
    else
        warn "Could not import Google's signing key."
        record_warning "Could not import Google's signing key."
    fi
else
    ok "Google Chrome RPM repository already configured."
fi

###############################################################################
# 6. Refresh third-party repositories
###############################################################################

log "Refreshing package repositories"

if sudo dnf --refresh makecache; then
    ok "All available repository metadata refreshed."
else
    warn "Some repository metadata could not be refreshed."
    record_warning "Some repository metadata could not be refreshed."
fi

###############################################################################
# 7. Package installation helpers
###############################################################################

install_optional_package() {
    local package="$1"

    if rpm -q "$package" >/dev/null 2>&1; then
        ok "$package is already installed."
        return 0
    fi

    printf 'Installing %-32s ... ' "$package"

    if sudo dnf install -y --skip-unavailable "$package" >/dev/null 2>&1; then
        printf '\033[1;32mOK\033[0m\n'
        record_success "$package installed."
        return 0
    fi

    printf '\033[1;33mSKIPPED\033[0m\n'
    warn "Could not install $package. Continuing."
    record_warning "Could not install $package."
    return 0
}

###############################################################################
# 8. Core package installation
#
# Each package is deliberately installed separately.
# One missing package therefore cannot abort the entire transaction.
###############################################################################

log "Installing shell, development, multimedia, firmware, and desktop utilities"

OPTIONAL_PACKAGES=(
    zsh
    git
    curl
    gh
    util-linux-user
    libva-utils
    vulkan-tools
    efibootmgr
    rsms-inter-fonts
    jetbrains-mono-fonts
    code
    telegram-desktop
    haruna
)

for package in "${OPTIONAL_PACKAGES[@]}"; do
    install_optional_package "$package"
done

###############################################################################
# 9. Google Chrome Beta
###############################################################################

log "Installing Google Chrome Beta"

install_chrome_beta() {
    # Already installed?
    if rpm -q google-chrome-beta >/dev/null 2>&1; then
        ok "Google Chrome Beta is already installed."
        return 0
    fi

    # First attempt: package from the configured Google repository.
    printf '%s\n' "Trying google-chrome-beta from the configured Google repository..."

    if sudo dnf install -y google-chrome-beta >/dev/null 2>&1; then
        ok "Google Chrome Beta installed from the Google RPM repository."
        record_success "Google Chrome Beta installed."
        return 0
    fi

    warn "google-chrome-beta was not available through DNF."

    # Direct official Google RPM fallback.
    local arch
    local rpm_url
    local temp_rpm

    arch="$(uname -m)"

    case "$arch" in
        x86_64)
            rpm_url="https://dl.google.com/linux/direct/google-chrome-beta_current_x86_64.rpm"
            ;;
        aarch64)
            rpm_url="https://dl.google.com/linux/direct/google-chrome-beta_current_aarch64.rpm"
            ;;
        *)
            warn "No Chrome Beta fallback RPM is configured for architecture: $arch"
            record_warning "Chrome Beta unavailable for architecture $arch."
            return 0
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        warn "curl is unavailable; cannot download the Chrome Beta fallback RPM."
        record_warning "Chrome Beta fallback could not run because curl is unavailable."
        return 0
    fi

    temp_rpm="$(mktemp --suffix=.rpm)"

    if curl \
        --fail \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$temp_rpm" \
        "$rpm_url"
    then
        if sudo dnf install -y "$temp_rpm"; then
            ok "Google Chrome Beta installed from Google's official RPM download."
            record_success "Google Chrome Beta installed."
            rm -f "$temp_rpm"
            return 0
        fi

        warn "The downloaded Chrome Beta RPM could not be installed."
        record_warning "Downloaded Chrome Beta RPM could not be installed."
    else
        warn "Could not download the Chrome Beta RPM."
        record_warning "Could not download Chrome Beta RPM."
    fi

    rm -f "$temp_rpm"
    return 0
}

install_chrome_beta

###############################################################################
# 10. GitHub CLI authentication
###############################################################################

log "Configuring GitHub CLI authentication"

if ! command -v gh >/dev/null 2>&1; then
    warn "GitHub CLI is not installed; skipping GitHub authentication."
    record_warning "GitHub authentication skipped because gh is unavailable."
else
    if gh auth status >/dev/null 2>&1; then
        ok "GitHub CLI is already authenticated."
    else
        printf '\nGitHub CLI authentication is not currently configured.\n'
        printf 'You can skip this step by pressing Enter on the token prompt.\n\n'

        GITHUB_TOKEN=""

        if read -r -s -p "Enter GitHub Personal Access Token (optional): " GITHUB_TOKEN; then
            printf '\n'
        else
            printf '\n'
            GITHUB_TOKEN=""
        fi

        if [[ -n "$GITHUB_TOKEN" ]]; then
            if printf '%s' "$GITHUB_TOKEN" | gh auth login --with-token; then
                unset GITHUB_TOKEN
                ok "GitHub CLI authentication completed."
            else
                unset GITHUB_TOKEN
                warn "GitHub CLI authentication failed; continuing."
                record_warning "GitHub CLI authentication failed."
            fi
        else
            unset GITHUB_TOKEN
            warn "No GitHub token supplied; authentication skipped."
            record_warning "GitHub authentication was skipped."
        fi
    fi
fi

###############################################################################
# 11. Oh My Zsh
###############################################################################

log "Installing/updating Oh My Zsh"

OMZ_DIR="$REAL_HOME/.oh-my-zsh"
ZSHRC="$REAL_HOME/.zshrc"
ZSH_CUSTOM="$OMZ_DIR/custom"

if ! command -v zsh >/dev/null 2>&1; then
    warn "zsh is unavailable; skipping Oh My Zsh configuration."
    record_warning "Oh My Zsh skipped because zsh is unavailable."
else
    if [[ -d "$OMZ_DIR/.git" ]]; then
        if git -C "$OMZ_DIR" pull --ff-only; then
            ok "Oh My Zsh updated."
        else
            warn "Could not update Oh My Zsh; keeping the existing installation."
            record_warning "Could not update Oh My Zsh."
        fi
    elif [[ -e "$OMZ_DIR" ]]; then
        backup="${OMZ_DIR}.backup.$(date +%Y%m%d-%H%M%S)"

        if mv -- "$OMZ_DIR" "$backup"; then
            warn "Existing non-Git Oh My Zsh directory moved to $backup."
        else
            warn "Could not move existing Oh My Zsh directory; skipping installation."
            record_warning "Could not move existing Oh My Zsh directory."
        fi

        if [[ ! -d "$OMZ_DIR" ]]; then
            if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR"; then
                ok "Oh My Zsh installed."
            else
                warn "Could not clone Oh My Zsh."
                record_warning "Could not clone Oh My Zsh."
            fi
        fi
    else
        if git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR"; then
            ok "Oh My Zsh installed."
        else
            warn "Could not clone Oh My Zsh."
            record_warning "Could not clone Oh My Zsh."
        fi
    fi

    if [[ -d "$OMZ_DIR" ]]; then
        mkdir -p "$ZSH_CUSTOM/plugins"

        install_or_update_plugin() {
            local repo="$1"
            local dir="$2"
            local name="${dir##*/}"

            if [[ -d "$dir/.git" ]]; then
                if git -C "$dir" pull --ff-only >/dev/null 2>&1; then
                    ok "$name updated."
                else
                    warn "Could not update $name; keeping current version."
                    record_warning "Could not update $name."
                fi
            elif [[ -e "$dir" ]]; then
                warn "$dir exists but is not a Git checkout; leaving it unchanged."
                record_warning "$name exists but is not a Git checkout."
            else
                if git clone --depth=1 "$repo" "$dir"; then
                    ok "$name installed."
                else
                    warn "Could not install $name."
                    record_warning "Could not install $name."
                fi
            fi
        }

        log "Installing/updating Zsh plugins"

        install_or_update_plugin \
            https://github.com/zsh-users/zsh-autosuggestions \
            "$ZSH_CUSTOM/plugins/zsh-autosuggestions"

        install_or_update_plugin \
            https://github.com/zsh-users/zsh-syntax-highlighting \
            "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"

        install_or_update_plugin \
            https://github.com/zsh-users/zsh-completions \
            "$ZSH_CUSTOM/plugins/zsh-completions"

        log "Configuring Zsh"

        if [[ ! -e "$ZSHRC" ]]; then
            if [[ -f "$OMZ_DIR/templates/zshrc.zsh-template" ]]; then
                cp "$OMZ_DIR/templates/zshrc.zsh-template" "$ZSHRC"
            else
                touch "$ZSHRC"
                warn "Oh My Zsh template unavailable; created empty .zshrc."
                record_warning "Oh My Zsh template unavailable."
            fi
        else
            touch "$ZSHRC"
        fi

        if grep -q '^ZSH_THEME=' "$ZSHRC"; then
            sed -i \
                's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' \
                "$ZSHRC"
        else
            printf '\nZSH_THEME="robbyrussell"\n' >> "$ZSHRC"
        fi

        if grep -q '^plugins=' "$ZSHRC"; then
            sed -i \
                's/^plugins=.*/plugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting zsh-completions)/' \
                "$ZSHRC"
        else
            printf '\nplugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting zsh-completions)\n' \
                >> "$ZSHRC"
        fi

        if ! grep -Eq \
            '^[[:space:]]*(source|\.)[[:space:]]+.*oh-my-zsh\.sh' \
            "$ZSHRC"
        then
            cat >> "$ZSHRC" <<'EOF_OMZ'

# BEGIN FEDORA-SETUP OH-MY-ZSH
export ZSH="$HOME/.oh-my-zsh"
source "$ZSH/oh-my-zsh.sh"
# END FEDORA-SETUP OH-MY-ZSH
EOF_OMZ
        fi

        ok "Zsh configuration completed."
    fi
fi

###############################################################################
# 12. VS Code configuration
###############################################################################

log "Configuring VS Code as the default text editor"

if command -v gio >/dev/null 2>&1 && command -v code >/dev/null 2>&1; then
    if gio mime text/plain code.desktop >/dev/null 2>&1; then
        ok "VS Code configured as the text/plain editor."
    else
        warn "Could not set VS Code as the text/plain default."
        record_warning "Could not set VS Code as the text/plain default."
    fi
else
    warn "gio or code is unavailable; skipping text editor configuration."
    record_warning "VS Code default-editor configuration skipped."
fi

if [[ -f "$ZSHRC" ]]; then
    sed -i \
        '/# BEGIN FEDORA-SETUP EDITOR/,/# END FEDORA-SETUP EDITOR/d' \
        "$ZSHRC"

    cat >> "$ZSHRC" <<'EOF_EDITOR'

# BEGIN FEDORA-SETUP EDITOR
export EDITOR='code --wait'
export VISUAL="$EDITOR"

nano() {
    command code --wait "$@"
}
# END FEDORA-SETUP EDITOR
EOF_EDITOR

    ok "Shell editor configuration updated."
fi

###############################################################################
# 13. KDE fonts
###############################################################################

log "Configuring KDE fonts"

if command -v kwriteconfig6 >/dev/null 2>&1; then
    KDE_UI_FONT='Inter,10,-1,5,50,0,0,0,0,0'
    KDE_SMALL_FONT='Inter,8,-1,5,50,0,0,0,0,0'
    KDE_MONO_FONT='JetBrains Mono,10,-1,5,50,0,0,0,0,0'

    run_optional \
        "Could not set KDE UI font." \
        kwriteconfig6 --file kdeglobals --group General --key font "$KDE_UI_FONT"

    run_optional \
        "Could not set KDE menu font." \
        kwriteconfig6 --file kdeglobals --group General --key menuFont "$KDE_UI_FONT"

    run_optional \
        "Could not set KDE toolbar font." \
        kwriteconfig6 --file kdeglobals --group General --key toolBarFont "$KDE_UI_FONT"

    run_optional \
        "Could not set KDE small font." \
        kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$KDE_SMALL_FONT"

    run_optional \
        "Could not set KDE fixed-width font." \
        kwriteconfig6 --file kdeglobals --group General --key fixed "$KDE_MONO_FONT"

    run_optional \
        "Could not set KDE active window font." \
        kwriteconfig6 --file kdeglobals --group WM --key activeFont "$KDE_UI_FONT"

    ok "KDE font configuration processed."
else
    warn "kwriteconfig6 is unavailable; skipping KDE font configuration."
    record_warning "KDE font configuration skipped."
fi

###############################################################################
# 14. NumLock
###############################################################################

log "Enabling NumLock for KDE Plasma and Plasma Login Manager"

if command -v kwriteconfig6 >/dev/null 2>&1; then
    run_optional \
        "Could not configure per-user Plasma NumLock." \
        kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
else
    warn "kwriteconfig6 unavailable; skipping per-user NumLock configuration."
fi

if systemctl list-unit-files plasmalogin.service --no-legend 2>/dev/null |
    grep -q '^plasmalogin\.service'
then
    if sudo tee /etc/plasmalogin.conf >/dev/null <<'EOF_PLM'
[General]
Numlock=on
EOF_PLM
    then
        ok "Plasma Login Manager NumLock configured."
    else
        warn "Could not write /etc/plasmalogin.conf."
        record_warning "Could not configure Plasma Login Manager NumLock."
    fi

    if sudo install -d -m 0755 /var/lib/plasmalogin/.config/kdedefaults; then
        if sudo tee /var/lib/plasmalogin/.config/kdedefaults/kcminputrc >/dev/null <<'EOF_PLM_KBD'
[Keyboard]
NumLock=0
EOF_PLM_KBD
        then
            if getent passwd plasmalogin >/dev/null 2>&1; then
                run_optional \
                    "Could not set ownership of Plasma Login Manager configuration." \
                    sudo chown -R plasmalogin:plasmalogin /var/lib/plasmalogin/.config
            fi
        else
            warn "Could not write Plasma Login Manager keyboard configuration."
            record_warning "Could not write Plasma Login Manager keyboard configuration."
        fi
    else
        warn "Could not create Plasma Login Manager configuration directory."
        record_warning "Could not create Plasma Login Manager configuration directory."
    fi
else
    warn "Plasma Login Manager is not installed; login-screen NumLock skipped."
fi

###############################################################################
# 15. KDE/system tweaks
###############################################################################

log "Applying KDE/system tweaks"

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    run_optional \
        "KDE cache rebuild reported an error." \
        kbuildsycoca6 --noincremental
else
    warn "kbuildsycoca6 unavailable; skipping KDE cache rebuild."
fi

run_optional \
    "Could not enable fstrim.timer." \
    sudo systemctl enable fstrim.timer

run_optional \
    "Could not configure hardware clock to UTC." \
    sudo timedatectl set-local-rtc 0

run_optional \
    "Could not disable NetworkManager-wait-online.service." \
    sudo systemctl disable NetworkManager-wait-online.service

run_optional \
    "Could not remove GNOME Software autostart entry." \
    sudo rm -f -- /etc/xdg/autostart/org.gnome.Software.desktop

###############################################################################
# 16. systemd journal limits
###############################################################################

log "Configuring systemd journal limits"

if sudo install -d -m 0755 /etc/systemd/journald.conf.d; then
    if sudo tee /etc/systemd/journald.conf.d/limits.conf >/dev/null <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF_JOURNAL
    then
        run_optional \
            "Could not restart systemd-journald." \
            sudo systemctl restart systemd-journald

        ok "Journal limits configured."
    else
        warn "Could not write journald limits configuration."
        record_warning "Could not write journald limits configuration."
    fi
else
    warn "Could not create journald configuration directory."
    record_warning "Could not create journald configuration directory."
fi

###############################################################################
# 17. UEFI BootOrder
###############################################################################

log "Checking UEFI boot order"

if [[ -d /sys/firmware/efi/efivars ]]; then

    if command -v efibootmgr >/dev/null 2>&1; then

        WIN="$(
            efibootmgr 2>/dev/null |
                awk '/Windows Boot Manager/ {
                    gsub(/\*/, "", $1)
                    sub(/^Boot/, "", $1)
                    print $1
                    exit
                }'
        )" || WIN=""

        if [[ -n "$WIN" ]]; then

            ORDER="$(
                efibootmgr 2>/dev/null |
                    awk -F'BootOrder: ' '/BootOrder/ {print $2; exit}'
            )" || ORDER=""

            if [[ -n "$ORDER" ]]; then

                NEW_ORDER="$(
                    printf '%s\n' "$ORDER" |
                        tr ',' '\n' |
                        awk -v win="$WIN" '$0 != win' |
                        paste -sd, -
                )"

                FINAL="$WIN"

                if [[ -n "$NEW_ORDER" ]]; then
                    FINAL="$WIN,$NEW_ORDER"
                fi

                if [[ "$ORDER" == "$FINAL" ]]; then
                    ok "Windows Boot Manager is already first in BootOrder."
                else
                    printf 'Current BootOrder: %s\n' "$ORDER"
                    printf 'New BootOrder    : %s\n' "$FINAL"

                    run_optional \
                        "Could not modify UEFI BootOrder." \
                        sudo efibootmgr -o "$FINAL"
                fi
            else
                warn "Could not read the current UEFI BootOrder."
                record_warning "Could not read UEFI BootOrder."
            fi
        else
            warn "Windows Boot Manager not found; leaving BootOrder unchanged."
        fi
    else
        warn "efibootmgr is unavailable; skipping UEFI BootOrder."
        record_warning "efibootmgr unavailable."
    fi
else
    warn "System is not booted in UEFI mode; skipping BootOrder adjustment."
fi

###############################################################################
# 18. Set Zsh as login shell
###############################################################################

log "Setting Zsh as the default shell"

if command -v zsh >/dev/null 2>&1; then
    ZSH_PATH="$(command -v zsh)"
    CURRENT_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"

    if [[ "$CURRENT_LOGIN_SHELL" == "$ZSH_PATH" ]]; then
        ok "Zsh is already the login shell for $REAL_USER."
    else
        if sudo usermod -s "$ZSH_PATH" "$REAL_USER"; then
            NEW_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"

            if [[ "$NEW_LOGIN_SHELL" == "$ZSH_PATH" ]]; then
                ok "Login shell changed to $ZSH_PATH."
            else
                warn "usermod completed but the login shell could not be verified."
                record_warning "Could not verify Zsh login shell."
            fi
        else
            warn "Could not change login shell to Zsh."
            record_warning "Could not change login shell to Zsh."
        fi
    fi
else
    warn "Zsh is not installed; keeping the existing login shell."
    record_warning "Zsh login shell was skipped."
    ZSH_PATH="$CURRENT_LOGIN_SHELL"
fi

###############################################################################
# 19. Final maintenance
###############################################################################

log "Running final maintenance"

if sudo dnf autoremove -y; then
    ok "DNF autoremove completed."
else
    warn "DNF autoremove reported an issue; continuing."
    record_warning "DNF autoremove reported an issue."
fi

if sudo journalctl --vacuum-time=7d; then
    ok "Old journal entries cleaned."
else
    warn "Journal cleanup reported an issue."
    record_warning "Journal cleanup reported an issue."
fi

if command -v flatpak >/dev/null 2>&1; then
    if flatpak uninstall --unused -y; then
        ok "Unused Flatpak runtimes cleaned."
    else
        warn "Flatpak cleanup reported an issue."
        record_warning "Flatpak cleanup reported an issue."
    fi
else
    warn "Flatpak is not installed; skipping Flatpak cleanup."
fi

if command -v fstrim >/dev/null 2>&1; then
    if sudo fstrim -av; then
        ok "Manual filesystem TRIM completed."
    else
        warn "Manual fstrim reported an issue."
        record_warning "Manual fstrim reported an issue."
    fi
else
    warn "fstrim is unavailable; skipping immediate TRIM."
fi

###############################################################################
# 20. Final status
###############################################################################

printf '\n'
printf '========================================\n'
printf ' Fedora KDE setup complete\n'
printf '========================================\n\n'

printf 'User     : %s\n' "$REAL_USER"
printf 'Fedora   : %s\n' "$FEDORA_VERSION"
printf 'Home     : %s\n' "$REAL_HOME"

if command -v zsh >/dev/null 2>&1; then
    printf 'Shell    : %s\n' "$(getent passwd "$REAL_USER" | cut -d: -f7)"
else
    printf 'Shell    : unchanged (zsh unavailable)\n'
fi

printf 'Theme    : robbyrussell\n'
printf 'Plugins  : git, sudo, zsh-autosuggestions,\n'
printf '           zsh-syntax-highlighting, zsh-completions\n\n'

if rpm -q google-chrome-beta >/dev/null 2>&1; then
    printf 'Chrome   : Google Chrome Beta installed\n'
else
    printf 'Chrome   : Google Chrome Beta NOT installed\n'
fi

if command -v code >/dev/null 2>&1; then
    printf 'VS Code  : installed\n'
else
    printf 'VS Code  : not installed\n'
fi

printf '\n'

if ((${#WARNINGS[@]} == 0)); then
    printf '\033[1;32mNo non-fatal errors were reported.\033[0m\n'
else
    printf '\033[1;33mThe setup completed with %d warning(s):\033[0m\n' \
        "${#WARNINGS[@]}"

    for warning in "${WARNINGS[@]}"; do
        printf '  - %s\n' "$warning"
    done
fi

printf '\n'
printf 'Most configuration changes are safe to use immediately.\n'
printf 'Log out and back in, or reboot, for the new login shell and KDE changes.\n'
printf '========================================\n'
