#!/usr/bin/env bash
# ==============================================================================
# lib/run.sh - Mounting and executing applications via sandbox engine
# ==============================================================================

cmd_run() {
    local target=""
    local sandbox_opts=()
    local app_args=()

    # Parse arguments & options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline|--no-net)
                sandbox_opts+=("--offline")
                shift
                ;;
            --)
                shift
                app_args+=("$@")
                break
                ;;
            -*)
                sandbox_opts+=("$1")
                shift
                ;;
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

    if [[ -z "$target" ]]; then
        error "Usage: ulpm run <app_name|package.lpk> [options] [-- arguments...]"
        exit 1
    fi

    # Delegate to the sandbox execution engine
    lpk_run_isolated "${sandbox_opts[@]}" "$target" "${app_args[@]}"
}
