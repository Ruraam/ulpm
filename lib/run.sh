#!/usr/bin/env bash
# ==============================================================================
# lib/run.sh - Direct Sandbox Execution Dispatcher
# ULPM v5.0.0 Declarative Engine (Profiles & Schema v5 Dispatcher)
# ==============================================================================

_run_resolve_target() {
    local target="${1:-}"
    local apps_dir="${ULPM_APPS_DIR:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/apps}"
    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"

    if declare -F normalize_target >/dev/null 2>&1; then
        target="$(normalize_target "$target")"
    fi

    # 1. Direct path to file
    if [[ -f "$target" ]]; then
        printf '%s\n' "$target"
        return 0
    fi

    # 2. Direct directory lookups in apps directory
    if [[ -f "$apps_dir/$target/$target.lpk" ]]; then
        printf '%s\n' "$apps_dir/$target/$target.lpk"
        return 0
    elif [[ -f "$apps_dir/$target.lpk" ]]; then
        printf '%s\n' "$apps_dir/$target.lpk"
        return 0
    elif [[ -f "$apps_dir/io.lpk.${target,,}.lpk" ]]; then
        printf '%s\n' "$apps_dir/io.lpk.${target,,}.lpk"
        return 0
    elif [[ -f "$apps_dir/io.lpk.${target,,}/io.lpk.${target,,}.lpk" ]]; then
        printf '%s\n' "$apps_dir/io.lpk.${target,,}/io.lpk.${target,,}.lpk"
        return 0
    fi

    # 3. Lookup inside installed.db
    if [[ -f "$db_file" ]]; then
        local id name _rest
        while IFS='|' read -r id name _rest; do
            if [[ "$id" == "$target" || "$name" == "$target" ]]; then
                if [[ -f "$apps_dir/$name/$name.lpk" ]]; then
                    printf '%s\n' "$apps_dir/$name/$name.lpk"
                    return 0
                elif [[ -f "$apps_dir/$name.lpk" ]]; then
                    printf '%s\n' "$apps_dir/$name.lpk"
                    return 0
                elif [[ -f "$apps_dir/$id/$id.lpk" ]]; then
                    printf '%s\n' "$apps_dir/$id/$id.lpk"
                    return 0
                elif [[ -f "$apps_dir/$id.lpk" ]]; then
                    printf '%s\n' "$apps_dir/$id.lpk"
                    return 0
                fi
            fi
        done < "$db_file"
    fi

    return 1
}

cmd_run() {
    local target=""
    local resolved_target=""
    local parsing_app_args=0
    local arg bind_value
    local -a sandbox_opts=()
    local -a app_args=()

    while (($#)); do
        arg="$1"

        if (( parsing_app_args )); then
            app_args+=("$arg")
            shift
            continue
        fi

        case "$arg" in
            --)
                parsing_app_args=1
                shift
                ;;
            # Execution Profiles
            --gaming|--strict|--desktop)
                sandbox_opts+=("$arg")
                shift
                ;;
            # Isolation & Hardware Flags
            --offline|--no-net)
                sandbox_opts+=("--offline")
                shift
                ;;
            --no-gpu|--no-audio|--no-gui|--no-input)
                sandbox_opts+=("$arg")
                shift
                ;;
            --bind)
                if (($# < 2)) || [[ -z "${2:-}" || "${2:-}" == -- ]]; then
                    error "--bind requires a mapping formatted as <host_dir>:<sandbox_dir>."
                    return 2
                fi
                bind_value="$2"
                if [[ "$bind_value" != *:* || "$bind_value" == :* || "$bind_value" == *: ]]; then
                    error "Invalid --bind mapping '$bind_value'; expected <host_dir>:<sandbox_dir>."
                    return 2
                fi
                sandbox_opts+=("--bind" "$bind_value")
                shift 2
                ;;
            --bind=*)
                bind_value="${arg#--bind=}"
                if [[ -z "$bind_value" || "$bind_value" != *:* || "$bind_value" == :* || "$bind_value" == *: ]]; then
                    error "Invalid --bind mapping '$bind_value'; expected <host_dir>:<sandbox_dir>."
                    return 2
                fi
                sandbox_opts+=("--bind" "$bind_value")
                shift
                ;;
            -*)
                sandbox_opts+=("$arg")
                shift
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$arg"
                else
                    app_args+=("$arg")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        error "Usage: ulpm run [flags] <package.lpk|app_id> [-- app_args...]"
        return 2
    fi

    if ! declare -F lpk_run_isolated >/dev/null 2>&1; then
        error "Sandbox runner is unavailable: lpk_run_isolated is not defined."
        return 127
    fi

    resolved_target="$(_run_resolve_target "$target")" || {
        error "Target LPK package or installed application not found: '$target'"
        return 1
    }

    # Pass sandbox options FIRST, then resolved target, then application arguments
    lpk_run_isolated \
        ${sandbox_opts[@]+"${sandbox_opts[@]}"} \
        "$resolved_target" \
        -- ${app_args[@]+"${app_args[@]}"}
}
