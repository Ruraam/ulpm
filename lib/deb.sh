#!/usr/bin/env bash
# ==============================================================================
# lib/deb.sh - Debian/Ubuntu package resolution & conversion (deb-pack)
# ==============================================================================

cmd_deb_pack() {
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"

    if [[ -z "$pkg_input" ]]; then
        error "Usage: ulpm deb-pack <package_name|file.deb> [custom_name] [output.lpk]"
        exit 1
    fi

    check_dependencies dpkg-deb

    local build_dir deb_dir root_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/deb_pack_XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT

    deb_dir="$build_dir/debs"
    root_dir="$build_dir/root"
    mkdir -p "$deb_dir" "$root_dir"

    local is_local_deb=false
    local target_pkg="$pkg_input"

    if [[ -f "$pkg_input" && "$pkg_input" =~ \.deb$ ]]; then
        is_local_deb=true
        target_pkg="$(dpkg-deb -f "$pkg_input" Package 2>/dev/null || basename "$pkg_input" .deb)"
        cp -f "$pkg_input" "$deb_dir/"
    else
        check_dependencies apt-get apt-cache
    fi

    local app_name="${app_name_hint:-$target_pkg}"
    log "Resolving APT dependencies for '$target_pkg'..."

    (
        cd "$deb_dir" || exit 1
        if [[ "$is_local_deb" == "false" ]]; then
            if ! apt-get download "$target_pkg" 2>/dev/null; then
                error "Failed to download primary package: $target_pkg"
                exit 1
            fi
        fi

        # Resolve dependencies if available in APT cache
        if command -v apt-cache >/dev/null 2>&1; then
            local deps
            deps=$(apt-cache depends --recurse --no-recommends --no-suggests "$target_pkg" 2>/dev/null \
                | awk '/Depends:/{print $2}' \
                | tr -d '<>' \
                | sed 's/:any$//' \
                | sort -u \
                | grep -vE "^(libc6|base-files|dpkg|debconf|sensible-utils|init-system-helpers|coreutils)$" || true)

            if [[ -n "$deps" ]]; then
                echo "$deps" | xargs -r apt-get download 2>/dev/null || true
            fi
        fi
    )

    log "Unpacking collected Debian packages..."
    shopt -s nullglob
    local debs=("$deb_dir"/*.deb)
    shopt -u nullglob

    if [[ ${#debs[@]} -eq 0 ]]; then
        error "No Debian packages were retrieved."
        exit 1
    fi

    for deb in "${debs[@]}"; do
        dpkg-deb -x "$deb" "$root_dir"
    done

    # Preventively remove host dynamic linkers and libc to avoid glibc conflicts
    find "$root_dir" -type f \( -name "ld-linux*.so*" -o -name "libc.so*" \) -delete 2>/dev/null || true

    # If a matching standard executable exists in usr/bin, ensure it's executable
    if [[ -f "$root_dir/usr/bin/$app_name" ]]; then
        chmod +x "$root_dir/usr/bin/$app_name"
    fi

    log "Packaging into .lpk via cmd_pack..."
    cmd_pack "$root_dir" "$app_name" "$out_pkg"
}
