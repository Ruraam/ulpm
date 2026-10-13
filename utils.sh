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

# ==============================================================================
# GitHub Configuration, API & Authentication Helper
# ==============================================================================

ULPM_CONFIG_FILE="${ULPM_CONFIG_HOME:-$HOME/.config/ulpm}/ulpm.conf"

get_github_token() {
    # 1. Environment variable takes priority
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        printf '%s' "$GITHUB_TOKEN"
        return 0
    fi

    # 2. Persistent ULPM configuration file
    if [[ -f "$ULPM_CONFIG_FILE" ]]; then
        local token
        token="$(grep -E '^[[:space:]]*GITHUB_TOKEN=' "$ULPM_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"'\'' ' || true)"
        if [[ -n "$token" ]]; then
            printf '%s' "$token"
            return 0
        fi
    fi

    return 1
}

cmd_token() {
    local token="${1:-}"

    if [[ -z "$token" ]]; then
        printf "\033[0;36mEnter GitHub Personal Access Token (PAT): \033[0m"
        read -rs token </dev/tty
        echo ""
    fi

    if [[ -z "$token" ]]; then
        error "Token cannot be empty."
        return 1
    fi

    local conf_dir
    conf_dir="$(dirname "$ULPM_CONFIG_FILE")"
    mkdir -p "$conf_dir"
    chmod 700 "$conf_dir" 2>/dev/null || true

    if [[ -f "$ULPM_CONFIG_FILE" ]] && grep -q '^[[:space:]]*GITHUB_TOKEN=' "$ULPM_CONFIG_FILE"; then
        sed -i "s|^[[:space:]]*GITHUB_TOKEN=.*|GITHUB_TOKEN=\"$token\"|" "$ULPM_CONFIG_FILE"
    else
        printf 'GITHUB_TOKEN="%s"\n' "$token" >> "$ULPM_CONFIG_FILE"
    fi
    chmod 600 "$ULPM_CONFIG_FILE" 2>/dev/null || true

    # Also export for the current session
    export GITHUB_TOKEN="$token"
    info "GitHub token saved successfully in $ULPM_CONFIG_FILE"
}

fetch_github_api() {
    local endpoint="$1"
    local ttl="${2:-15}" # Cache 15 minutes by default

    endpoint="${endpoint#https://api.github.com/}"
    endpoint="${endpoint#/}"

    local cache_api_dir="${ULPM_CACHE_HOME:-$HOME/.cache/ulpm}/api"
    mkdir -p "$cache_api_dir"

    local cache_key
    cache_key="$(printf '%s' "$endpoint" | tr '/' '_')"
    local cache_file="$cache_api_dir/${cache_key}.json"

    # Check local cache TTL
    if [[ -f "$cache_file" ]] && [[ -z "$(find "$cache_file" -mmin +"$ttl" 2>/dev/null)" ]]; then
        cat "$cache_file"
        return 0
    fi

    local auth_header=()
    local token
    if token="$(get_github_token)"; then
        auth_header=(-H "Authorization: Bearer $token")
    fi

    local response
    response="$(curl -sS --connect-timeout 10 --max-time 25 --retry 2 \
        "${auth_header[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ulpm-engine" \
        "https://api.github.com/${endpoint}" 2>/dev/null)" || {
        # If network fails but cache (even expired) exists, use it as fallback
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi
        return 1
    }

    # Detect rate limit or auth errors
    if grep -qiE '"message"[[:space:]]*:[[:space:]]*"(API rate limit|Not Found|Bad credentials)' <<< "$response"; then
        if [[ -f "$cache_file" ]]; then
            cat "$cache_file"
            return 0
        fi
        printf '%s\n' "$response"
        return 1
    fi

    if [[ -n "$response" ]] && jq -e . >/dev/null 2>&1 <<< "$response"; then
        printf '%s\n' "$response" > "$cache_file"
        printf '%s\n' "$response"
        return 0
    fi

    return 1
}

# ==============================================================================
# System Diagnostic & Self-Update Engine
# ==============================================================================

cmd_doctor() {
    info "Running ULPM Environmental & Kernel Capability Diagnostic..."
    echo "--------------------------------------------------------------------------------"

    local ok="${C_GREEN}✔ OK${C_RESET}"
    local warn_tag="${C_YELLOW}⚠ WARN${C_RESET}"
    local fail_tag="${C_RED}✖ FAIL${C_RESET}"

    # 1. Host Architecture & Kernel
    local arch kver
    arch="$(detect_arch)"
    kver="$(uname -r)"
    printf "%-32s : %s (%s)\n" "Host Architecture & Kernel" "$arch" "$kver"

    # 2. Linux Namespaces / Unprivileged Sandbox Support
    if bwrap --ro-bind / / true >/dev/null 2>&1; then
        printf "%-32s : %b (Unprivileged Namespaces)\n" "Bubblewrap Sandbox Engine" "$ok"
    elif [[ $EUID -eq 0 ]] && bwrap --dev-bind / / true >/dev/null 2>&1; then
        printf "%-32s : %b (Privileged / Root mode)\n" "Bubblewrap Sandbox Engine" "$warn_tag"
    else
        printf "%-32s : %b (Cannot create user namespace)\n" "Bubblewrap Sandbox Engine" "$fail_tag"
    fi

    # 3. SquashFS / FUSE Support
    if command -v squashfuse >/dev/null 2>&1; then
        printf "%-32s : %b\n" "Squashfuse (Mount Engine)" "$ok"
    else
        printf "%-32s : %b (Mounts will fallback to unsquashfs)\n" "Squashfuse" "$warn_tag"
    fi

    # 4. Storage Engine (fuse-overlayfs)
    if command -v fuse-overlayfs >/dev/null 2>&1; then
        printf "%-32s : %b\n" "fuse-overlayfs (COW Storage)" "$ok"
    else
        printf "%-32s : %b (Performance reduced on persistent layers)\n" "fuse-overlayfs" "$warn_tag"
    fi

    # 5. Core Binaries Audit
    local missing_tools=()
    for bin in mksquashfs unsquashfs jq curl openssl tar zstd; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            missing_tools+=("$bin")
        fi
    done
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        printf "%-32s : %b (All critical tools present)\n" "Core CLI Dependencies" "$ok"
    else
        printf "%-32s : %b (Missing: %s)\n" "Core CLI Dependencies" "$fail_tag" "${missing_tools[*]}"
    fi

    # 6. Cryptography Engine & Keychain
    local trusted_keys="${ULPM_CONFIG_HOME:-$HOME/.config/ulpm}/trusted_keys"
    local local_sec="${ULPM_KEYS_DIR:-$HOME/.config/ulpm/keys}/local.sec"
    if [[ -f "$local_sec" ]]; then
        printf "%-32s : %b (Ed25519 Signing Key Active)\n" "Cryptographic Keypair" "$ok"
    else
        printf "%-32s : %b (No signing key, package signing disabled)\n" "Cryptographic Keypair" "$warn_tag"
    fi

    local trust_count=0
    [[ -d "$trusted_keys" ]] && trust_count=$(find "$trusted_keys" -type f -name "*.pub" 2>/dev/null | wc -l)
    printf "%-32s : %s key(s) registered\n" "Trust Keychain" "$trust_count"

    # 7. GitHub API Token Status
    local token
    if token="$(get_github_token)"; then
        local gh_rate
        gh_rate="$(fetch_github_api "rate_limit" 0 2>/dev/null | jq -r '.resources.core.remaining // "Err"' 2>/dev/null || echo "Unknown")"
        printf "%-32s : %b (Remaining requests: %s/5000)\n" "GitHub API Authentication" "$ok" "$gh_rate"
    else
        printf "%-32s : %b (Rate-limit restricted to 60 req/h)\n" "GitHub API Authentication" "$warn_tag"
    fi

    echo "--------------------------------------------------------------------------------"
}

cmd_self_update() {
    local repo_target="${1:-${ULPM_GITHUB_REPO:-}}"
    [[ -z "$repo_target" ]] && {
        error "No update repository configured. Usage: ulpm self-update <owner/repo>"
        return 1
    }

    info "Checking for ULPM core engine updates from '$repo_target'..."

    local rel_data
    rel_data="$(fetch_github_api "repos/${repo_target}/releases/latest" 5)" || {
        error "Failed to contact update server."
        return 1
    }

    local latest_tag tarball_url
    latest_tag="$(jq -r '.tag_name // empty' <<< "$rel_data")"
    tarball_url="$(jq -r '.tarball_url // empty' <<< "$rel_data")"

    if [[ -z "$latest_tag" || -z "$tarball_url" ]]; then
        error "No release archive found on remote repository."
        return 1
    fi

    if [[ "$latest_tag" == "v${ULPM_VERSION}" || "$latest_tag" == "${ULPM_VERSION}" ]]; then
        info "ULPM is already at the latest release ($latest_tag)."
        return 0
    fi

    echo -e " ${C_GREEN}➜${C_RESET} Engine update available: ${C_RED}v${ULPM_VERSION}${C_RESET} ➔ ${C_GREEN}$latest_tag${C_RESET}"

    local tmp_dir
    tmp_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/ulpm_update_XXXXXX")"
    trap 'rm -rf "${tmp_dir:-}"' RETURN

    log "Downloading engine payload ($latest_tag)..."
    local auth_header=()
    local token
    if token="$(get_github_token)"; then
        auth_header=(-H "Authorization: Bearer $token")
    fi

    curl -fL "${auth_header[@]}" "$tarball_url" -o "$tmp_dir/update.tar.gz" || {
        error "Download failed."
        return 1
    }

    mkdir -p "$tmp_dir/extracted"
    tar -xzf "$tmp_dir/update.tar.gz" -C "$tmp_dir/extracted" --strip-components=1 || {
        error "Corrupted archive payload."
        return 1
    }

    # Backup current engine before atomic replacement
    local ulpm_root="${ULPM_LIB_DIR%/*}" # e.g. ~/.local
    local backup_dir="${ULPM_CACHE_HOME:-/tmp}/ulpm_backup_v${ULPM_VERSION}"
    mkdir -p "$backup_dir/lib" "$backup_dir/bin"
    cp -rf "$ULPM_LIB_DIR" "$backup_dir/lib/" 2>/dev/null || true
    cp -f "${ULPM_BIN:-$ulpm_root/bin/ulpm}" "$backup_dir/bin/" 2>/dev/null || true

    log "Applying update payload..."
    if [[ -d "$tmp_dir/extracted/lib" ]]; then
        cp -rf "$tmp_dir/extracted/lib/"* "$ULPM_LIB_DIR/"
    fi
    if [[ -f "$tmp_dir/extracted/bin/ulpm" ]]; then
        cp -f "$tmp_dir/extracted/bin/ulpm" "${ULPM_BIN:-$ulpm_root/bin/ulpm}"
        chmod 755 "${ULPM_BIN:-$ulpm_root/bin/ulpm}"
    fi

    info "ULPM successfully upgraded to $latest_tag!"
    cmd_doctor
}

    cmd_completion() {
        local comp_file="${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/completion.bash"
        if [[ -f "$comp_file" ]]; then
            cat "$comp_file"
        else
            error "Completion file not found at $comp_file"
            return 1
        fi
}