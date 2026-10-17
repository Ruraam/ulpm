#!/usr/bin/env bash
#==============================================================================
# lib/transaction.sh - Multi-package Atomic Transaction Engine with WAL
# ULPM v5.3 Architecture Engine (Crash Recovery, Persistent WAL & LIFO Rollback)
# Packages are fully resolved, downloaded, hash-checked and signature-checked
# before the first installation mutation. The persistent WAL guarantees full
# post-crash recovery even across SIGKILL or power losses.
# ==============================================================================

_txn_safe_name() {
    printf '%s' "$1" | tr -cd 'a-zA-Z0-9._-'
}

_txn_wal_dir() {
    local base="${ULPM_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/ulpm}"
    printf '%s/wal\n' "$base"
}

_txn_select_row() {
    local id="$1" preferred="${2:-}" root f repo cfg key row selected='' selected_version='' candidate_version selected_repo=''
    local raw_arch host_arch
    root="$(_repo_cache_root)"
    raw_arch="$(detect_arch)"
    host_arch="$(normalize_arch_name "$raw_arch")"

    shopt -s nullglob
    local indexes=("$root"/*/index.json)
    shopt -u nullglob

    if [[ -n "$preferred" ]]; then
        local -a ordered=() rest=()
        for f in "${indexes[@]}"; do
            if [[ "$(basename "$(dirname "$f")")" == "$preferred" ]]; then
                ordered+=("$f")
            else
                rest+=("$f")
            fi
        done
        indexes=("${ordered[@]}" "${rest[@]}")
    fi

    for f in "${indexes[@]}"; do
        repo="$(basename "$(dirname "$f")")"
        [[ -n "$preferred" && "$repo" != "$preferred" ]] && continue
        cfg="$(_repo_config "$repo")"
        key="$(_repo_key "$repo")"
        [[ -f "$cfg" && -f "$key" && "$(jq -r '.enabled // true' "$cfg" 2>/dev/null)" == true ]] || continue
        _repo_verify_index "$repo" "$f" "$(_repo_cache "$repo")/index.json.sig" "$key" >/dev/null 2>&1 || continue

        row="$(jq -c --arg id "$id" --arg arch "$host_arch" '
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
        ' "$f" | head -n 1)"
        [[ -n "$row" ]] || continue

        candidate_version="$(jq -r '.version' <<< "$row")"
        if [[ -n "$preferred" ]]; then
            selected="$row"
            selected_version="$candidate_version"
            selected_repo="$repo"
            break
        fi

        local cmp=0
        if [[ -n "$selected_version" ]]; then
            semver_compare "$candidate_version" "$selected_version" || cmp=$?
        fi

        if [[ -z "$selected" ]] || (( cmp == 1 )); then
            selected="$row"
            selected_version="$candidate_version"
            selected_repo="$repo"
        fi
    done

    if [[ -n "$selected" ]]; then
        printf '%s\t%s\n' "${selected_repo:-$preferred}" "$selected"
        return 0
    fi

    local pref_msg=""
    [[ -n "$preferred" ]] && pref_msg="(preferred repository: '$preferred')"
    error "No compatible package '$id' exists in an enabled, verified repository${pref_msg}."
    return 1
}

_txn_restore_file() {
    local saved="$1" target="$2"
    if [[ -e "$saved" ]]; then
        mkdir -p -- "$(dirname -- "$target")" || return 1
        cp -a -- "$saved" "$target.restore.$$" || return 1
        sync_file "$target.restore.$$"
        mv -f -- "$target.restore.$$" "$target" || {
            rm -f -- "$target.restore.$$"
            return 1
        }
        sync_dir "$(dirname -- "$target")"
    else
        rm -f -- "$target" 2>/dev/null || true
    fi
}

_txn_rollback() {
    local snap="$1" apps_dir="$2" db="$3" history="$4" data_home="$5"
    local failed=0 i name existed target id
    local meta_wal="$snap/meta.json"

    local -a t_names=() t_existed=() t_ids=()
    if [[ -f "$meta_wal" ]]; then
        while IFS=$'\t' read -r mid mname mex; do
            [[ -n "$mid" ]] || continue
            t_ids+=("$mid")
            t_names+=("$mname")
            t_existed+=("$mex")
        done < <(jq -r '.items[]? | [.id, .name, (.existed|tostring)] | @tsv' "$meta_wal" 2>/dev/null || true)
    fi

    # LIFO Rollback (in strict reverse order of installation mutation)
    for ((i=${#t_names[@]}-1; i>=0; i--)); do
        name="${t_names[$i]}"
        existed="${t_existed[$i]}"
        target="$apps_dir/$name"
        rm -rf -- "$target" || failed=1
        if [[ "$existed" == 1 && -d "$snap/apps/$name" ]]; then
            mkdir -p -- "$apps_dir" && cp -a -- "$snap/apps/$name" "$target" || failed=1
            sync_dir "$apps_dir"
        fi
        id="${t_ids[$i]}"
        _txn_restore_file "$snap/icons/$id.png" "$data_home/icons/hicolor/256x256/apps/$id.png" || failed=1
        _txn_restore_file "$snap/icons_512/$id.png" "$data_home/icons/hicolor/512x512/apps/$id.png" || failed=1
        _txn_restore_file "$snap/desktop/$id.desktop" "$data_home/applications/$id.desktop" || failed=1
    done

    if [[ -f "$snap/installed.db" ]]; then
        mkdir -p -- "$(dirname -- "$db")" 2>/dev/null || true
        cp -a -- "$snap/installed.db" "$db.restore.$$" && \
            sync_file "$db.restore.$$" && \
            mv -f -- "$db.restore.$$" "$db" || failed=1
        sync_dir "$(dirname -- "$db")"
    else
        mkdir -p -- "$(dirname -- "$db")" 2>/dev/null || true
        ( umask 077 && :> "$db") 2>/dev/null || rm -f -- "$db" || failed=1
        chmod 600 "$db" 2>/dev/null || true
        sync_file "$db"
    fi

    if [[ -d "$history" && -f "$snap/history.before" ]]; then
        local f base
        local tmp_hist_list
        tmp_hist_list="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/hist_rb.XXXXXX")" || failed=1
        if [[ -f "$tmp_hist_list" ]]; then
            find "$history" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null > "$tmp_hist_list"
            while IFS= read -r -d '' f; do
                base="$(basename -- "$f")"
                grep -Fqx -- "$base" "$snap/history.before" 2>/dev/null || rm -f -- "$f" || failed=1
            done < "$tmp_hist_list"
            rm -f -- "$tmp_hist_list"
        fi
    fi

    refresh_desktop_environment
    (( failed == 0 ))
}

# Post-crash recovery engine
cmd_transaction_recover() {
    local wal_dir
    wal_dir="$(_txn_wal_dir)"
    [[ -d "$wal_dir" ]] || return 0

    shopt -s nullglob
    local journals=("$wal_dir"/*.wal)
    shopt -u nullglob

    (( ${#journals[@]} == 0 )) && return 0

    warn "Detected unfinished transaction journal(s). Performing crash recovery..."
    acquire_lock 10 || { error "Cannot acquire lock to perform transaction recovery."; return 1; }

    local db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local history="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/history"

    local j snap_path
    for j in "${journals[@]}"; do
        snap_path="$(head -n 1 "$j" 2>/dev/null | tr -d '\r\n' || true)"
        if [[ -n "$snap_path" && -d "$snap_path" ]] && _safe_managed_dir "$snap_path"; then
            log "Recovering from snapshot: $snap_path..."
            if _txn_rollback "$snap_path" "$apps_dir" "$db" "$history" "$data_home"; then
                info "Successfully rolled back interrupted transaction."
                rm -rf -- "$snap_path" "$j"
                sync_dir "$wal_dir"
            else
                error "Failed to cleanly recover transaction at $snap_path; leaving files in place for inspection."
            fi
        else
            rm -f -- "$j"
            sync_dir "$wal_dir"
        fi
    done
    release_lock
}

cmd_transaction() {
    local action="${1:-}"
    shift || true

    case "$action" in
        recover)
            cmd_transaction_recover
            return $?
            ;;
        install)
            ;;
        *)
            error 'Usage: ulpm transaction <install|recover> [args...]'
            return 2
            ;;
    esac

    local preferred_repo='' arg
    local -a roots=()
    while (( $# )); do
        case "$1" in
            --repo)
                (( $# >= 2 )) || {
                    error '--repo requires a repository name.'
                    return 2
                }
                preferred_repo="$2"
                shift 2
                ;;
            --*)
                error "Unknown transaction option: $1"
                return 2
                ;;
            *)
                roots+=("$1")
                shift
                ;;
        esac
    done
    (( ${#roots[@]} > 0 )) || {
        error 'Usage: ulpm transaction install <app-id> [app-id ...]'
        return 2
    }

    check_dependencies jq sha256sum unsquashfs sync || return 1

    for arg in "${roots[@]}"; do
        is_safe_app_id "$arg" || {
            error "Invalid package ID: $arg"
            return 2
        }
    done
    if [[ -n "$preferred_repo" ]]; then
        _repo_name_ok "$preferred_repo" || {
            error "Invalid repository name: $preferred_repo"
            return 2
        }
    fi

    # Trigger automatic recovery of previous crashes if any
    cmd_transaction_recover || return 1

    if [[ "${ULPM_SKIP_REPO_REFRESH:-0}" != 1 ]]; then
        cmd_repo update || warn 'Repository refresh had errors; resolving from verified cached indexes.'
    fi

    acquire_lock 10 || return 1
    local work_root="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/transactions"
    local wal_dir
    wal_dir="$(_txn_wal_dir)"
    mkdir -p -- "$work_root" "$wal_dir" || { release_lock; return 1; }

    local work wal_file txn_uuid
    txn_uuid="txn_${$}_${RANDOM}"
    work="$(mktemp -d "$work_root/${txn_uuid}.XXXXXX")" || { release_lock; return 1; }
    wal_file="$wal_dir/${txn_uuid}.wal"

    local db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local history="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/history"

    _safe_managed_dir "$apps_dir" || {
        rm -rf -- "$work"
        release_lock
        error "Refusing unsafe application directory: $apps_dir"
        return 1
    }
    [[ ! -L "$apps_dir" ]] || {
        rm -rf -- "$work"
        release_lock
        error "Refusing symlinked application directory: $apps_dir"
        return 1
    }
    mkdir -p -- "$work/snap/apps" "$work/snap/icons" "$work/snap/icons_512" "$work/snap/desktop" "$work/packages" "$apps_dir" "$(dirname -- "$db")" || {
        rm -rf -- "$work"
        release_lock
        return 1
    }
    [[ ! -L "$db" ]] || {
        rm -rf -- "$work"
        release_lock
        error 'Refusing symlinked installed database.'
        return 1
    }
    if [[ -f "$db" ]]; then
        cp -a -- "$db" "$work/snap/installed.db" || {
            rm -rf -- "$work"
            release_lock
            error 'Could not snapshot installed database.'
            return 1
        }
    fi
    mkdir -p -- "$history" || { rm -rf -- "$work"; release_lock; return 1; }

    shopt -s nullglob
    local hf
    for hf in "$history"/*; do
        [[ -f "$hf" ]] && printf '%s\n' "${hf##*/}"
    done > "$work/snap/history.before"
    shopt -u nullglob

    local -a plan=()
    # shellcheck disable=SC2034
    local -a visiting=()
    # shellcheck disable=SC2034
    local -a done_ids=()
    local -a TXN_IDS=() TXN_NAMES=() TXN_EXISTED=() PKG_FILES=() PKG_REPOS=() PKG_VERSIONS=()
    local root id selected repo row name version file hash base pkg got manifest_id manifest_version existing_name installed_version remote_version

    for root in "${roots[@]}"; do
        installed_version="$(_deps_installed_version "$root" "$db" 2>/dev/null || true)"
        if [[ -n "$installed_version" ]]; then
            local root_preferred=''
            [[ -n "$preferred_repo" && "$root" == "${roots[0]}" ]] && root_preferred="$preferred_repo"
            selected="$(_txn_select_row "$root" "$root_preferred")" || { rm -rf -- "$work"; release_lock; return 1; }
            repo="${selected%%$'\t'*}"
            row="${selected#*$'\t'}"
            remote_version="$(jq -r '.version' <<< "$row")"

            local cmp_root=0
            semver_compare "$remote_version" "$installed_version" || cmp_root=$?
            if (( cmp_root == 1 )); then
                local -a kept_done=()
                for id in "${done_ids[@]}"; do
                    [[ "$id" == "$root" ]] || kept_done+=("$id")
                done
                done_ids=("${kept_done[@]}")
                _deps_resolve_visit "$root" "$(_repo_cache_root)" "$db" plan visiting done_ids '' 1 "$root_preferred" || { rm -rf -- "$work"; release_lock; return 1; }
            else
                _deps_resolve_visit "$root" "$(_repo_cache_root)" "$db" plan visiting done_ids '' 0 "$root_preferred" || { rm -rf -- "$work"; release_lock; return 1; }
            fi
        else
            local root_preferred=''
            [[ -n "$preferred_repo" && "$root" == "${roots[0]}" ]] && root_preferred="$preferred_repo"
            _deps_resolve_visit "$root" "$(_repo_cache_root)" "$db" plan visiting done_ids '' 0 "$root_preferred" || { rm -rf -- "$work"; release_lock; return 1; }
        fi
    done

    if (( ${#plan[@]} == 0 )); then
        info 'Nothing to install: all requested packages and dependencies are already satisfied.'
        rm -rf -- "$work"
        release_lock
        return 0
    fi
    info "Resolved transaction: ${#plan[@]} package(s) planned. Downloading and verifying before mutation..."

    for id in "${plan[@]}"; do
        local prefer=''
        [[ -n "$preferred_repo" && "$id" == "${roots[0]}" ]] && prefer="$preferred_repo"
        selected="$(_txn_select_row "$id" "$prefer")" || { rm -rf -- "$work"; release_lock; return 1; }
        repo="${selected%%$'\t'*}"
        row="${selected#*$'\t'}"
        name="$(jq -r '.name' <<< "$row")"
        version="$(jq -r '.version' <<< "$row")"
        file="$(jq -r '.file' <<< "$row")"
        hash="$(jq -r '.sha256' <<< "$row")"
        base="$(head -n 1 "$(_repo_cache "$repo")/base-url" 2>/dev/null | tr -d '\r\n' || true)"
        [[ -n "$base" ]] || {
            rm -rf -- "$work"
            release_lock
            error "Repository base URL missing for '$repo'."
            return 1
        }
        name="$(_txn_safe_name "$name")"
        [[ -n "$name" && ${#name} -le 128 ]] || {
            rm -rf -- "$work"
            release_lock
            error "Unsafe package name for '$id'."
            return 1
        }
        for existing_name in "${TXN_NAMES[@]}"; do
            [[ "$existing_name" != "$name" ]] || {
                rm -rf -- "$work"
                release_lock
                error "Two packages in this transaction map to the same installation name '$name'."
                return 1
            }
        done
        if [[ -f "$db" ]]; then
            local dbid dbname rest
            while IFS='|' read -r dbid dbname rest; do
                if [[ "$dbname" == "$name" && "$dbid" != "$id" ]]; then
                    rm -rf -- "$work"
                    release_lock
                    error "Installation name '$name' already belongs to package '$dbid'; refusing to replace it."
                    return 1
                fi
            done < "$db"
        fi
        pkg="$work/packages/$id.lpk"
        if ! _repo_fetch "${base%/}/$file" "$pkg"; then
            rm -rf -- "$work"
            release_lock
            error "Could not download '$id' from '$repo'."
            return 1
        }
        got="$(sha256sum "$pkg" | awk '{print $1}')"
        [[ "$got" == "$hash" ]] || {
            rm -rf -- "$work"
            release_lock
            error "SHA-256 mismatch for '$id'."
            return 1
        }
        check_package_signature "$pkg" || {
            rm -rf -- "$work"
            release_lock
            error "Signature/trust check failed for '$id'; no packages were installed."
            return 1
        }
        manifest_id="$(unsquashfs -cat "$pkg" meta/manifest.json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
        manifest_version="$(unsquashfs -cat "$pkg" meta/manifest.json 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
        if [[ -z "$manifest_id" ]]; then
            manifest_id="$(unsquashfs -cat "$pkg" lpk.json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true)"
            manifest_version="$(unsquashfs -cat "$pkg" lpk.json 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
        fi
        [[ "$manifest_id" == "$id" && "$manifest_version" == "$version" ]] || {
            rm -rf -- "$work"
            release_lock
            error "Signed package metadata does not match repository index for '$id'."
            return 1
        }
        TXN_IDS+=("$id")
        TXN_NAMES+=("$name")
        PKG_FILES+=("$pkg")
        PKG_REPOS+=("$repo")
        PKG_VERSIONS+=("$version")
        if [[ -e "$apps_dir/$name" ]]; then
            [[ -d "$apps_dir/$name" && ! -L "$apps_dir/$name" ]] || {
                rm -rf -- "$work"
                release_lock
                error "Unsafe existing package directory: $apps_dir/$name"
                return 1
            }
            cp -a -- "$apps_dir/$name" "$work/snap/apps/$name" || { rm -rf -- "$work"; release_lock; return 1; }
            TXN_EXISTED+=(1)
        else
            TXN_EXISTED+=(0)
        }
        [[ ! -L "$data_home/icons/hicolor/256x256/apps/$id.png" ]] || {
            rm -rf -- "$work"
            release_lock
            error "Refusing symlinked icon for '$id'."
            return 1
        }
        [[ ! -L "$data_home/icons/hicolor/512x512/apps/$id.png" ]] || {
            rm -rf -- "$work"
            release_lock
            error "Refusing symlinked 512x512 icon for '$id'."
            return 1
        }
        [[ ! -L "$data_home/applications/$id.desktop" ]] || {
            rm -rf -- "$work"
            release_lock
            error "Refusing symlinked desktop launcher for '$id'."
            return 1
        }
        if [[ -f "$data_home/icons/hicolor/256x256/apps/$id.png" ]]; then
            cp -a -- "$data_home/icons/hicolor/256x256/apps/$id.png" "$work/snap/icons/$id.png" || {
                rm -rf -- "$work"
                release_lock
                error "Could not snapshot icon for '$id'."
                return 1
            }
        fi
        if [[ -f "$data_home/icons/hicolor/512x512/apps/$id.png" ]]; then
            cp -a -- "$data_home/icons/hicolor/512x512/apps/$id.png" "$work/snap/icons_512/$id.png" || {
                rm -rf -- "$work"
                release_lock
                error "Could not snapshot 512x512 icon for '$id'."
                return 1
            }
        fi
        if [[ -f "$data_home/applications/$id.desktop" ]]; then
            cp -a -- "$data_home/applications/$id.desktop" "$work/snap/desktop/$id.desktop" || {
                rm -rf -- "$work"
                release_lock
                error "Could not snapshot launcher for '$id'."
                return 1
            }
        fi
    done

    # Durable WAL Manifest initialization
    local wal_meta='{"items":[]}'
    local i
    for ((i=0; i<${#TXN_IDS[@]}; i++)); do
        wal_meta="$(jq --arg id "${TXN_IDS[$i]}" --arg name "${TXN_NAMES[$i]}" --argjson ex "${TXN_EXISTED[$i]}" \
            '.items += [{id:$id, name:$name, existed:$ex}]' <<< "$wal_meta")"
    done
    durable_write "$work/snap/meta.json" "$wal_meta" 600 || { rm -rf -- "$work"; release_lock; return 1; }
    durable_write "$wal_file" "$work/snap" 600 || { rm -rf -- "$work"; release_lock; return 1; }

    local txn_committed=0

    # Setup signal traps to trigger LIFO rollback cleanly
    # shellcheck disable=SC2329
    _txn_handler() {
        local sig="$1"
        trap - INT TERM HUP EXIT
        if (( txn_committed == 0 )); then
            error "Transaction interrupted by $sig; executing atomic LIFO rollback..."
            if _txn_rollback "$work/snap" "$apps_dir" "$db" "$history" "$data_home"; then
                rm -rf -- "$work" "$wal_file"
                sync_dir "$wal_dir"
            fi
        fi
        release_lock
        case "$sig" in
            INT)  exit 130 ;;
            TERM) exit 143 ;;
            HUP)  exit 129 ;;
            *)    exit 1 ;;
        esac
    }
    trap '_txn_handler INT' INT
    trap '_txn_handler TERM' TERM
    trap '_txn_handler HUP' HUP

    local idx=0 rc=0
    for id in "${TXN_IDS[@]}"; do
        repo="${PKG_REPOS[$idx]}"
        pkg="${PKG_FILES[$idx]}"
        version="${PKG_VERSIONS[$idx]}"
        info "Committing $id ($version) from '$repo'..."
        if INSTALL_ORIGIN="repo:$repo/$id" ULPM_TRANSACTION_ACTIVE=1 cmd_install "$pkg"; then
            :
        else
            rc=$?
            break
        fi
        idx=$((idx + 1))
    done

    if (( rc != 0 )); then
        error "Transaction failed while installing '$id'; performing LIFO rollback..."
        if _txn_rollback "$work/snap" "$apps_dir" "$db" "$history" "$data_home"; then
            error 'Transaction successfully rolled back; system state restored.'
            rm -rf -- "$work" "$wal_file"
            sync_dir "$wal_dir"
        else
            error "CRITICAL: Rollback failed. Recovery snapshot retained at: $work/snap"
        fi
        txn_committed=1
        trap - INT TERM HUP
        release_lock
        return "$rc"
    fi

    # Commit phase: sync storage and remove WAL log atomically
    sync_dir "$apps_dir"
    sync_dir "$(dirname -- "$db")"
    rm -rf -- "$work" "$wal_file"
    sync_dir "$wal_dir"

    txn_committed=1
    trap - INT TERM HUP
    release_lock
    info "Transaction committed successfully: ${#TXN_IDS[@]} package(s) installed."
    return 0
}
