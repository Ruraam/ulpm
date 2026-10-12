#!/usr/bin/env bash
# ==============================================================================
# lib/deb.sh - Debian Package Downloader & Converter Engine
# ==============================================================================

cmd_deb_pack() {
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"

    [[ -z "$pkg_input" ]] && { error "Usage: ulpm deb-pack <pkg|file.deb> [name] [out.lpk]"; return 1; }

    # Dpkg-deb is mandatory; apt tools are needed only if resolving from repos
    check_dependencies dpkg-deb

    local build_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/deb_build_XXXXXX")"
    trap 'rm -rf "$build_dir"' RETURN

    local deb_dir="$build_dir/debs"
    local root_dir="$build_dir/root"
    mkdir -p "$deb_dir" "$root_dir"

    local app_name="$app_name_hint"

    # CASE 1: Local .deb file provided
    if [[ -f "$pkg_input" && "$pkg_input" =~ \.deb$ ]]; then
        log "Processing local Debian package: $pkg_input"
        local extracted_name
        extracted_name="$(dpkg-deb -f "$pkg_input" Package 2>/dev/null || true)"
        [[ -z "$app_name" ]] && app_name="${extracted_name:-$(basename "$pkg_input" .deb)}"

        cp -f "$pkg_input" "$deb_dir/"

        # Fetch only DIRECT (level-1) library dependencies if apt tools are available
        if command -v apt-cache >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
            if [[ -n "$extracted_name" ]]; then
                log "Resolving direct library dependencies for '$extracted_name'..."
                (
                    cd "$deb_dir" || exit 1
                    apt-cache depends --no-recommends --no-suggests "$extracted_name" 2>/dev/null \
                        | awk '/Depends: lib/{print $2}' \
                        | grep -vE '^<.*>$' \
                        | grep -vE "^(libc6|base-files|dpkg|debconf|perl-base|coreutils)$" \
                        | sort -u \
                        | xargs -r apt-get download 2>/dev/null || true
                )
            fi
        fi

    # CASE 2: APT package name provided (download from repositories)
    else
        check_dependencies apt-get apt-cache
        [[ -z "$app_name" ]] && app_name="$pkg_input"

        log "Downloading '$pkg_input' and direct library dependencies..."
        (
            cd "$deb_dir" || exit 1
            if ! apt-get download "$pkg_input" 2>/dev/null; then
                error "Failed to download primary package: $pkg_input"
                exit 1
            fi

            # Strict 1st level resolution only (no --recurse)
            apt-cache depends --no-recommends --no-suggests "$pkg_input" 2>/dev/null \
                | awk '/Depends: lib/{print $2}' \
                | grep -vE '^<.*>$' \
                | grep -vE "^(libc6|base-files|dpkg|debconf|perl-base|coreutils)$" \
                | sort -u \
                | xargs -r apt-get download 2>/dev/null || true
        ) || return 1
    fi

    shopt -s nullglob
    local downloaded_debs=("$deb_dir"/*.deb)
    shopt -u nullglob

    if [[ ${#downloaded_debs[@]} -eq 0 ]]; then
        error "No Debian packages were downloaded or extracted."
        return 1
    fi

    log "Extracting ${#downloaded_debs[@]} package archive(s)..."
    for deb_file in "${downloaded_debs[@]}"; do
        dpkg-deb -x "$deb_file" "$root_dir" || {
            warn "Failed to extract archive: $(basename "$deb_file")"
        }
    done

    # Remove conflicting low-level C runtimes to avoid ABI collision with host loader
    find "$root_dir" -type f \( \
        -name "ld-linux*.so*" -o \
        -name "libc.so*" -o \
        -name "libpthread.so*" -o \
        -name "libdl.so*" -o \
        -name "libm.so*" \
        \) -delete 2>/dev/null || true

    log "Handing over payload to bundler..."
    cmd_pack "$root_dir" "$app_name" "$out_pkg"
}
