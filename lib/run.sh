#!/usr/bin/env bash
# ==============================================================================
# lib/run.sh - Direct Sandbox Execution Dispatcher
# ULPM v6.1.0 — Session mode passthrough (Xephyr / gamescope / weston / cage)
# ==============================================================================

_run_resolve_target() {
    local target="${1:-}"
    local apps_dir="${ULPM_APPS_DIR:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/apps}"
    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"

    [[ -n "$target" ]] || return 1

    # Normalisation préalable si le module utils est chargé
    if declare -F normalize_target >/dev/null 2>&1; then
        target="$(normalize_target "$target" 2>/dev/null || printf '%s' "$target")"
    fi

    if [[ -f "$target" ]]; then
        local real_target
        real_target="$(realpath -e -- "$target" 2>/dev/null || printf '%s' "$target")"
        if [[ -f "$real_target" && -r "$real_target" ]]; then
            printf '%s\n' "$real_target"
            return 0
        fi
    fi

    if declare -F _manage_resolve_installed_lpk >/dev/null 2>&1; then
        local found
        if found="$(_manage_resolve_installed_lpk "$target" 2>/dev/null || true)"; then
            if [[ -n "$found" && -f "$found" ]]; then
                realpath -e -- "$found" 2>/dev/null || printf '%s\n' "$found"
                return 0
            fi
        fi
    fi

    local candidate
    for candidate in \
        "$apps_dir/$target/$target.lpk" \
        "$apps_dir/$target.lpk" \
        "$apps_dir/io.lpk.${target,,}.lpk" \
        "$apps_dir/io.lpk.${target,,}/io.lpk.${target,,}.lpk" \
        "$apps_dir/$target/${target,,}.lpk" \
        "$apps_dir/${target,,}/${target,,}.lpk"; do
        if [[ -f "$candidate" && -r "$candidate" ]]; then
            local resolved
            resolved="$(realpath -e -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
            printf '%s\n' "$resolved"
            return 0
        fi
    done

    if [[ -f "$db_file" && ! -L "$db_file" ]]; then
        local id name _rest

        # Passe 1 : Correspondance stricte
        while IFS='|' read -r id name _rest; do
            if [[ "$id" == "$target" || "$name" == "$target" ]]; then
                for candidate in \
                    "$apps_dir/$name/$name.lpk" \
                    "$apps_dir/$name.lpk" \
                    "$apps_dir/$id/$id.lpk" \
                    "$apps_dir/$id.lpk" \
                    "$apps_dir/io.lpk.${name,,}.lpk"; do
                    if [[ -f "$candidate" && -r "$candidate" ]]; then
                        local res
                        res="$(realpath -e -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
                        printf '%s\n' "$res"
                        return 0
                    fi
                done
            fi
        done < "$db_file"

        while IFS='|' read -r id name _rest; do
            if [[ "${id,,}" == "${target,,}" || "${name,,}" == "${target,,}" ]]; then
                for candidate in \
                    "$apps_dir/$name/$name.lpk" \
                    "$apps_dir/$name.lpk" \
                    "$apps_dir/$id/$id.lpk" \
                    "$apps_dir/$id.lpk" \
                    "$apps_dir/io.lpk.${name,,}.lpk"; do
                    if [[ -f "$candidate" && -r "$candidate" ]]; then
                        local res_ci
                        res_ci="$(realpath -e -- "$candidate" 2>/dev/null || printf '%s' "$candidate")"
                        printf '%s\n' "$res_ci"
                        return 0
                    fi
                done
            fi
        done < "$db_file"
    fi

    return 1
}

cmd_run() {
    local target=""
    local resolved_target=""
    local explicit_app_args=0
    local arg bind_value session_mode
    local -a sandbox_opts=()
    local -a app_args=()

    while (( $# )); do
        arg="$1"

        if (( explicit_app_args )); then
            app_args+=("$arg")
            shift
            continue
        fi

        case "$arg" in
            --)
                explicit_app_args=1
                shift
                ;;
            --gaming|--strict|--desktop)
                sandbox_opts+=("$arg")
                shift
                ;;
            --session-mode)
                if (( $# < 2 )) || [[ -z "${2:-}" || "${2:-}" == -- ]]; then
                    error "--session-mode requires a value: xephyr|gamescope|weston|cage|app|auto"
                    return 2
                fi
                session_mode="$2"
                case "$session_mode" in
                    xephyr|gamescope|weston|cage|app|auto) ;;
                    *)
                        error "Invalid --session-mode value: '$session_mode' (expected xephyr|gamescope|weston|cage|app|auto)"
                        return 2
                        ;;
                esac
                sandbox_opts+=("--session-mode" "$session_mode")
                shift 2
                ;;
            --session-mode=*)
                session_mode="${arg#--session-mode=}"
                case "$session_mode" in
                    xephyr|gamescope|weston|cage|app|auto) ;;
                    *)
                        error "Invalid --session-mode value: '$session_mode' (expected xephyr|gamescope|weston|cage|app|auto)"
                        return 2
                        ;;
                esac
                sandbox_opts+=("--session-mode=$session_mode")
                shift
                ;;
            --offline|--no-net)
                sandbox_opts+=("--offline")
                shift
                ;;
            --net)
                sandbox_opts+=("--net")
                shift
                ;;
            --no-gpu|--no-audio|--no-gui|--no-input)
                sandbox_opts+=("$arg")
                shift
                ;;
            --bind)
                if (( $# < 2 )) || [[ -z "${2:-}" || "${2:-}" == -- ]]; then
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
                if [[ -z "$target" ]]; then
                    sandbox_opts+=("$arg")
                else
                    app_args+=("$arg")
                fi
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
        error "Usage: ulpm run [sandbox_flags] [--session-mode <mode>] <package.lpk|app_id> [-- app_args...]"
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

    local app_rc=0
    if (( ${#app_args[@]} > 0 )); then
        lpk_run_isolated \
            ${sandbox_opts[@]+"${sandbox_opts[@]}"} \
            "$resolved_target" \
            -- "${app_args[@]}" || app_rc=$?
    else
        lpk_run_isolated \
            ${sandbox_opts[@]+"${sandbox_opts[@]}"} \
            "$resolved_target" || app_rc=$?
    fi

    return "$app_rc"
}