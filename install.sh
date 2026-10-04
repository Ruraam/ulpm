#!/usr/bin/env bash
#
# ULPM Official Installer
# Supports both rootless (~/.local/bin) and system-wide (/usr/local/bin)
#
# Usage:
#   ./install.sh [options]
#   curl -fsSL <raw-url>/install.sh | bash -s -- [options]
#
# Options:
#   --user          Force rootless install (~/.local/bin or $XDG_BIN_HOME)
#   --system        Force system-wide install (/usr/local/bin, uses sudo/doas if needed)
#   --bin-dir DIR   Install into DIR
#   --ref REF       Branch, tag or commit to install (default: main, or $ULPM_REF)
#   -y, --yes       Install missing dependencies without asking
#   --no-deps       Never try to install dependencies
#   --no-integrate  Do not register *.lpk double-click / graphical-session PATH
#   --uninstall     Remove ULPM, its integration, cache, packages and keys
#   -h, --help      Show this help
#
# Environment:
#   ULPM_REF        Same as --ref
#   ULPM_RAW_URL    Full URL of the ulpm script (mirror / testing)
#   ULPM_SHA256     Expected sha256 of the script; the install aborts on mismatch
#

# Must stay POSIX-only: runs before any bash-specific syntax is parsed.
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
    NC='\033[0m'
else
    BOLD='' RED='' GREEN='' CYAN='' YELLOW='' NC=''
fi

REPO="Ruraam/ulpm"
REF="${ULPM_REF:-main}"

info() { echo -e ":: $*"; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
die()  { echo -e "${RED}[X] $*${NC}" >&2; exit 1; }

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

MODE="auto"
BIN_DIR=""
ASSUME_YES=false
INSTALL_DEPS=true
INTEGRATE=true
UNINSTALL=false

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
        -h|--help)      usage; exit 0 ;;
        *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

# Interactive first-run menu. Explicit command-line options always take priority.
if [ "$MODE" = "auto" ] && [ "$UNINSTALL" = false ] && [ -t 0 ] && [ -t 1 ]; then
    echo
    echo -e "${BOLD}${CYAN}ULPM — Installation${NC}"
    echo "  1) Installation rootless (utilisateur)"
    echo "  2) Installation root (système)"
    echo "  3) Désinstallation propre"
    echo
    printf "Choix [1-3] : "
    read -r choice || choice=""
    case "$choice" in
        1) MODE="user" ;;
        2) MODE="system" ;;
        3) UNINSTALL=true ;;
        *) die "Choix invalide." ;;
    esac
fi

# --bin-dir must be absolute: a relative path would break launchers later.
if [ -n "$BIN_DIR" ]; then
    case "$BIN_DIR" in
        /*) ;;
        "~"|"~ /"*) BIN_DIR="$HOME${BIN_DIR#"~"}" ;;
        *)  BIN_DIR="$(pwd)/$BIN_DIR" ;;
    esac
fi

RAW_URL="${ULPM_RAW_URL:-https://raw.githubusercontent.com/$REPO/$REF/ulpm}"

# ------------------------------------------------------------
# Environment checks
# ------------------------------------------------------------

[ "$(uname -s)" = "Linux" ] || die "ULPM only supports Linux."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required (found ${BASH_VERSION})."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME is not set or not a directory."

if [ "$UNINSTALL" = true ]; then
    uninstall_ulpm
    exit 0
fi

echo -e "${BOLD}${CYAN}Installing Universal Linux Package Manager (ulpm)...${NC}"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

confirm() {
    local prompt="$1" reply=""
    if [ "$ASSUME_YES" = true ]; then
        return 0
    fi
    if [ -t 0 ]; then
        printf '%b' "$prompt"
        read -r reply || reply=""
    elif ( : < /dev/tty ) 2>/dev/null; then
        # `curl | bash`: stdin is the script, ask on the terminal instead.
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

# Runs a command with elevation when needed.
priv() {
    if [ "${#ELEVATE[@]}" -gt 0 ]; then
        "${ELEVATE[@]}" "$@"
    else
        "$@"
    fi
}


# Remove only PATH lines created by this installer / ULPM integration.
clean_path_file() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    local tmp
    tmp="$(mktemp)"
    awk '
        /# Added by ULPM installer/ { skip=1; next }
        /# Added by ULPM \(graphical sessions do not read ~/.bashrc\)/ { skip=1; next }
        skip && /^[[:space:]]*export PATH=/ { skip=0; next }
        skip { skip=0 }
        { print }
    ' "$cfg" > "$tmp"
    cat "$tmp" > "$cfg"
    rm -f "$tmp"
}

uninstall_ulpm() {
    local user_bin="${XDG_BIN_HOME:-$HOME/.local/bin}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local cache_home="${XDG_CACHE_HOME:-$HOME/.cache}"
    local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    local path
    local found=false

    echo
    echo "Cette opération supprime ULPM, les paquets LPK installés,"
    echo "les clés de signature locales, le cache et l'intégration bureau."
    echo "Les données applicatives dans ~/.var/app ne seront PAS supprimées."
    echo

    if [ "$ASSUME_YES" != true ]; then
        local reply=""
        if [ -t 0 ]; then
            printf "Confirmer la désinstallation complète d'ULPM ? [y/N]: "
            read -r reply || reply=""
        elif ( : < /dev/tty ) 2>/dev/null; then
            printf "Confirmer la désinstallation complète d'ULPM ? [y/N]: "
            read -r reply < /dev/tty || reply=""
        else
            warn "Désinstallation interactive impossible sans terminal. Relance avec --uninstall --yes."
            return 1
        fi
        case "$reply" in
            [yY]|[yY][eE][sS]|[oO]|[oO][uU][iI]) ;;
            *) info "Désinstallation annulée."; return 0 ;;
        esac
    fi

    local binaries=("$user_bin/ulpm" "/usr/local/bin/ulpm")
    [ -n "$BIN_DIR" ] && binaries+=("$BIN_DIR/ulpm")
    for path in "${binaries[@]}"; do
        if [ -f "$path" ]; then
            found=true
            if [ -w "$(dirname "$path")" ]; then
                rm -f -- "$path"
            else
                resolve_elevate
                priv rm -f -- "$path"
            fi
            info "Removed $path"
        fi
    done

    # Clean shell and graphical-session PATH additions.
    for path in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
        clean_path_file "$path"
    done
    rm -f "$config_home/fish/conf.d/ulpm.fish" \
          "$config_home/environment.d/60-ulpm.conf"

    # Remove ULPM MIME / desktop integration and ULPM-generated app launchers.
    rm -f "$data_home/applications/ulpm-open.desktop" \
          "$data_home/mime/packages/application-x-lpk.xml"
    find "$data_home/applications" -maxdepth 1 -type f -name 'ulpm-*.desktop' -delete 2>/dev/null || true
    find "$data_home/icons/hicolor/512x512/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true

    # Remove only the ULPM MIME default association, preserving other handlers.
    for path in "$config_home/mimeapps.list" "$data_home/applications/mimeapps.list"; do
        if [ -f "$path" ]; then
            sed -i '/^application\/x-lpk=ulpm-open\.desktop;/d' "$path"
        fi
    done

    rm -rf -- "$data_home/ulpm" "$cache_home/ulpm" "$config_home/ulpm"

    command -v update-mime-database >/dev/null 2>&1 \
        && update-mime-database "$data_home/mime" >/dev/null 2>&1 || true
    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true

    if [ "$found" = true ]; then
        echo -e "${GREEN}✔ ULPM désinstallé.${NC}"
    else
        echo -e "${GREEN}✔ Intégration et données ULPM nettoyées (binaire déjà absent).${NC}"
    fi
    echo "Les données applicatives de ~/.var/app ont été conservées."
}

PM=""
detect_pm() {
    local pm
    for pm in apt-get pacman dnf zypper apk xbps-install; do
        if command -v "$pm" >/dev/null 2>&1; then
            PM="$pm"
            return 0
        fi
    done
    return 1
}

# Maps a missing command (or pseudo-name) to the package providing it.
pkg_for() {
    case "$1" in
        mksquashfs)
            if [ "$PM" = "zypper" ]; then echo "squashfs"; else echo "squashfs-tools"; fi ;;
        bwrap)                                   echo "bubblewrap" ;;
        fuse3)                                   echo "fuse3" ;;
        cmp)                                     echo "diffutils" ;;
        od|truncate|tail|head|dd|realpath|mktemp) echo "coreutils" ;;
        *)                                       echo "$1" ;;
    esac
}

PM_UPDATED=false
install_packages() {
    case "$PM" in
        apt-get)
            if [ "$PM_UPDATED" = false ]; then
                priv apt-get update || warn "apt-get update failed, trying to install anyway"
                PM_UPDATED=true
            fi
            priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        pacman)       priv pacman -S --needed --noconfirm "$@" ;;
        dnf)          priv dnf install -y "$@" ;;
        zypper)       priv zypper --non-interactive install "$@" ;;
        apk)          priv apk add "$@" ;;
        xbps-install) priv xbps-install -Sy "$@" ;;
    esac
}

# ------------------------------------------------------------
# Dependencies (kept in sync with the checks done by ulpm itself)
# ------------------------------------------------------------

REQUIRED_CMDS=(squashfuse mksquashfs bwrap jq file curl openssl cmp od truncate tail head dd realpath mktemp)
MISSING=()

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done

if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
    MISSING+=("fuse3")
fi

if [ "${#MISSING[@]}" -gt 0 ]; then
    warn "Missing tools: ${MISSING[*]}"

    if [ "$INSTALL_DEPS" = false ]; then
        warn "Skipping dependency installation (--no-deps)."
    elif ! detect_pm; then
        warn "No supported package manager found. Please install: ${MISSING[*]}"
    elif confirm "${BOLD}Do you want to install missing dependencies now? [y/N]: ${NC}"; then
        PKGS=()
        for c in "${MISSING[@]}"; do
            p="$(pkg_for "$c")"
            case " ${PKGS[*]-} " in
                *" $p "*) ;;
                *) PKGS+=("$p") ;;
            esac
        done

        resolve_elevate
        info "Installing missing packages with ${PM}: ${PKGS[*]}"
        if ! install_packages "${PKGS[@]}"; then
            die "Dependency installation failed. Please install manually: ${PKGS[*]}"
        fi

        # Recommended (best effort): D-Bus filtering inside the sandbox.
        if ! command -v xdg-dbus-proxy >/dev/null 2>&1; then
            install_packages xdg-dbus-proxy >/dev/null 2>&1 \
                || warn "Could not install optional package 'xdg-dbus-proxy' (D-Bus filtering)."
        fi
    else
        warn "Dependencies not installed. ulpm will refuse to start until they are available."
        warn "Re-run with --yes to install them automatically."
    fi
elif ! command -v xdg-dbus-proxy >/dev/null 2>&1; then
    info "Optional: install 'xdg-dbus-proxy' to let ulpm filter the session D-Bus in its sandbox."
fi

command -v curl >/dev/null 2>&1 || die "curl is required to download ulpm."

# ------------------------------------------------------------
# Target directory
# ------------------------------------------------------------

USER_BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"

if [ -n "$BIN_DIR" ]; then
    TARGET_DIR="$BIN_DIR"
elif [ "$MODE" = "system" ]; then
    TARGET_DIR="/usr/local/bin"
elif [ "$MODE" = "user" ]; then
    TARGET_DIR="$USER_BIN"
elif [ "$(id -u)" -eq 0 ] || [ -w "/usr/local/bin" ]; then
    TARGET_DIR="/usr/local/bin"
else
    TARGET_DIR="$USER_BIN"
fi

NEED_PRIV=false
if [ -d "$TARGET_DIR" ]; then
    [ -w "$TARGET_DIR" ] || NEED_PRIV=true
else
    mkdir -p "$TARGET_DIR" 2>/dev/null || NEED_PRIV=true
fi

if [ "$NEED_PRIV" = true ]; then
    resolve_elevate
    priv mkdir -p "$TARGET_DIR"
    info "Mode: ${BOLD}System-wide${NC} (elevated) -> Target directory: ${CYAN}$TARGET_DIR${NC}"
elif [ "$TARGET_DIR" = "/usr/local/bin" ]; then
    info "Mode: ${BOLD}System-wide${NC} -> Target directory: ${CYAN}$TARGET_DIR${NC}"
else
    info "Mode: ${BOLD}Rootless (User)${NC} -> Target directory: ${CYAN}$TARGET_DIR${NC}"
fi

TARGET="$TARGET_DIR/ulpm"

# ------------------------------------------------------------
# Download, verify, install (atomically)
# ------------------------------------------------------------

TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/ulpm-install.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT

info "Downloading ulpm (${REF})..."
curl -fsSL --retry 3 --connect-timeout 10 "$RAW_URL" -o "$TMP_FILE" \
    || die "Download failed: $RAW_URL"

# Refuse HTML error pages, truncated downloads and anything that is not a bash script.
head -n 1 "$TMP_FILE" | grep -q '^#!.*bash' \
    || die "Downloaded file is not a bash script (wrong URL or ref?)."
bash -n "$TMP_FILE" \
    || die "Downloaded script has syntax errors (truncated download?)."

if [ -n "${ULPM_SHA256:-}" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha="$(sha256sum "$TMP_FILE" | cut -d' ' -f1)"
    else
        actual_sha="$(openssl dgst -sha256 -r "$TMP_FILE" | cut -d' ' -f1)"
    fi
    [ "$actual_sha" = "$ULPM_SHA256" ] \
        || die "Checksum mismatch (expected $ULPM_SHA256, got $actual_sha)."
    info "Checksum verified."
fi

# Write next to the target then rename: a running ulpm is never overwritten in place.
if [ "$NEED_PRIV" = true ]; then
    priv install -m 0755 "$TMP_FILE" "$TARGET.new"
    priv mv -f "$TARGET.new" "$TARGET"
else
    install -m 0755 "$TMP_FILE" "$TARGET.new"
    mv -f "$TARGET.new" "$TARGET"
fi

# ------------------------------------------------------------
# PATH
# ------------------------------------------------------------
# Interactive shells read ~/.bashrc / ~/.zshrc, but graphical sessions (file
# manager double-click, .desktop launchers) do NOT: that is why a .lpk could
# start from one place and fail with "ulpm: command not found" from another.
# We therefore also register the directory in ~/.profile and in systemd's
# environment.d (read at graphical login).

RELOAD_HINT=""

add_path_line() {
    # add_path_line <rc-file>
    local cfg="$1"
    mkdir -p "$(dirname "$cfg")"
    touch "$cfg"
    if ! grep -qF "$TARGET_DIR" "$cfg" 2>/dev/null; then
        {
            echo ""
            echo "# Added by ULPM installer"
            echo "export PATH=\"$TARGET_DIR:\$PATH\""
        } >> "$cfg"
        info "Added ${CYAN}$TARGET_DIR${NC} to ${BOLD}$cfg${NC}"
    fi
}

setup_path() {
    # System directories are expected to be on PATH already.
    if [ "$TARGET_DIR" = "/usr/local/bin" ] || [ "$NEED_PRIV" = true ]; then
        return 0
    fi

    local shell_name="${SHELL:-}" cfg=""
    shell_name="${shell_name##*/}"

    case "$shell_name" in
        fish)
            cfg="$HOME/.config/fish/conf.d/ulpm.fish"
            mkdir -p "$(dirname "$cfg")"
            echo "fish_add_path -g \"$TARGET_DIR\"" > "$cfg"
            info "Added ${CYAN}$TARGET_DIR${NC} to ${BOLD}$cfg${NC}"
            ;;
        zsh)  cfg="$HOME/.zshrc";  add_path_line "$cfg" ;;
        bash) cfg="$HOME/.bashrc"; add_path_line "$cfg" ;;
        *)    cfg="$HOME/.profile" ;;
    esac

    # Graphical sessions
    add_path_line "$HOME/.profile"
    local envd="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/60-ulpm.conf"
    mkdir -p "$(dirname "$envd")"
    # shellcheck disable=SC2016
    printf 'PATH=%s:${PATH}\n' "$TARGET_DIR" > "$envd"

    case ":$PATH:" in
        *":$TARGET_DIR:"*) ;;
        *) RELOAD_HINT="Open a new terminal (and log out/in once for graphical launchers) to use ulpm directly." ;;
    esac
}
setup_path

# ------------------------------------------------------------
# Sanity checks (warnings only)
# ------------------------------------------------------------

post_checks() {
    if [ ! -e /dev/fuse ]; then
        warn "/dev/fuse not found: squashfuse needs the 'fuse' kernel module (try: sudo modprobe fuse)."
    elif [ ! -r /dev/fuse ] || [ ! -w /dev/fuse ]; then
        warn "/dev/fuse is not accessible by your user (check the 'fuse' group or udev rules)."
    fi

    if command -v bwrap >/dev/null 2>&1; then
        local out
        if ! out="$(bwrap --ro-bind / / --dev /dev true 2>&1)"; then
            warn "bubblewrap cannot create a sandbox on this system: ${out}"
            warn "Unprivileged user namespaces may be restricted (AppArmor / sysctl on some distributions)."
            warn "Until this is fixed, 'ulpm run' will not work."
        fi
    fi
}
post_checks

if ! "$TARGET" help >/dev/null 2>&1; then
    warn "Installed script did not start correctly: try running '$TARGET help'."
fi

# ------------------------------------------------------------
# Desktop integration: *.lpk double-click with an absolute ulpm path
# ------------------------------------------------------------

if [ "$INTEGRATE" = true ]; then
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        warn "Running as root via sudo: skipping desktop integration (run 'ulpm integrate' as your normal user)."
    elif ! PATH="$TARGET_DIR:$PATH" "$TARGET" integrate; then
        warn "Desktop integration failed (missing dependencies?). Retry later with: ulpm integrate"
    fi
fi

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------

echo -e "${GREEN}✔ ULPM installed successfully to: ${BOLD}$TARGET${NC}"
if [ -n "$RELOAD_HINT" ]; then
    warn "$RELOAD_HINT"
fi
echo -e "Run '${BOLD}ulpm help${NC}' to get started."
