#!/usr/bin/env bash
# ==============================================================================
# lib/utils.sh - Core utilities, binary helpers and environment setup
# ULPMv5.3 Architecture Engine (Hardened POSIX / Strict Bash)
# ==============================================================================

# Strict color configuration (supports NO_COLOR standard & terminal detection)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'
C_BOLD=$'\033[1m'
else
C_RESET=''
C_RED=''
C_GREEN=''
C_YELLOW=''
C_BLUE=''
C_CYAN=''
C_BOLD=''
fi

log()   { printf '%b[ulpm]%b %s\n' "${C_BLUE}${C_BOLD}" "$C_RESET" "$*"; }
info(){ printf '%b[+]%b %s\n' "${C_GREEN}${C_BOLD}" "$C_RESET" "$*"; }
warn()  { printf '%b[!]%b %s\n'"${C_YELLOW}${C_BOLD}" "$C_RESET" "$*" >&2; }
error() { printf '%b[x]%b %s\n' "${C_RED}${C_BOLD}" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

# ==============================================================================
#Path, URI & Durability (WAL Primitives)
# ==============================================================================

sync_file() {
local target="${1:-}"
[[ -n "$target" && -f "$target" ]] || return 0
if command -v python3 >/dev/null 2>&1; then
python3 -c "importos, sys; f = os.open(sys.argv[1], os.O_RDONLY); os.fsync(f); os.close(f)" "$target" 2>/dev/null && return 0
fi
if command -v sync >/dev/null 2>&1; then
sync "$target" 2>/dev/null || sync 2>/dev/null || true
fi
}

sync_dir() {
local dir="${1:-}"
[[ -n "$dir" && -d "$dir" ]] || return 0
if command -v python3 >/dev/null2>&1; then
python3 -c "import os, sys; d = os.open(sys.argv[1], os.O_RDONLY); os.fsync(d); os.close(d)" "$dir" 2>/dev/null && return 0
fi
if command -v sync >/dev/null 2>&1; then
sync "$dir" 2>/dev/null || sync 2>/dev/null || true
fi
}

durable_write() {
local dest="$1" content="$2" mode="${3:-600}"
local dest_dir tmp_file
dest_dir="$(dirname -- "$dest")"
mkdir -p -- "$dest_dir" || return1

tmp_file="$(mktemp "$dest_dir/.tmp.wal.XXXXXX")" ||return 1
chmod "$mode" "$tmp_file" 2>/dev/null || true

if ! printf '%s' "$content" > "$tmp_file"; then
rm -f -- "$tmp_file"
return1
fi

sync_file "$tmp_file"
if ! mv -f -- "$tmp_file" "$dest"; then
rm -f -- "$tmp_file"
return 1
fi
sync_dir "$dest_dir"
}

normalize_target() {
local t="${1:-}" rest escape hex prefix ch decoded=''
if [[ "$t" != file://* ]]; then
printf '%s\n' "$t"
return 0
fi

rest="${t#file://}"
if [[ "$rest" == localhost/* ]]; then
rest="${rest#localhost}"
elif [[ "$rest" == localhost ]]; then
rest='/'
elif [[ "$rest" != /* && -n "$rest" ]]; then
error 'Unsupported non-local file URI.'
return 1
fi

if [[ "$rest"=~ %00 ]]; then
error 'NUL byte is not valid in a file path.'
return1
fi

while [[ "$rest" =~ ^([^%]*)(%[0-9A-Fa-f]{2})(.*)$ ]]; do
prefix="${BASH_REMATCH[1]}"
escape="${BASH_REMATCH[2]}"
rest="${BASH_REMATCH[3]}"
hex="${escape:1:2}"
printf -v ch '%b' "\\x${hex}"
decoded+="${prefix}${ch}"
done
local result="${decoded}${rest}"
if [[ "$result" =~(^|/)\.\.(/|$) ]]; then
error 'Path traversal is not permitted in file URIs.'
return 1
fi
printf '%s\n' "$result"
}

canonicalize_strict_path() {
local target="${1:-}"
if [[ "$target" != /*]]; then
target="$PWD/$target"
fi
if [[ "$target" =~ (^|/)\.\.(/|$) ]]; then
return 1
fi
printf '%s\n' "$target"
}

init_environment() {
local data_home="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}"
local config_home="${ULPM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ulpm}"
local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
local state_home="${ULPM_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/ulpm}"
local apps_dir="${ULPM_APPS_DIR:-$data_home/apps}"
local runtimes_dir="${ULPM_RUNTIMES_DIR:-$data_home/runtimes}"
local keys_dir="${ULPM_KEYS_DIR:-$config_home/keys}"
local overrides_dir="${ULPM_OVERRIDES_DIR:-$config_home/overrides}"
local trusted_dir="${config_home}/trusted_keys"
local history_dir="${data_home}/history"
local journal_dir="${state_home}/wal"
local db_file="${ULPM_DB:-$data_home/installed.db}"

[[ -n "${HOME:-}" && -d "$HOME" ]] || {
error 'HOME is unsetor is not an existing directory.'
return 1
}

mkdir -p -- "$data_home" "$config_home" "$cache_home/tmp" "$apps_dir" \
"$runtimes_dir" "$overrides_dir" "$history_dir" || {
error 'Could not create ULPM data directories.'
return 1
}

# Secure directories creation with explicit permissions
mkdir -p -- "$keys_dir" "$trusted_dir" "$journal_dir" || {
error 'Could not create secure ULPM key or transaction directories.'
return 1
}
chmod 700 "$keys_dir" "$trusted_dir" "$journal_dir" 2>/dev/null || true

if [[ ! -e "$db_file" ]]; then
( umask 077; : >> "$db_file" ) || {
error "Could not create ULPM database: $db_file"
return 1
}
sync_file "$db_file"
elif [[ -L "$db_file" || ! -f "$db_file" || ! -w "$db_file" ]]; then
error "ULPM database is not a writable regular file: $db_file"
return 1
else
chmod 600 "$db_file" 2>/dev/null || true
fi
}

# ------------------------------------------------------------------------------
# Security, Path, Environment & Identifier Validation
#------------------------------------------------------------------------------

is_proot() {
[[ -n "${PROOT_TMP_DIR:-}" ]] || \
[[ -n "${TERMUX_VERSION:-}" ]] || \
[[ "${PREFIX:-}" == *com.termux* ]] || \
[[ "$(uname -r 2>/dev/null)" == *"PRoot"* ]] || \
grep -q -i "proot" /proc/version 2>/dev/null
}

is_container() {
[[ -f /.dockerenv ]] || [[ -f /run/.containerenv ]] || is_proot
}

can_use_fuse() {
[[ -c /dev/fuse && -r /dev/fuse && -w /dev/fuse ]]
}

is_safe_app_id() {
local v="${1:-}"
[[ -n "$v" && "$v" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$v" != *..* ]]
}

is_safe_app_name(){
local v="${1:-}"
[[ -n "$v" && "$v" != "." &&"$v" != ".." && "$v" != */* && "$v" != *'|'* \
&& "$v" != -* && "$v" != *$'\n'* && "$v" != *$'\r'* && "$v" != *$'\t'* ]]
}

_ulpm_valid_bind_dest() {
local dest="$1"
[[ "$dest" == /* && "$dest" != / ]] || return1
case "$dest" in
/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*)
return 1
;;
esac
[[ "$dest" != *$'\n'* && "$dest" != *$'\r'* ]] || return 1
[[ ! "/$dest/" =~ /\.\.?/ ]] || return 1
return 0
}

#------------------------------------------------------------------------------
# Semantic Version Comparison Engine (Deterministic, Pure Bash Fallback)
# ------------------------------------------------------------------------------

semver_compare() {
local v1="${1:-0}" v2="${2:-0}"
if [[ "$v1" == "$v2" ]]; then
return 0
fi

# Strip epoch prefixes if present (e.g., "1:2.0" ->"2.0")
v1="${v1#*:}"
v2="${v2#*:}"

# Delegate to dpkg if available (highest compatibility)
if command -v dpkg >/dev/null 2>&1; then
if dpkg --compare-versions "$v1" eq "$v2"; then return0; fi
if dpkg --compare-versions "$v1" gt "$v2"; then return1; fi
return 2
fi

# Pure Bash SemVer comparison (handles numeric & alphanumerictags safely)
local -a ver1 ver2
local old_ifs="$IFS"
IFS='.-+' read -r -a ver1 <<< "$v1"
IFS='.-+' read -r-a ver2 <<< "$v2"
IFS="$old_ifs"

local max_len="${#ver1[@]}"
(( ${#ver2[@]} > max_len )) && max_len="${#ver2[@]}"

local i p1 p2 clean1 clean2
for ((i=0; i<max_len; i++)); do
p1="${ver1[i]:-0}"
p2="${ver2[i]:-0}"

if [[ "$p1" == "$p2" ]]; then
continue
fi

clean1="${p1//[^0-9]/}"
clean2="${p2//[^0-9]/}"

# If both parts contain numeric data andare equal in length, compare numerically
if [[ -n "$clean1" && -n "$clean2"&& "$p1" =~ ^[0-9]+$ && "$p2" =~ ^[0-9]+$ ]]; then
if (( ${#clean1} > ${#clean2} )); then
return1
elif (( ${#clean1} < ${#clean2} )); then
return 2
fi
if [[ "$clean1" > "$clean2" ]]; then
return 1
elif [[ "$clean1"< "$clean2" ]]; then
return 2
fi
else
# LexicographicalASCII comparison for pre-releases (e.g., "alpha" < "beta")
if [[ "$p1" > "$p2" ]]; then
return 1
else
return 2
fi
fi
done
return 0
}

version_matches_constraint() {
local version="$1" constraint="${2:-all}"
[[ -z "$constraint" || "$constraint" =="all" || "$constraint" == "*" ]] && return 0

local op target_ver
if[[ "$constraint" =~ ^([>=<]+)(.*)$ ]]; then
op="${BASH_REMATCH[1]}"
target_ver="${BASH_REMATCH[2]}"
else
op="="
target_ver="$constraint"
fi

local cmp=0
semver_compare "$version" "$target_ver" || cmp=$?

case "$op" in
"="|"==") (( cmp == 0 )) ;;
">=")     (( cmp == 0 || cmp== 1 )) ;;
"<=")     (( cmp == 0 || cmp == 2 )) ;;
">")      (( cmp == 1 )) ;;
"<")      (( cmp == 2 )) ;;
*)        return 1 ;;
esac
}

# ------------------------------------------------------------------------------
# Manifest v5 Resolution & Persistent Overrides
# ------------------------------------------------------------------------------

manifest_resolve_effective() {
local manifest_file="$1"
local app_id="$2"
local override_file="${ULPM_OVERRIDES_DIR:-${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/overrides}/${app_id}.json"

if [[ ! -f "$manifest_file" ]]; then
printf '{}\n'
return 1
fi

if [[ ! -f "$override_file" || ! -s "$override_file" ]]; then
cat "$manifest_file"
return 0
fi

jq -s '.[0] * .[1]' "$manifest_file" "$override_file" 2>/dev/null || cat"$manifest_file"
}

manifest_get() {
local json="$1" query="$2"default_val="${3:-}" res
res=$(jq -r "$query // empty" <<< "$json"2>/dev/null || true)
if [[ -z "$res" ]]; then
printf '%s\n' "$default_val"
else
printf '%s\n' "$res"
fi
}

manifest_set_override() {
local app_id="$1" jq_path="$2" val="$3"
local overrides_dir="${ULPM_OVERRIDES_DIR:-${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/overrides}"
mkdir -p "$overrides_dir" || return 1
local override_file="$overrides_dir/${app_id}.json"
local current="{}"

if [[ -f "$override_file" && -s "$override_file" ]]; then
current="$(cat "$override_file")"
fi
local tmp_file
tmp_file="$(mktemp "${override_file}.tmp.XXXXXX")" || return 1

local ret=0
if jq -e . >/dev/null 2>&1 <<< "$val"; then
jq --argjson v "$val""$jq_path = \$v" <<< "$current" > "$tmp_file" 2>/dev/null|| ret=$?
else
jq --arg v "$val" "$jq_path = \$v" <<< "$current" > "$tmp_file" 2>/dev/null || ret=$?
fi

if ((ret == 0 )); then
sync_file "$tmp_file"
mv -f -- "$tmp_file" "$override_file"
sync_dir "$overrides_dir"
info "Override persistently set for[$app_id]: $jq_path = $val"
return 0
else
rm -f-- "$tmp_file"
error "Failed to set override on $jq_path"
return1
fi
}

manifest_reset_overrides() {
local app_id="$1"
local override_file="${ULPM_OVERRIDES_DIR:-${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/overrides}/${app_id}.json"
if [[ -f "$override_file" ]]; then
rm -f "$override_file"
info "Overrides successfully reset for[$app_id]"
else
info "No overrides found for [$app_id]"
fi
}

#------------------------------------------------------------------------------
# Database & Locking Mechanisms
# ------------------------------------------------------------------------------

db_remove_entry() {
local id="${1:-}" name="${2:-}" tmp db_dir
[[ -n "$id" && -n "$name" ]] || {
error "db_remove_entry requires anapp ID and name."
return 2
}
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
[[ -f "$db_file" ]] || return 0
[[ ! -L "$db_file" ]] || {
error "Refusing symlinked package database: $db_file"
return1
}
db_dir="$(dirname -- "$db_file")"
tmp="$(mktemp "$db_dir/.installed.db.XXXXXX")" || return 1
if ! awk -F'|' -v id="$id" -v name="$name" '!($1 == id || $2== name)' "$db_file" > "$tmp"; then
rm -f -- "$tmp"
error "Could not prepare package database removal."
return 1
fi
chmod --reference="$db_file" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || {
rm -f -- "$tmp"
return 1
}
sync_file "$tmp"
mv -f -- "$tmp" "$db_file" || {
rm -f -- "$tmp"
error "Could not commit package database removal."
return 1
}
sync_dir "$db_dir"
}

check_dependencies() {
local depmissing=()
for dep in "$@"; do
command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if (( ${#missing[@]} )); then
error"Missing required dependencies: ${missing[*]}"
return 1
fi
}

export ULPM_LOCK_FD=200
ULPM_LOCK_HELD=0

acquire_lock() {
local timeout="${1:-10}"
local lock_file="${ULPM_LOCK:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db.lock}"

timeout="${timeout%%.*}"
[[ "$timeout" =~ ^[0-9]+$ ]] || timeout=10

command -v flock >/dev/null 2>&1 || {
error 'Required command not found: flock'
return 1
}
mkdir -p -- "$(dirname -- "$lock_file")" || {
error "Could not create lock directory for $lock_file."
return 1
}
eval "exec ${ULPM_LOCK_FD}>\"\$lock_file\"" || {
error "Couldnot open lock file: $lock_file"
return 1
}
if flock -n"$ULPM_LOCK_FD"; then
ULPM_LOCK_HELD=1
return0
fi
warn "Another instance of ULPM is active. Waiting up to ${timeout}s..."
if flock -w "$timeout" "$ULPM_LOCK_FD"; then
ULPM_LOCK_HELD=1
return 0
fi
error "Could not acquire database lock within ${timeout}s ($lock_file)."
eval "exec ${ULPM_LOCK_FD}>&-"
ULPM_LOCK_HELD=0
return 1
}

release_lock() {
if [[ "${ULPM_TRANSACTION_ACTIVE:-0}" == 1 ]]; then
return 0
fi
[[ "${ULPM_LOCK_HELD:-0}" == 1 ]] || return 0
flock -u "$ULPM_LOCK_FD" 2>/dev/null || true
eval "exec ${ULPM_LOCK_FD}>&- 2>/dev/null" || true
ULPM_LOCK_HELD=0
}

with_lock() {
acquire_lock 10 || return 1
local status=0
"$@" || status=$?
release_lock
return "$status"
}

safe_unmount() {
local mount_point="${1:-}"
[[ -n "$mount_point" &&-d "$mount_point" ]] || return 0
command -v mountpoint >/dev/null2>&1 || {
error 'Cannot verify mount state: mountpoint command is missing.'
return1
}
mountpoint -q -- "$mount_point" 2>/dev/null ||return 0
if command -v fusermount3 >/dev/null 2>&1 && fusermount3 -u -z -- "$mount_point" 2>/dev/null; then
return0
fi
if command -v fusermount >/dev/null 2>&1 &&fusermount -u -z -- "$mount_point" 2>/dev/null; then
return0
fi
if command -v umount >/dev/null 2>&1 && umount -l -- "$mount_point" 2>/dev/null; then
return 0
fi
error "Could not unmount '$mount_point'; leaving it in place for safety."
return1
}

normalize_arch_name() {
case "${1,,}" in
amd64|x86_64|x86-64|x64)          printf 'amd64\n' ;;
arm64|aarch64|arm-64|armv8)       printf 'arm64\n' ;;
armhf|armv7|armv7l|arm32)         printf 'armhf\n' ;;
i386|i486|i586|i686|x86)          printf 'i386\n' ;;
riscv64)                          printf 'riscv64\n' ;;
ppc64le)                          printf'ppc64le\n' ;;
s390x)                            printf 's390x\n' ;;
loongarch64)                      printf 'loongarch64\n' ;;
mips64)                           printf 'mips64\n' ;;
mips)                             printf 'mips\n' ;;
sparc64)                          printf 'sparc64\n' ;;
all|any|noarch|no-arch|universal) printf 'all\n' ;;
*)                                printf'%s\n' "${1,,}" ;;
esac
}

is_arch_compatible() {
local package_arch="${1:-all}" host_arch
package_arch="$(normalize_arch_name "$package_arch")"
host_arch="$(normalize_arch_name "$(detect_arch)")"
[[ "$package_arch" == all || "$package_arch" == "$host_arch" ]]
}

detect_arch(){
case "$(uname -m)" in
x86_64|amd64)echo amd64 ;;
aarch64|arm64)       echo arm64 ;;
armv7*|armhf)        echo armhf ;;
i386|i486|i586|i686) echo i386 ;;
riscv64)             echo riscv64 ;;
*)                   uname -m ;;
esac
}

find_host_loader() {
local arch
arch="$(uname -m)" || return 1
local candidates=()
case "$arch" in
x86_64|amd64)
candidates=(
/lib64/ld-linux-x86-64.so.2
/usr/lib64/ld-linux-x86-64.so.2
/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
/lib/ld-musl-x86_64.so.1
/usr/lib/ld-musl-x86_64.so.1
)
;;
aarch64|arm64)
candidates=(
/lib/ld-linux-aarch64.so.1
/usr/lib/ld-linux-aarch64.so.1
/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
/lib/ld-musl-aarch64.so.1
/usr/lib/ld-musl-aarch64.so.1
)
;;
armv7*|armv6*|armhf)
candidates=(
/lib/ld-linux-armhf.so.3
/usr/lib/ld-linux-armhf.so.3
/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
/usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
/lib/ld-musl-armhf.so.1
/usr/lib/ld-musl-armhf.so.1
)
;;
i386|i486|i586|i686)
candidates=(
/lib/ld-linux.so.2
/usr/lib/ld-linux.so.2
/lib/i386-linux-gnu/ld-linux.so.2
/usr/lib/i386-linux-gnu/ld-linux.so.2
/lib/ld-musl-i386.so.1
/usr/lib/ld-musl-i386.so.1
)
;;
riscv64)
candidates=(
/lib/ld-linux-riscv64-lp64d.so.1
/usr/lib/ld-linux-riscv64-lp64d.so.1
/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1
/usr/lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1
/lib/ld-musl-riscv64.so.1
/usr/lib/ld-musl-riscv64.so.1
)
;;
*) return 1 ;;
esac
for cand in "${candidates[@]}"; do
if [[ -x "$cand" ]]; then
printf '%s\n' "$cand"
return 0
fi
done
return 1
}

# ==============================================================================
# GitHub Configuration, API & Authentication Helper
# ==============================================================================

ULPM_CONFIG_FILE="${ULPM_CONFIG_FILE:-${ULPM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ulpm}/ulpm.conf}"

get_github_token() {
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
printf '%s' "$GITHUB_TOKEN"
return 0
fi
[[ -f "$ULPM_CONFIG_FILE" && -r "$ULPM_CONFIG_FILE" ]] || return 1
local line token
while IFS=read -r line || [[ -n "$line" ]]; do
[[ "$line" =~ ^[[:space:]]*GITHUB_TOKEN= ]] || continue
token="${line#*=}"
token="${token#\"}"; token="${token%\"}"
token="${token#\'}"; token="${token%\'}"
[[ -n "$token" ]] ||continue
printf '%s' "$token"
return 0
done < "$ULPM_CONFIG_FILE"
return 1
}

cmd_token() {
local token="${1:-}"conf_dir tmp_file line found=0
if [[ -z "$token" ]]; then
[[ -r /dev/tty ]] || {
error 'No terminal available to read the GitHub token.'
return 1
}
printf '%b' "${C_CYAN}Enter GitHub Personal Access Token (PAT):${C_RESET}" >/dev/tty
IFS= read -r -s token < /dev/tty || {
printf '\n' >/dev/tty
error 'Could not read token.'
return 1
}
printf '\n' >/dev/tty
fi
[[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || {
error 'Invalid token format; use only alphanumeric characters, underscores, dots, or hyphens.'
return1
}

conf_dir="$(dirname -- "$ULPM_CONFIG_FILE")"
mkdir-p -- "$conf_dir" || {
error "Could not create $conf_dir"
return 1
}
chmod 700 -- "$conf_dir" 2>/dev/null || true
tmp_file="$(mktemp "$conf_dir/.ulpm.conf.XXXXXX")" || {
error 'Could not create temporary config file.'
return 1
}
chmod 600 -- "$tmp_file" || {
rm -f -- "$tmp_file"
return 1
}
if [[ -f "$ULPM_CONFIG_FILE" ]];then
while IFS= read -r line || [[ -n "$line" ]]; do
if [[ "$line" =~ ^[[:space:]]*GITHUB_TOKEN= ]]; then
if (( found == 0 ));then
printf 'GITHUB_TOKEN="%s"\n' "$token" >> "$tmp_file" || {
rm -f -- "$tmp_file"
return 1
}
found=1
fi
else
printf '%s\n' "$line" >> "$tmp_file" ||{
rm -f -- "$tmp_file"
return 1
}
fi
done < "$ULPM_CONFIG_FILE"
fi
(( found == 1 )) || printf'GITHUB_TOKEN="%s"\n' "$token" >> "$tmp_file" || {
rm -f -- "$tmp_file"
return 1
}
sync_file "$tmp_file"
if ! chmod600 -- "$tmp_file" || ! mv -f -- "$tmp_file" "$ULPM_CONFIG_FILE"; then
rm -f -- "$tmp_file"
error 'Could not update configfile.'
return 1
fi
sync_dir "$conf_dir"
export GITHUB_TOKEN="$token"
info "GitHub token saved successfully in $ULPM_CONFIG_FILE"
}

fetch_github_api() {
local endpoint="${1:-}" ttl="${2:-15}"cache_api_dir cache_key cache_file token response http_code tmp_file
endpoint="${endpoint#https://api.github.com/}"
endpoint="${endpoint#/}"
if [[ -z "$endpoint" || "$endpoint" == *'..'* || "$endpoint" == *$'\n'* || "$endpoint" == *$'\r'* || "$endpoint" == *' '* || "$endpoint" == *"://"* || "$endpoint" == /* ]]; then
error 'Invalid GitHub API endpoint.'
return 2
fi
[[ "$ttl" =~ ^[0-9]+$ ]] || {
error "Invalid API cache TTL: $ttl"
return2
}
check_dependencies curl jq sha256sum awk || return 1
cache_api_dir="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/api"
mkdir -p -- "$cache_api_dir" || return 1
cache_key="$(printf '%s' "$endpoint" | sha256sum | awk '{print $1}')" || return 1
cache_file="$cache_api_dir/${cache_key}.json"

if [[ -f "$cache_file" ]] && jq -e . "$cache_file" >/dev/null 2>&1; then
if [[ "$ttl" != 0 ]] && ! find "$cache_file" -mmin "+$ttl" -print-quit 2>/dev/null | grep -q .; then
cat -- "$cache_file"
return 0
fi
fi

local auth_header=()
if token="$(get_github_token)"; then
auth_header=(-H "Authorization: Bearer $token")
fi
tmp_file="$(mktemp "$cache_api_dir/.response.XXXXXX")" || return1
http_code="$(curl -sS --connect-timeout 10 --max-time25 --retry 2 \
"${auth_header[@]}" -H 'Accept: application/vnd.github+json' -H 'User-Agent: ulpm-engine' \
-o "$tmp_file" -w '%{http_code}' "https://api.github.com/${endpoint}")" || http_code=000
response="$(cat -- "$tmp_file" 2>/dev/null ||true)"
if [[ "$http_code" =~ ^2[0-9][0-9]$ ]] && [[ -n "$response"]] && jq -e . >/dev/null 2>&1 <<< "$response"; then
chmod 600 -- "$tmp_file" 2>/dev/null || true
sync_file "$tmp_file"
mv-f -- "$tmp_file" "$cache_file" || {
rm -f -- "$tmp_file"
return 1
}
sync_dir "$cache_api_dir"
printf '%s\n' "$response"
return 0
fi
rm -f -- "$tmp_file"
if [[ -f "$cache_file" ]] && jq -e . "$cache_file" >/dev/null 2>&1; then
warn "GitHub API returned HTTP ${http_code};using cached response."
cat -- "$cache_file"
return 0
fi
[[ -n "$response" ]] && printf '%s\n' "$response"
error "GitHub API request failed(HTTP ${http_code})."
return 1
}

# ==============================================================================
# System Diagnostic & Self-UpdateEngine
# ==============================================================================

cmd_doctor() {
info 'Running ULPM environmental,hardware and sandbox diagnostic...'
printf '%s\n' '--------------------------------------------------------------------------------'
local ok="${C_GREEN}✔ OK${C_RESET}" warn_tag="${C_YELLOW}⚠ WARN${C_RESET}" fail_tag="${C_RED}✖ FAIL${C_RESET}"
local arch kver
arch="$(detect_arch)"; kver="$(uname -r)"
printf '%-34s: %s (%s)\n' 'Host Architecture & Kernel' "$arch" "$kver"

#1. Bubblewrap engine
if command -v bwrap >/dev/null 2>&1 &&bwrap --ro-bind / / true > /dev/null 2>&1; then
printf '%-34s : %b (Unprivileged namespaces)\n' 'Bubblewrap Sandbox Engine' "$ok"
elif [[ ${EUID:-1} -eq 0 ]] && command -v bwrap >/dev/null 2>&1 && bwrap --dev-bind / / true >/dev/null 2>&1; then
printf '%-34s : %b (Privileged/root mode)\n' 'Bubblewrap Sandbox Engine' "$warn_tag"
elif is_proot; then
printf '%-34s : %b (PRoot environment: sandbox fallback active)\n' 'Bubblewrap Sandbox Engine' "$warn_tag"
else
printf '%-34s : %b (Cannot create user namespace)\n' 'Bubblewrap Sandbox Engine' "$fail_tag"
fi

# 2. Mount engines
if command -v squashfuse >/dev/null 2>&1 && can_use_fuse; then
printf '%-34s : %b (Native FUSE available)\n' 'Squashfuse (Mount Engine)' "$ok"
elif command -v squashfuse >/dev/null 2>&1;then
printf '%-34s : %b (Binary present but /dev/fuse blocked: unpack fallbackactive)\n' 'Squashfuse' "$warn_tag"
else
printf '%-34s : %b (Mounts will fall back to unpack mode)\n' 'Squashfuse' "$warn_tag"
fi

if command -v fuse-overlayfs >/dev/null 2>&1 &&can_use_fuse; then
printf '%-34s : %b\n' 'fuse-overlayfs (COW Engine)' "$ok"
else
printf '%-34s : %b(Persistent overlay disabled)\n' 'fuse-overlayfs' "$warn_tag"
fi

#3. Portals & D-Bus Proxy
if command -v xdg-dbus-proxy >/dev/null 2>&1; then
printf '%-34s : %b (Dynamic sessionfiltering)\n' 'xdg-dbus-proxy' "$ok"
else
printf '%-34s : %b (D-Bus sandboxing unavailable)\n' 'xdg-dbus-proxy' "$warn_tag"
fi

local portal_status="$fail_tag"
if pgrep -f "xdg-desktop-portal" >/dev/null 2>&1; then
portal_status="$ok"
fi
printf '%-34s : %b\n' 'XDG Desktop Portal' "$portal_status"

# 4. GPU & Direct Rendering
local dri_status="$fail_tag"
if [[ -d "/dev/dri" && -r "/dev/dri" ]]; then
dri_status="$ok"
shopt -s nullglob
local nv_devs=(/dev/nvidia*)
shopt -u nullglob
(( ${#nv_devs[@]} > 0 )) && dri_status="$ok (NVIDIA Direct)"
fi
printf '%-34s : %b\n' 'GPU & Direct Rendering (/dev/dri)' "$dri_status"

# 5. Core dependencies
local missing_tools=() bin
for bin in unsquashfs mksquashfs jq curl openssl tar flock sync; do
command -v "$bin" >/dev/null 2>&1 || missing_tools+=("$bin")
done
if (( ${#missing_tools[@]} ==0 )); then
printf '%-34s : %b (All critical tools present)\n' 'Core CLI Dependencies' "$ok"
else
printf '%-34s : %b (Missing:%s)\n' 'Core CLI Dependencies' "$fail_tag" "${missing_tools[*]}"
fi

# 6. Keys& Keychain
local keys_dir="${ULPM_KEYS_DIR:-${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm}/keys"
local trusted_dir="${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/trusted_keys"
local default_priv="$keys_dir/default.priv"
if [[ -f "$default_priv" ]]; then
printf '%-34s : %b (Default private keypresent)\n' 'Cryptographic Keypair' "$ok"
else
printf '%-34s : %b (No default keypair generated)\n' 'Cryptographic Keypair' "$warn_tag"
fi

local trust_count=0
shopt -s nullglob
local trusted_files=("$trusted_dir"/*.pub "$keys_dir"/*.pub)
shopt -u nullglob
trust_count="${#trusted_files[@]}"
printf '%-34s : %s key(s) registered\n''Trust Keychain' "$trust_count"

# 7. GitHub API token
local token
iftoken="$(get_github_token)"; then
local gh_rate
gh_rate="$(fetch_github_api rate_limit 0 2>/dev/null | jq -r '.resources.core.remaining //"Unknown"' 2>/dev/null || true)"
[[ -n "$gh_rate" ]] ||gh_rate='Unknown'
printf '%-34s : %b (Remaining requests: %s)\n' 'GitHub API Authentication' "$ok" "$gh_rate"
else
printf '%-34s : %b (Unauthenticated API rate limit applies)\n' 'GitHub API Authentication' "$warn_tag"
fi
printf '%s\n' '--------------------------------------------------------------------------------'
}

cmd_self_update() {
local repo_target="${1:-${ULPM_GITHUB_REPO:-}}"
[[ -n "$repo_target" ]] || {
error 'No update repository configured. Usage: ulpm self-update <owner/repo>'
return 1
}
[[ "$repo_target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
error 'Invalid repository name. Expected owner/repo.'
return 1
}
[[ -n "${ULPM_LIB_DIR:-}" && -d "$ULPM_LIB_DIR" ]] || {
error 'ULPM_LIB_DIR is not configured or missing; refusingto update.'
return 1
}

info "Checking for ULPM core engine updates from '$repo_target'..."
local rel_data latest_tag tarball_url
rel_data="$(fetch_github_api "repos/${repo_target}/releases/latest" 5)" || {
error'Failed to contact update server.'
return 1
}
latest_tag="$(jq -r'.tag_name // empty' <<< "$rel_data")"
tarball_url="$(jq -r'.tarball_url // empty' <<< "$rel_data")"
[[ -n "$latest_tag" && -n "$tarball_url" ]] || {
error 'No release archive found on remote repository.'
return 1
}
[[ "$tarball_url" == https://api.github.com/repos/*/tarball/* || "$tarball_url" == https://codeload.github.com/*/tar.gz/* ]] || {
error 'Unexpected release archive URL; refusing to download it.'
return1
}
if [[ "$latest_tag" == "v${ULPM_VERSION:-}"|| "$latest_tag" == "${ULPM_VERSION:-}" ]]; then
info "ULPM is already at the latest release ($latest_tag)."
return 0
fi
printf '%b➜%b Engine update available: %bv%s%b ➔ %b%s%b\n' \
"$C_GREEN" "$C_RESET" "$C_RED" "${ULPM_VERSION:-unknown}" "$C_RESET" "$C_GREEN" "$latest_tag" "$C_RESET"

local cache_root="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}" tmp_dir ulpm_root bin_path backup_dir
mkdir -p -- "$cache_root" || return 1
tmp_dir="$(mktemp -d "$cache_root/ulpm_update_XXXXXX")" || return 1
ulpm_root="${ULPM_ROOT_DIR:-${ULPM_LIB_DIR%/lib/ulpm}}"
bin_path="${ULPM_BIN:-$ulpm_root/bin/ulpm}"
backup_dir="$tmp_dir/backup"
mkdir -p -- "$tmp_dir/extracted""$backup_dir" || {
rm -rf -- "$tmp_dir"
return 1
}

local auth_header=() token
if token="$(get_github_token)"; then
auth_header=(-H "Authorization: Bearer $token")
fi
log "Downloading engine payload($latest_tag)..."
if ! curl -fLsS --connect-timeout 10 --max-time 180 --retry 2 "${auth_header[@]}" "$tarball_url" -o"$tmp_dir/update.tar.gz"; then
error 'Download failed.'
rm -rf-- "$tmp_dir"
return 1
fi
tar -tzf "$tmp_dir/update.tar.gz" > "$tmp_dir/archive.list" || {
error 'Corrupted archive payload.'
rm -rf -- "$tmp_dir"
return 1
}
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$tmp_dir/archive.list"; then
error 'Archive contains unsafe paths; update cancelled.'
rm -rf -- "$tmp_dir"
return1
fi
if ! tar -tvzf "$tmp_dir/update.tar.gz"> "$tmp_dir/archive.verbose"; then
error 'Could not inspect update archive entries.'
rm -rf -- "$tmp_dir"
return 1
fi
if awk 'substr($0,1,1) ~ /^[bcps]/ { bad=1 } END { exit bad ? 0 : 1 }' "$tmp_dir/archive.verbose"; then
error 'Archive contains dangerous special device nodes or FIFOs; update cancelled.'
rm -rf -- "$tmp_dir"
return 1
fi
if ! tar -xzf "$tmp_dir/update.tar.gz" -C "$tmp_dir/extracted" --strip-components=1 --no-same-owner --no-same-permissions; then
error 'Could not safely extract update archive.'
rm -rf -- "$tmp_dir"
return1
fi
local update_lib_dir=''
if [[ -d "$tmp_dir/extracted/lib/ulpm" && -f "$tmp_dir/extracted/lib/ulpm/utils.sh" ]]; then
update_lib_dir="$tmp_dir/extracted/lib/ulpm"
elif [[ -d "$tmp_dir/extracted/lib" && -f "$tmp_dir/extracted/lib/utils.sh" ]]; then
update_lib_dir="$tmp_dir/extracted/lib"
else
error 'Archive must contain lib/ulpm/utils.sh or lib/utils.sh, plus bin/ulpm.'
rm -rf -- "$tmp_dir"
return 1
fi
[[ -f "$tmp_dir/extracted/bin/ulpm" ]] || {
error 'Archive does not contain bin/ulpm.'
rm -rf -- "$tmp_dir"
return 1
}
[[ -d "$ULPM_LIB_DIR" && ! -L"$ULPM_LIB_DIR" && -f "$bin_path" && ! -L "$bin_path" ]] || {
error 'Current ULPM installation is incomplete or uses unsafe symbolic links; refusing to update.'
rm -rf -- "$tmp_dir"
return 1
}

if ! cp-a -- "$ULPM_LIB_DIR" "$backup_dir/lib" || ! cp -a --"$bin_path" "$backup_dir/ulpm"; then
error 'Could not backup current installation;update cancelled.'
rm -rf -- "$tmp_dir"
return 1
fi
log 'Applying update payload...'
if ! cp -a -- "$update_lib_dir/." "$ULPM_LIB_DIR/" || ! install -m 755 -- "$tmp_dir/extracted/bin/ulpm" "$bin_path"; then
error 'Update failed; restoring previous ULPM files.'
rm -rf -- "$ULPM_LIB_DIR"
cp -a -- "$backup_dir/lib" "$ULPM_LIB_DIR" 2>/dev/null || error "WARNING: library rollback failed; backup remains at $backup_dir/lib"
cp -a -- "$backup_dir/ulpm" "$bin_path" 2>/dev/null || error "WARNING: executable rollback failed; backup remains at $backup_dir/ulpm"
rm -rf -- "$tmp_dir"
return 1
fi
rm -rf -- "$tmp_dir"
info "ULPM files updated to $latest_tag."
warn'The archive path was checked, but this function does not verify a publisher signature. Only update from a repository you trust.'
cmd_doctor
}

cmd_completion() {
local comp_file
for comp_file in \
"${ULPM_ROOT_DIR:-}/completion.bash" \
"${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/completion.bash" \
"/usr/local/share/bash-completion/completions/ulpm" \
"/usr/share/bash-completion/completions/ulpm"; do
if [[ -f "$comp_file" && -r "$comp_file" ]]; then
cat -- "$comp_file"
return 0
fi
done
cat <<'EOF_COMPLETION'
_ulpm_completion() {
local cur prev
COMPREPLY=()
cur="${COMP_WORDS[COMP_CWORD]}"
prev="${COMP_WORDS[COMP_CWORD-1]}"
case "$prev" in
run|stream|install|pack|sign|trust|inspect|info) COMPREPLY=( $(compgen -f -- "$cur") ); return ;;
--bind) COMPREPLY=(); return;;
esac
COMPREPLY=( $(compgen -W 'run stream override permissions runtime pack deb-pack install upgrade remove search list inspect doctor keygen sign trust token self-update clean integrate completion help version repo depstransaction history rollback' -- "$cur") )
}
complete -F _ulpm_completion ulpm
EOF_COMPLETION
return 0
}
