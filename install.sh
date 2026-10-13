#!/usr/bin/env bash
# ==============================================================================
# ULPM Official Universal Installer & Lifecycle Manager (v4.0.0)
# Supports: Rootless (~/.local/bin) & System-wide (/usr/local/bin)
#
# Usage:
#   ./install.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
# ==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "[X] This installer requires bash (try: curl -fsSL <url> | bash)" >&2
    exit 1
fi

set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD='\033[1m'
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    YELLOW='\033[1;33m'
    GRAY='\033[0;90m'
    NC='\033[0m'
else
    BOLD=''
    RED=''
    GREEN=''
    CYAN=''
    YELLOW=''
    GRAY=''
    NC=''
fi

info() { echo -e "${CYAN}::${NC} $*"; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
die()  { echo -e "${RED}[X] $*${NC}" >&2; exit 1; }

REPO="Ruraam/ulpm"
REF="${ULPM_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"
APT_REPO_URL="https://ruraam.github.io/ulpm"

print_banner() {
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 80)

    if [[ -n "${NO_COLOR:-}" || ! -t 1 || "$term_cols" -lt 80 ]]; then
        echo -e "\n=== ULPM (Universal Linux Package Manager Engine) ===\n"
        return 0
    fi

    clear
    echo -e "           \033[0;97m▐\033[0;96m██\033[0;97m \033[0;97m▐\033[0;96m██\033[0;97m▐\033[0;96m██\033[0;37m    \033[0;97m▐\033[0;96m█████▌\033[0;97m▐\033[0;96m███▄███▄\033[0m"
    echo -e "            \033[0;37m▐\033[0;97m██\033[0;37m \033[0;97m▐██\033[0;37m▐\033[0;97m██\033[0;37m    ▐\033[0;97m██\033[0;37m  \033[0;97;47m▐\033[0;97m█\033[0;37m▐\033[0;97m██\033[0;36m▐\033[0;97m█\033[0;97;47m▌\033[0;97m▐██\033[0m"
    echo -e "            \033[0;37m▐\033[0;37;46m  \033[0;37m ▐\033[0;37;46m  \033[0;37m▐\033[0;37;46m  \033[0;37m    ▐\033[0;37;46m  \033[0;36m██\033[0;37;46m \033[0;36m▌\033[0;37m▐\033[0;37;46m  \033[0;37m▐\033[0;36m█\033[0;90;46m▐\033[0;37m▐\033[0;37;46m  \033[0m"
    echo -e "           \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m    \033[0;94m▐\033[0;94;44m  \033[0;37m   \033[0;94m▐\033[0;94;44m  \033[0m"
    echo -e "           \033[0;97m▐\033[0;94m██████\033[0;96m▐\033[0;94m██████\033[0;96m▐\033[0;94m██\033[0;37m    \033[0;97m▐\033[0;94m██\033[0;37m   \033[0;97m▐\033[0;94m██\033[0m"
}

# ------------------------------------------------------------
# System checks
# ------------------------------------------------------------

[ "$(uname -s)" = "Linux" ] || die "ULPM only supports Linux operating systems."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >=4 is required (found ${BASH_VERSION})."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME is not set or not a directory."

ELEVATE=()
resolve_elevate() {
    if [ "$(id -u)" -eq 0 ]; then
        ELEVATE=()
    elif command -v sudo >/dev/null 2>&1; then
        ELEVATE=(sudo)
    elif command -v doas >/dev/null 2>&1; then
        ELEVATE=(doas)
    else
        die "Root privileges are required, but neither 'sudo' nor 'doas' was found."
    fi
}

priv() {
    if [ "${#ELEVATE[@]}" -gt 0 ]; then
        "${ELEVATE[@]}" "$@"
    else
        "$@"
    fi
}

confirm() {
    local prompt="$1" reply=""
    [ "${ASSUME_YES:-false}" = true ] && return 0
    if [ -t 0 ]; then
        printf '%b' "$prompt"
        read -r reply || reply=""
    elif [ -r /dev/tty ]; then
        printf '%b' "$prompt"
        read -r reply < /dev/tty || reply=""
    else
        return 1
    fi
    case "$reply" in
        [yY]|[yY][eE][sS]|[oO]|[oO][uU][iI]) return 0 ;;
        *) return 1 ;;
    esac
}

clean_path_file() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    local tmp
    tmp="$(mktemp)"
    awk '
    /# Added by ULPM installer/ { skip=1; next }
    /# Added by ULPM \(graphical sessions do not read ~\/.bashrc\)/ { skip=1; next }
    skip && /^[[:space:]]*export PATH=/ { skip=0; next }
    skip { skip=0 }
    { print }
    ' "$cfg" > "$tmp"
    cat "$tmp" > "$cfg"
    rm -f "$tmp"
}

# ------------------------------------------------------------
# APT Installation Path
# ------------------------------------------------------------

install_via_apt() {
    resolve_elevate
    info "Installing ULPM from official signed APT repository..."

    command -v curl >/dev/null 2>&1 || {
        info "curl is required to fetch GPG key, installing via apt..."
        priv apt-get update && priv env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
    }
    command -v gpg >/dev/null 2>&1 || {
        info "gpg is required to dearmor repository key, installing via apt..."
        priv apt-get update && priv env DEBIAN_FRONTEND=noninteractive apt-get install -y gnupg
    }

    info "Importing official repository signing key..."
    priv mkdir -p /usr/share/keyrings
    curl -fsSL --proto '=https' --retry 2 "$APT_REPO_URL/KEY.gpg" | gpg --dearmor | priv tee /usr/share/keyrings/ulpm.gpg >/dev/null \
        || die "Failed to download and dearmor the ULPM repository signing key."
    priv chmod 0644 /usr/share/keyrings/ulpm.gpg

    info "Configuring APT source list..."
    priv mkdir -p /etc/apt/sources.list.d
    echo "deb [signed-by=/usr/share/keyrings/ulpm.gpg] $APT_REPO_URL stable main" | priv tee /etc/apt/sources.list.d/ulpm.list >/dev/null

    info "Updating APT cache..."
    priv apt-get update || die "Failed to update apt cache from ULPM repository."

    info "Installing ulpm deb package..."
    priv env DEBIAN_FRONTEND=noninteractive apt-get install -y ulpm || die "Failed to install ulpm via apt."

    provision_default_keys

    echo
    echo -e "${GREEN}✔ ULPM engine successfully installed via APT!${NC}"
    echo -e "  Binary: ${BOLD}/usr/bin/ulpm${NC} (or system configured path)"
    echo -e "\nGet started with: ${BOLD}ulpm help${NC}"
    exit 0
}

# ------------------------------------------------------------
# Arguments & Interactive Menu
# ------------------------------------------------------------

MODE="auto"
BIN_DIR=""
ASSUME_YES=false
INSTALL_DEPS=true
INTEGRATE=true
UNINSTALL=false
USE_APT=false

print_banner

while [ $# -gt 0 ]; do
    case "$1" in
        --apt)          USE_APT=true ;;
        --user)         MODE="user" ;;
        --system)       MODE="system" ;;
        --bin-dir)      shift; BIN_DIR="${1:?--bin-dir needs a directory}" ;;
        --ref)          shift; REF="${1:?--ref needs a value}" ;;
        -y|--yes)       ASSUME_YES=true ;;
        --no-deps)      INSTALL_DEPS=false ;;
        --no-integrate) INTEGRATE=false ;;
        --uninstall)    UNINSTALL=true ;;
        -h|--help)
            echo "Usage: ./install.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --apt           Install via official signed APT repository (Debian/Ubuntu)"
            echo "  --user          Install in user home directory (~/.local)"
            echo "  --system        Install system-wide (/usr/local, requires root)"
            echo "  --bin-dir DIR   Custom binary directory"
            echo "  --ref REF       GitHub branch/tag to download from (default: main)"
            echo "  -y, --yes       Assume yes to all prompts"
            echo "  --no-deps       Do not attempt to install missing host dependencies"
            echo "  --no-integrate  Skip desktop MIME and launcher configuration"
            echo "  --uninstall     Completely remove ULPM from system and user profiles"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"

if [ "$USE_APT" = true ]; then
    command -v apt-get >/dev/null 2>&1 || die "Option --apt specified, but 'apt-get' was not found on this system."
    install_via_apt
fi

if [ "$MODE" = "auto" ] && [ "$UNINSTALL" = false ]; then
    TTY_IN=""
    if [ -t 0 ]; then
        TTY_IN="-"
    elif [ -r /dev/tty ]; then
        TTY_IN="/dev/tty"
    fi

    if [ -n "$TTY_IN" ]; then
        HAS_APT=false
        command -v apt-get >/dev/null 2>&1 && HAS_APT=true

        echo
        echo -e "${BOLD}${CYAN}ULPM — Universal Linux Package Manager Engine${NC}"
        echo "  1) Rootless installation (User: ~/.local/bin)"
        echo "  2) System-wide installation (Root: /usr/local/bin)"
        if [ "$HAS_APT" = true ]; then
            echo "  3) Official signed APT repository (Debian/Ubuntu system-wide)"
            echo "  4) Clean uninstallation"
            echo "  5) Exit"
            echo
            printf "Choice [1-5] : "
        else
            echo "  1) Rootless installation (User: ~/.local/bin)"
            echo "  2) System-wide installation (Root: /usr/local/bin)"
            echo "  3) Clean uninstallation"
            echo "  4) Exit"
            echo
            printf "Choice [1-4] : "
        fi

        choice=""
        if [ "$TTY_IN" = "-" ]; then
            read -r choice || choice=""
        else
            read -r choice < /dev/tty || choice=""
        fi

        if [ "$HAS_APT" = true ]; then
            case "$choice" in
                1) MODE="user" ;;
                2) MODE="system" ;;
                3) install_via_apt ;;
                4) UNINSTALL=true ;;
                5) info "Aborted by user."; exit 0 ;;
                *) die "Invalid choice: $choice" ;;
            esac
        else
            case "$choice" in
                1) MODE="user" ;;
                2) MODE="system" ;;
                3) UNINSTALL=true ;;
                4) info "Aborted by user."; exit 0 ;;
                *) die "Invalid choice: $choice" ;;
            esac
        fi
    else
        MODE="user"
    fi
fi

# ------------------------------------------------------------
# Complete Uninstallation Logic
# ------------------------------------------------------------

uninstall_ulpm() {
    local user_bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

    local xdg_path
    for xdg_path in "$data_home" "$cache_home" "$config_home"; do
        case "$xdg_path" in
            /*) ;;
            *) die "Refusing uninstall: XDG directory is not absolute: $xdg_path" ;;
        esac
        [ "$xdg_path" != "/" ] || die "Refusing uninstall: an XDG directory resolves to /"
    done

    echo
    echo -e "${YELLOW}This operation will remove ULPM, its libraries, installed apps and keys.${NC}"
    echo

    if ! confirm "Confirm complete uninstallation of ULPM? [y/N]: "; then
        info "Uninstallation cancelled."
        return 0
    fi

    local targets=("$user_bin/ulpm" "/usr/local/bin/ulpm")
    if [ -n "$BIN_DIR" ]; then
        case "$BIN_DIR" in
            /*) targets+=("$BIN_DIR/ulpm") ;;
            *) warn "Ignoring non-absolute custom BIN_DIR during uninstall: $BIN_DIR" ;;
        esac
    fi
    local lib_dirs=("$HOME/.local/lib/ulpm" "/usr/local/lib/ulpm" "$data_home/ulpm/engine" "$data_home/ulpm/lib")

    local path
    for path in "${targets[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            if [ -w "$(dirname "$path")" ]; then
                rm -f -- "$path"
            else
                resolve_elevate
                priv rm -f -- "$path"
            fi
            info "Removed binary: $path"
        fi
    done

    local dir
    for dir in "${lib_dirs[@]}"; do
        if [ -d "$dir" ]; then
            if [ -w "$(dirname "$dir")" ]; then
                rm -rf -- "$dir"
            else
                resolve_elevate
                priv rm -rf -- "$dir"
            fi
            info "Removed libraries: $dir"
        fi
    done

    for path in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
        clean_path_file "$path"
    done
    rm -f "$config_home/fish/conf.d/ulpm.fish" "$config_home/environment.d/60-ulpm.conf"
    rm -f "$data_home/applications/ulpm-open.desktop" "$data_home/applications/ulpm-handler.desktop" "$data_home/mime/packages/application-x-lpk.xml"
    rm -f -- "$data_home/bash-completion/completions/ulpm" 2>/dev/null || true
    if [ -e /usr/local/share/bash-completion/completions/ulpm ]; then
        if [ -w /usr/local/share/bash-completion/completions ]; then
            rm -f -- /usr/local/share/bash-completion/completions/ulpm
        else
            resolve_elevate
            priv rm -f -- /usr/local/share/bash-completion/completions/ulpm
        fi
    fi
    find "$data_home/applications" -maxdepth 1 -type f -name 'io.lpk.*.desktop' -delete 2>/dev/null || true
    find "$data_home/icons/hicolor/256x256/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true
    find "$data_home/icons/hicolor/512x512/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true

    local sys_path
    for sys_path in /usr/local/share/applications/ulpm-open.desktop /usr/local/share/applications/ulpm-handler.desktop /usr/local/share/mime/packages/application-x-lpk.xml; do
        if [ -e "$sys_path" ]; then
            if [ -w "$(dirname "$sys_path")" ]; then
                rm -f -- "$sys_path"
            else
                resolve_elevate
                priv rm -f -- "$sys_path"
            fi
            info "Removed: $sys_path"
        fi
    done

    local sys_cfg
    for sys_cfg in /etc/xdg/mimeapps.list /usr/local/share/applications/mimeapps.list; do
        if [ -f "$sys_cfg" ] && grep -q '^application/x-lpk=' "$sys_cfg" 2>/dev/null; then
            if [ -w "$sys_cfg" ]; then
                sed -i '/^application\/x-lpk=/d' "$sys_cfg" 2>/dev/null || true
            else
                resolve_elevate
                priv sed -i '/^application\/x-lpk=/d' "$sys_cfg" 2>/dev/null || true
            fi
            info "Cleaned default-app mapping in: $sys_cfg"
        fi
    done

    for path in "$config_home/mimeapps.list" "$data_home/applications/mimeapps.list"; do
        [ -f "$path" ] && sed -i '/^application\/x-lpk=/d' "$path" 2>/dev/null || true
    done

    if [ -d "$config_home/ulpm" ]; then
        if confirm "Back up your ULPM config and signing keys to \$HOME before removal? [y/N]: "; then
            local key_backup
            key_backup="$HOME/ulpm-config-backup-$(date +%Y%m%d-%H%M%S)"
            if mkdir -p "$key_backup" && chmod 700 "$key_backup" && cp -a "$config_home/ulpm/." "$key_backup/"; then
                info "Config and keys backed up to: $key_backup"
            else
                warn "Backup failed."
            fi
        fi
    fi

    rm -rf -- "$data_home/ulpm" "$cache_home/ulpm" "$config_home/ulpm"

    command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$data_home/mime" >/dev/null 2>&1 || true
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true

    echo -e "\n${GREEN}✔ ULPM has been completely uninstalled.${NC}"
}

if [ "$UNINSTALL" = true ]; then
    uninstall_ulpm
    exit 0
fi

# ------------------------------------------------------------
# Host Dependencies Check
# ------------------------------------------------------------

PM=""
for pm in apt-get pacman dnf zypper apk xbps-install; do
    if command -v "$pm" >/dev/null 2>&1; then PM="$pm"; break; fi
done

pkg_for() {
    local cmd="$1"
    case "$cmd" in
        flock)          echo "util-linux" ;;
        squashfuse)     echo "squashfuse" ;;
        mksquashfs)
            case "$PM" in
                zypper) echo "squashfs" ;;
                *)      echo "squashfs-tools" ;;
            esac
            ;;
        bwrap)          echo "bubblewrap" ;;
        fuse3)          echo "fuse3" ;;
        xdg-dbus-proxy) echo "xdg-dbus-proxy" ;;
        cmp)            echo "diffutils" ;;
        readelf)        echo "binutils" ;;
        dpkg-deb)       echo "dpkg" ;;
        od|truncate|tail|head|dd|realpath|mktemp) echo "coreutils" ;;
        find)           echo "findutils" ;;
        awk)            echo "gawk" ;;
        tar)            echo "tar" ;;
        *)              echo "$cmd" ;;
    esac
}

REQUIRED_CMDS=(
    flock
    squashfuse
    mksquashfs
    bwrap
    jq
    file
    curl
    openssl
    cmp
    od
    truncate
    tail
    head
    dd
    realpath
    mktemp
    find
    awk
    tar
    readelf
)

MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || MISSING+=("fuse3")

if [ "${#MISSING[@]}" -gt 0 ]; then
    warn "Missing tools: ${MISSING[*]}"
    if [ "$INSTALL_DEPS" = true ] && [ -n "$PM" ]; then
        if confirm "${BOLD}Install missing packages automatically with $PM? [y/N]:${NC}"; then
            PKGS=()
            for c in "${MISSING[@]}"; do
                p="$(pkg_for "$c")"
                case " ${PKGS[*]-} " in *" $p "*);; *) PKGS+=("$p") ;; esac
            done
            resolve_elevate
            set +e
            pkg_rc=0
            case "$PM" in
                apt-get)      priv apt-get update && priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" ;;
                pacman)       priv pacman -S --needed --noconfirm "${PKGS[@]}" ;;
                dnf)          priv dnf install -y "${PKGS[@]}" ;;
                zypper)       priv zypper --non-interactive install "${PKGS[@]}" ;;
                apk)          priv apk add "${PKGS[@]}" ;;
                xbps-install) priv xbps-install -Sy "${PKGS[@]}" ;;
            esac
            pkg_rc=$?
            set -e
            [ "$pkg_rc" -eq 0 ] || warn "Automatic package installation failed (exit $pkg_rc). Install manually: ${PKGS[*]}"
        fi
    elif [ -z "$PM" ]; then
        warn "No supported package manager detected."
        info "Please install missing packages manually: ${MISSING[*]}"
    fi
fi

# ------------------------------------------------------------
# Deployment Paths & Validation
# ------------------------------------------------------------

NEED_PRIV=false
if [ "$MODE" = "system" ]; then
    BIN_DIR="${BIN_DIR:-/usr/local/bin}"
    LIB_DIR="/usr/local/lib/ulpm"
    [ "$(id -u)" -ne 0 ] && NEED_PRIV=true
else
    BIN_DIR="${BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
    LIB_DIR="$HOME/.local/lib/ulpm"
fi

[ "$NEED_PRIV" = true ] && resolve_elevate

case "$BIN_DIR" in
    /*) ;;
    *) die "Binary directory must be an absolute path: $BIN_DIR" ;;
esac
case "$BIN_DIR" in
    "/"|"/usr"|"/usr/local"|"/bin"|"/sbin"|"/etc"|"/home"|"/root"|"/var"|"/tmp")
        die "Refusing unsafe binary directory: $BIN_DIR" ;;
esac
case "$BIN_DIR" in
    *$'\n'*|*$'\r'*|*:*) die "Binary directory contains an unsafe character (newline or colon)." ;;
esac

info "Installing ULPM to ${BOLD}$BIN_DIR/ulpm${NC} (Modules: ${BOLD}$LIB_DIR${NC})..."

# ------------------------------------------------------------
# Atomic Deployment with Rollback Support
# ------------------------------------------------------------

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ulpm-install.XXXXXX")"
BACKUP_DIR="$TMP_DIR/backups"
mkdir -p "$BACKUP_DIR"
DEPLOYMENT_STARTED=false
DEPLOYMENT_COMMITTED=false
BACKUP_TARGETS=()
BACKUP_FILES=()

rollback_deployment() {
    local i target backup
    for ((i=${#BACKUP_TARGETS[@]}-1; i>=0; i--)); do
        target="${BACKUP_TARGETS[$i]}"
        backup="${BACKUP_FILES[$i]}"
        if [ "$NEED_PRIV" = true ]; then
            priv rm -f -- "$target" 2>/dev/null || true
            if [ -e "$backup" ] || [ -L "$backup" ]; then
                priv mkdir -p "$(dirname "$target")" 2>/dev/null || true
                priv cp -a -- "$backup" "$target" 2>/dev/null || warn "Could not restore $target automatically."
            fi
        else
            rm -f -- "$target" 2>/dev/null || true
            if [ -e "$backup" ] || [ -L "$backup" ]; then
                mkdir -p "$(dirname "$target")" 2>/dev/null || true
                cp -a -- "$backup" "$target" 2>/dev/null || warn "Could not restore $target automatically."
            fi
        fi
    done
}

cleanup_install() {
    local rc=$?
    if [ "$DEPLOYMENT_STARTED" = true ] && [ "$DEPLOYMENT_COMMITTED" = false ]; then
        warn "Installation did not finish; restoring previous ULPM files..."
        rollback_deployment
    fi
    rm -rf -- "$TMP_DIR"
    exit "$rc"
}
trap cleanup_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Fetch or Copy Modules
# ------------------------------------------------------------

MODULES=(
    "utils.sh"
    "crypto.sh"
    "sandbox.sh"
    "pack.sh"
    "deb.sh"
    "run.sh"
    "stream.sh"
    "manage.sh"
)

mkdir -p "$TMP_DIR/lib"
FETCHED=()

LOCAL_MAIN=""
if [ -f "./bin/ulpm" ]; then
    LOCAL_MAIN="./bin/ulpm"
elif [ -f "./ulpm" ]; then
    LOCAL_MAIN="./ulpm"
fi
LOCAL_TREE=true
[ -n "$LOCAL_MAIN" ] || LOCAL_TREE=false
for m in "${MODULES[@]}"; do
    [ -f "./lib/$m" ] || LOCAL_TREE=false
done

if [ "$LOCAL_TREE" = true ]; then
    cp -- "$LOCAL_MAIN" "$TMP_DIR/ulpm"
    for m in "${MODULES[@]}"; do
        cp -- "./lib/$m" "$TMP_DIR/lib/$m"
    done
else
    info "Fetching ULPM engine and modules from $BASE_URL..."
    curl -fL --proto '=https' --progress-bar --retry 2 "$BASE_URL/bin/ulpm" -o "$TMP_DIR/ulpm" \
        || die "Failed to download bin/ulpm from GitHub ($BASE_URL/bin/ulpm)"
    FETCHED+=("bin/ulpm")
    for m in "${MODULES[@]}"; do
        curl -fL --proto '=https' --progress-bar --retry 2 "$BASE_URL/lib/$m" -o "$TMP_DIR/lib/$m" \
            || die "Failed to download lib/$m from GitHub ($BASE_URL/lib/$m)"
        FETCHED+=("lib/$m")
    done
fi

# ------------------------------------------------------------
# Checksum Verification
# ------------------------------------------------------------

if [ "${#FETCHED[@]}" -gt 0 ]; then
    if ! command -v sha256sum >/dev/null 2>&1; then
        warn "sha256sum not found: integrity of downloaded files not verified."
    elif curl -fsSL --proto '=https' --retry 2 "$BASE_URL/SHA256SUMS" -o "$TMP_DIR/SHA256SUMS" 2>/dev/null; then
        info "Verifying checksums (SHA256SUMS)..."
        for f in "${FETCHED[@]}"; do
            expected="$(awk -v f="$f" '{n = $2; sub(/^\*/, "", n); if (n == f || n == "./" f){ print $1; exit } }' "$TMP_DIR/SHA256SUMS")"
            target_local=""
            if [ -f "$TMP_DIR/$f" ]; then
                target_local="$TMP_DIR/$f"
            elif [ -f "$TMP_DIR/${f#bin/}" ]; then
                target_local="$TMP_DIR/${f#bin/}"
            elif [ -f "$TMP_DIR/${f##*/}" ]; then
                target_local="$TMP_DIR/${f##*/}"
            fi

            [ -n "$target_local" ] && [ -f "$target_local" ] || die "Internal error locating: $f"
            actual="$(sha256sum "$target_local" | awk '{ print $1 }')"

            if [ -z "$expected" ]; then
                die "No checksum entry for $f in SHA256SUMS."
            elif [ "$expected" != "$actual" ]; then
                die "Checksum mismatch for $f."
            fi
        done
    fi
fi

# ------------------------------------------------------------
# Syntax Validation
# ------------------------------------------------------------

info "Performing syntax checks..."
bash -n "$TMP_DIR/ulpm" || die "Syntax error detected in ulpm executable!"
for m in "${MODULES[@]}"; do
    bash -n "$TMP_DIR/lib/$m" || die "Syntax error detected in module lib/$m!"
done

# ------------------------------------------------------------
# Atomic Deployment
# ------------------------------------------------------------

DEPLOYMENT_STARTED=true

install_managed_file() {
    local source="$1" target="$2" mode="$3" backup=""
    if [ -e "$target" ] || [ -L "$target" ]; then
        backup="$BACKUP_DIR/$(printf '%04d' "${#BACKUP_TARGETS[@]}")"
        if [ "$NEED_PRIV" = true ]; then
            priv cp -a -- "$target" "$backup"
        else
            cp -a -- "$target" "$backup"
        fi
        BACKUP_TARGETS+=("$target")
        BACKUP_FILES+=("$backup")
    else
        BACKUP_TARGETS+=("$target")
        BACKUP_FILES+=("")
    fi
    if [ "$NEED_PRIV" = true ]; then
        priv mkdir -p -- "$(dirname "$target")"
        priv install -m "$mode" "$source" "$target"
    else
        mkdir -p -- "$(dirname "$target")"
        install -m "$mode" "$source" "$target"
    fi
}

install_managed_file "$TMP_DIR/ulpm" "$BIN_DIR/ulpm" 0755
for m in "${MODULES[@]}"; do
    install_managed_file "$TMP_DIR/lib/$m" "$LIB_DIR/$m" 0644
done
DEPLOYMENT_COMMITTED=true

# ------------------------------------------------------------
# Shell Environment & PATH
# ------------------------------------------------------------

add_path_line() {
    local cfg="$1"
    mkdir -p "$(dirname "$cfg")"
    touch "$cfg"
    if ! grep -qF "$BIN_DIR" "$cfg" 2>/dev/null; then
        {
            echo ""
            echo "# Added by ULPM installer"
            echo "export PATH=\"$BIN_DIR:\$PATH\""
        } >> "$cfg"
    fi
}

RELOAD_HINT=""
USER_SHELL_NAME="${SHELL:-}"
USER_SHELL_NAME="${USER_SHELL_NAME##*/}"

if [ "$MODE" = "user" ]; then
    case "$USER_SHELL_NAME" in
        fish)
            cfg="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/ulpm.fish"
            mkdir -p "$(dirname "$cfg")"
            echo "fish_add_path -g \"$BIN_DIR\"" > "$cfg"
            ;;
        zsh)  add_path_line "$HOME/.zshrc" ;;
        bash) add_path_line "$HOME/.bashrc" ;;
        *)    add_path_line "$HOME/.profile" ;;
    esac
    add_path_line "$HOME/.profile"

    envd="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/60-ulpm.conf"
    mkdir -p "$(dirname "$envd")"
    printf 'PATH=%s:${PATH}\n' "$BIN_DIR" > "$envd"

    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *)
            RELOAD_HINT="$BIN_DIR is not yet in your PATH for this terminal session."
            ;;
    esac
fi

# ------------------------------------------------------------
# Shell Auto-Completion
# ------------------------------------------------------------

setup_shell_completion() {
    local comp_target_dir
    if [ "$MODE" = "system" ]; then
        comp_target_dir="/usr/local/share/bash-completion/completions"
    else
        comp_target_dir="${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions"
    fi

    info "Setting up shell auto-completion..."

    local comp_file="$TMP_DIR/ulpm_completion.bash"
    cat <<'EOF' > "$comp_file"
# ==============================================================================
# ULPM Bash/Zsh Completion Engine
# ==============================================================================

_ulpm_completions() {
    local cur prev words cword
    _init_completion -n = 2>/dev/null || {
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    }

    local commands="run stream pack deb-pack install remove search list inspect doctor keygen verify sign trust token self-update upgrade clean integrate completion help version"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return 0
    fi

    case "$prev" in
        run|remove|rm|inspect|info)
            local db_file="${ULPM_DB:-$HOME/.local/share/ulpm/installed.db}"
            local installed_apps=""
            if [[ -s "$db_file" ]]; then
                installed_apps="$(awk -F'|' '{print $2}' "$db_file" 2>/dev/null)"
            fi
            COMPREPLY=($(compgen -W "$installed_apps" -- "$cur"))
            ;;
        install|verify|sign)
            COMPREPLY=($(compgen -f -X '!*.lpk' -- "$cur") $(compgen -d -- "$cur"))
            ;;
        deb-pack)
            COMPREPLY=($(compgen -f -X '!*.deb' -- "$cur") $(compgen -d -- "$cur"))
            ;;
        doctor|keygen|clean|list|self-update|upgrade|integrate|completion)
            COMPREPLY=()
            ;;
        *)
            COMPREPLY=($(compgen -f -- "$cur"))
            ;;
    esac
}

complete -F _ulpm_completions ulpm
EOF

    if [ "$NEED_PRIV" = true ]; then
        priv mkdir -p "$comp_target_dir"
        priv install -m 0644 "$comp_file" "$comp_target_dir/ulpm"
    else
        mkdir -p "$comp_target_dir"
        install -m 0644 "$comp_file" "$comp_target_dir/ulpm"
    fi
}

setup_shell_completion

# ------------------------------------------------------------
# Desktop & MIME Integration
# ------------------------------------------------------------

setup_desktop_integration() {
    local target_data target_config
    if [ "$MODE" = "system" ]; then
        target_data="/usr/local/share"
        target_config="/etc/xdg"
    else
        target_data="${XDG_DATA_HOME:-$HOME/.local/share}"
        target_config="${XDG_CONFIG_HOME:-$HOME/.config}"
    fi

    info "Configuring OS Desktop / MIME association..."

    local mime_dir="$target_data/mime/packages"
    local apps_dir="$target_data/applications"

    if [ "$NEED_PRIV" = true ]; then
        priv mkdir -p "$mime_dir" "$apps_dir"
    else
        mkdir -p "$mime_dir" "$apps_dir"
    fi

    local mime_file="$TMP_DIR/application-x-lpk.xml"
    cat <<'EOF' > "$mime_file"
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
    <mime-type type="application/x-lpk">
        <comment>ULPM Package Bundle</comment>
        <comment xml:lang="fr">Paquet d'application ULPM</comment>
        <icon name="package-x-generic"/>
        <glob pattern="*.lpk"/>
    </mime-type>
</mime-info>
EOF

    local desktop_file="$TMP_DIR/ulpm-handler.desktop"
    cat <<EOF > "$desktop_file"
[Desktop Entry]
Type=Application
Name=ULPM Package Handler
Comment=Install and integrate sandboxed .lpk applications
Exec=$BIN_DIR/ulpm install %f
Icon=package-x-generic
Terminal=false
NoDisplay=true
MimeType=application/x-lpk;
Categories=System;Utility;
EOF

    if [ "$NEED_PRIV" = true ]; then
        priv install -m 0644 "$mime_file" "$mime_dir/application-x-lpk.xml"
        priv install -m 0644 "$desktop_file" "$apps_dir/ulpm-handler.desktop"
    else
        install -m 0644 "$mime_file" "$mime_dir/application-x-lpk.xml"
        install -m 0644 "$desktop_file" "$apps_dir/ulpm-handler.desktop"
    fi

    local mimeapps_list="$target_config/mimeapps.list"
    if [ "$NEED_PRIV" = true ]; then
        priv mkdir -p "$target_config"
        priv touch "$mimeapps_list"
        if ! grep -q "application/x-lpk=" "$mimeapps_list" 2>/dev/null; then
            if grep -q "\[Default Applications\]" "$mimeapps_list" 2>/dev/null; then
                priv sed -i '/\[Default Applications\]/a application\/x-lpk=ulpm-handler.desktop;' "$mimeapps_list"
            else
                printf "\n[Default Applications]\napplication/x-lpk=ulpm-handler.desktop;\n" | priv tee -a "$mimeapps_list" >/dev/null
            fi
        fi
    else
        mkdir -p "$target_config"
        touch "$mimeapps_list"
        if ! grep -q "application/x-lpk=" "$mimeapps_list" 2>/dev/null; then
            if grep -q "\[Default Applications\]" "$mimeapps_list" 2>/dev/null; then
                sed -i '/\[Default Applications\]/a application\/x-lpk=ulpm-handler.desktop;' "$mimeapps_list"
            else
                printf "\n[Default Applications]\napplication/x-lpk=ulpm-handler.desktop;\n" >> "$mimeapps_list"
            fi
        fi
    fi

    if command -v update-mime-database >/dev/null 2>&1; then
        if [ "$NEED_PRIV" = true ]; then
            priv update-mime-database "$target_data/mime" >/dev/null 2>&1 || true
        else
            update-mime-database "$target_data/mime" >/dev/null 2>&1 || true
        fi
    fi

    if command -v update-desktop-database >/dev/null 2>&1; then
        if [ "$NEED_PRIV" = true ]; then
            priv update-desktop-database "$target_data/applications" >/dev/null 2>&1 || true
        else
            update-desktop-database "$target_data/applications" >/dev/null 2>&1 || true
        fi
    fi
}

if [ "$INTEGRATE" = true ]; then
    setup_desktop_integration
fi

# ------------------------------------------------------------
# Crypto Key Provisioning
# ------------------------------------------------------------

provision_default_keys() {
    local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ulpm"
    local keys_dir="$config_dir/keys"
    local trusted_dir="$config_dir/trusted_keys"
    local priv_key="$keys_dir/default.priv"
    local pub_key="$keys_dir/default.pub"
    local trusted_pub="$trusted_dir/default.pub"

    if [ ! -f "$priv_key" ] || [ ! -f "$pub_key" ]; then
        info "Initializing local Ed25519 cryptographic authority..."
        ( umask 077 && mkdir -p "$keys_dir" "$trusted_dir" )
        if command -v openssl >/dev/null 2>&1; then
            if [ ! -f "$priv_key" ]; then
                ( umask 077; openssl genpkey -algorithm Ed25519 -out "$priv_key" 2>/dev/null ) \
                    || warn "Failed to generate Ed25519 private key ($priv_key)."
            fi
            chmod 600 "$priv_key" 2>/dev/null || true
            if [ -f "$priv_key" ]; then
                openssl pkey -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null \
                    || warn "Failed to derive public key ($pub_key)."
                chmod 644 "$pub_key" 2>/dev/null || true
                cp -f -- "$pub_key" "$trusted_pub" 2>/dev/null || true
            fi
        fi
    fi
}

provision_default_keys

# ------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------

echo
echo -e "${GREEN}✔ ULPM engine successfully installed!${NC}"
echo -e "  Binary: ${BOLD}$BIN_DIR/ulpm${NC}"
echo -e "  Libraries: ${GRAY}$LIB_DIR${NC}"

if [ -n "$RELOAD_HINT" ]; then
    echo
    warn "$RELOAD_HINT"
    case "$USER_SHELL_NAME" in
        fish)  echo -e "  >> Run: ${BOLD}set -U fish_user_paths $BIN_DIR"'$fish_user_paths'"${NC}" ;;
        zsh)   echo -e "  >> Run: ${BOLD}source ~/.zshrc${NC} (or restart terminal)" ;;
        *)     echo -e "  >> Run: ${BOLD}source ~/.bashrc${NC} (or restart terminal)" ;;
    esac
fi

echo -e "\nGet started with: ${BOLD}ulpm help${NC}"
