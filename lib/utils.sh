#!/usr/bin/env bash
# ==============================================================================
# lib/utils.sh - Core Utilities, Binary Helpers & Environment Setup
# ==============================================================================

# Strict color configuration (support NO_COLOR standard & terminal detection)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN='' C_BOLD=''
fi

log()   { printf "%b[ulpm]%b %s\n" "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*"; }
info()  { printf "%b[+]%b %s\n" "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*"; }
warn()  { printf "%b[!]%b %s\n" "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; }
error() { printf "%b[x]%b %s\n" "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; }
die()   { error "$*"; exit 1; }

# Binary-safe string / URI normalizer (strips file:// and handles url-encodings)
normalize_target() {
    local t="${1:-}"
    if [[ "$t" == file://* ]]; then
        t="${t#file://}"
        t="${t#localhost}"
        # Block null bytes
        [[ "$t" == *%00* ]] && return 1
        # Safe percent-decoding
        t="$(printf '%s' "$t" | sed -E 's/%([0-9A-Fa-f]{2})/\\x\1/g')"
        t="$(printf '%b' "$t")"
    fi
    printf '%s' "$t"
}

init_environment() {
    mkdir -p "${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}" \
        "${ULPM_CONFIG_HOME:-$HOME/.config/ulpm}" \
        "${ULPM_CACHE_HOME:-$HOME/.cache/ulpm}/tmp" \
        "${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}" \
        "${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}"
    chmod 700 "${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}" 2>/dev/null || true
    touch "${ULPM_DB:-$HOME/.local/share/ulpm/installed.db}"
}

check_dependencies() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        return 1
    fi
}

# Concurrency locking mechanism (prevents race conditions on database)
ULPM_LOCK_FD=200

acquire_lock() {
    local timeout="${1:-10}"
    local lock_file="${ULPM_LOCK:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db.lock}"

    mkdir -p "$(dirname "$lock_file")"
    eval "exec $ULPM_LOCK_FD>\"$lock_file\""

    if ! flock -n "$ULPM_LOCK_FD"; then
        warn "Another instance of ULPM is currently active. Waiting up to ${timeout}s..."
        if ! flock -w "$timeout" "$ULPM_LOCK_FD"; then
            error "Could not acquire database lock within ${timeout}s ($lock_file)."
            release_lock
            return 1
        fi
    fi
}

release_lock() {
    if { true >&"$ULPM_LOCK_FD"; } 2>/dev/null; then
        flock -u "$ULPM_LOCK_FD" 2>/dev/null || true
        eval "exec $ULPM_LOCK_FD>&-" 2>/dev/null || true
    fi
}

# Run a command under guaranteed lock and release immediately after
with_lock() {
    acquire_lock 10 || return 1
    local status=0
    "$@" || status=$?
    release_lock
    return $status
}

safe_unmount() {
    local mount_point="$1"
    if [[ -d "$mount_point" ]] && mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount3 -u -z "$mount_point" 2>/dev/null \
            || fusermount -u -z "$mount_point" 2>/dev/null \
            || umount -l "$mount_point" 2>/dev/null \
            || true
    fi
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*|armhf)   echo "armhf" ;;
        i386|i686)      echo "i386" ;;
        riscv64)        echo "riscv64" ;;
        *)              echo "$m" ;;
    esac
}

find_host_loader() {
    local cand
    local candidates=(
        /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
        /lib/ld-linux-aarch64.so.1 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
        /lib/ld-linux-armhf.so.3 /lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
        /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2
        /lib/ld-linux-riscv64-lp64d.so.1 /lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1
        /lib/ld-musl-x86_64.so.1 /lib/ld-musl-aarch64.so.1
    )
    for cand in "${candidates[@]}"; do
        if [[ -x "$cand" ]]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}
