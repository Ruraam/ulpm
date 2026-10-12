#!/usr/bin/env bash
# ==============================================================================
# lib/utils.sh - Core Utilities, Binary Helpers & Environment Setup
# ==============================================================================

# Strict color configuration
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

log()   { printf "${C_BLUE}${C_BOLD}[ulpm]${C_RESET} %s\n" "$*"; }
info()  { printf "${C_GREEN}${C_BOLD}[+]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}${C_BOLD}[!]${C_RESET} %s\n" "$*" >&2; }
error() { printf "${C_RED}${C_BOLD}[x]${C_RESET} %s\n" "$*" >&2; }

# Binary-safe string / URI normalizer (strips file:// and handles url-encodings)
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

init_environment() {
    mkdir -p "$ULPM_DATA_HOME" "$ULPM_CONFIG_HOME" "$ULPM_CACHE_HOME" \
        "$ULPM_APPS_DIR" "$ULPM_KEYS_DIR" "$ULPM_CACHE_HOME/tmp"
    chmod 700 "$ULPM_KEYS_DIR" 2>/dev/null || true
    touch "$ULPM_DB"
}

check_dependencies() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

acquire_lock() {
    local lock_file="$ULPM_CACHE_HOME/ulpm.lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        warn "Another instance of ULPM is currently writing. Waiting..."
        flock 200
    fi
}

release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
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
    for cand in \
        /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
        /lib/ld-linux-aarch64.so.1 /lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
        /lib/ld-linux-armhf.so.3 /lib/arm-linux-gnueabihf/ld-linux-armhf.so.3 \
        /lib/ld-linux.so.2 /lib/i386-linux-gnu/ld-linux.so.2 \
        /lib/ld-linux-riscv64-lp64d.so.1 /lib/riscv64-linux-gnu/ld-linux-riscv64-lp64d.so.1 \
        /lib/ld-musl-*.so.1; do
        if [[ -x "$cand" ]]; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}
