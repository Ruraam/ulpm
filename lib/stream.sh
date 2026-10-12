#!/usr/bin/env bash
# ==============================================================================
# lib/stream.sh - Ephemeral RAM Streaming Engine
# ==============================================================================

cmd_stream() {
    local source_uri="${1:-}"
    [[ -z "$source_uri" ]] && { error "Usage: ulpm stream <url|owner/repo> [args...]"; return 1; }
    shift || true

    local ram_base="${XDG_RUNTIME_DIR:-/dev/shm}"
    local tmp_lpk
    tmp_lpk="$(mktemp "$ram_base/stream_XXXXXX.lpk")"
    trap 'rm -f "$tmp_lpk"' EXIT INT TERM

    log "Streaming package directly into volatile memory (RAM)..."
    curl -# -L -f "$source_uri" -o "$tmp_lpk" || { error "Failed to stream archive."; return 1; }

    cmd_run "$tmp_lpk" "$@"
}
