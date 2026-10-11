#!/usr/bin/env bash
# ==============================================================================
# lib/manage.sh - Local package management commands (install, list, remove, clean)
# ==============================================================================

cmd_install() {
    local source="${1:-}"
    if [ -z "$source" ]; then
        error "Usage: ulpm install <package.lpk|url>"
        exit 1
    fi

    acquire_lock

    local tmp_target
    tmp_target="$(mktemp "${ULPM_CACHE_HOME}/tmp/install_XXXXXX.lpk")"
    trap 'rm -f "$tmp_target"; release_lock' EXIT INT TERM

    if [ -f "$source" ]; then
        cp "$source" "$tmp_target"
    elif [[ "$source" =~ ^https?:// ]]; then
        check_dependencies curl
        log "Downloading package from $source..."
        if ! curl -# -L -f "$source" -o "$tmp_target"; then
            error "Download failed."
            exit 1
        fi
    else
        error "Package source not found: $source"
        exit 1
    fi

    # 1. Cryptographic integrity verification
    if command -v verify_package &>/dev/null; then
        if ! verify_package "$tmp_target"; then
            warn "Package failed signature check or is unsigned. Proceeding anyway..."
        fi
    fi

    # 2. Extract package metadata
    local tmp_mnt
    tmp_mnt="$(mktemp -d "${ULPM_CACHE_HOME}/mnt_install_XXXXXX")"
    squashfuse "$tmp_target" "$tmp_mnt" 2>/dev/null || {
        error "Unable to inspect package manifest (SquashFS mount error)."
        exit 1
    }

    local manifest="$tmp_mnt/meta/manifest.json"
    local app_id app_name app_version
    if [ -f "$manifest" ]; then
        app_id=$(jq -r '.id // empty' "$manifest" 2>/dev/null || true)
        app_name=$(jq -r '.name // empty' "$manifest" 2>/dev/null || true)
        app_version=$(jq -r '.version // "1.0.0"' "$manifest" 2>/dev/null || true)
    fi

    app_name="${app_name:-$(basename "$source")}"
    app_name="${app_name%.*}"
    app_id="${app_id:-io.lpk.$app_name}"

    local dest_dir="$ULPM_APPS_DIR/$app_name"
    mkdir -p "$dest_dir"

    # 3. Deploy icon and standard XDG .desktop launcher
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    mkdir -p "$desktop_dir" "$icon_dir"

    if [ -f "$tmp_mnt/meta/icon.png" ]; then
        cp "$tmp_mnt/meta/icon.png" "$icon_dir/${app_id}.png"
    fi

    cat <<EOF > "$desktop_dir/${app_id}.desktop"
[Desktop Entry]
Type=Application
Name=${app_name}
Exec=ulpm run ${app_name} -- %u
Icon=${app_id}
Categories=Utility;
Terminal=false
StartupWMClass=${app_id}
X-ULPM-Package=${app_name}
X-ULPM-Version=${app_version:-1.0.0}
EOF
    chmod +x "$desktop_dir/${app_id}.desktop"

    # Unmount inspection point
    safe_unmount "$tmp_mnt"
    rm -rf "$tmp_mnt"

    # 4. Install final .lpk file
    mv "$tmp_target" "$dest_dir/$app_name.lpk"
    trap - EXIT INT TERM
    release_lock

    info "Application '$app_name' (v${app_version:-1.0.0}) successfully installed."
    info "Desktop entry registered: $desktop_dir/${app_id}.desktop"
}

cmd_list() {
    info "Applications installed in ulpm:"
    echo "--------------------------------------------------------------------------------"
    printf "%-25s %-12s %-12s %-20s\n" "NAME" "VERSION" "SIZE" "ID"
    echo "--------------------------------------------------------------------------------"
    if [ -d "$ULPM_APPS_DIR" ]; then
        shopt -s nullglob
        for app in "$ULPM_APPS_DIR"/*; do
            if [ -d "$app" ]; then
                local name size pkg lpk_file
                name="$(basename "$app")"
                size="$(du -sh "$app" 2>/dev/null | cut -f1)"
                lpk_file="$app/$name.lpk"

                local id="-" ver="-"
                local desktop_file="${XDG_DATA_HOME:-$HOME/.local/share}/applications"/*"${name}.desktop"
                if [ -f "$desktop_file" ]; then
                    id="$(basename "$desktop_file" .desktop)"
                    ver="$(grep -E '^X-ULPM-Version=' "$desktop_file" 2>/dev/null | cut -d= -f2 || echo "-")"
                fi

                printf "%-25s %-12s %-12s %-20s\n" "$name" "${ver:-1.0.0}" "$size" "$id"
            fi
        done
        shopt -u nullglob
    fi
    echo "--------------------------------------------------------------------------------"
}

cmd_remove() {
    local purge=false
    local app_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            *) app_name="$1"; shift ;;
        esac
    done

    if [ -z "$app_name" ]; then
        error "Usage: ulpm remove [--purge] <app_name>"
        exit 1
    fi

    acquire_lock
    local app_dir="$ULPM_APPS_DIR/$app_name"
    local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    local icon_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

    if [ -d "$app_dir" ]; then
        rm -rf "$app_dir"

        # Remove menu shortcuts and icons
        shopt -s nullglob
        for d in "$desktop_dir"/*"$app_name"*.desktop; do
            local base_id
            base_id="$(basename "$d" .desktop)"
            rm -f "$d"
            rm -f "$icon_dir/${base_id}.png"
        done
        shopt -u nullglob

        # Optionally purge sandboxed user data
        if [ "$purge" = "true" ]; then
            log "Purging sandboxed user data for $app_name..."
            rm -rf "$HOME/.var/app/$app_name" "$HOME/.var/app/io.lpk.${app_name,,}" 2>/dev/null || true
        fi

        info "Application '$app_name' removed successfully."
    else
        warn "Application '$app_name' not found."
    fi

    release_lock
}

cmd_clean() {
    log "Unmounting dangling sessions and cleaning caches..."

    # Proactively clean up orphaned FUSE mount points
    if [ -d "$ULPM_CACHE_HOME" ]; then
        find "$ULPM_CACHE_HOME" -maxdepth 2 -type d \( -name "mnt_*" -o -name "ulpm_run_*" \) 2>/dev/null | while IFS= read -r dangling_mount; do
            safe_unmount "$dangling_mount"
        done
    fi

    # Clean temporary directories
    rm -rf "${ULPM_CACHE_HOME:?}"/mnt_* \
        "${ULPM_CACHE_HOME:?}"/ulpm_run_* \
        "${ULPM_CACHE_HOME:?}"/build_* \
        "${ULPM_CACHE_HOME:?}"/tmp/* 2>/dev/null || true

    info "Cache is clean and dangling mounts released."
}
