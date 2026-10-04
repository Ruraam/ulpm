#!/usr/bin/env bash
#
# ULPM Official Installer (Modular v3.3)
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
NC='\033[0m'
else
BOLD='' RED='' GREEN='' CYAN='' YELLOW='' NC=''
fi

REPO="Ruraam/ulpm"
REF="${ULPM_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"

info() { echo -e "${CYAN}::${NC} $*"; }
warn() { echo -e "${YELLOW}[!] $*${NC}" >&2; }
die()  { echo -e "${RED}[X] $*${NC}" >&2; exit 1; }

# ------------------------------------------------------------
# Arguments & Menu
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
echo -e "${BOLD}${CYAN}ULPM — Universal Linux Package Manager (LPK Engine v3.3)${NC}"
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
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "\$HOME is not setor not a directory."

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
/# Added by ULPM \(graphical sessions do not read ~/.bashrc\)/{ skip=1; next }
skip && /^[[:space:]]*export PATH=/ { skip=0; next }
skip { skip=0 }
{ print }
' "$cfg" > "$tmp"
cat "$tmp" > "$cfg"
rm -f "$tmp"
}

#------------------------------------------------------------
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
local share_dirs=("$data_home/ulpm/lib" "/usr/local/lib/ulpm")

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

for dir in "${share_dirs[@]}"; do
if [ -d "$dir" ];then
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
case "$1" in
mksquashfs) [ "$PM" = "zypper" ] && echo "squashfs" || echo "squashfs-tools" ;;
bwrap)      echo "bubblewrap" ;;
fuse3)      echo "fuse3" ;;
cmp)        echo "diffutils" ;;
od|truncate|tail|head|dd|realpath|mktemp) echo "coreutils" ;;
*)          echo "$1" ;;
esac
}

REQUIRED_CMDS=(squashfuse mksquashfs bwrap jq file curl openssl cmp od truncate tail headdd realpath mktemp)
MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
command-v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
command -v fusermount3 >/dev/null 2>&1 || command -v fusermount >/dev/null 2>&1 || MISSING+=("fuse3")

if [ "${#MISSING[@]}" -gt 0 ]; then
warn "Missing tools: ${MISSING[*]}"
if [ "$INSTALL_DEPS" = true ] && [ -n "$PM" ]; then
if confirm "${BOLD}Install missing packages automatically with $PM? [y/N]: ${NC}"; then
PKGS=()
for c in "${MISSING[@]}"; do
p="$(pkg_for "$c")"
case " ${PKGS[*]-} "in *" $p "*) ;; *) PKGS+=("$p") ;; esac
done
resolve_elevate
case "$PM" in
apt-get)      priv apt-get update && priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" ;;
pacman)       priv pacman -S --needed --noconfirm "${PKGS[@]}" ;;
dnf)          priv dnf install -y "${PKGS[@]}";;
zypper)       priv zypper --non-interactive install "${PKGS[@]}" ;;
apk)          priv apk add "${PKGS[@]}" ;;
xbps-install) priv xbps-install -Sy "${PKGS[@]}" ;;
esac
command -v xdg-dbus-proxy >/dev/null 2>&1 || {
case "$PM" in
apt-get) priv apt-get install -y xdg-dbus-proxy >/dev/null 2>&1 || true ;;
pacman)  priv pacman -S --needed --noconfirm xdg-dbus-proxy >/dev/null 2>&1 || true ;;
dnf)     priv dnf install -y xdg-dbus-proxy >/dev/null 2>&1 || true ;;
esac
}
fi
fi
fi

# ------------------------------------------------------------
# Paths & Installation targets
# ------------------------------------------------------------

NEED_PRIV=false
if [ "$MODE" = "system" ]; then
BIN_DIR="/usr/local/bin"
INSTALL_ROOT="/usr/local/lib/ulpm"
[ "$(id -u)" -ne 0 ] && NEED_PRIV=true
else
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/ulpm/engine"
fi

[ "$NEED_PRIV" = true ] && resolve_elevate

info "Installing ULPM into ${BOLD}$INSTALL_ROOT${NC}..."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ulpm-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# 1. Download executables and modules
mkdir -p "$TMP_DIR/lib"
FILES=(
"ulpm"
"lib/common.sh"
"lib/crypto.sh"
"lib/db.sh"
"lib/packaging.sh"
"lib/sandbox.sh"
"lib/cli.sh"
)

LOCAL_BUILD=false
if [ -f "./ulpm" ] && [ -d "./lib" ]; then
LOCAL_BUILD=true
fi

for f in "${FILES[@]}"; do
if [ "$LOCAL_BUILD" = true ] && [ -f "./$f" ]; then
cp "./$f" "$TMP_DIR/$f"
else
info "Downloading $f..."
curl -fsSL --retry 2 "$BASE_URL/$f" -o "$TMP_DIR/$f" || die "Failed to download $f from GitHub ($BASE_URL/$f)"
fi
done

bash -n "$TMP_DIR/ulpm" || die "Syntax error detected in downloaded ulpm!"

# 2. Deploy to final directory
if [ "$NEED_PRIV" = true ]; then
priv mkdir -p "$INSTALL_ROOT/lib" "$BIN_DIR"
priv install -m 0755 "$TMP_DIR/ulpm" "$INSTALL_ROOT/ulpm"
for f in "${FILES[@]}"; do
[[ "$f" == lib/* ]] && priv install -m 0644 "$TMP_DIR/$f" "$INSTALL_ROOT/$f"
done
priv ln -sf "$INSTALL_ROOT/ulpm" "$BIN_DIR/ulpm"
else
mkdir -p "$INSTALL_ROOT/lib" "$BIN_DIR"
install -m 0755 "$TMP_DIR/ulpm" "$INSTALL_ROOT/ulpm"
for f in "${FILES[@]}"; do
[[ "$f" == lib/* ]] && install -m 0644 "$TMP_DIR/$f" "$INSTALL_ROOT/$f"
done
ln -sf "$INSTALL_ROOT/ulpm" "$BIN_DIR/ulpm"
fi

#------------------------------------------------------------
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
if [ "$MODE" = "user" ]; then
case "${SHELL##*/}" in
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
*) RELOAD_HINT="Notice: Add $BIN_DIR to your PATH or restart your session." ;;
esac
fi

# ------------------------------------------------------------
# Desktopintegration & checks
# ------------------------------------------------------------

if [ "$INTEGRATE" = true ]; then
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
warn "Running under sudo: skipping integration (run 'ulpm integrate' under your user)."
else
PATH="$BIN_DIR:$PATH" "$INSTALL_ROOT/ulpm" integrate quiet || true
fi
fi

echo
echo -e "${GREEN}✔ ULPM v3.3 installed successfully!${NC}"
echo -e "  Binary: ${BOLD}$BIN_DIR/ulpm${NC} -> ${GRAY}$INSTALL_ROOT/ulpm${NC}"
[ -n "$RELOAD_HINT" ] && warn "$RELOAD_HINT"
echo -e "Try: ${BOLD}ulpm help${NC}"
