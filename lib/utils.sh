#!/usr/bin/env bash
# ==============================================================================
# lib/utils.sh - Utility functions, logging, signals & lock management
# ==============================================================================

# ANSI color codes with NO_COLOR and non-interactive terminal fallback
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_BOLD='\033[1m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

log()   { printf "${C_BLUE}${C_BOLD}[ulpm]${C_RESET} %s\n" "$*"; }
info()  { printf "${C_GREEN}${C_BOLD}[+]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}${C_BOLD}[!]${C_RESET} %s\n" "$*" >&2; }
error() { printf "${C_RED}${C_BOLD}[x]${C_RESET} %s\n" "$*" >&2; }

init_environment() {
    mkdir -p "$ULPM_DATA_HOME" "$ULPM_CONFIG_HOME" "$ULPM_CACHE_HOME" \
        "$ULPM_APPS_DIR" "$ULPM_KEYS_DIR" "$ULPM_CACHE_HOME/tmp"
    chmod 700 "$ULPM_KEYS_DIR" 2>/dev/null || true
}

check_dependencies() {
    local missing=()
    for dep in "$@"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing system dependencies: ${missing[*]}"
        error "Please install the required packages to continue."
        exit 1
    fi
}

# Acquire lock to prevent concurrent write collisions
acquire_lock() {
    local lock_file="$ULPM_CACHE_HOME/ulpm.lock"
    exec 200>"$lock_file"
    if ! flock -n 200; then
        warn "Another instance of ulpm is active. Waiting for lock..."
        flock 200
    fi
}

release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
}

# Safe lazy unmount and cleanup (supports fuse3, fuse2, umount)
safe_unmount() {
    local mount_point="$1"
    if [ -d "$mount_point" ] && mountpoint -q "$mount_point" 2>/dev/null; then
        fusermount3 -u -z "$mount_point" 2>/dev/null \
            || fusermount -u -z "$mount_point" 2>/dev/null \
            || umount -l "$mount_point" 2>/dev/null \
            || true
    fi
}
