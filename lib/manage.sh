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

    # Atomic DB update under existing ULPM lock
    sed -i "/^${app_id}|/d; /|${app_name}|/d" "$ULPM_DB" 2>/dev/null || true
    printf "%s|%s|%s|%s\n" "$app_id" "$app_name" "$app_version" "$(date +%s)" >> "$ULPM_DB"

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
        while IFS='|' read -r id name ver _; do
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
        while IFS='|' read -r id name ver _; do
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
