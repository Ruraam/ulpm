#!/usr/bin/env bash
# ==============================================================================
# ULPM Official Universal Installer & Lifecycle Manager (v4.0.0 Architecture)
# Supports: Rootless (~/.local/bin) & System-wide (/usr/local/bin)
#
# Usage:
#   ./install.sh [options]
#   curl -fsSL https://raw.githubusercontent.com/Ruraam/ulpm/main/install.sh | bash
# ==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
echo "[X]This installer requires bash (try: curl -fsSL <url> | bash)" >&2
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

REPO="Ruraam/ulpm"
REF="${ULPM_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"

print_banner() {
local term_cols
term_cols=$(tput cols 2>/dev/null || echo 80)

if [[ -n "${NO_COLOR:-}" || ! -t 1 || "$term_cols" -lt 80 ]]; then
echo -e "\n=== ULPM (Universal Linux Package Manager Engine) ===\n"
return0
fi

clear
echo -e "              \033[0;97m▐\033[0;96m██\033[0;37m \033[0;97m▐\033[0;96m██\033[0;97m▐\033[0;96m██\033[0;37m    \033[0;97m▐\033[0;96m█████▌\033[0;97m▐\033[0;96m███▄███▄\033[0m"
echo -e "              \033[0;37m▐\033[0;97m██\033[0;37m \033[0;97m▐██\033[0;37m▐\033[0;97m██\033[0;37m    ▐\033[0;97m██\033[0;37m  \033[0;97;47m▐\033[0;97m█\033[0;37m▐\033[0;97m██\033[0;36m▐\033[0;97m█\033[0;97;47m▌\033[0;97m▐██\033[0m"
echo -e "              \033[0;37m▐\033[0;37;46m  \033[0;37m ▐\033[0;37;46m  \033[0;37m▐\033[0;37;46m  \033[0;37m    ▐\033[0;37;46m  \033[0;36m██\033[0;37;46m \033[0;36m▌\033[0;37m▐\033[0;37;46m  \033[0;37m▐\033[0;36m█\033[0;90;46m▐\033[0;37m▐\033[0;37;46m  \033[0m"
echo -e "              \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m    \033[0;94m▐\033[0;94;44m  \033[0;37m   \033[0;94m▐\033[0;94;44m  \033[0m"
echo -e "              \033[0;97m▐\033[0;94m██████\033[0;96m▐\033[0;94m██████\033[0;96m▐\033[0;94m██\033[0;37m    \033[0;97m▐\033[0;94m██\033[0;37m   \033[0;97m▐\033[0;94m██\033[0m"
}

# ------------------------------------------------------------
# System checks & Privilegesresolution
# ------------------------------------------------------------

[ "$(uname -s)" = "Linux" ] || die "ULPM only supports Linux operating systems."
[ "${BASH_VERSINFO[0]}" -ge 4 ] || die "bash >= 4 is required (found ${BASH_VERSION})."
[ -n "${HOME:-}" ]&& [ -d "$HOME" ] || die "\$HOME is not set or not a directory."

ELEVATE=()
resolve_elevate() {
if [ "$(id -u)" -eq 0 ]; then
ELEVATE=()
elif command -v sudo >/dev/null 2>&1; then
ELEVATE=(sudo)
elif command -v doas >/dev/null 2>&1;then
ELEVATE=(doas)
else
die "Root privileges are required, but neither'sudo' nor 'doas' was found."
fi
}

priv() {
if[ "${#ELEVATE[@]}" -gt 0 ]; then
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
elif [ -r /dev/tty ];then
printf '%b' "$prompt"
read -r reply < /dev/tty || reply=""
else
return 1
fi
case "$reply" in
[yY]|[yY][eE][sS]|[oO]|[oO][uU][iI]) return 0 ;;
*) return1 ;;
esac
}

clean_path_file() {
local cfg="$1"
[ -f "$cfg" ] || return 0
local tmp
tmp="$(mktemp)"
awk '
/# Added by ULPM installer/ { skip=1; next }
/#Added by ULPM \(graphical sessions do not read ~\/.bashrc\)/ { skip=1; next }
skip && /^[[:space:]]*export PATH=/ { skip=0; next }
skip { skip=0 }
{ print }
' "$cfg" > "$tmp"
cat "$tmp" > "$cfg"
rm -f "$tmp"
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
echo "Usage: ./install.sh [OPTIONS]"
echo
echo "Options:"
echo "  --user          Install in user home directory (~/.local)"
echo "  --system        Install system-wide (/usr/local, requires root)"
echo"  --bin-dir DIR   Custom binary directory"
echo "  --ref BRANCH    GitHub branch/tag to download from (default: main)"
echo "  -y, --yes       Assume yes to allprompts"
echo "  --no-deps       Do not attempt to install missing host dependencies"
echo"  --no-integrate  Skip desktop MIME and launcher configuration"
echo "  --uninstall     Completelyremove ULPM from system and user profiles"
exit 0
;;
*) die "Unknown option: $1" ;;
esac
shift
done

if [ "$MODE" = "auto"] && [ "$UNINSTALL" = false ]; then
TTY_IN=""
if[ -t 0 ]; then
TTY_IN="-"
elif [ -r /dev/tty ]; then
TTY_IN="/dev/tty"
fi

if [ -n "$TTY_IN" ]; then
echo
echo -e "${BOLD}${CYAN}ULPM — Universal Linux Package Manager Engine${NC}"
echo "  1) Rootless installation (User: ~/.local/bin)"
echo "  2) System-wide installation (Root: /usr/local/bin)"
echo "  3) Clean uninstallation"
echo "4) Exit"
echo
printf "Choice [1-4] : "
if [ "$TTY_IN" = "-" ]; then
read -r choice || choice=""
else
read -r choice < /dev/tty || choice=""
fi

case "$choice" in
1)MODE="user" ;;
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
# Complete Uninstallation Logic
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
local lib_dirs=("$HOME/.local/lib/ulpm" "/usr/local/lib/ulpm" "$data_home/ulpm/engine" "$data_home/ulpm/lib")

for path in "${targets[@]}"; do
if [ -e "$path" ] ||[ -L "$path" ]; then
if [ -w "$(dirname "$path")" ]; then
rm -f-- "$path"
else
resolve_elevate
priv rm -f -- "$path"
fi
info "Removed binary: $path"
fi
done

for dir in "${lib_dirs[@]}";do
if [ -d "$dir" ]; then
if [ -w "$(dirname "$dir")"]; then
rm -rf -- "$dir"
else
resolve_elevate
priv rm -rf -- "$dir"
fi
info "Removed libraries: $dir"
fi
done

for path in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
clean_path_file"$path"
done
rm -f "$config_home/fish/conf.d/ulpm.fish" "$config_home/environment.d/60-ulpm.conf"
rm -f "$data_home/applications/ulpm-open.desktop" "$data_home/applications/ulpm-handler.desktop" "$data_home/mime/packages/application-x-lpk.xml"
find "$data_home/applications" -maxdepth 1 -type f -name 'io.lpk.*.desktop' -delete 2>/dev/null || true
find "$data_home/icons/hicolor/256x256/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true
find "$data_home/icons/hicolor/512x512/apps" -maxdepth 1 -type f -name 'io.lpk.*.png' -delete 2>/dev/null || true

for path in "$config_home/mimeapps.list" "$data_home/applications/mimeapps.list"; do
[ -f "$path" ] && sed -i '/^application\/x-lpk=/d' "$path" 2>/dev/null || true
done

rm -rf -- "$data_home/ulpm" "$cache_home/ulpm" "$config_home/ulpm"

command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$data_home/mime" >/dev/null 2>&1 || true
command -vupdate-desktop-database >/dev/null 2>&1 && update-desktop-database "$data_home/applications" >/dev/null 2>&1 || true

echo -e "\n${GREEN}✔ ULPM has been completely uninstalled.${NC}"
}

if [ "$UNINSTALL" = true ]; then
uninstall_ulpm
exit 0
fi

# ------------------------------------------------------------
# Host Dependencies Check & Auto-Installation
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
bwrap)          echo "bubblewrap" ;;
fuse3)          echo "fuse3" ;;
xdg-dbus-proxy) echo "xdg-dbus-proxy" ;;
cmp)            echo "diffutils" ;;
readelf)echo "binutils" ;;
dpkg-deb)       echo "dpkg" ;;
od|truncate|tail|head|dd|realpath|mktemp) echo "coreutils" ;;
find)           echo "findutils" ;;
awk)            echo "gawk" ;;
tar)            echo "tar" ;;
*)echo "$cmd" ;;
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
readelf
)

MISSING=()
for cmd in "${REQUIRED_CMDS[@]}"; do
command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
command -v fusermount3 >/dev/null2>&1 || command -v fusermount >/dev/null 2>&1 || MISSING+=("fuse3")

if [ "${#MISSING[@]}" -gt 0 ]; then
warn "Missing tools: ${MISSING[*]}"
if [ "$INSTALL_DEPS" = true ] && [ -n "$PM" ]; then
if confirm "${BOLD}Install missing packages automatically with $PM? [y/N]: ${NC}"; then
PKGS=()
for c in "${MISSING[@]}"; do
p="$(pkg_for "$c")"
case" ${PKGS[*]-} " in *" $p "*) ;; *) PKGS+=("$p") ;; esac
done
resolve_elevate
case "$PM" in
apt-get)      priv apt-get update &&priv env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}" ;;
pacman)       priv pacman -S --needed --noconfirm "${PKGS[@]}" ;;
dnf)          priv dnf install -y "${PKGS[@]}" ;;
zypper)       priv zypper --non-interactive install "${PKGS[@]}" ;;
apk)          priv apk add "${PKGS[@]}" ;;
xbps-install) priv xbps-install -Sy "${PKGS[@]}" ;;
esac
fi
elif [ -z "$PM" ]; then
warn "No supported package manager detected."
info "Pleaseinstall missing packages manually: ${MISSING[*]}"
fi
fi

# ------------------------------------------------------------
#Deployment Paths & Targets Configuration
# ------------------------------------------------------------

NEED_PRIV=false
if [ "$MODE"= "system" ]; then
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
LIB_DIR="/usr/local/lib/ulpm"
[ "$(id -u)" -ne0 ] && NEED_PRIV=true
else
BIN_DIR="${BIN_DIR:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
LIB_DIR="$HOME/.local/lib/ulpm"
fi

[ "$NEED_PRIV" = true ] && resolve_elevate

info "InstallingULPM to ${BOLD}$BIN_DIR/ulpm${NC} (Modules: ${BOLD}$LIB_DIR${NC})..."

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ulpm-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

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

mkdir -p"$TMP_DIR/lib"

# 1. Download or fetch local source tree
if [ -f "./bin/ulpm" ]; then
cp "./bin/ulpm" "$TMP_DIR/ulpm"
elif [ -f "./ulpm" ]; then
cp "./ulpm" "$TMP_DIR/ulpm"
else
info "Fetching bin/ulpm..."
curl -fL --progress-bar--retry 2 "$BASE_URL/bin/ulpm" -o "$TMP_DIR/ulpm"|| die "Failed to download bin/ulpm from GitHub ($BASE_URL/bin/ulpm)"
fi

for min "${MODULES[@]}"; do
if [ -f "./lib/$m" ]; then
cp"./lib/$m" "$TMP_DIR/lib/$m"
else
info "Fetching lib/$m..."
curl -fL --progress-bar --retry 2 "$BASE_URL/lib/$m" -o "$TMP_DIR/lib/$m" || die "Failed to download lib/$m from GitHub ($BASE_URL/lib/$m)"
fi
done

# 2. Syntax validation
info "Performing syntax checks..."
bash -n "$TMP_DIR/ulpm" || die "Syntax error detected in ulpm executable!"
for m in "${MODULES[@]}"; do
bash -n "$TMP_DIR/lib/$m" || die "Syntax error detected in modulelib/$m!"
done

# 3. Final atomic deployment
if [ "$NEED_PRIV" = true]; then
priv mkdir -p "$LIB_DIR" "$BIN_DIR"
priv install -m0755 "$TMP_DIR/ulpm" "$BIN_DIR/ulpm"
form in "${MODULES[@]}"; do
priv install -m 0644 "$TMP_DIR/lib/$m" "$LIB_DIR/$m"
done
else
mkdir -p "$LIB_DIR" "$BIN_DIR"
install -m 0755 "$TMP_DIR/ulpm""$BIN_DIR/ulpm"
for m in "${MODULES[@]}"; do
install -m 0644 "$TMP_DIR/lib/$m" "$LIB_DIR/$m"
done
fi

# ------------------------------------------------------------
# Shell Environment & PATH Configuration
# ------------------------------------------------------------

add_path_line() {
local cfg="$1"
mkdir -p "$(dirname "$cfg")"
touch "$cfg"
if ! grep -qF "$BIN_DIR" "$cfg"2>/dev/null; then
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
case "$USER_SHELL_NAME"in
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
RELOAD_HINT="$BIN_DIR is not yet in your PATH for thisterminal session."
;;
esac
fi

# ------------------------------------------------------------
# Desktop, MIME& Double-Click Integration
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

# 1. MIME type definition
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

# 2.Open-with runner
local desktop_file="$TMP_DIR/ulpm-open.desktop"
cat<<EOF > "$desktop_file"
[Desktop Entry]
Type=Application
Name=ULPM Package Runner
Comment=Execute sandboxed .lpk applications
Exec=$BIN_DIR/ulpm run %f
Icon=package-x-generic
Terminal=false
NoDisplay=true
MimeType=application/x-lpk;
Categories=System;Utility;
EOF

if [ "$NEED_PRIV" = true ]; then
privinstall -m 0644 "$mime_file" "$mime_dir/application-x-lpk.xml"
priv install -m 0644 "$desktop_file" "$apps_dir/ulpm-open.desktop"
else
install -m 0644 "$mime_file" "$mime_dir/application-x-lpk.xml"
install -m 0644 "$desktop_file" "$apps_dir/ulpm-open.desktop"
fi

#3. Default applications mapping (User & System-wide)
local mimeapps_list="$target_config/mimeapps.list"
if [ "$NEED_PRIV" = true ]; then
priv mkdir -p "$target_config"
priv touch "$mimeapps_list"
if ! grep -q "application/x-lpk=" "$mimeapps_list" 2>/dev/null; then
if grep -q "\[Default Applications\]" "$mimeapps_list"2>/dev/null; then
priv sed -i '/\[Default Applications\]/a application\/x-lpk=ulpm-open.desktop;' "$mimeapps_list"
else
printf "\n[Default Applications]\napplication/x-lpk=ulpm-open.desktop;\n" | priv tee-a "$mimeapps_list" >/dev/null
fi
fi
else
mkdir -p "$target_config"
touch "$mimeapps_list"
if ! grep -q "application/x-lpk=" "$mimeapps_list" 2>/dev/null; then
if grep -q "\[Default Applications\]" "$mimeapps_list" 2>/dev/null; then
sed -i '/\[Default Applications\]/a application\/x-lpk=ulpm-open.desktop;' "$mimeapps_list"
else
printf "\n[Default Applications]\napplication/x-lpk=ulpm-open.desktop;\n" >> "$mimeapps_list"
fi
fi
fi

# 4. Database updates
if command -v update-mime-database >/dev/null2>&1; then
if [ "$NEED_PRIV" = true ]; then
priv update-mime-database "$target_data/mime" >/dev/null 2>&1 || true
else
update-mime-database "$target_data/mime" >/dev/null 2>&1 || true
fi
fi

if command -v update-desktop-database >/dev/null 2>&1; then
if [ "$NEED_PRIV" = true ]; then
priv update-desktop-database"$target_data/applications" >/dev/null 2>&1 || true
else
update-desktop-database "$target_data/applications" >/dev/null 2>&1 || true
fi
fi
}

if [ "$INTEGRATE" = true ]; then
setup_desktop_integration
fi

# ------------------------------------------------------------
# Auto-Key Provisioning (Zero-Friction Crypto Setup)
# ------------------------------------------------------------
provision_default_keys() {
local keys_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ulpm/keys"
local priv_key="$keys_dir/default.priv"
local pub_key="$keys_dir/default.pub"

if [ ! -f "$priv_key" ] || [ ! -f "$pub_key" ]; then
info"Initializing local Ed25519 cryptographic authority..."
mkdir -p "$keys_dir"
chmod700 "$keys_dir" 2>/dev/null || true
if command -v openssl >/dev/null 2>&1; then
openssl genpkey -algorithm Ed25519 -out "$priv_key"2>/dev/null || true
chmod 600 "$priv_key" 2>/dev/null || true
openssl pkey -in "$priv_key" -pubout -out "$pub_key" 2>/dev/null || true
fi
fi
}

provision_default_keys

# ------------------------------------------------------------
# Wrap-up & Information
# ------------------------------------------------------------

echo
echo -e "${GREEN}✔ ULPM engine successfully installed!${NC}"
echo -e "  Binary:    ${BOLD}$BIN_DIR/ulpm${NC}"
echo -e "  Libraries: ${GRAY}$LIB_DIR${NC}"

if [ -n "$RELOAD_HINT" ]; then
echo
warn "$RELOAD_HINT"
case"$USER_SHELL_NAME" in
fish)    echo -e "  >> Run: ${BOLD}set -U fish_user_paths $BIN_DIR \$fish_user_paths${NC}" ;;
zsh)     echo -e "  >> Run: ${BOLD}source ~/.zshrc${NC} (or restart terminal)" ;;
*)       echo -e "  >> Run: ${BOLD}source ~/.bashrc${NC} (or restart terminal)" ;;
esac
fi

echo -e "\nGet started with: ${BOLD}ulpm help${NC}"