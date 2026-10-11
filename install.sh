#!/usr/bin/env bash
#
# ULPM Official Installer (Modular v4.0.0)
# Supports rootless (~/.local/bin) and system-wide (/usr/local/bin)
#
# Usage:
#   ./install.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
#

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
    BOLD='' RED='' GREEN='' CYAN='' YELLOW='' GRAY='' NC=''
fi

info() { echo -e "${CYAN}::${NC} $*"; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
die()  { echo -e "${RED}[X] $*${NC}" >&2; exit 1; }

if ! command -v curl >/dev/null 2>&1 && { [ ! -f "./bin/ulpm" ] && [ ! -f "./ulpm" ]; }; then
    die "curl is required to download components. Please install it first (e.g. sudo apt install curl)."
fi

print_banner() {
    local term_cols
    term_cols=$(tput cols 2>/dev/null || echo 80)

    if [[ -n "${NO_COLOR:-}" || ! -t 1 || "$term_cols" -lt 80 ]]; then
        echo -e "\n=== ULPM (Universal Linux Package Manager v4.0.0) ===\n"
        return 0
    fi

    clear
    echo -e "              \033[0;97m▐\033[0;96m██\033[0;37m \033[0;97m▐\033[0;96m██\033[0;97m▐\033[0;96m██\033[0;37m    \033[0;97m▐\033[0;96m█████▌\033[0;97m▐\033[0;96m███▄███▄\033[0m"
    echo -e "              \033[0;37m▐\033[0;97m██\033[0;37m \033[0;97m▐██\033[0;37m▐\033[0;97m██\033[0;37m    ▐\033[0;97m██\033[0;37m  \033[0;97;47m▐\033[0;97m█\033[0;37m▐\033[0;97m██\033[0;36m▐\033[0;97m█\033[0;97;47m▌\033[0;97m▐██\033[0m"
    echo -e "              \033[0;37m▐\033[0;37;46m  \033[0;37m ▐\033[0;37;46m  \033[0;37m▐\033[0;37;46m  \033[0;37m    ▐\033[0;37;46m  \033[0;36m██\033[0;37;46m \033[0;36m▌\033[0;37m▐\033[0;37;46m  \033[0;37m▐\033[0;36m█\033[0;90;46m▐\033[0;37m▐\033[0;37;46m  \033[0m"
    echo -e "              \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m    \033[0;94m▐\033[0;94;44m  \033[0;37m   \033[0;94m▐\033[0;94;44m  \033[0m"
    echo -e "              \033[0;97m▐\033[0;94m██████\033[0;96m▐\033[0;94m██████\033[0;96m▐\033[0;94m██\033[0;37m    \033[0;97m▐\033[0;94m██\033[0;37m   \033[0;97m▐\033[0;94m██\033[0m"
}

REPO="Ruraam/ulpm"
REF="${ULPM_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"

# ------------------------------------------------------------
# Arguments & Menu
# ------------------------------------------------------------

MODE="auto"
BIN_DIR=""
ASSUME_YES=false
INSTALL_DEPS=true
INTEGRATE=true
UNINSTALL=false

print_banner

while [ $# -gt 0 ]; do
    case "$1" in
        --user)         MODE="user" ;;
        --system)       MODE="system" ;;
        --bin-dir)      shift; BIN_DIR="${1:?--bin-dir needs a directory}" ;;
        --ref)          shift; REF="${1:?--ref needs a value}" ;;
        -y|--yes)       ASSUME_YES=true ;;
        --no-deps)      INSTALL_DEPS=false ;;
        --no-integrate) INTEGRATE=false ;;
        --uninstall)    UNINSTALL=true ;;
        -h|--help)
            echo "Usage: ./install.sh [--user|--system] [-y] [--uninstall]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

if [ "$MODE" = "auto" ] && [ "$UNINSTALL" = false ]; then
    TTY_IN=""
    if [ -t 0 ]; then
        TTY_IN="-"
    elif [ -r /dev/tty ]; then
        TTY_IN="/dev/tty"
    fi

    if [ -n "$TTY_IN" ]; then
        echo
        echo -e "${BOLD}${CYAN}ULPM — Universal Linux Package Manager (LPK Engine v4.0.0)${NC}"
        echo "  1) Rootless installation (User: ~/.local/bin)"
        echo "  2) System-wide installation (Root: /usr/local/bin)"
        echo "  3) Clean uninstallation"
        echo "  4) Exit"
        echo
        printf "Choice [1-4] : "
        if [ "$TTY_IN" = "-" ]; then
            read -r choice || choice=""
        else
            read -r choice < /dev/tty || choice=""
        fi

        case "$choice" in
            1) MODE="user" ;;
            2) MODE="system" ;;
            3) UNINSTALL=true ;;
            4) info "Aborted by user."; exit 0 ;;
            *) die "Invalid choice: $choice" ;;
        esac
    else
        MODE="user"
    fi
fi

# ------------------------------------------------------------
# System checks
# ------------------------------------------------------------

[ "$(uname -s)" = "Linux" ] || die "ULPM only supports Linux."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required (found ${BASH_VERSION})."
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
    [ "$ASSUME_YES" = true ] && return 0
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
# Uninstall
# ------------------------------------------------------------

uninstall_ulpm() {
    local user_bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"

    echo
    echo -e "${YELLOW}This operation will remove ULPM, its libraries, installed apps and keys.${NC}"
    echo "Sandbox app storage in ~/.var/app will be preserved."
    echo

    if ! confirm "Confirm complete uninstallation of ULPM? [y/N]: "; then
        info "Uninstallation cancelled."
        return 0
    fi

    local targets=("$user_bin/ulpm" "/usr/local/bin/ulpm")
    local lib_dirs=("$HOME/.local/lib/ulpm" "/usr/local/lib/ulpm" "$data_home/ulpm/engine")

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
    rm -f "$data_home/applications/ulpm-open.desktop" "$data_home/mime/packages/application-x-lpk.xml"
    find "$data_home/applications" -maxdepth 1 -type f -name 'ulpm-*.desktop' -delete 2>/dev/null || true
    find "$data_home/icons/hicolor/512x512/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true

    for path in "$config_home/mimeapps.list" "$data_home/applications/mimeapps.list"; do
        [ -f "$path" ] && sed -i '/^application\/x-lpk=ulpm-open\.desktop;/d' "$path" 2>/dev/null || true
    done

    rm -rf -- "$data_home/ulpm" "$cache_home/ulpm" "$config_home/ulpm"

    command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$data_home/mime" >/dev/null 2>&1 || true
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true

    echo -e "${GREEN}✔ ULPM has been completely uninstalled.${NC}"
}

if [ "$UNINSTALL" = true ]; then
    uninstall_ulpm
    exit 0
fi

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

PM=""
for pm in apt-get pacman dnf zypper apk xbps-install; do
    if command -v "$pm" >/dev/null 2>&1; then PM="$pm"; break; fi
done

pkg_for() {
    local cmd="$1"
    case "$cmd" in
        mksquashfs)
            case "$PM" in
                zypper) echo "squashfs" ;;
                *)      echo "squashfs-tools" ;;
            esac
            ;;
        bwrap)
            echo "bubblewrap"
            ;;
        fuse3)
            echo "fuse3"
            ;;
        xdg-dbus-proxy)
            echo "xdg-dbus-proxy"
            ;;
        cmp)
            echo "diffutils"
            ;;
        ldd)
            case "$PM" in
                apt-get) echo "libc-bin" ;;
                apk)     echo "musl-utils" ;;
                *)       echo "glibc" ;;
            esac
            ;;
        od|truncate|tail|head|dd|realpath|mktemp)
            echo "coreutils"
            ;;
        find)
            echo "findutils"
            ;;
        awk)
            echo "gawk"
            ;;
        tar)
            echo "tar"
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

REQUIRED_CMDS=(
    squashfuse
    mksquashfs
    bwrap
    xdg-dbus-proxy
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
    ldd
)

MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || MISSING+=("fuse3")

if [ "${#MISSING[@]}" -gt 0 ]; then
    warn "Missing tools: ${MISSING[*]}"
    if [ "$INSTALL_DEPS" = true ] && [ -n "$PM" ]; then
        if confirm "${BOLD}Install missing packages automatically with $PM? [y/N]: ${NC}"; then
            PKGS=()
            for c in "${MISSING[@]}"; do
                p="$(pkg_for "$c")"
                case " ${PKGS[*]-} " in *" $p "*) ;; *) PKGS+=("$p") ;; esac
            done
            resolve_elevate
            case "$PM" in
                apt-get)      priv apt-get update && priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" ;;
                pacman)       priv pacman -S --needed --noconfirm "${PKGS[@]}" ;;
                dnf)          priv dnf install -y "${PKGS[@]}" ;;
                zypper)       priv zypper --non-interactive install "${PKGS[@]}" ;;
                apk)          priv apk add "${PKGS[@]}" ;;
                xbps-install) priv xbps-install -Sy "${PKGS[@]}" ;;
            esac
        fi
    elif [ -z "$PM" ]; then
        warn "No supported package manager detected."
        info "Please install the missing tools manually using your system package manager: ${MISSING[*]}"
    fi
fi

# ------------------------------------------------------------
# Paths & Installation targets (Aligned with ULPM v4.0.0)
# ------------------------------------------------------------

NEED_PRIV=false
if [ "$MODE" = "system" ]; then
    BIN_DIR="/usr/local/bin"
    LIB_DIR="/usr/local/lib/ulpm"
    [ "$(id -u)" -ne 0 ] && NEED_PRIV=true
else
    BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
    LIB_DIR="$HOME/.local/lib/ulpm"
fi

[ "$NEED_PRIV" = true ] && resolve_elevate

info "Installing ULPM into ${BOLD}$BIN_DIR/ulpm${NC} (Libs: ${BOLD}$LIB_DIR${NC})..."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ulpm-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Modules v4.0.0
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

# Retrieve / copy the ulpm binary
if [ -f "./bin/ulpm" ]; then
    cp "./bin/ulpm" "$TMP_DIR/ulpm"
elif [ -f "./ulpm" ]; then
    cp "./ulpm" "$TMP_DIR/ulpm"
else
    info "Downloading bin/ulpm..."
    curl -fL --progress-bar --retry 2 "$BASE_URL/bin/ulpm" -o "$TMP_DIR/ulpm" || die "Failed to download bin/ulpm from GitHub ($BASE_URL/bin/ulpm)"
fi

# Retrieve / copy the 8 lib/*.sh modules
for m in "${MODULES[@]}"; do
    if [ -f "./lib/$m" ]; then
        cp "./lib/$m" "$TMP_DIR/lib/$m"
    else
        info "Downloading lib/$m..."
        curl -fL --progress-bar --retry 2 "$BASE_URL/lib/$m" -o "$TMP_DIR/lib/$m" || die "Failed to download lib/$m from GitHub ($BASE_URL/lib/$m)"
    fi
done

bash -n "$TMP_DIR/ulpm" || die "Syntax error detected in ulpm executable!"
for m in "${MODULES[@]}"; do
    bash -n "$TMP_DIR/lib/$m" || die "Syntax error detected in module lib/$m!"
done

# 2. Final deployment
if [ "$NEED_PRIV" = true ]; then
    priv mkdir -p "$LIB_DIR" "$BIN_DIR"
    priv install -m 0755 "$TMP_DIR/ulpm" "$BIN_DIR/ulpm"
    for m in "${MODULES[@]}"; do
        priv install -m 0644 "$TMP_DIR/lib/$m" "$LIB_DIR/$m"
    done
else
    mkdir -p "$LIB_DIR" "$BIN_DIR"
    install -m 0755 "$TMP_DIR/ulpm" "$BIN_DIR/ulpm"
    for m in "${MODULES[@]}"; do
        install -m 0644 "$TMP_DIR/lib/$m" "$LIB_DIR/$m"
    done
fi

# ------------------------------------------------------------
# PATH Configuration
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
USER_SHELL_NAME="${SHELL##*/}"

if [ "$MODE" = "user" ]; then
    case "$USER_SHELL_NAME" in
        fish)
            cfg="$HOME/.config/fish/conf.d/ulpm.fish"
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
# Desktop integration & checks
# ------------------------------------------------------------

if [ "$INTEGRATE" = true ]; then
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        warn "Running under sudo: skipping integration (run 'ulpm integrate' under your user)."
    else
        PATH="$BIN_DIR:$PATH" "$BIN_DIR/ulpm" integrate quiet 2>/dev/null || true
    fi
fi

echo
echo -e "${GREEN}✔ ULPM v4.0.0 installed successfully!${NC}"
echo -e "  Binary:    ${BOLD}$BIN_DIR/ulpm${NC}"
echo -e "  Libraries: ${GRAY}$LIB_DIR${NC}"

if [ -n "$RELOAD_HINT" ]; then
    echo
    warn "$RELOAD_HINT"
    case "$USER_SHELL_NAME" in
        fish) echo -e "  >> To use it immediately, run: ${BOLD}set -U fish_user_paths $BIN_DIR \$fish_user_paths${NC}" ;;
        zsh)  echo -e "  >> To use it immediately, run: ${BOLD}source ~/.zshrc${NC} (or open a new terminal)" ;;
        *)    echo -e "  >> To use it immediately, run: ${BOLD}source ~/.bashrc${NC} (or open a new terminal)" ;;
    esac
fi

echo -e "\nTry: ${BOLD}ulpm help${NC}"
