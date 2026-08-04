#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Fedora KDE post-install / maintenance setup
# - Designed to be safe to rerun
# - Requests sudo password once at startup
# - Keeps sudo credentials alive for the duration of the script
###############################################################################

readonly SCRIPT_NAME="${0##*/}"
readonly REAL_USER="${SUDO_USER:-$USER}"
readonly REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
    die "Run this script as your normal user, not with sudo. It will request sudo once itself."
fi

command -v sudo >/dev/null 2>&1 || die "sudo is not installed."

###############################################################################
# Sudo authentication: prompt once, then keep timestamp alive
###############################################################################
log "Authenticating administrator access"
sudo -v

# Refresh the sudo timestamp periodically so long downloads/installs do not
# cause another password prompt later in the script.
(
    while true; do
        sudo -n -v >/dev/null 2>&1 || exit
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
# 1. Remove unwanted applications
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

# DNF safely ignores package names/patterns that are not installed.
sudo dnf remove -y "${UNWANTED_PACKAGES[@]}" || \
    warn "Some requested packages were already absent or could not be removed."

###############################################################################
# 2. Cleanup and update
###############################################################################
log "Cleaning unused packages"
sudo dnf autoremove -y || warn "dnf autoremove reported a non-fatal issue."

log "Refreshing repositories and upgrading Fedora"
sudo dnf clean all
sudo dnf upgrade --refresh -y

###############################################################################
# 3. RPM Fusion
###############################################################################
log "Ensuring RPM Fusion repositories are installed"

FEDORA_VERSION="$(rpm -E %fedora)"

if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VERSION}.noarch.rpm"
else
    ok "RPM Fusion Free already installed."
fi

if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
    sudo dnf install -y \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VERSION}.noarch.rpm"
else
    ok "RPM Fusion Nonfree already installed."
fi

###############################################################################
# 4. Multimedia
###############################################################################
log "Installing multimedia support"

sudo dnf group install -y --with-optional multimedia || \
    warn "Multimedia group installation reported a non-fatal issue."

# Only swap when Fedora's ffmpeg-free is actually installed.
if rpm -q ffmpeg-free >/dev/null 2>&1; then
    sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
elif rpm -q ffmpeg >/dev/null 2>&1; then
    ok "Full ffmpeg is already installed."
else
    sudo dnf install -y ffmpeg
fi

sudo dnf upgrade -y @multimedia \
    --setopt=install_weak_deps=False \
    --exclude=PackageKit-gstreamer-plugin || \
    warn "Multimedia group upgrade reported a non-fatal issue."

sudo dnf group install -y sound-and-video || \
    warn "sound-and-video group installation reported a non-fatal issue."

sudo dnf install -y ffmpeg-libs libva libva-utils

###############################################################################
# 5. Mesa hardware acceleration
###############################################################################
log "Configuring RPM Fusion Mesa hardware acceleration"

swap_if_installed() {
    local from="$1"
    local to="$2"

    if rpm -q "$from" >/dev/null 2>&1; then
        sudo dnf swap -y "$from" "$to" || \
            warn "Could not swap $from -> $to."
    fi
}

swap_if_installed mesa-va-drivers mesa-va-drivers-freeworld
swap_if_installed mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
swap_if_installed mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686
swap_if_installed mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686

###############################################################################
# 6. Base development / shell packages
###############################################################################
log "Installing Zsh, Git, curl, and utilities"
sudo dnf install -y zsh git curl util-linux-user

###############################################################################
# 7. Oh My Zsh
###############################################################################
log "Installing/updating Oh My Zsh"

OMZ_DIR="$REAL_HOME/.oh-my-zsh"
ZSHRC="$REAL_HOME/.zshrc"
ZSH_CUSTOM="$OMZ_DIR/custom"

if [[ -d "$OMZ_DIR/.git" ]]; then
    git -C "$OMZ_DIR" pull --ff-only || warn "Could not update Oh My Zsh; keeping current installation."
else
    # Preserve an unrelated broken/partial directory rather than deleting user data.
    if [[ -e "$OMZ_DIR" ]]; then
        backup="${OMZ_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$OMZ_DIR" "$backup"
        warn "Existing non-Git Oh My Zsh directory moved to $backup"
    fi

    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

mkdir -p "$ZSH_CUSTOM/plugins"

install_or_update_plugin() {
    local repo="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --ff-only || warn "Could not update ${dir##*/}; keeping current version."
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

touch "$ZSHRC"

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

# Remove stale Powerlevel10k configuration from the requested setup.
sed -i '/p10k/d; /POWERLEVEL9K/d' "$ZSHRC"
rm -f "$REAL_HOME/.p10k.zsh"
rm -rf "$ZSH_CUSTOM/themes/powerlevel10k"

###############################################################################
# 8. Visual Studio Code
###############################################################################
log "Installing Visual Studio Code"

if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc

    sudo tee /etc/yum.repos.d/vscode.repo >/dev/null <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
fi

if rpm -q code >/dev/null 2>&1; then
    ok "Visual Studio Code already installed."
else
    sudo dnf install -y code
fi

###############################################################################
# 9. VS Code editor configuration
###############################################################################
log "Configuring VS Code as the default text editor"

if command -v gio >/dev/null 2>&1; then
    gio mime text/plain code.desktop || warn "Could not set text/plain MIME default."
fi

# Idempotent managed block: remove previous copy, then add exactly one.
sed -i \
    '/# BEGIN FEDORA-SETUP EDITOR/,/# END FEDORA-SETUP EDITOR/d' \
    "$ZSHRC"

cat >> "$ZSHRC" <<'EOF'

# BEGIN FEDORA-SETUP EDITOR
export EDITOR='code --wait'
export VISUAL="$EDITOR"

nano() {
    command code --wait "$@"
}
# END FEDORA-SETUP EDITOR
EOF

###############################################################################
# 10. NumLock
###############################################################################
log "Enabling NumLock for KDE and Plasma Login"

if command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kcminputrc --group Keyboard --key NumLock 0
else
    warn "kwriteconfig6 not found; skipping per-user KDE NumLock setting."
fi

sudo tee /etc/plasmalogin.conf >/dev/null <<'EOF'
[General]
Numlock=on
EOF

sudo mkdir -p /var/lib/plasmalogin/.config/kdedefaults
sudo tee /var/lib/plasmalogin/.config/kdedefaults/kcminputrc >/dev/null <<'EOF'
[Keyboard]
NumLock=0
EOF

###############################################################################
# 11. KDE cache and system tweaks
###############################################################################
log "Applying KDE/system tweaks"

if command -v kbuildsycoca6 >/dev/null 2>&1; then
    # Some third-party .desktop files can emit harmless parser warnings here.
    # Cache rebuild failure should not abort the entire setup.
    kbuildsycoca6 --noincremental || \
        warn "KDE cache rebuild reported a warning/error."
fi

sudo systemctl enable fstrim.timer >/dev/null 2>&1 || \
    warn "Could not enable fstrim.timer."

sudo timedatectl set-local-rtc 0 || \
    warn "Could not set RTC to UTC."

sudo systemctl disable NetworkManager-wait-online.service >/dev/null 2>&1 || true
sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop

###############################################################################
# 12. Journal limits
###############################################################################
log "Configuring systemd journal limits"

sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/limits.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF

sudo systemctl restart systemd-journald

###############################################################################
# 13. Maintenance
###############################################################################
log "Running maintenance"

sudo journalctl --vacuum-time=7d || warn "Journal vacuum reported a non-fatal issue."

if command -v flatpak >/dev/null 2>&1; then
    flatpak uninstall --unused -y || warn "Flatpak cleanup reported a non-fatal issue."
fi

sudo fstrim -av || warn "Manual fstrim reported a non-fatal issue."

###############################################################################
# 14. UEFI BootOrder
###############################################################################
log "Checking UEFI boot order"

if command -v efibootmgr >/dev/null 2>&1; then
    # Preserve the original behavior: select the first Windows Boot Manager.
    WIN="$(
        efibootmgr | awk '/Windows Boot Manager/ {
            gsub(/\*/, "", $1)
            sub(/^Boot/, "", $1)
            print $1
            exit
        }'
    )"

    if [[ -n "${WIN:-}" ]]; then
        ORDER="$(efibootmgr | awk -F'BootOrder: ' '/BootOrder/ {print $2; exit}')"

        if [[ -n "${ORDER:-}" ]]; then
            NEW_ORDER="$(
                printf '%s\n' "$ORDER" |
                    tr ',' '\n' |
                    grep -v "^${WIN}$" |
                    paste -sd, -
            )"

            FINAL="$WIN"
            [[ -n "$NEW_ORDER" ]] && FINAL="$WIN,$NEW_ORDER"

            if [[ "$ORDER" == "$FINAL" ]]; then
                ok "Windows Boot Manager is already first in BootOrder."
            else
                echo "Setting BootOrder to: $FINAL"
                sudo efibootmgr -o "$FINAL"
            fi
        else
            warn "Could not read current UEFI BootOrder."
        fi
    else
        warn "Windows Boot Manager not found; leaving BootOrder unchanged."
    fi
else
    warn "efibootmgr is not installed; skipping BootOrder adjustment."
fi

###############################################################################
# 15. Set Zsh as login shell WITHOUT a second password prompt
###############################################################################
log "Setting Zsh as the default shell"

ZSH_PATH="$(command -v zsh)"
CURRENT_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"

if [[ "$CURRENT_LOGIN_SHELL" == "$ZSH_PATH" ]]; then
    ok "Zsh is already the login shell for $REAL_USER."
else
    # chsh asks for the user's password separately. Since sudo is already
    # authenticated and kept alive, modify the passwd database through
    # usermod instead. This avoids the second password prompt.
    sudo usermod -s "$ZSH_PATH" "$REAL_USER"

    NEW_LOGIN_SHELL="$(getent passwd "$REAL_USER" | cut -d: -f7)"
    if [[ "$NEW_LOGIN_SHELL" == "$ZSH_PATH" ]]; then
        ok "Login shell changed to $ZSH_PATH."
    else
        die "Failed to change the login shell for $REAL_USER."
    fi
fi

###############################################################################
# Complete
###############################################################################
echo
echo "========================================"
echo " Fedora KDE setup complete!"
echo "========================================"
echo
echo "User     : $REAL_USER"
echo "Shell    : $ZSH_PATH"
echo "Theme    : robbyrussell"
echo "Plugins  : git, sudo, zsh-autosuggestions,"
echo "           zsh-syntax-highlighting, zsh-completions"
echo
echo "VS Code is configured as the text editor."
echo "NumLock is configured for KDE/Plasma Login."
echo
echo "Log out and log back in, or reboot, for the new login shell."
echo "========================================"