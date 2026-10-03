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

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

while [ $# -gt 0 ]; do
    case "$1" in
        --user)    MODE="user" ;;
        --system)  MODE="system" ;;
        --bin-dir) shift; BIN_DIR="${1:?--bin-dir needs a directory}" ;;
        --ref)     shift; REF="${1:?--ref needs a value}" ;;
        -y|--yes)  ASSUME_YES=true ;;
        --no-deps) INSTALL_DEPS=false ;;
        -h|--help) usage; exit 0 ;;
        *)         die "Unknown option: $1 (see --help)" ;;
    esac
    shift
done

RAW_URL="${ULPM_RAW_URL:-https://raw.githubusercontent.com/$REPO/$REF/ulpm}"

# ------------------------------------------------------------
# Environment checks
# ------------------------------------------------------------

[ "$(uname -s)" = "Linux" ] || die "ULPM only supports Linux."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required (found ${BASH_VERSION})."

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
        bwrap)                       echo "bubblewrap" ;;
        fuse3)                       echo "fuse3" ;;
        cmp)                         echo "diffutils" ;;
        od|truncate|tail|head)       echo "coreutils" ;;
        *)                           echo "$1" ;;
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

REQUIRED_CMDS=(squashfuse mksquashfs bwrap jq file curl openssl cmp od truncate tail head)
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

        # Recommended (best effort): filters the session D-Bus inside the sandbox.
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
# PATH (only when the target directory is not already on it)
# ------------------------------------------------------------

RELOAD_HINT=""
setup_path() {
    case ":$PATH:" in
        *":$TARGET_DIR:"*) return 0 ;;
    esac
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
            RELOAD_HINT="Open a new terminal to use ulpm directly."
            return 0
            ;;
        zsh)  cfg="$HOME/.zshrc" ;;
        bash) cfg="$HOME/.bashrc" ;;
        *)    cfg="$HOME/.profile" ;;
    esac

    touch "$cfg"
    if ! grep -qF "$TARGET_DIR" "$cfg"; then
        {
            echo ""
            echo "# Added by ULPM installer"
            echo "export PATH=\"$TARGET_DIR:\$PATH\""
        } >> "$cfg"
        info "Added ${CYAN}$TARGET_DIR${NC} to ${BOLD}$cfg${NC}"
    fi
    RELOAD_HINT="Run 'source $cfg' or restart your terminal to use ulpm directly."
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
# Done
# ------------------------------------------------------------

echo -e "${GREEN}✔ ULPM installed successfully to: ${BOLD}$TARGET${NC}"
if [ -n "$RELOAD_HINT" ]; then
    warn "$RELOAD_HINT"
fi
echo -e "Run '${BOLD}ulpm help${NC}' to get started."
