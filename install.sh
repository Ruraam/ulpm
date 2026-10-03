#!/usr/bin/env bash
#
# ULPM Official Installer
# Supports both rootless (~/.local/bin) and system-wide (/usr/local/bin)
#
set -euo pipefail

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

MSG_ERR_NO_ELEVATE="[X] Root privileges are required to install dependencies, but neither 'sudo' nor 'doas' was found."

REPO="Ruraam/ulpm"
RAW_URL="https://raw.githubusercontent.com/$REPO/main/ulpm"

echo -e "${BOLD}${CYAN}Installing Universal Linux Package Manager (ulpm)...${NC}"

COMMANDS=("squashfuse" "mksquashfs" "bwrap" "jq" "file" "curl" "openssl")
MISSING_CMDS=()

for cmd in "${COMMANDS[@]}"; do
if ! command -v "$cmd" >/dev/null 2>&1; then
MISSING_CMDS+=("$cmd")
fi
done

if ! command -v fusermount3 >/dev/null 2>&1 && ! command -v fusermount >/dev/null 2>&1; then
MISSING_CMDS+=("fuse3")
fi

if [ "${#MISSING_CMDS[@]}"-gt 0 ]; then
echo -e "${YELLOW}[!] Missing tools: ${MISSING_CMDS[*]}${NC}"

if [ -t 0 ]; then
printf "%b" "${BOLD}Do you want to install missing dependencies now? [y/N]: ${NC}"
read -r response
elif [ -e /dev/tty ]; then
printf "%b" "${BOLD}Do you want to install missing dependencies now? [y/N]: ${NC}"
read -r response < /dev/tty
else
response="n"
fi

case "$response" in
[yY][eE][sS]|[yY])
echo -e ":: Installing missing packages..."
;;
*)
echo -e "${RED}[X] Installation aborted by user.${NC}"
exit 0
;;
esac

if [ "$(id -ru)" -eq 0 ]; then
ELEVATE=""
elif command -v sudo >/dev/null 2>&1; then
ELEVATE="sudo"
elif command -v doas >/dev/null 2>&1; then
ELEVATE="doas"
else
echo -e "${RED}${MSG_ERR_NO_ELEVATE}${NC}" >&2
exit 1
fi

PKGS=()
for c in "${MISSING_CMDS[@]}"; do
case "$c" in
mksquashfs) PKGS+=("squashfs-tools") ;;
fuse3)      PKGS+=("fuse3") ;;
bwrap)      PKGS+=("bubblewrap") ;;
*)          PKGS+=("$c") ;;
esac
done

if command -v apt-get >/dev/null 2>&1; then
$ELEVATE apt-get update && $ELEVATE apt-get install -y "${PKGS[@]}"
elif command -v pacman >/dev/null 2>&1; then
$ELEVATE pacman -Sy --noconfirm "${PKGS[@]}"
elif command -v dnf >/dev/null 2>&1; then
$ELEVATE dnf install -y "${PKGS[@]}"
elif command -v zypper >/dev/null 2>&1; then
$ELEVATE zypper install -y "${PKGS[@]}"
elif command -v apk >/dev/null 2>&1; then
$ELEVATE apk add "${PKGS[@]}"
else
echo -e "${RED}[X] Could not auto-install dependencies. Please install: ${MISSING_CMDS[*]}${NC}"
exit 1
fi
fi

if [ "$(id -ru)" -eq 0 ] || [ -w "/usr/local/bin" ]; then
TARGET_DIR="/usr/local/bin"
IS_SYSTEM=true
echo -e ":: Mode: ${BOLD}System-wide${NC} -> Target directory: ${CYAN}$TARGET_DIR${NC}"
else
TARGET_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
IS_SYSTEM=false
echo -e ":: Mode: ${BOLD}Rootless (User)${NC} -> Target directory: ${CYAN}$TARGET_DIR${NC}"
fi

mkdir -p "$TARGET_DIR"
TARGET="$TARGET_DIR/ulpm"

echo -e ":: Downloading ulpm..."
curl -fsSL "$RAW_URL" -o "$TARGET"
chmod +x "$TARGET"

if [ "$IS_SYSTEM" = false ]; then
SHELL_CONFIG=""
case "${SHELL:-}" in
*/zsh)  SHELL_CONFIG="$HOME/.zshrc" ;;
*/bash) SHELL_CONFIG="$HOME/.bashrc" ;;
*)      SHELL_CONFIG="$HOME/.profile" ;;
esac

if [[ ":$PATH:" != *":$TARGET_DIR:"* ]]; then
[ -n "$SHELL_CONFIG" ] && touch "$SHELL_CONFIG"
if [ -n "$SHELL_CONFIG" ] && ! grep -q "$TARGET_DIR" "$SHELL_CONFIG"; then
echo "" >> "$SHELL_CONFIG"
echo '# Added by ULPM installer' >> "$SHELL_CONFIG"
echo "export PATH=\"$TARGET_DIR:\$PATH\"" >> "$SHELL_CONFIG"
echo -e ":: Added ${CYAN}$TARGET_DIR${NC} to ${BOLD}$SHELL_CONFIG${NC}"
fi
echo -e "${YELLOW}[!] Run 'source $SHELL_CONFIG' or restart your terminal to use ulpm directly.${NC}"
fi
fi

echo -e "${GREEN}✔ ULPM installed successfully to: ${BOLD}$TARGET${NC}"
echo -e "Run '${BOLD}ulpm help${NC}' to get started."
