#!/usr/bin/env bash
# common.sh - Configuration, paths, helpers, runtime init

ULPM_FORMAT_VERSION=3
: "${ULPM_API_CACHE_TTL:=15}"
: "${ULPM_STRICT_SIGNATURES:=true}"
: "${ULPM_REQUIRE_TRUSTED_KEYS:=false}"
: "${ULPM_DBUS_MODE:=proxy}"
: "${ULPM_SHARE_PID:=false}"
: "${ULPM_CLEARENV:=true}"
: "${ULPM_NO_INTEGRATION:=false}"

SIG_MAGIC="LPKSIG01"
SIG_MAGIC_LEN=8
SIG_RAW_LEN=64
SIG_PUB_LEN=32
SIG_FOOTER_TOTAL=104

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

if [[ -n "${NO_COLOR:-}" || ! -t 1 || ! -t 2 ]]; then
 BOLD='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY='' NC=''
fi

print_banner() {
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
echo "=== ULPM (Universal Linux Package Manager) ==="
return 0
fi
echo -e "\033[0;97m▐\033[0;96m██\033[0;37m \033[0;97m▐\033[0;96m██\033[0;97m▐\033[0;96m██\033[0;37m    \033[0;97m▐\033[0;96m█████▌\033[0;97m▐\033[0;96m███▄███▄\033[0m"
echo -e "\033[0;37m▐\033[0;97m██\033[0;37m \033[0;97m▐██\033[0;37m▐\033[0;97m██\033[0;37m    ▐\033[0;97m██\033[0;37m  \033[0;97;47m▐\033[0;97m█\033[0;37m▐\033[0;97m██\033[0;36m▐\033[0;97m█\033[0;97;47m▌\033[0;97m▐██\033[0m"
echo -e "\033[0;37m▐\033[0;37;46m  \033[0;37m ▐\033[0;37;46m  \033[0;37m▐\033[0;37;46m  \033[0;37m    ▐\033[0;37;46m  \033[0;36m██\033[0;37;46m \033[0;36m▌\033[0;37m▐\033[0;37;46m  \033[0;37m▐\033[0;36m█\033[0;90;46m▐\033[0;37m▐\033[0;37;46m  \033[0m"
echo -e "\033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m \033[0;94m▐\033[0;94;44m  \033[0;94m▐\033[0;94;44m  \033[0;37m    \033[0;94m▐\033[0;94;44m  \033[0;37m   \033[0;94m▐\033[0;94;44m  \033[0m"
echo -e "\033[0;97m▐\033[0;94m██████\033[0;96m▐\033[0;94m██████\033[0;96m▐\033[0;94m██\033[0;37m    \033[0;97m▐\033[0;94m██\033[0;37m   \033[0;97m▐\033[0;94m██\033[0m"
}

ULPM_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/ulpm"
ULPM_APPS="$ULPM_DATA/apps"
ULPM_DB="$ULPM_DATA/installed.db"
ULPM_LOCK="$ULPM_DATA/installed.db.lock"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ulpm"
CACHE_API_DIR="$CACHE_DIR/api"
CACHE_PKG_DIR="$CACHE_DIR/pkgs"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ulpm"
TRUSTED_KEYS_DIR="$CONF_DIR/trusted_keys"
DEFAULT_KEY="$CONF_DIR/ulpm_ed25519.key"
CONF_FILE="$CONF_DIR/ulpm.conf"

FUSERMOUNT="fusermount"
TEMP_DIR=""
LAST_SIG_FPR=""
RUN_MNT_DIR=""
RUN_DBUS_DIR=""
RUN_DBUS_PID=""
INST_MNT_DIR=""
STAGE_PKG=""

if [[ -z "${ULPM_BIN:-}" ]]; then
if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
ULPM_BIN="$(readlink -f -- "${BASH_SOURCE[1]}" 2>/dev/null || true)"
else
ULPM_BIN="$(command -v ulpm 2>/dev/null || true)"
fi
fi
ULPM_BIN_DIR=""
[[ -n "$ULPM_BIN" ]] && ULPM_BIN_DIR="${ULPM_BIN%/*}"

_path_add() {
 [[ -n "$1" && -d "$1" ]] || return 0
 case ":${PATH:-}:" in *":$1:"*) return 0 ;; esac
 if [[ "${2:-back}" == "front" ]]; then
 PATH="$1${PATH:+:$PATH}"
 else
 PATH="${PATH:+$PATH:}$1"
 fi
}
_path_add "$ULPM_BIN_DIR" front
for _d in "$HOME/.local/bin" /usr/local/bin /usr/bin /bin /usr/local/sbin /usr/sbin /sbin; do
 _path_add "$_d" back
done
unset _d
export PATH

unmount_dir() {
 local d="${1:-}"
 [[ -n "$d" ]] || return 0
 "${FUSERMOUNT:-fusermount}" -u "$d" 2>/dev/null \
 || "${FUSERMOUNT:-fusermount}" -u -z "$d" 2>/dev/null || true
 rmdir "$d" 2>/dev/null || true
}

cleanup_temp() {
 if [[ -n "${INST_MNT_DIR:-}" ]]; then
 unmount_dir "$INST_MNT_DIR"
 INST_MNT_DIR=""
 fi
 if [[ -n "${TEMP_DIR:-}" ]]; then
 rm -rf -- "$TEMP_DIR" 2>/dev/null || true
 fi
}

cleanup_instance_dbus_only() {
 if [[ -n "${RUN_DBUS_PID:-}" ]]; then
 kill "$RUN_DBUS_PID" 2>/dev/null || true
 wait "$RUN_DBUS_PID" 2>/dev/null || true
 RUN_DBUS_PID=""
 fi
 if [[ -n "${RUN_DBUS_DIR:-}" ]]; then
 rm -rf -- "$RUN_DBUS_DIR" 2>/dev/null || true
 RUN_DBUS_DIR=""
 fi
}

cleanup_instance() {
 cleanup_instance_dbus_only
 if [[ -n "${RUN_MNT_DIR:-}" ]]; then
 unmount_dir "$RUN_MNT_DIR"
 RUN_MNT_DIR=""
 fi
}

init_runtime() {
 local required_cmds=(squashfuse mksquashfs bwrap jq file curl openssl tail head truncate cmp od dd realpath mktemp)
 local cmd
 for cmd in "${required_cmds[@]}"; do
 if ! command -v "$cmd" &>/dev/null; then
 echo -e "${RED}[-] Missing required tool: ${BOLD}$cmd${NC}" >&2
 exit 1
 fi
 done

 if command -v fusermount3 &>/dev/null; then
 FUSERMOUNT="fusermount3"
 elif command -v fusermount &>/dev/null; then
 FUSERMOUNT="fusermount"
 else
 echo -e "${RED}[-] Missing required tool: ${BOLD}fusermount3 / fusermount${NC}" >&2
 exit 1
 fi

 mkdir -p "$ULPM_APPS" "$CACHE_API_DIR" "$CACHE_PKG_DIR" \
 "$DESKTOP_DIR" "$ICON_DIR" "$TRUSTED_KEYS_DIR"
 chmod 700 "$CONF_DIR" "$TRUSTED_KEYS_DIR" 2>/dev/null || true
 touch "$ULPM_DB"

 TEMP_DIR=$(mktemp -d "${ULPM_TMPDIR:-${TMPDIR:-/tmp}}/ulpm.XXXXXX")
 trap cleanup_temp EXIT
 trap 'exit 130' INT
 trap 'exit 143' TERM
}

require_openssl3() {
 local ver
 ver=$(openssl version 2>/dev/null | awk '{print $1" "$2}')
 if [[ "$ver" =~ ^OpenSSL\ ([0-9]+)\. ]] && (( BASH_REMATCH[1] >= 3 )); then
 return 0
 fi
 echo -e "${RED}[-] OpenSSL >= 3.0 is required for Ed25519 (found: ${ver:-unknown})${NC}" >&2
 return 1
}

hex_at() {
 dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null \
 | od -An -v -tx1 | tr -d ' \n'
}

hex_tail() {
 tail -c "$2" "$1" 2>/dev/null | od -An -v -tx1 | tr -d ' \n'
}

SIG_MAGIC_HEX="$(printf '%s' "$SIG_MAGIC" | od -An -v -tx1 | tr -d ' \n')"

has_sig_footer() {
 [[ "$(hex_tail "$1" "$SIG_MAGIC_LEN")" == "$SIG_MAGIC_HEX" ]]
}

normalize_target() {
 local t="${1:-}"
 if [[ "$t" == file://* ]]; then
 t="${t#file://}"
 t="${t#localhost}"
 [[ "$t" == *%00* ]] && return 1
 t="$(printf '%b' "${t//%/\\x}")"
 fi
 printf '%s' "$t"
}

detect_arch() {
 local m
 m="$(uname -m)"
 case "$m" in
 x86_64|amd64) echo "amd64" ;;
 aarch64|arm64) echo "arm64" ;;
 armv7*|armhf) echo "armhf" ;;
 i386|i686) echo "i386" ;;
 riscv64) echo "riscv64" ;;
 *) echo "$m" ;;
 esac
}

SYS_ARCH=$(detect_arch)

ARCH_EXCLUDE_REGEX=""
case "$SYS_ARCH" in
 amd64) ARCH_REGEX="x86_64|x86-64|amd64|x64" ;;
 arm64) ARCH_REGEX="aarch64|arm64|armv8" ;;
 armhf) ARCH_REGEX="armv7l|armv7|armhf|arm" ;;
 i386) ARCH_REGEX="i386|i686|x86"
 ARCH_EXCLUDE_REGEX="x86[_-]64|amd64|x64" ;;
 *) ARCH_REGEX="$SYS_ARCH" ;;
esac

filter_arch() {
 local include="$1" line name
 local b='[^[:alnum:]]'
 local re_in="(^|${b})(${include})(${b}|\$)"
 local re_ex=""
 if [[ -n "${ARCH_EXCLUDE_REGEX:-}" ]]; then
 re_ex="(^|${b})(${ARCH_EXCLUDE_REGEX})(${b}|\$)"
 fi
 while IFS= read -r line; do
 name="${line%%$'\t'*}"
 name="${name,,}"
 [[ "$name" =~ $re_in ]] || continue
 if [[ -n "$re_ex" && "$name" =~ $re_ex ]]; then
 continue
 fi
 printf '%s\n' "$line"
 done
}

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" && -f "$CONF_FILE" ]]; then
 raw_token=$(grep -E '^GITHUB_TOKEN=' "$CONF_FILE" 2>/dev/null | cut -d'=' -f2- || true)
 GITHUB_TOKEN=$(echo "$raw_token" | tr -d "\"'")
fi

fetch_github_api() {
 local endpoint="${1#https://api.github.com/}"
 endpoint="${endpoint#/}"
 local ttl="${2:-$ULPM_API_CACHE_TTL}"
 [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=15
 local cache_key cache_file
 cache_key=$(echo "$endpoint" | tr '/' '_')
 cache_file="${CACHE_API_DIR}/${cache_key}.json"

 if [[ -f "$cache_file" ]]; then
 if [[ "$ttl" -eq 0 ]]; then
 rm -f "$cache_file"
 elif [[ -z "$(find "$cache_file" -mmin "+$ttl" 2>/dev/null)" ]]; then
 cat "$cache_file"
 return 0
 fi
 fi

 local auth_header=()
 if [[ -n "$GITHUB_TOKEN" ]]; then
 auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
 fi

 local response
 response=$(curl -sS --connect-timeout 10 --max-time 25 --retry 2 \
 ${auth_header[@]+"${auth_header[@]}"} \
 -H "Accept: application/vnd.github+json" \
 -H "User-Agent: ulpm-client" \
 "https://api.github.com/${endpoint}" 2>/dev/null) || true

 if [[ -n "$response" ]] && echo "$response" | jq -e . >/dev/null 2>&1; then
 echo "$response" > "$cache_file"
 echo "$response"
 return 0
 fi

 if [[ -f "$cache_file" ]]; then
 cat "$cache_file"
 return 0
 fi
 return 1
}

find_lpk_download_url() {
 local json="$1" regex="$2"
 echo "$json" | jq -r '.assets[]? | "\(.name)\t\(.browser_download_url)"' 2>/dev/null \
 | grep -iE '\.lpk$' \
 | filter_arch "$regex" \
 | head -n1 \
 | cut -f2 || true
}

find_archive_download_url() {
 local json="$1" regex="$2"
 echo "$json" | jq -r '.assets[]? | "\(.name)\t\(.browser_download_url)"' 2>/dev/null \
 | grep -iE '\.(appimage|deb|rpm|tar\.gz|tar\.xz|tgz|tar\.zst|zip)$' \
 | filter_arch "$regex" \
 | grep -ivE "src|source|dev|doc|debug" \
 | head -n1 \
 | cut -f2 || true
}

desktop_entry_escape() {
 local value="$1"
 value="${value//\\/\\\\}"
 value="${value//$'\n'/\\n}"
 value="${value//$'\r'/\\r}"
 value="${value//$'\t'/\\t}"
 printf '%s' "$value"
}

desktop_exec_quote() {
 local value="$1"
 value="${value//\\/\\\\}"
 value="${value//\"/\\\"}"
 value="${value//\`/\\\`}"
 value="${value//\$/\\\$}"
 value="${value//%/%%}"
 printf '"%s"' "$value"
}

write_desktop_entry() {
 local id="$1" name="$2" icon="$3"
 mkdir -p "$DESKTOP_DIR"
 cat > "$DESKTOP_DIR/ulpm-$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$(desktop_entry_escape "$name")
Exec=$(desktop_exec_quote "$ULPM_BIN") run "$id" %U
Icon=$icon
Terminal=false
Categories=Utility;Network;Development;AudioVideo;Graphics;
StartupNotify=true
EOF
}

refresh_desktop_entries() {
 [[ -s "$ULPM_DB" ]] || return 0
 local id name icon
 while IFS='|' read -r id name _ || [[ -n "$id" ]]; do
 if [[ -z "$id" || ! -f "$DESKTOP_DIR/ulpm-$id.desktop" ]]; then
 continue
 fi
 icon="$id"
 if [[ -f "$ICON_DIR/$id.png" ]]; then
 icon="$ICON_DIR/$id.png"
 fi
 write_desktop_entry "$id" "$name" "$icon"
 done < "$ULPM_DB"
}