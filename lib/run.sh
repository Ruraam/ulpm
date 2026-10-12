#!/usr/bin/env bash
# ==============================================================================
# lib/run.sh - Direct Sandbox Execution Dispatcher
# ==============================================================================

cmd_run() {
    local target=""
    local sandbox_opts=()
    local app_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline|--no-net) sandbox_opts+=("--offline"); shift ;;
            --) shift; app_args+=("$@"); break ;;
            -*) sandbox_opts+=("$1"); shift ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                else
                    app_args+=("$1")
                fi
                shift
                ;;
        esac
    done

    [[ -z "$target" ]] && { error "Usage: ulpm run <target> [flags] [-- args...]"; return 1; }
    lpk_run_isolated "${sandbox_opts[@]}" "$target" "${app_args[@]}"
}
