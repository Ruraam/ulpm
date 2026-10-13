#!/usr/bin/env bash
# ==============================================================================
# lib/stream.sh - Ephemeral RAM Streaming Engine
# ==============================================================================

resolve_stream_url() {
    local uri="$1"

    # Direct HTTP/HTTPS or local file link
    if [[ "$uri" =~ ^https?:// ]] || [[ "$uri" == file://* ]]; then
        printf '%s\n' "$uri"
        return 0
    fi

    # GitHub shorthand syntax: owner/repo
    if [[ "$uri" =~ ^([a-zA-Z0-9._-]+)/([a-zA-Z0-9._-]+)$ ]]; then
        check_dependencies curl jq
        local owner="${BASH_REMATCH[1]}"
        local repo="${BASH_REMATCH[2]}"
        local arch
        arch="$(detect_arch)"

        log "Resolving latest GitHub release for $owner/$repo ($arch)..."
        local api_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
        local release_json
        release_json="$(curl -fsSL "$api_url" 2>/dev/null || true)"

        if [[ -z "$release_json" ]]; then
            error "Failed to fetch release metadata from GitHub API for '$owner/$repo'."
            return 1
        fi

        # Find .lpk asset matching current host architecture or fallback to any .lpk
        local download_url
        download_url="$(
            echo "$release_json" | jq -r --arg arch "$arch" '
                .assets[] | select(.name | endswith(".lpk")) |
                select(.name | contains($arch)) | .browser_download_url
            ' | head -n 1
        )"

        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            download_url="$(
                echo "$release_json" | jq -r '
                    .assets[] | select(.name | endswith(".lpk")) | .browser_download_url
                ' | head -n 1
            )"
        fi

        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            error "No .lpk release asset found in $owner/$repo."
            return 1
        fi

        printf '%s\n' "$download_url"
        return 0
    fi

    printf '%s\n' "$uri"
}

cmd_stream() {
    local source_input="${1:-}"
    [[ -z "$source_input" ]] && {
        error "Usage: ulpm stream <url|owner/repo> [sandbox_flags] [-- app_args...]"
        return 1
    }
    shift || true

    check_dependencies curl

    local target_url
    target_url="$(resolve_stream_url "$source_input")" || return 1

    # Choose volatile memory target: prioritize /dev/shm for generous limits
    local ram_base="/dev/shm"
    if [[ ! -d "$ram_base" || ! -w "$ram_base" ]]; then
        ram_base="${XDG_RUNTIME_DIR:-/tmp}"
    fi

    local tmp_lpk
    tmp_lpk="$(mktemp "${ram_base}/stream_XXXXXX.lpk")"

    # Contextual cleanup
    _cleanup_stream() {
        rm -f "$tmp_lpk"
    }
    trap '_cleanup_stream' RETURN
    trap '_cleanup_stream; exit 130' INT
    trap '_cleanup_stream; exit 143' TERM HUP

    log "Streaming package directly into volatile memory (RAM: $ram_base)..."

    local curl_opts=(-fL --retry 2)
    if [[ -t 1 ]]; then
        curl_opts+=(--progress-bar)
    else
        curl_opts+=(-sS)
    fi

    if ! curl "${curl_opts[@]}" "$target_url" -o "$tmp_lpk"; then
        error "Failed to stream package from: $target_url"
        return 1
    fi

    # Dispatch directly into sandbox execution engine
    cmd_run "$tmp_lpk" "$@"
}
