#!/usr/bin/env bash
# ==============================================================================
# lib/manage.sh - Application Lifecycle & Desktop Integration Engine
# ==============================================================================

write_desktop_launcher() {
    local app_id="$1"
    local app_name="$2"
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    mkdir -p "$desktop_dir"

    cat <<EOF > "$desktop_dir/${app_id}.desktop"
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=${ULPM_BIN} run ${app_id} %u
Icon=${app_id}
Categories=Utility;Network;AudioVideo;Graphics;Development;
Terminal=false
StartupWMClass=${app_id}
X-ULPM-Package=${app_name}
EOF
    chmod +x "$desktop_dir/${app_id}.desktop"
}

cmd_install() {
    local source="${1:-}"
    [[ -z "$source" ]] && { error "Usage: ulpm install <package.lpk|url>"; return 1; }

    acquire_lock
    local tmp_lpk
    tmp_lpk="$(mktemp "${ULPM_CACHE_HOME}/tmp/install_XXXXXX.lpk")"
    trap 'rm -f "$tmp_lpk"; release_lock' EXIT INT TERM

    source="$(normalize_target "$source")"

    if [[ -f "$source" ]]; then
        cp -f "$source" "$tmp_lpk"
    elif [[ "$source" =~ ^https?:// ]]; then
        check_dependencies curl
        log "Downloading $source..."
        curl -# -L -f "$source" -o "$tmp_lpk" || { error "Download failed"; return 1; }
    else
        error "Source not found: $source"
        return 1
    fi

    verify_package "$tmp_lpk" || warn "Package signature is unverified. Continuing..."

    local mnt_tmp
    mnt_tmp="$(mktemp -d "${ULPM_CACHE_HOME}/mnt_chk_XXXXXX")"
    squashfuse "$tmp_lpk" "$mnt_tmp" 2>/dev/null || { error "Failed to inspect package."; return 1; }

    local manifest="$mnt_tmp/meta/manifest.json"
    local app_id app_name app_version
    app_id="$(jq -r '.id // empty' "$manifest" 2>/dev/null || true)"
    app_name="$(jq -r '.name // empty' "$manifest" 2>/dev/null || true)"
    app_version="$(jq -r '.version // "1.0.0"' "$manifest" 2>/dev/null || true)"

    app_name="${app_name:-$(basename "$source" .lpk)}"
    app_id="${app_id:-io.lpk.$app_name}"

    local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    mkdir -p "$icon_dir"
    [[ -f "$mnt_tmp/meta/icon.png" ]] && cp -f "$mnt_tmp/meta/icon.png" "$icon_dir/${app_id}.png"

    safe_unmount "$mnt_tmp"
    rm -rf "$mnt_tmp"

    local dest_dir="$ULPM_APPS_DIR/$app_name"
    mkdir -p "$dest_dir"
    mv -f "$tmp_lpk" "$dest_dir/$app_name.lpk"

    write_desktop_launcher "$app_id" "$app_name"

    # Register in DB: id|name|version|timestamp
    (
        flock -x 9
        sed -i "/^${app_id}|/d" "$ULPM_DB" 2>/dev/null || true
        echo "${app_id}|${app_name}|${app_version}|$(date +%s)" >> "$ULPM_DB"
    ) 9> "$ULPM_LOCK"

    info "Successfully installed '$app_name' ($app_id)."
    release_lock
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
Exec=${ULPM_BIN} run %f
Terminal=false
NoDisplay=true
MimeType=application/x-lpk;
EOF

    update-mime-database "$mime_dir" >/dev/null 2>&1 || true
    update-desktop-database "$desk_dir" >/dev/null 2>&1 || true
    info "MIME association and desktop integration registered."
}

cmd_list() {
    info "Installed ULPM Applications:"
    echo "--------------------------------------------------------------------------------"
    printf "%-25s %-15s %-12s %-20s\n" "NAME" "VERSION" "SIZE" "ID"
    echo "--------------------------------------------------------------------------------"
    if [[ -s "$ULPM_DB" ]]; then
        while IFS='|' read -r id name ver _; do
            local sz="-"
            [[ -f "$ULPM_APPS_DIR/$name/$name.lpk" ]] && sz="$(du -sh "$ULPM_APPS_DIR/$name/$name.lpk" 2>/dev/null | cut -f1)"
            printf "%-25s %-15s %-12s %-20s\n" "$name" "$ver" "$sz" "$id"
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

    [[ -z "$target" ]] && { error "Usage: ulpm remove [--purge] <app_name>"; return 1; }
    acquire_lock

    local id="io.lpk.${target,,}"
    rm -rf "$ULPM_APPS_DIR/$target"
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/"*"$target"*.desktop
    rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/${id}.png"

    (
        flock -x 9
        sed -i "/|${target}|/d; /^${target}|/d" "$ULPM_DB" 2>/dev/null || true
    ) 9> "$ULPM_LOCK"

    if [[ "$purge" == "true" ]]; then
        log "Purging persistent user application state..."
        rm -rf "$HOME/.var/app/$target" "$HOME/.var/app/$id"
    fi

    info "Application '$target' removed."
    release_lock
}

cmd_clean() {
    log "Unmounting orphaned sessions & purging temporary storage..."
    find "$ULPM_CACHE_HOME" -maxdepth 2 -type d -name "mnt_*" 2>/dev/null | while IFS= read -r pt; do
        safe_unmount "$pt"
    done
    rm -rf "${ULPM_CACHE_HOME:?}/mnt_"* "${ULPM_CACHE_HOME:?}/tmp/"* "${ULPM_CACHE_HOME:?}/build_"* 2>/dev/null || true
    info "Cleanup complete."
}
