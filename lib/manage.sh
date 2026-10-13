#!/usr/bin/env bash
# ==============================================================================
# lib/manage.sh - Application Lifecycle & Desktop Integration Engine
# ==============================================================================

refresh_desktop_environment() {
    local apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local icons_base="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$apps_dir" 2>/dev/null || true
    fi

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q -t "$icons_base" 2>/dev/null || true
    fi
}

write_desktop_launcher() {
    local app_id="$1"
    local app_name="$2"
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$desktop_dir"

    cat <<EOF > "$desktop_dir/${app_id}.desktop"
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=${ULPM_BIN:-ulpm} run ${app_id} %u
Icon=${app_id}
Categories=Utility;Network;AudioVideo;Graphics;Development;
Terminal=false
StartupWMClass=${app_id}
X-ULPM-Package=${app_name}
EOF
    chmod 644 "$desktop_dir/${app_id}.desktop"
}

cmd_install() {
    local source="${1:-}"
    [[ -z "$source" ]] && { error "Usage: ulpm install <package.lpk|url>"; return 1; }

    acquire_lock 10 || return 1

    local tmp_lpk mnt_tmp=""
    tmp_lpk="$(mktemp "${ULPM_CACHE_HOME}/tmp/install_XXXXXX.lpk")"

    # Contextual cleanup for installation instance
    _cleanup_install() {
        if [[ -n "$mnt_tmp" && -d "$mnt_tmp" ]]; then
            safe_unmount "$mnt_tmp"
            rm -rf "$mnt_tmp"
        fi
        rm -f "$tmp_lpk"
        release_lock
    }
    trap '_cleanup_install' RETURN
    trap '_cleanup_install; exit 130' INT
    trap '_cleanup_install; exit 143' TERM HUP

    local raw_target="$source"
    source="$(normalize_target "$source")"

    if [[ -f "$source" ]]; then
        cp -f "$source" "$tmp_lpk"
    elif [[ "$source" =~ ^https?:// ]]; then
        check_dependencies curl
        log "Downloading $source..."
        local curl_opts=(-fL --retry 2)
        [[ -t 1 ]] && curl_opts+=(--progress-bar) || curl_opts+=(-sS)
        curl "${curl_opts[@]}" "$source" -o "$tmp_lpk" || {
            error "Download failed: $source"
            return 1
        }
    else
        error "Source package not found: $source"
        return 1
    fi

    # Cryptographic integrity check
    verify_package "$tmp_lpk" || warn "Package signature is unverified. Continuing installation..."

    mnt_tmp="$(mktemp -d "${ULPM_CACHE_HOME}/mnt_chk_XXXXXX")"
    if ! squashfuse "$tmp_lpk" "$mnt_tmp" 2>/dev/null; then
        error "Failed to inspect package archive (SquashFS mount failed)."
        return 1
    fi

    local manifest="$mnt_tmp/meta/manifest.json"
    [[ ! -f "$manifest" ]] && manifest="$mnt_tmp/lpk.json"

    local app_id app_name app_version
    app_id="$(jq -r '.id // empty' "$manifest" 2>/dev/null || true)"
    app_name="$(jq -r '.name // empty' "$manifest" 2>/dev/null || true)"
    app_version="$(jq -r '.version // "1.0.0"' "$manifest" 2>/dev/null || true)"

    app_name="${app_name:-$(basename "$source" .lpk)}"
    app_id="${app_id:-io.lpk.$app_name}"

    # Extract icon if provided
    local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    mkdir -p "$icon_dir"
    if [[ -f "$mnt_tmp/meta/icon.png" ]]; then
        cp -f "$mnt_tmp/meta/icon.png" "$icon_dir/${app_id}.png"
    elif [[ -f "$mnt_tmp/icon.png" ]]; then
        cp -f "$mnt_tmp/icon.png" "$icon_dir/${app_id}.png"
    fi

    # Unmount inspection directory before permanent move
    safe_unmount "$mnt_tmp"
    rm -rf "$mnt_tmp"
    mnt_tmp=""

    local dest_dir="$ULPM_APPS_DIR/$app_name"
    mkdir -p "$dest_dir"
    mv -f "$tmp_lpk" "$dest_dir/$app_name.lpk"

    write_desktop_launcher "$app_id" "$app_name"

    # Upstream origin tracking for automatic updates
    local source_origin="${INSTALL_ORIGIN:-$raw_target}"

    # Atomic DB update under existing ULPM lock
    sed -i "/^${app_id}|/d; /|${app_name}|/d" "$ULPM_DB" 2>/dev/null || true
    printf "%s|%s|%s|%s|%s\n" "$app_id" "$app_name" "$app_version" "$(date +%s)" "$source_origin" >> "$ULPM_DB"

    refresh_desktop_environment
    info "Successfully installed '$app_name' ($app_id v$app_version)."
}

cmd_integrate() {
    local mime_dir="${XDG_DATA_HOME:-$HOME/.local/share}/mime"
    local desk_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$mime_dir/packages" "$desk_dir"

    cat <<EOF > "$mime_dir/packages/application-x-lpk.xml"
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
    <mime-type type="application/x-lpk">
        <comment>ULPM Package</comment>
        <glob pattern="*.lpk"/>
    </mime-type>
</mime-info>
EOF

    cat <<EOF > "$desk_dir/ulpm-handler.desktop"
[Desktop Entry]
Type=Application
Name=ULPM Package Handler
Exec=${ULPM_BIN:-ulpm} run %f
Terminal=false
NoDisplay=true
MimeType=application/x-lpk;
EOF

    if command -v update-mime-database >/dev/null 2>&1; then
        update-mime-database "$mime_dir" >/dev/null 2>&1 || true
    fi
    refresh_desktop_environment
    info "MIME association and desktop integration registered."
}

cmd_list() {
    info "Installed ULPM Applications:"
    echo "--------------------------------------------------------------------------------"
    printf "%-25s %-15s %-12s %-24s\n" "NAME" "VERSION" "SIZE" "ID"
    echo "--------------------------------------------------------------------------------"
    if [[ -s "$ULPM_DB" ]]; then
        while IFS='|' read -r id name ver _ origin; do
            [[ -z "$name" ]] && continue
            local sz="-"
            if [[ -f "$ULPM_APPS_DIR/$name/$name.lpk" ]]; then
                sz="$(du -sh "$ULPM_APPS_DIR/$name/$name.lpk" 2>/dev/null | cut -f1)"
            elif [[ -f "$ULPM_APPS_DIR/$name.lpk" ]]; then
                sz="$(du -sh "$ULPM_APPS_DIR/$name.lpk" 2>/dev/null | cut -f1)"
            fi
            printf "%-25s %-15s %-12s %-24s\n" "$name" "$ver" "$sz" "$id"
        done < "$ULPM_DB"
    fi
    echo "--------------------------------------------------------------------------------"
}

cmd_remove() {
    local purge=false
    local target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            *) target="$1"; shift ;;
        esac
    done

    [[ -z "$target" ]] && { error "Usage: ulpm remove [--purge] <app_name|app_id>"; return 1; }

    acquire_lock 10 || return 1
    _cleanup_remove() { release_lock; }
    trap '_cleanup_remove' RETURN

    # Resolve app_id and app_name from DB if present
    local resolved_id="" resolved_name=""
    if [[ -s "$ULPM_DB" ]]; then
        while IFS='|' read -r id name ver _ origin; do
            if [[ "$id" == "$target" || "$name" == "$target" ]]; then
                resolved_id="$id"
                resolved_name="$name"
                break
            fi
        done < "$ULPM_DB"
    fi

    local app_name="${resolved_name:-$target}"
    local app_id="${resolved_id:-io.lpk.${target,,}}"

    rm -rf "${ULPM_APPS_DIR:?}/$app_name"
    rm -f "$ULPM_APPS_DIR/$app_name.lpk"
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/${app_id}.desktop"
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/${app_id}.png"

    # Atomic DB cleanup
    sed -i "/^${app_id}|/d; /|${app_name}|/d" "$ULPM_DB" 2>/dev/null || true

    if [[ "$purge" == "true" ]]; then
        log "Purging persistent user sandbox state..."
        rm -rf "$HOME/.var/app/$app_name" "$HOME/.var/app/$app_id"
    fi

    refresh_desktop_environment
    info "Application '$app_name' removed successfully."
}

cmd_clean() {
    log "Unmounting orphaned sessions & purging temporary storage..."
    find "$ULPM_CACHE_HOME" -maxdepth 2 -type d -name "mnt_*" 2>/dev/null | while IFS= read -r pt; do
        safe_unmount "$pt"
    done
    rm -rf "${ULPM_CACHE_HOME:?}/mnt_"* "${ULPM_CACHE_HOME:?}/tmp/"* "${ULPM_CACHE_HOME:?}/build_"* 2>/dev/null || true
    info "Cleanup complete."
}

cmd_search() {
    local query="$*"
    [[ -z "$query" ]] && { error "Usage: ulpm search <keyword>"; return 1; }

    check_dependencies curl jq

    # Detect host OS (Debian/Ubuntu based)
    local is_debian_like=false
    if [[ -f /etc/os-release ]] && grep -qiE "ID(=|_LIKE=).*(debian|ubuntu)" /etc/os-release 2>/dev/null; then
        is_debian_like=true
    elif command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        is_debian_like=true
    fi

    # Resolve architecture for filtering
    local arch arch_regex
    arch="$(detect_arch)"
    if [[ "$arch" == "arm64" ]]; then
        arch_regex="arm64|aarch64|arm-64|armv8|arm64v8|all"
    elif [[ "$arch" == "x86_64" ]]; then
        arch_regex="amd64|x86_64|x86-64|x64|all"
    else
        arch_regex="$arch|all"
    fi

    info "Searching for '$query' across GitHub Releases and Local Repositories..."

    local global_targets=()
    local global_types=()
    local global_assets=()
    local display_idx=1

    # ==========================================================================
    # PHASES 1, 2, 3: GITHUB RELEASES (.lpk > .AppImage > .deb)
    # ==========================================================================
    local gh_query
    gh_query="$(printf '%s' "$query" | tr ' ' '+')"
    local raw_results
    raw_results="$(fetch_github_api "search/repositories?q=${gh_query}+in:name&sort=stars&order=desc&per_page=10" 15)" || true

    local raw_count
    raw_count="$(jq -r '.items | length // 0' <<< "$raw_results" 2>/dev/null || echo 0)"

    if [[ "$raw_count" -gt 0 ]]; then
        echo -e "\n\033[1;32m[ GitHub Upstream Releases ]\033[0m"
        echo "--------------------------------------------------------------------------------"

        while IFS=$'\t' read -r repo stars desc; do
            [[ -z "$repo" ]] && continue

            local rel_data
            rel_data="$(fetch_github_api "repos/${repo}/releases/latest" 30)" || continue

            # Get all assets from the release
            local assets_json
            assets_json="$(jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' <<< "$rel_data" 2>/dev/null || true)"
            [[ -z "$assets_json" ]] && continue

            # Filter by host architecture
            local compat_assets=()
            while IFS=$'\t' read -r aname aurl; do
                [[ -z "$aname" ]] && continue
                # Architecture regex test
                if grep -qiE "($arch_regex)" <<< "$aname"; then
                    # Negative filter against false positives
                    if [[ "$arch" == "arm64" ]] && grep -qiE "x86|amd64|i386|i686" <<< "$aname"; then
                        continue
                    elif [[ "$arch" == "x86_64" ]] && grep -qiE "(^|[^a-z0-9])(arm|aarch64?|armv[0-9]+)([^a-z0-9]|$)" <<< "$aname"; then
                        continue
                    fi
                    compat_assets+=("$aname|$aurl")
                fi
            done <<< "$assets_json"

            local selected_type=""
            local selected_url=""
            local selected_filename=""

            # PRIORITY 1: Native .lpk file
            for item in "${compat_assets[@]}"; do
                local fname="${item%%|*}"
                if [[ "$fname" =~ \.lpk$ ]]; then
                    selected_type="LPK"
                    selected_filename="$fname"
                    selected_url="${item#*|}"
                    break
                fi
            done

            # PRIORITY 2: .AppImage file
            if [[ -z "$selected_type" ]]; then
                for item in "${compat_assets[@]}"; do
                    local fname="${item%%|*}"
                    if [[ "$fname" =~ \.appimage$ ]]; then
                        selected_type="APPIMAGE"
                        selected_filename="$fname"
                        selected_url="${item#*|}"
                        break
                    fi
                done
            fi

            # PRIORITY 3: .deb file (only on Debian/Ubuntu)
            if [[ -z "$selected_type" && "$is_debian_like" == "true" ]]; then
                for item in "${compat_assets[@]}"; do
                    local fname="${item%%|*}"
                    if [[ "$fname" =~ \.deb$ ]]; then
                        selected_type="DEB"
                        selected_filename="$fname"
                        selected_url="${item#*|}"
                        break
                    fi
                done
            fi

            # If an eligible candidate was found
            if [[ -n "$selected_type" ]]; then
                global_targets[display_idx]="$repo"
                global_types[display_idx]="$selected_type"
                global_assets[display_idx]="$selected_url"

                local badge=""
                case "$selected_type" in
                    LPK)       badge="\033[1;32m[1. Native LPK]\033[0m" ;;
                    APPIMAGE)  badge="\033[1;34m[2. AppImage]\033[0m" ;;
                    DEB)       badge="\033[1;33m[3. Debian .deb]\033[0m" ;;
                esac

                printf " \033[1;33m[%d]\033[0m %b \033[1m%-25s\033[0m \033[1;33m★ %-5s\033[0m\n     \033[0;90mAsset: %s\033[0m\n     \033[0;90m%s\033[0m\n" \
                    "$display_idx" "$badge" "$repo" "$stars" "$selected_filename" "${desc:0:70}"
                ((display_idx++))
            fi

        done < <(jq -r '.items[]? | [.full_name, (.stargazers_count|tostring), (.description // "No description")] | @tsv' <<< "$raw_results" 2>/dev/null)
    fi

    # ==========================================================================
    # PRIORITY 4: NATIVE APT REPOSITORIES (Only on Debian/Ubuntu)
    # ==========================================================================
    if [[ "$is_debian_like" == "true" ]] && command -v apt-cache >/dev/null 2>&1; then
        echo -e "\n\033[1;35m[ 4. Native Debian / APT Candidates ]\033[0m"
        echo "--------------------------------------------------------------------------------"
        local apt_results
        apt_results="$(apt-cache search "$query" 2>/dev/null | head -n 5 || true)"

        if [[ -n "$apt_results" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local apt_pkg apt_desc
                apt_pkg="$(awk '{print $1}' <<< "$line")"
                apt_desc="$(cut -d' ' -f2- <<< "$line")"

                global_targets[display_idx]="$apt_pkg"
                global_types[display_idx]="APT"
                global_assets[display_idx]=""

                printf " \033[1;33m[%d]\033[0m \033[0;35m[4. APT]\033[0m \033[1m%-25s\033[0m\n     \033[0;90m%s\033[0m\n" \
                    "$display_idx" "$apt_pkg" "${apt_desc:0:70}"
                ((display_idx++))
            done <<< "$apt_results"
        else
            echo -e "  \033[0;90mNo direct APT packages matching query.\033[0m"
        fi
    fi

    local total_options=$((display_idx - 1))
    echo "--------------------------------------------------------------------------------"

    if [[ "$total_options" -eq 0 ]]; then
        warn "No package candidates found for '$query'."
        return 0
    fi

    # ==========================================================================
    # MULTI-CHOICE INTERACTIVE SELECTION & PIPELINE EXECUTION
    # ==========================================================================
    printf "\033[1;36mSelect package(s) to install (e.g. 1, 1 2, 1-3) [default: cancel]: \033[0m"
    local raw_input
    read -r raw_input </dev/tty
    [[ -z "$raw_input" ]] && { log "Operation cancelled."; return 0; }

    local -a tokens=(${raw_input//,/ })
    local -a selected=()

    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            if (( start > 0 && end <= total_options && start <= end )); then
                for ((i=start; i<=end; i++)); do selected+=("$i"); done
            fi
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            if (( token >= 1 && token <= total_options )); then
                selected+=("$token")
            fi
        fi
    done

    [[ ${#selected[@]} -eq 0 ]] && { log "Operation cancelled."; return 0; }

    local -a unique_indices=($(printf "%s\n" "${selected[@]}" | sort -nu))

    for idx in "${unique_indices[@]}"; do
        local target="${global_targets[idx]}"
        local type="${global_types[idx]}"
        local asset_url="${global_assets[idx]}"

        echo -e "\n\033[1;34m:: Processing candidate [$idx]: $target ($type)...\033[0m"

        case "$type" in
            LPK)
                # Direct download and installation of sealed package
                info "Installing upstream native LPK..."
                INSTALL_ORIGIN="$asset_url" cmd_install "$asset_url"
                ;;

            APPIMAGE)
                # Download and convert AppImage -> LPK
                info "Wrapping AppImage upstream release into LPK..."
                local app_bin="${target##*/}"
                local tmp_ai="${ULPM_CACHE_HOME:-/tmp}/${app_bin}.AppImage"
                curl -fL --progress-bar "$asset_url" -o "$tmp_ai" || {
                    error "Failed to download $asset_url"
                    continue
                }
                chmod +x "$tmp_ai"

                # Create minimal rootfs to package the AppImage
                local wrap_root
                wrap_root="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/wrap_ai_XXXXXX")"
                mkdir -p "$wrap_root/bin"
                mv "$tmp_ai" "$wrap_root/bin/$app_bin"

                local out_lpk="${app_bin}.lpk"
                if cmd_pack "$wrap_root" "$app_bin" "$out_lpk"; then
                    INSTALL_ORIGIN="https://github.com/$target" cmd_install "$out_lpk"
                fi
                rm -rf "$wrap_root"
                ;;

            DEB)
                # Convert upstream .deb to LPK
                info "Converting upstream Debian package to LPK..."
                local out_lpk="${target##*/}.lpk"
                if cmd_deb_pack "$asset_url" "${target##*/}" "$out_lpk"; then
                    INSTALL_ORIGIN="https://github.com/$target" cmd_install "$out_lpk"
                fi
                ;;

            APT)
                # Package from local APT repositories to LPK
                info "Packaging APT system package to LPK..."
                local out_lpk="${target}.lpk"
                if cmd_deb_pack "$target" "$target" "$out_lpk"; then
                    INSTALL_ORIGIN="apt:$target" cmd_install "$out_lpk"
                fi
                ;;
        esac
    done
}

cmd_inspect() {
    local target="${1:-}"
    [[ -z "$target" ]] && { error "Usage: ulpm inspect <package.lpk|app_name>"; return 1; }

    check_dependencies unsquashfs jq stat

    local lpk_file=""
    if [[ -f "$target" ]]; then
        lpk_file="$target"
    elif [[ -f "$ULPM_APPS_DIR/$target/$target.lpk" ]]; then
        lpk_file="$ULPM_APPS_DIR/$target/$target.lpk"
    elif [[ -f "$ULPM_APPS_DIR/$target.lpk" ]]; then
        lpk_file="$ULPM_APPS_DIR/$target.lpk"
    else
        error "Target LPK archive or installed application not found: $target"
        return 1
    fi

    # Read manifest directly without extracting to disk
    local manifest_raw
    manifest_raw="$(unsquashfs -cat "$lpk_file" meta/manifest.json 2>/dev/null || unsquashfs -cat "$lpk_file" lpk.json 2>/dev/null || true)"

    if [[ -z "$manifest_raw" ]]; then
        error "Archive does not contain a valid ULPM manifest (meta/manifest.json)."
        return 1
    fi

    # Parse metadata via jq
    local app_id app_name app_ver app_arch app_exec app_net app_fv
    app_id="$(jq -r '.id // "unknown"' <<< "$manifest_raw")"
    app_name="$(jq -r '.name // "unknown"' <<< "$manifest_raw")"
    app_ver="$(jq -r '.version // "1.0.0"' <<< "$manifest_raw")"
    app_arch="$(jq -r '.arch // "unknown"' <<< "$manifest_raw")"
    app_exec="$(jq -r '.exec // "unknown"' <<< "$manifest_raw")"
    app_net="$(jq -r '.network // false' <<< "$manifest_raw")"
    app_fv="$(jq -r '.format_version // 1' <<< "$manifest_raw")"

    # Evaluate cryptographic signature status
    local crypto_status
    if verify_package "$lpk_file" >/dev/null 2>&1; then
        crypto_status="\033[0;32m✔ Verified (Trusted Key)\033[0m"
    else
        local code=$?
        if [[ $code -eq 3 ]]; then
            crypto_status="\033[1;33m⚠ Signed (Untrusted / Unknown Authority)\033[0m"
        elif [[ $code -eq 2 ]]; then
            crypto_status="\033[0;31m✖ Unsigned (Missing ULPM_SIG)\033[0m"
        else
            crypto_status="\033[0;31m✖ FORGERY / CORRUPTED SIGNATURE\033[0m"
        fi
    fi

    local fsize
    fsize="$(du -sh "$lpk_file" 2>/dev/null | cut -f1)"

    echo "================================================================================"
    printf " \033[1;36m%-16s\033[0m : %s\n" "Application" "$app_name"
    printf " \033[1;36m%-16s\033[0m : %s\n" "Identifier" "$app_id"
    printf " \033[1;36m%-16s\033[0m : \033[1;32mv%s\033[0m (%s)\n" "Version" "$app_ver" "$app_arch"
    printf " \033[1;36m%-16s\033[0m : %s (Archive: %s)\n" "Format" "LPK v$app_fv" "$fsize"
    echo "--------------------------------------------------------------------------------"
    printf " \033[1;34m%-16s\033[0m : %s\n" "Entrypoint" "$app_exec"
    printf " \033[1;34m%-16s\033[0m : %b\n" "Network Access" "$([[ "$app_net" == "true" ]] && echo "\033[0;32mEnabled\033[0m" || echo "\033[1;33mIsolated\033[0m")"
    printf " \033[1;34m%-16s\033[0m : %b\n" "Security Seal" "$crypto_status"
    echo "================================================================================"
}

cmd_upgrade() {
    [[ ! -s "$ULPM_DB" ]] && { info "No ULPM applications installed."; return 0; }

    info "Checking for application updates..."
    local updates_found=0

    while IFS='|' read -r app_id app_name cur_ver installed_date origin; do
        [[ -z "$app_name" || -z "$origin" ]] && continue

        # CASE 1: GitHub Origin
        if [[ "$origin" =~ ^https?://github\.com/ || "$origin" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+ ]]; then
            local repo_path
            repo_path="$(printf '%s' "$origin" | sed -E 's#^https?://github.com/##; s#/$##; s#\.git$##')"

            log "Checking upstream release for '$app_name' ($repo_path)..."
            local rel_data
            rel_data="$(fetch_github_api "repos/${repo_path}/releases/latest" 10)" || continue

            local latest_tag
            latest_tag="$(jq -r '.tag_name // empty' <<< "$rel_data" 2>/dev/null)"
            [[ -z "$latest_tag" ]] && continue

            # Strip leading 'v'
            local clean_latest="${latest_tag#v}"
            local clean_cur="${cur_ver#v}"

            local needs_update=false
            if command -v dpkg >/dev/null 2>&1; then
                if dpkg --compare-versions "$clean_latest" "gt" "$clean_cur" 2>/dev/null; then
                    needs_update=true
                fi
            else
                if [[ "$clean_latest" != "$clean_cur" ]]; then
                    needs_update=true
                fi
            fi

            if [[ "$needs_update" == "true" ]]; then
                ((updates_found++))
                echo -e " \033[1;32m➜\033[0m Update available for \033[1m$app_name\033[0m: \033[1;31m$cur_ver\033[0m ➔ \033[1;32m$latest_tag\033[0m"
                log "Rebuilding package for $app_name..."

                local out_lpk="${app_name}.lpk"
                if cmd_deb_pack "$repo_path" "$app_name" "$out_lpk"; then
                    INSTALL_ORIGIN="$origin" cmd_install "$out_lpk"
                    info "Updated '$app_name' successfully to $latest_tag."
                else
                    error "Failed to upgrade $app_name."
                fi
            fi

        # CASE 2: APT Repository Origin
        elif [[ "$origin" =~ ^apt: ]]; then
            local apt_pkg="${origin#apt:}"
            if command -v apt-cache >/dev/null 2>&1; then
                local candidate_ver
                candidate_ver="$(apt-cache policy "$apt_pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
                if [[ -n "$candidate_ver" && "$candidate_ver" != "(none)" && "$candidate_ver" != "$cur_ver" ]]; then
                    ((updates_found++))
                    echo -e " \033[1;32m➜\033[0m APT update available for \033[1m$app_name\033[0m: \033[1;31m$cur_ver\033[0m ➔ \033[1;32m$candidate_ver\033[0m"
                    local out_lpk="${app_name}.lpk"
                    if cmd_deb_pack "$apt_pkg" "$app_name" "$out_lpk"; then
                        INSTALL_ORIGIN="$origin" cmd_install "$out_lpk"
                        info "Updated '$app_name' successfully to $candidate_ver."
                    fi
                fi
            fi
        fi
    done < "$ULPM_DB"

    if [[ "$updates_found" -eq 0 ]]; then
        info "All ULPM applications are up to date."
    else
        info "Upgrade process finished. Updated $updates_found application(s)."
    fi
}
