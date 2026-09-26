#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Fedora KDE post-install / maintenance setup
# - Run as the normal desktop user (not with sudo)
# - Designed to be safe to rerun
# - Preserves the personalized package/configuration choices in this setup
###############################################################################

readonly SCRIPT_NAME="${0##*/}"
readonly REAL_USER="$(id -un)"
readonly REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
readonly FEDORA_VERSION="$(rpm -E %fedora)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

if (( EUID == 0 )); then
    die "Run $SCRIPT_NAME as your normal user, not with sudo. It requests sudo itself."
fi

[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || die "Could not determine the home directory for $REAL_USER."
command -v sudo >/dev/null 2>&1 || die "sudo is not installed."
command -v dnf  >/dev/null 2>&1 || die "dnf is not installed."
command -v rpm  >/dev/null 2>&1 || die "rpm is not installed."

###############################################################################
# Sudo authentication
###############################################################################
log "Authenticating administrator access"
sudo -v

# Keep the sudo timestamp alive during long downloads/transactions.
(
    while sudo -n -v >/dev/null 2>&1; do
        sleep 45
    done
) &
SUDO_KEEPALIVE_PID=$!

cleanup() {
    if kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

###############################################################################
# 1. Remove unwanted Fedora/KDE applications
###############################################################################
log "Removing unwanted Fedora/KDE applications"

UNWANTED_PACKAGES=(
    kamoso dragonplayer elisa-player
    kmines kmahjongg kpat
    akregator kmail kontact korganizer kaddressbook
    krdc krfb krdp kfind kdebugsettings
    okular skanpage
    kcharselect kmouth kwrite qrca kcalc kolourpaint
    'libreoffice*' 'libreoffice-langpack-*'
    firefox firefox-langpacks fedora-bookmarks
    neochat
)

# --skip-unavailable makes reruns tolerant of packages/specs that are absent.
sudo dnf remove -y  "${UNWANTED_PACKAGES[@]}" || \
    warn "Some requested packages could not be removed; continuing."

###############################################################################
# 2. Fully update the Fedora base before adding third-party repositories
###############################################################################
log "Refreshing repositories and upgrading Fedora"
# --refresh is sufficient; 'dnf clean all' here would only force a full metadata
# redownload and make the next transaction slower.
sudo dnf --refresh upgrade -y

###############################################################################
# 3. RPM Fusion repositories
###############################################################################
log "Ensuring RPM Fusion repositories are installed"

RPMFUSION_RPMS=()
rpm -q rpmfusion-free-release >/dev/null 2>&1 || \
    RPMFUSION_RPMS+=("https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm")
rpm -q rpmfusion-nonfree-release >/dev/null 2>&1 || \
    RPMFUSION_RPMS+=("https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm")

if ((${#RPMFUSION_RPMS[@]})); then
    sudo dnf install -y "${RPMFUSION_RPMS[@]}"
else
    ok "RPM Fusion Free and Nonfree are already installed."
fi

###############################################################################
# 4. Microsoft VS Code repository
###############################################################################
log "Ensuring the Visual Studio Code repository is configured"

if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
    # This is Microsoft's current documented RPM-repository configuration.
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF_REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF_REPO
else
    ok "Visual Studio Code repository already configured."
fi

###############################################################################
# 5. Vivaldi Stable repository
###############################################################################
log "Ensuring the official Vivaldi Stable repository is configured"

VIVALDI_REPO_FILE="/etc/yum.repos.d/vivaldi-fedora.repo"

if [[ ! -f "$VIVALDI_REPO_FILE" ]]; then
    # Vivaldi's official Fedora repository definition. Download first, then
    # install atomically so a failed transfer cannot leave a partial repo file.
    VIVALDI_REPO_TMP="$(mktemp)"
    if curl -fL --retry 3 --retry-delay 2 \
        https://repo.vivaldi.com/archive/vivaldi-fedora.repo \
        -o "$VIVALDI_REPO_TMP"; then
        sudo install -m 0644 "$VIVALDI_REPO_TMP" "$VIVALDI_REPO_FILE"
        rm -f -- "$VIVALDI_REPO_TMP"
    else
        rm -f -- "$VIVALDI_REPO_TMP"
        die "Could not download the official Vivaldi Fedora repository configuration."
    fi
else
    ok "Vivaldi repository already configured."
fi

###############################################################################
# 7. Base packages and utilities
###############################################################################
log "Installing shell, development, multimedia, and firmware utilities"

# Keep compatible installs in one DNF transaction.
sudo dnf install -y \
    zsh git curl gh util-linux-user \
    libva-utils vulkan-tools efibootmgr \
    rsms-inter-fonts jetbrains-mono-fonts \
    code vivaldi-stable telegram-desktop haruna

###############################################################################
# 7. GitHub CLI authentication
###############################################################################
log "Configuring GitHub CLI authentication"

if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI is already authenticated."
else
    printf '\nGitHub CLI authentication is required.\n'
    printf 'The token will not be echoed and will be passed to gh through stdin.\n\n'

    read -r -s -p "Enter GitHub Personal Access Token: " GITHUB_TOKEN
    printf '\n'

    if [[ -z "$GITHUB_TOKEN" ]]; then
        unset GITHUB_TOKEN
        die "No GitHub token was entered."
    fi

    if printf '%s' "$GITHUB_TOKEN" | gh auth login --with-token; then
        unset GITHUB_TOKEN
        ok "GitHub CLI authentication completed."
    else
        unset GITHUB_TOKEN
        die "GitHub CLI authentication failed."
    fi
fi

###############################################################################
# 8. Third-party desktop customizations
###############################################################################
log "Installing KDE Windows System Tray"

curl -fsSL --retry 3 --retry-delay 2 \
    https://github.com/RaceConditionWinner/Kde-windows-system-tray/releases/latest/download/install.sh |
    bash

log "Installing Vivaldi Swift"

bash <(curl -fsSL --retry 3 --retry-delay 2 \
    https://raw.githubusercontent.com/Utkarsh-tiwari27/Vivaldi-Swift/main/installers/install.sh)

###############################################################################
# 9. Oh My Zsh and plugins
###############################################################################
log "Installing/updating Oh My Zsh"

OMZ_DIR="$REAL_HOME/.oh-my-zsh"
ZSHRC="$REAL_HOME/.zshrc"
ZSH_CUSTOM="$OMZ_DIR/custom"

if [[ -d "$OMZ_DIR/.git" ]]; then
    git -C "$OMZ_DIR" pull --ff-only || \
        warn "Could not update Oh My Zsh; keeping the current installation."
else
    if [[ -e "$OMZ_DIR" ]]; then
        backup="${OMZ_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        mv -- "$OMZ_DIR" "$backup"
        warn "Existing non-Git Oh My Zsh directory moved to $backup"
    fi

    # Clone the project directly instead of executing a network-fetched installer.
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OMZ_DIR"
fi

mkdir -p "$ZSH_CUSTOM/plugins"

install_or_update_plugin() {
    local repo="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --ff-only || \
            warn "Could not update ${dir##*/}; keeping the current version."
    elif [[ -e "$dir" ]]; then
        warn "$dir exists but is not a Git checkout; leaving it unchanged."
    else
        git clone --depth=1 "$repo" "$dir"
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

# On a fresh install, seed .zshrc from the upstream template. Existing user
# configuration is preserved and then normalized below.
if [[ ! -e "$ZSHRC" ]]; then
    cp "$OMZ_DIR/templates/zshrc.zsh-template" "$ZSHRC"
else
    touch "$ZSHRC"
fi

if grep -q '^ZSH_THEME=' "$ZSHRC"; then
    sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' "$ZSHRC"
else
    printf '\nZSH_THEME="robbyrussell"\n' >> "$ZSHRC"
fi

if grep -q '^plugins=' "$ZSHRC"; then
    sed -i 's/^plugins=.*/plugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting zsh-completions)/' "$ZSHRC"
else
    printf '\nplugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting zsh-completions)\n' >> "$ZSHRC"
fi

# Ensure an existing custom .zshrc actually loads this Oh My Zsh checkout.
if ! grep -Eq '^[[:space:]]*(source|\.)[[:space:]]+.*oh-my-zsh\.sh' "$ZSHRC"; then
    cat >> "$ZSHRC" <<'EOF_OMZ'

# BEGIN FEDORA-SETUP OH-MY-ZSH
export ZSH="$HOME/.oh-my-zsh"
source "$ZSH/oh-my-zsh.sh"
# END FEDORA-SETUP OH-MY-ZSH
EOF_OMZ
fi

###############################################################################
# 10. VS Code editor configuration
###############################################################################
log "Configuring VS Code as the default text editor"

if command -v gio >/dev/null 2>&1; then
    gio mime text/plain code.desktop || warn "Could not set text/plain MIME default."
else
    warn "gio is unavailable; skipping the text/plain MIME association."
fi

# Idempotent managed block: remove the previous copy and add exactly one.
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

###############################################################################
# 11. KDE fonts
###############################################################################
log "Configuring Inter for KDE and JetBrains Mono for monospace/terminal text"

if command -v kwriteconfig6 >/dev/null 2>&1; then
    # Qt/KDE font serialization: family,size,...,weight,...
    KDE_UI_FONT='Inter,10,-1,5,50,0,0,0,0,0'
    KDE_SMALL_FONT='Inter,8,-1,5,50,0,0,0,0,0'
    KDE_MONO_FONT='JetBrains Mono,10,-1,5,50,0,0,0,0,0'

    kwriteconfig6 --file kdeglobals --group General --key font "$KDE_UI_FONT"
    kwriteconfig6 --file kdeglobals --group General --key menuFont "$KDE_UI_FONT"
    kwriteconfig6 --file kdeglobals --group General --key toolBarFont "$KDE_UI_FONT"
    kwriteconfig6 --file kdeglobals --group General --key smallestReadableFont "$KDE_SMALL_FONT"
    kwriteconfig6 --file kdeglobals --group General --key fixed "$KDE_MONO_FONT"
    kwriteconfig6 --file kdeglobals --group WM --key activeFont "$KDE_UI_FONT"

    ok "KDE fonts set to Inter; fixed-width font set to JetBrains Mono."
else
    warn "kwriteconfig6 not found; skipping KDE font configuration."
fi

###############################################################################
# 12. NumLock: Plasma session and Plasma Login Manager
###############################################################################
log "Enabling NumLock for KDE Plasma and Plasma Login Manager"

if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
else
    warn "kwriteconfig6 not found; skipping the per-user Plasma NumLock setting."
fi

if systemctl list-unit-files plasmalogin.service --no-legend 2>/dev/null | grep -q '^plasmalogin\.service'; then
    # Fedora 44+ KDE fresh installs use Plasma Login Manager by default.
    sudo tee /etc/plasmalogin.conf >/dev/null <<'EOF_PLM'
[General]
Numlock=on
EOF_PLM

    sudo install -d -m 0755 /var/lib/plasmalogin/.config/kdedefaults
    sudo tee /var/lib/plasmalogin/.config/kdedefaults/kcminputrc >/dev/null <<'EOF_PLM_KBD'
[Keyboard]
NumLock=0
EOF_PLM_KBD

    if getent passwd plasmalogin >/dev/null 2>&1; then
        sudo chown -R plasmalogin:plasmalogin /var/lib/plasmalogin/.config
    fi
else
    warn "Plasma Login Manager is not installed; login-screen NumLock configuration was skipped."
fi

###############################################################################
# 15. KDE/system tweaks
###############################################################################
log "Applying KDE/system tweaks"

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    kbuildsycoca6 --noincremental || \
        warn "KDE cache rebuild reported a non-fatal warning/error."
fi

# Fedora enables fstrim.timer by default, but this preserves the requested
# behavior and repairs it if it has been disabled locally.
sudo systemctl enable fstrim.timer >/dev/null 2>&1 || \
    warn "Could not enable fstrim.timer."

sudo timedatectl set-local-rtc 0 || \
    warn "Could not configure the hardware clock to use UTC."

# Intentional boot optimization. Systems with remote mounts/services that truly
# require network-online.target should leave this service enabled.
sudo systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || \
    warn "Could not disable NetworkManager-wait-online.service."

# Preserve the original customization, but only remove the file if present.
sudo rm -f -- /etc/xdg/autostart/org.gnome.Software.desktop

###############################################################################
# 16. systemd journal limits
###############################################################################
log "Configuring systemd journal limits"

sudo install -d -m 0755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/limits.conf >/dev/null <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF_JOURNAL

sudo systemctl restart systemd-journald

###############################################################################
# 17. UEFI BootOrder
###############################################################################
log "Checking UEFI boot order"

if [[ -d /sys/firmware/efi/efivars ]]; then
    WIN="$(
        efibootmgr | awk '/Windows Boot Manager/ {
            gsub(/\*/, "", $1)
            sub(/^Boot/, "", $1)
            print $1
            exit
        }'
    )"

    if [[ -n "$WIN" ]]; then
        ORDER="$(efibootmgr | awk -F'BootOrder: ' '/BootOrder/ {print $2; exit}')"

        if [[ -n "$ORDER" ]]; then
            NEW_ORDER="$(
                printf '%s\n' "$ORDER" |
                    tr ',' '\n' |
                    awk -v win="$WIN" '$0 != win' |
                    paste -sd, -
            )"

            FINAL="$WIN"
            [[ -n "$NEW_ORDER" ]] && FINAL="$WIN,$NEW_ORDER"

            if [[ "$ORDER" == "$FINAL" ]]; then
                ok "Windows Boot Manager is already first in BootOrder."
            else
                printf 'Setting BootOrder to: %s\n' "$FINAL"
                sudo efibootmgr -o "$FINAL"
            fi
        else
            warn "Could not read the current UEFI BootOrder."
        fi
    else
        warn "Windows Boot Manager not found; leaving BootOrder unchanged."
    fi
else
    warn "System is not booted in UEFI mode; skipping BootOrder adjustment."
fi

###############################################################################
# 18. Set Zsh as login shell
###############################################################################
log "Setting Zsh as the default shell"

ZSH_PATH="$(command -v zsh)"
CURRENT_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"

if [[ "$CURRENT_LOGIN_SHELL" == "$ZSH_PATH" ]]; then
    ok "Zsh is already the login shell for $REAL_USER."
else
    # Use the already-authenticated sudo session to avoid a second password
    # prompt from chsh. usermod updates the same passwd shell field directly.
    sudo usermod -s "$ZSH_PATH" "$REAL_USER"

    NEW_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"
    [[ "$NEW_LOGIN_SHELL" == "$ZSH_PATH" ]] || \
        die "Failed to change the login shell for $REAL_USER."
    ok "Login shell changed to $ZSH_PATH."
fi

###############################################################################
# 19. Final maintenance
###############################################################################
log "Running final maintenance"

# Run autoremove after all package changes so dependency cleanup is based on the
# final desired package set rather than an intermediate state.
sudo dnf autoremove -y || warn "dnf autoremove reported a non-fatal issue."

sudo journalctl --vacuum-time=7d || \
    warn "Journal vacuum reported a non-fatal issue."

if command -v flatpak >/dev/null 2>&1; then
    flatpak uninstall --unused -y || \
        warn "Flatpak cleanup reported a non-fatal issue."
fi

# The weekly timer handles ongoing TRIM; preserve the original immediate trim.
sudo fstrim -av || warn "Manual fstrim reported a non-fatal issue."

###############################################################################
# Complete
###############################################################################
printf '\n========================================\n'
printf ' Fedora KDE setup complete!\n'
printf '========================================\n\n'
printf 'User     : %s\n' "$REAL_USER"
printf 'Fedora   : %s\n' "$FEDORA_VERSION"
printf 'Shell    : %s\n' "$ZSH_PATH"
printf 'Theme    : robbyrussell\n'
printf 'Plugins  : git, sudo, zsh-autosuggestions,\n'
printf '           zsh-syntax-highlighting, zsh-completions\n\n'
printf 'VS Code is configured as the text editor.\n'
printf 'Vivaldi Stable is installed from the official Vivaldi repository.\n'
printf 'Telegram Desktop and VLC are installed.\n'
printf 'KDE uses Inter; monospace/terminal font is JetBrains Mono.\n'
printf 'NumLock is configured for KDE/Plasma Login where PLM is available.\n\n'
printf 'Log out and log back in, or reboot, for the new login shell.\n'
printf '========================================\n'
