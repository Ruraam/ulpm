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
            --offline|--no-net)
                sandbox_opts+=("--offline")
                shift
                ;;
            --no-gpu|--no-audio|--no-gui)
                sandbox_opts+=("$1")
                shift
                ;;
            --bind)
                if [[ -n "${2:-}" ]]; then
                    sandbox_opts+=("--bind" "$2")
                    shift 2
                else
                    error "--bind requires a mapping argument formatted as <host_dir>:<sandbox_dir>"
                    return 1
                fi
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
        error "Usage: ulpm run <package.lpk|app_id> [sandbox_flags] [-- app_args...]"
        return 1
    fi

    lpk_run_isolated \
        ${sandbox_opts[@]+"${sandbox_opts[@]}"} \
        "$target" \
        ${app_args[@]+"${app_args[@]}"}
}
