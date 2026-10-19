#!/usr/bin/env bash
# ==============================================================================
# lib/deps.sh - ULPM Dependency Resolution & Transaction Planning Engine
# ULPM v6.0.0 Architecture Engine (v5.3 Deterministic DAG & SemVer Resolution)
# ==============================================================================

_deps_split_spec() {
    local spec="${1:-}"
    local op="=" wanted="$spec"
    if [[ "$spec" =~ ^([>=<]+)(.*)$ ]]; then
        op="${BASH_REMATCH[1]}"
        wanted="${BASH_REMATCH[2]}"
        [[ "$op" == "==" ]] && op="="
    fi
    printf '%s\t%s\n' "$op" "$wanted"
}

_deps_compare() {
    local have="${1:-0}" op="${2:-=}" want="${3:-0}"
    [[ -n "$want" ]] || return 0

    if declare -F version_matches_constraint >/dev/null 2>&1; then
        version_matches_constraint "$have" "${op}${want}"
        return $?
    fi

    if command -v dpkg >/dev/null 2>&1; then
        case "$op" in
            '='|'==') dpkg --compare-versions "$have" eq "$want" ;;
            '>=')     dpkg --compare-versions "$have" ge "$want" ;;
            '<=')     dpkg --compare-versions "$have" le "$want" ;;
            '>')      dpkg --compare-versions "$have" gt "$want" ;;
            '<')      dpkg --compare-versions "$have" lt "$want" ;;
            *)        return 2 ;;
        esac
    else
        local cmp=0
        if declare -F semver_compare >/dev/null 2>&1; then
            semver_compare "$have" "$want" || cmp=$?
        else
            [[ "$have" == "$want" ]] && cmp=0 || cmp=2
        fi
        case "$op" in
            '='|'==') (( cmp == 0 )) ;;
            '>=')     (( cmp == 0 || cmp == 1 )) ;;
            '<=')     (( cmp == 0 || cmp == 2 )) ;;
            '>')      (( cmp == 1 )) ;;
            '<')      (( cmp == 2 )) ;;
            *)        return 2 ;;
        esac
    fi
}

_deps_installed_version() {
    local id="$1" db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    [[ -f "$db" && ! -L "$db" ]] || return 1
    awk -F'|' -v id="$id" '$1 == id { print $3; found=1; exit } END { if (!found) exit 1 }' "$db"
}

_deps_parse_requirement() {
    local req="$1" dep_id="$1" spec=''
    if [[ "$req" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)(\(?(>=|<=|==|=|>|<)([A-Za-z0-9.+_~-]+)\)?)$ ]]; then
        dep_id="${BASH_REMATCH[1]}"
        spec="${BASH_REMATCH[3]}${BASH_REMATCH[4]}"
    fi
    [[ "$dep_id" != *..* && "$dep_id" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || return 2
    printf '%s\t%s\n' "$dep_id" "$spec"
}

_deps_normalize_item() {
    local item="$1"
    local id="" spec=""
    if [[ "$item" == '"'* ]]; then
        local raw parsed
        raw="$(jq -r '.' <<< "$item")"
        parsed="$(_deps_parse_requirement "$raw")" || return 1
        id="${parsed%%$'\t'*}"
        spec="${parsed#*$'\t'}"
    else
        id="$(jq -r '.id // empty' <<< "$item")"
        spec="$(jq -r '.version // empty' <<< "$item")"
        [[ "$id" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$id" != *..* ]] || return 1
        if [[ "$spec" =~ ^(>=|<=|==|=|>|<)(.+)$ ]]; then
            spec="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        elif [[ -n "$spec" ]]; then
            spec="=$spec"
        fi
    fi
    printf '%s\t%s\n' "$id" "$spec"
}

_deps_check_manifest() {
    local manifest="$1" dependencies count i item id spec installed missing=0
    jq -e 'type == "object" and ((.dependencies // []) | type == "array")' "$manifest" >/dev/null 2>&1 || {
        error 'Manifest has an invalid dependencies field.'
        return 2
    }
    dependencies="$(jq -c '.dependencies // []' "$manifest")" || return 2
    count="$(jq 'length' <<< "$dependencies")"

    for ((i=0; i<count; i++)); do
        item="$(jq -c ".[$i]" <<< "$dependencies")"
        local norm
        norm="$(_deps_normalize_item "$item")" || {
            error "Invalid dependency declaration: $item"
            missing=$((missing + 1))
            continue
        }
        id="${norm%%$'\t'*}"
        spec="${norm#*$'\t'}"

        installed="$(_deps_installed_version "$id" 2>/dev/null || true)"
        if [[ -z "$installed" ]]; then
            error "Missing dependency: $id${spec:+ ($spec)}"
            missing=$((missing + 1))
            continue
        fi

        if [[ -n "$spec" ]]; then
            local split op wanted
            split="$(_deps_split_spec "$spec")"
            op="${split%%$'\t'*}"
            wanted="${split#*$'\t'}"
            if ! _deps_compare "$installed" "$op" "$wanted"; then
                error "Dependency version mismatch: $id (installed=$installed, required=$spec)"
                missing=$((missing + 1))
            fi
        fi
    done

    (( missing == 0 )) || return 1
    info 'All declared dependencies are installed and version-compatible.'
}

cmd_deps() {
    local action="${1:-}" target="${2:-}" manifest='' tmp=''
    case "$action" in
        check)
            [[ -n "$target" ]] || {
                error 'Usage: ulpm deps check <manifest.json|installed-app-id>'
                return 2
            }
            if [[ -f "$target" ]]; then
                manifest="$target"
            else
                local found=""
                if declare -F _manage_resolve_installed_lpk >/dev/null 2>&1; then
                    found="$(_manage_resolve_installed_lpk "$target" 2>/dev/null || true)"
                fi

                # Fallback v5.3 direct scan
                if [[ -z "$found" || ! -f "$found" ]]; then
                    local app_dir="${ULPM_APPS_DIR:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/apps}"
                    local db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
                    if [[ -f "$db" ]]; then
                        local entry_id entry_name rest candidate
                        while IFS='|' read -r entry_id entry_name rest; do
                            if [[ "$entry_id" == "$target" || "$entry_name" == "$target" ]]; then
                                for candidate in "$app_dir/$entry_name/$entry_name.lpk" "$app_dir/$entry_name.lpk"; do
                                    [[ -f "$candidate" ]] && { found="$candidate"; break; }
                                done
                                break
                            fi
                        done < "$db"
                    fi
                fi

                [[ -n "$found" && -f "$found" ]] || {
                    error "No manifest or installed package found for '$target'."
                    return 1
                }

                check_dependencies unsquashfs jq || return 1
                manifest="$(mktemp "${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/deps-manifest.XXXXXX.json")" || return 1
                tmp="$manifest"

                local m_content=""
                if declare -F read_package_manifest >/dev/null 2>&1; then
                    m_content="$(read_package_manifest "$found" 2>/dev/null || true)"
                fi
                if [[ -z "$m_content" ]]; then
                    m_content="$(unsquashfs -cat "$found" meta/manifest.json 2>/dev/null || unsquashfs -cat "$found" lpk.json 2>/dev/null || true)"
                fi

                if [[ -z "$m_content" ]]; then
                    rm -f -- "$manifest"
                    error 'Could not read installed package manifest.'
                    return 1
                fi
                printf '%s' "$m_content" > "$manifest"
            fi

            local rc=0
            _deps_check_manifest "$manifest" || rc=$?
            [[ -n "$tmp" && -f "$tmp" ]] && rm -f -- "$tmp"
            return "$rc"
            ;;
        resolve)
            [[ -n "$target" ]] || {
                error 'Usage: ulpm deps resolve <app-id>'
                return 2
            }
            _deps_resolve_repo_plan "$target"
            ;;
        *)
            error 'Usage: ulpm deps <check|resolve> <manifest.json|app-id>'
            return 2
            ;;
    esac
}

_deps_resolve_repo_plan() {
    local target="$1"
    local root="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/repos"
    local db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    check_dependencies jq || return 1
    [[ -d "$root" ]] || {
        error "No repository indexes cached; run 'ulpm repo update' first."
        return 1
    }

    local -a plan=()
    # shellcheck disable=SC2034
    local -a visiting=() done_ids=()
    _deps_resolve_visit "$target" "$root" "$db" plan visiting done_ids '' || return 1
    printf 'Dependency installation plan (dependencies first):\n'
    local id
    for id in "${plan[@]}"; do
        printf '  %s\n' "$id"
    done
}

_deps_resolve_visit() {
    local id="$1" root="$2" db="$3" plan_name="$4" visiting_name="$5" done_name="$6" requirement="${7:-}" force="${8:-0}" preferred_repo="${9:-}"
    local -n __ulpm_plan_ref="$plan_name" __ulpm_visiting_ref="$visiting_name" __ulpm_done_ref="$done_name"
    local x f selected='' selected_version='' candidate_version repo dep dep_id dep_spec installed
    local raw_arch host_arch
    raw_arch="$(detect_arch)"
    host_arch="$(normalize_arch_name "$raw_arch")"

    for x in "${__ulpm_done_ref[@]}"; do [[ "$x" == "$id" ]] && return 0; done
    for x in "${__ulpm_visiting_ref[@]}"; do
        [[ "$x" == "$id" ]] && { error "Dependency cycle detected at '$id'."; return 1; }
    done

    installed="$(_deps_installed_version "$id" 2>/dev/null || true)"
    if [[ -n "$installed" && "$force" != 1 ]]; then
        if [[ -n "$requirement" ]]; then
            local split_req req_op req_version
            split_req="$(_deps_split_spec "$requirement")"
            req_op="${split_req%%$'\t'*}"
            req_version="${split_req#*$'\t'}"
            if _deps_compare "$installed" "$req_op" "$req_version"; then
                __ulpm_done_ref+=("$id")
                return 0
            fi
            force=1
        else
            __ulpm_done_ref+=("$id")
            return 0
        fi
    fi

    shopt -s nullglob
    local -a index_files=("$root"/*/index.json)
    shopt -u nullglob

    if [[ -n "$preferred_repo" ]]; then
        local -a preferred_files=() other_files=()
        for f in "${index_files[@]}"; do
            if [[ "$(basename "$(dirname "$f")")" == "$preferred_repo" ]]; then
                preferred_files+=("$f")
            else
                other_files+=("$f")
            fi
        done
        index_files=("${preferred_files[@]}" "${other_files[@]}")
    fi

    for f in "${index_files[@]}"; do
        repo="$(basename "$(dirname "$f")")"
        local key="${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/repos/$repo.pub"
        local cfg="${ULPM_CONFIG_HOME:-$HOME/.config}/ulpm/repos/$repo.json"
        [[ -n "$preferred_repo" && "$repo" != "$preferred_repo" ]] && continue
        [[ -f "$key" && -f "$cfg" ]] || continue
        [[ "$(jq -r '.enabled // true' "$cfg" 2>/dev/null)" == true ]] || continue

        if declare -F _repo_verify_index >/dev/null 2>&1; then
            _repo_verify_index "$repo" "$f" "$(dirname "$f")/index.json.sig" "$key" >/dev/null 2>&1 || continue
        fi

        local rows
        rows="$(jq -c --arg id "$id" --arg arch "$host_arch" '
            .packages[] | select(
                .id == $id and (
                    .arch == $arch or
                    .arch == "all" or
                    .arch == "any" or
                    ($arch == "amd64" and (.arch == "x86_64" or .arch == "x86-64")) or
                    ($arch == "arm64" and (.arch == "aarch64" or .arch == "arm-64")) or
                    ($arch == "armhf" and (.arch == "armv7l" or .arch == "armv7"))
                )
            )
        ' "$f" 2>/dev/null || true)"

        [[ -n "$rows" ]] || continue

        local row
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            candidate_version="$(jq -r '.version' <<< "$row")"
            if [[ -n "$requirement" ]]; then
                local split_cand cand_op cand_wanted
                split_cand="$(_deps_split_spec "$requirement")"
                cand_op="${split_cand%%$'\t'*}"
                cand_wanted="${split_cand#*$'\t'}"
                _deps_compare "$candidate_version" "$cand_op" "$cand_wanted" || continue
            fi

            if [[ -n "$preferred_repo" ]]; then
                selected="$row"
                selected_version="$candidate_version"
                break 2
            fi

            if [[ -z "$selected" ]] || _deps_compare "$candidate_version" '>' "$selected_version"; then
                selected="$row"
                selected_version="$candidate_version"
            fi
        done <<< "$rows"
    done

    [[ -n "$selected" ]] || {
        error "Dependency '$id' is neither installed nor available in a verified compatible repository."
        return 1
    }

    if [[ -n "$requirement" ]]; then
        local sel_v split_req req_op req_version
        sel_v="$(jq -r '.version' <<< "$selected")"
        split_req="$(_deps_split_spec "$requirement")"
        req_op="${split_req%%$'\t'*}"
        req_version="${split_req#*$'\t'}"
        _deps_compare "$sel_v" "$req_op" "$req_version" || {
            error "Available dependency '$id' version $sel_v does not satisfy $requirement."
            return 1
        }
    fi

    __ulpm_visiting_ref+=("$id")

    local dep_entries
    dep_entries="$(jq -c '.dependencies[]? | select(. != null)' <<< "$selected" 2>/dev/null || true)"
    if [[ -n "$dep_entries" ]]; then
        while IFS= read -r dep; do
            [[ -n "$dep" ]] || continue
            local norm_dep
            norm_dep="$(_deps_normalize_item "$dep")" || {
                error "Invalid dependency metadata for '$id'."
                return 1
            }
            dep_id="${norm_dep%%$'\t'*}"
            dep_spec="${norm_dep#*$'\t'}"
            _deps_resolve_visit "$dep_id" "$root" "$db" "$plan_name" "$visiting_name" "$done_name" "$dep_spec" || return 1
        done <<< "$dep_entries"
    fi

    local -a keep_visiting=()
    for x in "${__ulpm_visiting_ref[@]}"; do
        [[ "$x" == "$id" ]] || keep_visiting+=("$x")
    done
    __ulpm_visiting_ref=("${keep_visiting[@]}")

    __ulpm_done_ref+=("$id")
    __ulpm_plan_ref+=("$id")
}
