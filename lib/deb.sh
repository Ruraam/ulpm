#!/usr/bin/env bash
# ==============================================================================
# lib/deb.sh - Debian Package Downloader & Converter Engine
# ==============================================================================

cmd_deb_pack() {
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"

    [[ -z "$pkg_input" ]] && { error "Usage: ulpm deb-pack <pkg|file.deb> [name]"; return 1; }
    check_dependencies dpkg-deb apt-get apt-cache

    local build_dir deb_dir root_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME}/deb_build_XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT INT TERM

    deb_dir="$build_dir/debs"
    root_dir="$build_dir/root"
    mkdir -p "$deb_dir" "$root_dir"

    local app_name="${app_name_hint:-$pkg_input}"
    log "Collecting APT dependencies for '$pkg_input'..."

    (
        cd "$deb_dir" || exit 1
        apt-get download "$pkg_input" 2>/dev/null || true
        apt-cache depends --recurse --no-recommends "$pkg_input" 2>/dev/null \
            | awk '/Depends:/{print $2}' | tr -d '<>' | grep -vE "^(libc6|base-files|dpkg)$" \
            | xargs -r apt-get download 2>/dev/null || true
    )

    for d in "$deb_dir"/*.deb; do
        [[ -f "$d" ]] && dpkg-deb -x "$d" "$root_dir"
    done

    # Strip low-level conflicting C runtime libs
    find "$root_dir" -type f \( -name "ld-linux*.so*" -o -name "libc.so*" \) -delete 2>/dev/null || true

    cmd_pack "$root_dir" "$app_name" "$out_pkg"
}
