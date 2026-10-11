#!/usr/bin/env bash
# ==============================================================================
# lib/stream.sh - Ephemeral streaming execution in RAM/tmpfs
# ==============================================================================

cmd_stream() {
    local source_uri=""
    local forward_args=()

    # Extract options and URI
    while [[ $# -gt 0 ]]; do
        case "$1" in
            http://*|https://*)
                source_uri="$1"
                shift
                ;;
            *)
                forward_args+=("$1")
                shift
                ;;
        esac
    done

    if [[ -z "$source_uri" ]]; then
        error "Usage: ulpm stream <https://.../app.lpk> [sandbox_flags] [-- args...]"
        exit 1
    fi

    check_dependencies curl

    # Priority: RAM via XDG_RUNTIME_DIR -> /dev/shm -> Local disk cache
    local ram_base="${XDG_RUNTIME_DIR:-/dev/shm}"
    local tmp_lpk=""

    if [[ -d "$ram_base" && -w "$ram_base" ]]; then
        tmp_lpk="$(mktemp "$ram_base/ulpm_stream_XXXXXX.lpk" 2>/dev/null || true)"
    fi

    if [[ -z "$tmp_lpk" || ! -f "$tmp_lpk" ]]; then
        tmp_lpk="$(mktemp "${ULPM_CACHE_HOME}/tmp/stream_XXXXXX.lpk")"
    fi

    cleanup_stream() {
        if [[ -n "${tmp_lpk:-}" && -f "$tmp_lpk" ]]; then
            rm -f "$tmp_lpk"
        fi
    }
    trap cleanup_stream EXIT INT TERM HUP

    log "Streaming package into memory from $source_uri..."
    if ! curl -# -L -f --retry 2 "$source_uri" -o "$tmp_lpk"; then
        error "Download failed for: $source_uri"
        cleanup_stream
        exit 1
    fi

    # cmd_run handles cryptographic verification and isolated execution
    cmd_run "$tmp_lpk" "${forward_args[@]}"
    local rc=$?

    cleanup_stream
    return "$rc"
}
