#!/usr/bin/env bash
# ==============================================================================
# lib/manage.sh - Application Lifecycle & Desktop Integration Engine
# ULPM v4.1.0 Unified Architecture
# ==============================================================================

refresh_desktop_environment() {
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local apps_dir="$data_home/applications"
    local icons_base="$data_home/icons/hicolor"
    [[ -d "$apps_dir" ]] || mkdir -p "$apps_dir" 2>/dev/null || true
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        [[ -d "$icons_base" ]] && gtk-update-icon-cache -q -t "$icons_base" 2>/dev/null || true
    fi
}

_desktop_escape_value() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//\;/\\;}
    value=${value//\#/\\#}
    printf '%s' "$value"
}

_valid_app_id() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

_safe_managed_dir() {
    local path="${1:-}" resolved
    [[ -n "$path" ]] || return 1
    resolved="$(readlink -m -- "$path" 2>/dev/null)" || return 1
    [[ -n "$resolved" && "$resolved" != / && "$resolved" != "$HOME" ]]
}

_version_gt() {
    local v1="${1:-}" v2="${2:-}"
    if command -v dpkg >/dev/null 2>&1; then
        dpkg --compare-versions "$v1" gt "$v2" 2>/dev/null
    else
        [[ "$v1" != "$v2" ]] && [[ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V 2>/dev/null | tail -n 1)" == "$v1" ]]
    fi
}

write_desktop_launcher() {
    local app_id="${1:-}" app_name="${2:-}"
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local launcher exec_bin safe_name
    _valid_app_id "$app_id" || { error "Invalid application ID for desktop launcher: $app_id"; return 1; }
    [[ -n "$app_name" ]] || { error "Application name is empty."; return 1; }
    mkdir -p "$desktop_dir" || return 1
    launcher="$desktop_dir/$app_id.desktop"
    exec_bin="${ULPM_BIN:-ulpm}"
    safe_name="$(_desktop_escape_value "$app_name")"
    exec_bin=${exec_bin//\\/\\\\}
    exec_bin=${exec_bin//\"/\\\"}
    cat > "$launcher" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=$safe_name
Exec="$exec_bin" run $app_id %u
Icon=$app_id
Categories=Utility;Network;AudioVideo;Graphics;Development;
Terminal=false
StartupWMClass=$app_id
X-ULPM-Package=$safe_name
EOF_DESKTOP
    chmod 644 "$launcher"
}

_manage_cleanup_install() {
    local tmp_lpk="${1:-}" mnt_tmp="${2:-}"
    if [[ -n "$mnt_tmp" && -d "$mnt_tmp" ]]; then
        if declare -F safe_unmount >/dev/null 2>&1; then
            safe_unmount "$mnt_tmp" >/dev/null 2>&1 || true
        fi
        local tries=0
        while mountpoint -q -- "$mnt_tmp" 2>/dev/null && (( tries++ < 20 )); do
            sleep 0.05
        done
        if ! mountpoint -q -- "$mnt_tmp" 2>/dev/null; then
            rm -rf -- "$mnt_tmp"
        else
            warn "Leaving mounted inspection directory in place: $mnt_tmp"
        fi
    fi
    [[ -n "$tmp_lpk" ]] && rm -f -- "$tmp_lpk"
    release_lock >/dev/null 2>&1 || true
}

cmd_install() (
    local source="${1:-}"
    [[ -n "$source" ]] || { error "Usage: ulpm install <package.lpk|url>"; return 1; }
    acquire_lock 10 || return 1

    local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    mkdir -p "$cache_home/tmp" "$cache_home" || { release_lock; return 1; }
    local tmp_lpk mnt_tmp=""
    tmp_lpk="$(mktemp "$cache_home/tmp/install_XXXXXX.lpk")" || { release_lock; return 1; }
    trap '_manage_cleanup_install "$tmp_lpk" "$mnt_tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    local raw_target="$source"
    source="$(normalize_target "$source")" || { error "Could not resolve package target."; return 1; }
    if [[ -f "$source" ]]; then
        cp -- "$source" "$tmp_lpk" || { error "Could not copy package file."; return 1; }
    elif [[ "$source" =~ ^https?:// ]]; then
        check_dependencies curl || return 1
        log "Downloading $source..."
        local curl_opts=(-fL --retry 2 --connect-timeout 15)
        if [[ -t 2 ]]; then curl_opts+=(--progress-bar); else curl_opts+=(-sS); fi
        curl "${curl_opts[@]}" "$source" -o "$tmp_lpk" || { error "Download failed: $source"; return 1; }
    else
        error "Source package not found: $source"
        return 1
    fi
    [[ -s "$tmp_lpk" ]] || { error "Downloaded package is empty."; return 1; }

    # Cryptographic integrity check
    local verify_status=0
    if declare -F verify_package >/dev/null 2>&1; then
        verify_package "$tmp_lpk" || verify_status=$?
    elif declare -F enforce_package_trust >/dev/null 2>&1; then
        enforce_package_trust "$tmp_lpk" || verify_status=$?
    fi

    case "$verify_status" in
        0) ;;
        2|3)
            if [[ "${ULPM_STRICT_SIGNATURES:-0}" == 1 ]]; then
                error "Package signature untrusted or unsigned (rejected by strict mode)."
                return 1
            fi
            warn "Package signature is missing or untrusted; continuing installation."
            ;;
        *)
            error "Package signature verification failed (corrupted or forged package)."
            return 1
            ;;
    esac

    check_dependencies squashfuse jq mountpoint || return 1
    mnt_tmp="$(mktemp -d "$cache_home/mnt_chk_XXXXXX")" || return 1
    if ! squashfuse "$tmp_lpk" "$mnt_tmp"; then
        error "Failed to inspect package archive (SquashFS mount failed)."
        return 1
    fi

    local manifest="$mnt_tmp/meta/manifest.json"
    [[ -f "$manifest" ]] || manifest="$mnt_tmp/lpk.json"
    [[ -f "$manifest" ]] || { error "Package manifest not found."; return 1; }
    jq -e 'type == "object"' "$manifest" >/dev/null 2>&1 || { error "Invalid package manifest JSON."; return 1; }

    local app_id app_name app_version
    app_id="$(jq -r '.id // empty' "$manifest")"
    app_name="$(jq -r '.name // empty' "$manifest")"
    app_version="$(jq -r '.version // "1.0.0"' "$manifest")"
    app_name="${app_name:-$(basename -- "$source" .lpk)}"
    app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"
    [[ -n "$app_name" && ${#app_name} -le 128 ]] || {
        error "Unsafe or empty application name in package manifest."; return 1;
    }

    if [[ -z "$app_id" ]]; then
        local id_slug
        id_slug="${app_name,,}"
        id_slug="${id_slug// /-}"
        id_slug="$(printf '%s' "$id_slug" | sed -E 's/[^a-z0-9._-]+/-/g; s/^[.-]+//; s/[.-]+$//')"
        [[ -n "$id_slug" ]] || id_slug="app"
        app_id="io.lpk.$id_slug"
    fi
    _valid_app_id "$app_id" || { error "Invalid application ID in package manifest: $app_id"; return 1; }
    app_version="$(printf '%s' "$app_version" | tr -cd 'A-Za-z0-9.+_-')"
    [[ -n "$app_version" && ${#app_version} -le 64 ]] || app_version="1.0.0"

    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local icon_dir="$data_home/icons/hicolor/256x256/apps"
    mkdir -p "$icon_dir" || return 1
    if [[ -f "$mnt_tmp/meta/icon.png" ]]; then
        cp -- "$mnt_tmp/meta/icon.png" "$icon_dir/$app_id.png" || true
    elif [[ -f "$mnt_tmp/icon.png" ]]; then
        cp -- "$mnt_tmp/icon.png" "$icon_dir/$app_id.png" || true
    fi

    if declare -F safe_unmount >/dev/null 2>&1; then
        safe_unmount "$mnt_tmp" || true
    fi

    local unmount_tries=0
    while mountpoint -q -- "$mnt_tmp" 2>/dev/null && (( unmount_tries++ < 20 )); do
        sleep 0.05
    done
    if mountpoint -q -- "$mnt_tmp" 2>/dev/null; then
        error "Could not unmount package inspection directory; refusing to continue."
        return 1
    fi
    rm -rf -- "$mnt_tmp" || { error "Could not remove temporary inspection directory."; return 1; }
    mnt_tmp=""

    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    _safe_managed_dir "$apps_dir" || { error "Refusing unsafe application directory: $apps_dir"; return 1; }
    mkdir -p "$apps_dir" "$(dirname -- "$db_file")" || return 1
    local dest_dir="$apps_dir/$app_name"
    [[ ! -L "$dest_dir" ]] || { error "Refusing to install through a symlinked application directory: $dest_dir"; return 1; }
    mkdir -p "$dest_dir" || return 1
    mv -f -- "$tmp_lpk" "$dest_dir/$app_name.lpk" || { error "Could not place package in application directory."; return 1; }
    tmp_lpk=""

    if ! write_desktop_launcher "$app_id" "$app_name"; then
        warn "Package installed, but desktop launcher creation failed."
    fi

    local source_origin="${INSTALL_ORIGIN:-$raw_target}"
    if [[ "$source_origin" == *$'\n'* || "$source_origin" == *$'\r'* || \
          "$source_origin" == *$'\t'* || "$source_origin" == *'|'* || "$source_origin" == *[[:cntrl:]]* ]]; then
        source_origin="local"
    fi

    # Atomic DB update
    if declare -F db_remove_entry >/dev/null 2>&1; then
        db_remove_entry "$app_id" "$app_name"
    else
        local db_tmp
        db_tmp="$(mktemp "${db_file}.tmp.XXXXXX")" || return 1
        if [[ -f "$db_file" ]]; then
            awk -F'|' -v id="$app_id" -v name="$app_name" '$1 != id && $2 != name' "$db_file" > "$db_tmp" || { rm -f "$db_tmp"; return 1; }
        fi
        mv -f -- "$db_tmp" "$db_file" 2>/dev/null || true
    fi
    printf '%s|%s|%s|%s|%s\n' "$app_id" "$app_name" "$app_version" "$(date +%s)" "$source_origin" >> "$db_file"

    refresh_desktop_environment
    info "Successfully installed '$app_name' ($app_id v$app_version)."
)

cmd_integrate() {
    local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    local mime_dir="$data_home/mime" desk_dir="$data_home/applications"
    mkdir -p "$mime_dir/packages" "$desk_dir" || return 1

    cat > "$mime_dir/packages/ulpm-lpk.xml" <<'EOF_MIME'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
    <mime-type type="application/x-lpk">
        <comment>ULPM Package Bundle</comment>
        <comment xml:lang="fr">Paquet d'application ULPM</comment>
        <icon name="package-x-generic"/>
        <glob pattern="*.lpk"/>
        <glob pattern="*.LPK"/>
    </mime-type>
</mime-info>
EOF_MIME

    local handler_bin="${ULPM_BIN:-ulpm}"
    handler_bin=${handler_bin//\\/\\\\}
    handler_bin=${handler_bin//\"/\\\"}

    # Exec invokes 'run' directly to satisfy double-click expectations
    cat > "$desk_dir/ulpm-handler.desktop" <<EOF_HANDLER
[Desktop Entry]
Type=Application
Name=ULPM Package Runner
Name[fr]=Exécuteur de paquets ULPM
GenericName=Package Runner
Comment=Run sandboxed .lpk applications directly
Comment[fr]=Exécuter des paquets autonomes LPK
Exec="$handler_bin" run %f
Icon=package-x-generic
Terminal=false
NoDisplay=false
MimeType=application/x-lpk;
Categories=System;Utility;
StartupNotify=true
EOF_HANDLER

    chmod 644 "$mime_dir/packages/ulpm-lpk.xml" "$desk_dir/ulpm-handler.desktop"
    command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$mime_dir" >/dev/null 2>&1 || true
    refresh_desktop_environment

    # Notify active file managers
    nautilus -q 2>/dev/null || true
    thunar -q 2>/dev/null || true
    kbuildsycoca5 2>/dev/null || kbuildsycoca6 2>/dev/null || true

    info "MIME association and desktop integration registered."
}

cmd_list() {
    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
    info "Installed ULPM Applications:"
    printf '%s\n' '--------------------------------------------------------------------------------'
    printf '%-25s %-15s %-12s %-24s\n' NAME VERSION SIZE ID
    printf '%s\n' '--------------------------------------------------------------------------------'
    if [[ -s "$db_file" ]]; then
        while IFS='|' read -r id name ver _ origin; do
            [[ -n "$name" ]] || continue
            local sz='-'
            if [[ -f "$apps_dir/$name/$name.lpk" ]]; then
                sz="$(du -sh -- "$apps_dir/$name/$name.lpk" 2>/dev/null | cut -f1)"
            elif [[ -f "$apps_dir/$name.lpk" ]]; then
                sz="$(du -sh -- "$apps_dir/$name.lpk" 2>/dev/null | cut -f1)"
            fi
            printf '%-25.25s %-15.15s %-12s %-24.24s\n' "$name" "$ver" "$sz" "$id"
        done < "$db_file"
    fi
    printf '%s\n' '--------------------------------------------------------------------------------'
}

cmd_remove() (
    local purge=false target=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            --) shift; break ;;
            -*) error "Unknown remove option: $1"; return 1 ;;
            *) [[ -z "$target" ]] && target="$1" || { error "Only one application may be removed at a time."; return 1; }; shift ;;
        esac
    done
    [[ -n "$target" ]] || { error "Usage: ulpm remove [--purge] <app_name|app_id>"; return 1; }
    acquire_lock 10 || return 1
    trap 'release_lock >/dev/null 2>&1 || true' EXIT

    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
    _safe_managed_dir "$apps_dir" || { error "Refusing unsafe application directory: $apps_dir"; return 1; }
    local resolved_id='' resolved_name='' id name ver installed origin
    if [[ -s "$db_file" ]]; then
        while IFS='|' read -r id name ver installed origin; do
            if [[ "$id" == "$target" || "$name" == "$target" ]]; then
                resolved_id="$id"; resolved_name="$name"; break
            fi
        done < "$db_file"
    fi
    local app_name="${resolved_name:-$target}" app_id="${resolved_id:-io.lpk.${target,,}}"
    [[ "$app_name" != */* && "$app_name" != . && "$app_name" != .. ]] || { error "Unsafe application name."; return 1; }
    _valid_app_id "$app_id" || { error "Unsafe application ID."; return 1; }

    rm -rf -- "${apps_dir:?}/${app_name:?}"
    rm -f -- "$apps_dir/$app_name.lpk"
    rm -f -- "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$app_id.desktop"
    rm -f -- "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/$app_id.png"

    if declare -F db_remove_entry >/dev/null 2>&1; then
        db_remove_entry "$app_id" "$app_name"
    elif [[ -f "$db_file" ]]; then
        local db_tmp
        db_tmp="$(mktemp "${db_file}.tmp.XXXXXX")" || return 1
        awk -F'|' -v id="$app_id" -v name="$app_name" '$1 != id && $2 != name' "$db_file" > "$db_tmp" || { rm -f "$db_tmp"; return 1; }
        mv -f -- "$db_tmp" "$db_file" || { rm -f "$db_tmp"; return 1; }
    fi

    # Correct purge of isolated sandbox directories in ~/.var/app
    if [[ "$purge" == true ]]; then
        log "Purging persistent user sandbox state..."
        rm -rf -- "$HOME/.var/app/$app_name"
        [[ "$app_id" != "$app_name" ]] && rm -rf -- "$HOME/.var/app/$app_id"
    fi

    refresh_desktop_environment
    info "Application '$app_name' removed successfully."
)

cmd_clean() {
    local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    _safe_managed_dir "$cache_home" || { error "Refusing unsafe cache path: $cache_home"; return 1; }
    command -v mountpoint >/dev/null 2>&1 || { error "The mountpoint command is required for safe cleanup."; return 1; }
    log "Unmounting orphaned sessions & purging temporary storage..."
    if [[ -d "$cache_home" ]]; then
        while IFS= read -r -d '' pt; do
            if declare -F safe_unmount >/dev/null 2>&1; then safe_unmount "$pt" || true; fi
        done < <(find "$cache_home" -maxdepth 2 -type d -name 'mnt_*' -print0 2>/dev/null)
        for pattern in "$cache_home"/mnt_* "$cache_home"/tmp/* "$cache_home"/build_* "$cache_home"/wrap_ai_*; do
            [[ -e "$pattern" || -L "$pattern" ]] || continue
            if mountpoint -q -- "$pattern" 2>/dev/null; then
                warn "Skipping active mount point: $pattern"
                continue
            fi
            rm -rf -- "$pattern"
        done
    fi
    info "Cleanup complete."
}

cmd_search() {
    local query="$*"
    [[ -n "$query" ]] || { error "Usage: ulpm search <keyword>"; return 1; }
    check_dependencies curl jq || return 1
    local is_debian_like=false
    if [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
        is_debian_like=true
    elif command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        is_debian_like=true
    fi
    local arch arch_regex
    arch="$(detect_arch)"
    case "$arch" in
        arm64|aarch64) arch_regex='arm64|aarch64|arm-64|armv8|arm64v8|all' ;;
        x86_64|amd64) arch_regex='amd64|x86_64|x86-64|x64|all' ;;
        armv7l|armhf)  arch_regex='armv7|armhf|armv7l|all' ;;
        *)             arch_regex="$arch|all" ;;
    esac
    info "Searching for '$query' across GitHub Releases and Local Repositories..."

    local -a global_targets=() global_types=() global_assets=() global_labels=()
    local display_idx=1 gh_query raw_results raw_count
    gh_query="$(printf '%s' "$query" | sed 's/ /+/g')"
    raw_results="$(fetch_github_api "search/repositories?q=${gh_query}+in:name&sort=stars&order=desc&per_page=10" 15)" || raw_results=''
    raw_count="$(jq -r '.items | length // 0' <<< "$raw_results" 2>/dev/null || printf '0')"

    if [[ "$raw_count" =~ ^[0-9]+$ ]] && (( raw_count > 0 )); then
        printf '\n\033[1;32m[ GitHub Upstream Releases ]\033[0m\n%s\n' '--------------------------------------------------------------------------------'
        while IFS=$'\t' read -r repo stars desc; do
            [[ -n "$repo" ]] || continue
            local rel_data assets_json aname aurl
            rel_data="$(fetch_github_api "repos/${repo}/releases/latest" 30)" || continue
            assets_json="$(jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' <<< "$rel_data" 2>/dev/null)"
            [[ -n "$assets_json" ]] || continue
            local -a compat_names=() compat_urls=()
            while IFS=$'\t' read -r aname aurl; do
                [[ -n "$aname" && -n "$aurl" ]] || continue
                [[ "$aname" =~ \.(lpk|appimage|deb)$ ]] || continue
                if grep -qiE "$arch_regex" <<< "$aname"; then
                    if [[ "$arch" == arm64 || "$arch" == aarch64 ]] && grep -qiE 'x86|amd64|i386|i686' <<< "$aname"; then continue; fi
                    if [[ "$arch" == x86_64 || "$arch" == amd64 ]] && grep -qiE '(^|[^a-z0-9])(arm|aarch64?|armv[0-9]+)([^a-z0-9]|$)' <<< "$aname"; then continue; fi
                    compat_names+=("$aname"); compat_urls+=("$aurl")
                fi
            done <<< "$assets_json"
            local selected_type='' selected_url='' selected_filename='' priority
            for priority in lpk appimage deb; do
                [[ "$priority" != deb || "$is_debian_like" == true ]] || continue
                local j
                for ((j=0; j<${#compat_names[@]}; j++)); do
                    if [[ "${compat_names[j],,}" == *".$priority" ]]; then
                        selected_filename="${compat_names[j]}"; selected_url="${compat_urls[j]}"
                        case "$priority" in
                            lpk) selected_type=LPK ;;
                            appimage) selected_type=APPIMAGE ;;
                            deb) selected_type=DEB ;;
                        esac
                        break
                    fi
                done
                [[ -n "$selected_type" ]] && break
            done
            [[ -n "$selected_type" ]] || continue
            global_targets[display_idx]="$repo"; global_types[display_idx]="$selected_type"; global_assets[display_idx]="$selected_url"; global_labels[display_idx]="$selected_filename"

            local badge=""
            case "$selected_type" in
                LPK)       badge="\033[1;32m[1. Native LPK]\033[0m" ;;
                APPIMAGE)  badge="\033[1;34m[2. AppImage]\033[0m" ;;
                DEB)       badge="\033[1;33m[3. Debian .deb]\033[0m" ;;
            esac

            printf " \033[1;33m[%d]\033[0m %b \033[1m%-25s\033[0m \033[1;33m★ %-5s\033[0m\n     \033[0;90mAsset: %s\033[0m\n     \033[0;90m%s\033[0m\n" \
                "$display_idx" "$badge" "$repo" "$stars" "$selected_filename" "${desc:0:70}"
            ((display_idx++))
        done < <(jq -r '.items[]? | [.full_name, (.stargazers_count|tostring), (.description // "No description")] | @tsv' <<< "$raw_results" 2>/dev/null)
    fi

    if [[ "$is_debian_like" == true ]] && command -v apt-cache >/dev/null 2>&1; then
        printf '\n\033[1;35m[ Native Debian / APT Candidates ]\033[0m\n%s\n' '--------------------------------------------------------------------------------'
        local apt_results
        apt_results="$(apt-cache search "$query" 2>/dev/null | head -n 5 || true)"
        if [[ -n "$apt_results" ]]; then
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                local apt_pkg apt_desc
                apt_pkg="$(awk '{print $1}' <<< "$line")"
                apt_desc="$(cut -d' ' -f2- <<< "$line")"
                global_targets[display_idx]="$apt_pkg"; global_types[display_idx]=APT; global_assets[display_idx]=''; global_labels[display_idx]="$apt_desc"
                printf " \033[1;33m[%d]\033[0m \033[0;35m[4. APT]\033[0m \033[1m%-25s\033[0m\n     \033[0;90m%s\033[0m\n" \
                    "$display_idx" "$apt_pkg" "${apt_desc:0:70}"
                ((display_idx++))
            done <<< "$apt_results"
        else
            printf '  No direct APT packages matching query.\n'
        fi
    fi

    local total_options=$((display_idx - 1))
    printf '%s\n' '--------------------------------------------------------------------------------'
    (( total_options > 0 )) || { warn "No package candidates found for '$query'."; return 0; }
    [[ -r /dev/tty ]] || { error 'Interactive selection requires a terminal.'; return 1; }
    printf '\033[1;36mSelect package(s) to install (e.g. 1, 1 2, 1-3) [default: cancel]: \033[0m'
    local raw_input
    IFS= read -r raw_input </dev/tty || return 1
    [[ -n "$raw_input" ]] || { log 'Operation cancelled.'; return 0; }
    raw_input="${raw_input//,/ }"
    local -a tokens=() selected=() unique_indices=()
    read -r -a tokens <<< "$raw_input"
    local token start end i
    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
            if (( start > 0 && end <= total_options && start <= end && end - start <= 100 )); then
                for ((i=start;i<=end; i++)); do selected+=("$i"); done
            fi
        elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= total_options )); then
            selected+=("$token")
        fi
    done
    (( ${#selected[@]} > 0 )) || { log 'No valid selection; operation cancelled.'; return 0; }
    mapfile -t unique_indices < <(printf '%s\n' "${selected[@]}" | sort -nu)
    local idx target type asset_url
    for idx in "${unique_indices[@]}"; do
        target="${global_targets[idx]}"; type="${global_types[idx]}"; asset_url="${global_assets[idx]}"
        printf '\n\033[1;34m:: Processing candidate [%s]: %s (%s)...\033[0m\n' "$idx" "$target" "$type"
        case "$type" in
            LPK)
                info 'Installing upstream native LPK...'
                INSTALL_ORIGIN="$asset_url" cmd_install "$asset_url" || warn "Installation failed for $target."
                ;;
            APPIMAGE)
                info 'Wrapping AppImage upstream release into LPK...'
                local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
                mkdir -p "$cache_home" || continue
                local app_bin="${target##*/}" tmp_ai wrap_root out_lpk
                tmp_ai="$(mktemp "$cache_home/stream_ai_XXXXXX.AppImage")" || continue
                if ! curl -fL --retry 2 --connect-timeout 15 --progress-bar "$asset_url" -o "$tmp_ai"; then
                    error "Failed to download $asset_url"; rm -f -- "$tmp_ai"; continue
                fi
                chmod +x "$tmp_ai" || { rm -f -- "$tmp_ai"; continue; }
                wrap_root="$(mktemp -d "$cache_home/wrap_ai_XXXXXX")" || { rm -f -- "$tmp_ai"; continue; }
                mkdir -p "$wrap_root/bin" || { rm -rf -- "$wrap_root"; rm -f -- "$tmp_ai"; continue; }
                mv -- "$tmp_ai" "$wrap_root/bin/$app_bin" || { rm -rf -- "$wrap_root" "$tmp_ai"; continue; }
                ln -sf -- "bin/$app_bin" "$wrap_root/AppRun" 2>/dev/null || true
                out_lpk="${app_bin}.lpk"
                if cmd_pack "$wrap_root" "$app_bin" "$out_lpk"; then
                    INSTALL_ORIGIN="https://github.com/$target" cmd_install "$out_lpk" || warn "Installation failed for $target."
                fi
                rm -rf -- "$wrap_root"
                ;;
            DEB)
                info 'Converting upstream Debian package to LPK...'
                local out_lpk="${target##*/}.lpk"
                if cmd_deb_pack "$asset_url" "${target##*/}" "$out_lpk"; then
                    INSTALL_ORIGIN="https://github.com/$target" cmd_install "$out_lpk" || warn "Installation failed for $target."
                fi
                ;;
            APT)
                info 'Packaging APT package to LPK...'
                local out_lpk="${target}.lpk"
                if cmd_deb_pack "$target" "$target" "$out_lpk"; then
                    INSTALL_ORIGIN="apt:$target" cmd_install "$out_lpk" || warn "Installation failed for $target."
                fi
                ;;
        esac
    done
}

cmd_inspect() {
    local target="${1:-}"
    [[ -n "$target" ]] || { error "Usage: ulpm inspect <package.lpk|app_name>"; return 1; }
    check_dependencies unsquashfs jq stat || return 1
    local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}" lpk_file=''
    if [[ -f "$target" ]]; then
        lpk_file="$target"
    elif [[ -f "$apps_dir/$target/$target.lpk" ]]; then
        lpk_file="$apps_dir/$target/$target.lpk"
    elif [[ -f "$apps_dir/$target.lpk" ]]; then
        lpk_file="$apps_dir/$target.lpk"
    elif [[ -f "$apps_dir/io.lpk.${target,,}.lpk" ]]; then
        lpk_file="$apps_dir/io.lpk.${target,,}.lpk"
    else
        error "Target LPK archive or installed application not found: $target"; return 1
    fi

    local manifest_raw
    manifest_raw="$(unsquashfs -cat "$lpk_file" meta/manifest.json 2>/dev/null)" || manifest_raw=''
    [[ -n "$manifest_raw" ]] || manifest_raw="$(unsquashfs -cat "$lpk_file" lpk.json 2>/dev/null)" || manifest_raw=''
    [[ -n "$manifest_raw" ]] || { error 'Archive does not contain a readable ULPM manifest.'; return 1; }
    jq -e 'type == "object"' <<< "$manifest_raw" >/dev/null 2>&1 || { error 'Manifest JSON is invalid.'; return 1; }

    local app_id app_name app_ver app_arch app_exec app_net app_fv crypto_status code fsize
    app_id="$(jq -r '.id // "unknown"' <<< "$manifest_raw")"
    app_name="$(jq -r '.name // "unknown"' <<< "$manifest_raw")"
    app_ver="$(jq -r '.version // "1.0.0"' <<< "$manifest_raw")"
    app_arch="$(jq -r '.arch // "unknown"' <<< "$manifest_raw")"
    app_exec="$(jq -r '.exec // "unknown"' <<< "$manifest_raw")"
    app_net="$(jq -r '.network // false' <<< "$manifest_raw")"
    app_fv="$(jq -r '.format_version // 1' <<< "$manifest_raw")"
    crypto_status="\033[0;31m✖ Unsigned / unverified\033[0m"
    if verify_package "$lpk_file" >/dev/null 2>&1; then
        crypto_status="\033[0;32m✔ Verified (trusted key)\033[0m"
    else
        code=$?
        case "$code" in
            2) crypto_status="\033[0;31m✖ Unsigned (missing signature)\033[0m" ;;
            3) crypto_status="\033[1;33m⚠ Signed (untrusted authority)\033[0m" ;;
            *) crypto_status="\033[0;31m✖ INVALID / CORRUPTED SIGNATURE\033[0m" ;;
        esac
    fi
    fsize="$(du -sh -- "$lpk_file" 2>/dev/null | cut -f1)"
    printf '%s\n' '================================================================================'
    printf ' \033[1;36m%-16s\033[0m : %s\n' Application "$app_name"
    printf ' \033[1;36m%-16s\033[0m : %s\n' Identifier "$app_id"
    printf ' \033[1;36m%-16s\033[0m : \033[1;32mv%s\033[0m (%s)\n' Version "$app_ver" "$app_arch"
    printf ' \033[1;36m%-16s\033[0m : LPK v%s (Archive: %s)\n' Format "$app_fv" "$fsize"
    printf '%s\n' '--------------------------------------------------------------------------------'
    printf ' \033[1;34m%-16s\033[0m : %s\n' Entrypoint "$app_exec"
    printf ' \033[1;34m%-16s\033[0m : %b\n' 'Network Access' "$([[ "$app_net" == true ]] && printf '\033[0;32mEnabled\033[0m' || printf '\033[1;33mIsolated\033[0m')"
    printf ' \033[1;34m%-16s\033[0m : %b\n' 'Security Seal' "$crypto_status"
    printf '%s\n' '================================================================================'
}

cmd_upgrade() {
    local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
    [[ -s "$db_file" ]] || { info 'No ULPM applications installed.'; return 0; }
    check_dependencies jq || return 1
    info 'Checking for application updates...'
    local updates_found=0
    local app_id app_name cur_ver origin

    while IFS='|' read -r app_id app_name cur_ver _ origin; do
        [[ -n "$app_name" && -n "$origin" ]] || continue

        # CASE 1: GitHub Origin
        if [[ "$origin" =~ ^https?://github\.com/ || "$origin" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+ ]]; then
            local repo_path rel_data latest_tag clean_latest clean_cur needs_update=false
            repo_path="$(printf '%s' "$origin" | sed -E 's#^https?://github\.com/##; s#/$##; s#\.git$##')"
            repo_path="$(cut -d/ -f1-2 <<< "$repo_path")"

            log "Checking upstream release for '$app_name' ($repo_path)..."
            rel_data="$(fetch_github_api "repos/${repo_path}/releases/latest" 10)" || continue
            latest_tag="$(jq -r '.tag_name // empty' <<< "$rel_data" 2>/dev/null)"
            [[ -n "$latest_tag" ]] || continue
            clean_latest="${latest_tag#v}"; clean_cur="${cur_ver#v}"

            if _version_gt "$clean_latest" "$clean_cur"; then
                needs_update=true
            fi

            if [[ "$needs_update" == true ]]; then
                ((updates_found+=1))
                printf ' \033[1;32m➜\033[0m Update available for \033[1m%s\033[0m: \033[1;31m%s\033[0m ➔ \033[1;32m%s\033[0m\n' "$app_name" "$cur_ver" "$latest_tag"

                if [[ "$origin" =~ \.lpk$ ]]; then
                    local new_url arch
                    arch="$(detect_arch)"
                    new_url="$(jq -r --arg arch "$arch" '
                        .assets[]? | select(.name | endswith(".lpk")) |
                        select(.name | contains($arch)) | .browser_download_url
                    ' <<< "$rel_data" 2>/dev/null | head -n 1)"
                    [[ -n "$new_url" ]] || new_url="$(jq -r '.assets[]? | select(.name | endswith(".lpk")) | .browser_download_url' <<< "$rel_data" 2>/dev/null | head -n 1)"

                    if [[ -n "$new_url" ]] && INSTALL_ORIGIN="$new_url" cmd_install "$new_url"; then
                        info "Updated '$app_name' successfully to $latest_tag."
                    else
                        error "Failed to upgrade $app_name."
                    fi
                else
                    local out_lpk="${app_name}.lpk"
                    if cmd_deb_pack "$repo_path" "$app_name" "$out_lpk" "$clean_latest"; then
                        INSTALL_ORIGIN="$origin" cmd_install "$out_lpk"
                        info "Updated '$app_name' successfully to $latest_tag."
                    else
                        error "Failed to upgrade $app_name."
                    fi
                fi
            fi

        # CASE 2: APT Repository Origin
        elif [[ "$origin" == apt:* ]]; then
            local apt_pkg="${origin#apt:}" candidate_ver
            command -v apt-cache >/dev/null 2>&1 || continue
            candidate_ver="$(apt-cache policy "$apt_pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
            if [[ -n "$candidate_ver" && "$candidate_ver" != '(none)' && "$candidate_ver" != "$cur_ver" ]]; then
                ((updates_found+=1))
                printf '\033[1;32m➜\033[0m APT update available for \033[1m%s\033[0m: \033[1;31m%s\033[0m ➔ \033[1;32m%s\033[0m\n' "$app_name" "$cur_ver" "$candidate_ver"
                local out_lpk="${app_name}.lpk"
                if cmd_deb_pack "$apt_pkg" "$app_name" "$out_lpk" "$candidate_ver"; then
                    INSTALL_ORIGIN="$origin" cmd_install "$out_lpk" || error "Failed to install update for $app_name."
                fi
            fi
        fi
    done < "$db_file"

    if (( updates_found == 0 )); then
        info 'All ULPM applications are up to date.'
    else
        info "Upgrade process finished. $updates_found application(s) updated."
    fi
}
