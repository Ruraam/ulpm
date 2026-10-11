#!/usr/bin/env bash
# ==============================================================================
# lib/pack.sh - Hardened .lpk Production Engine (Recursive DT_NEEDED Parsing)
# ==============================================================================

validate_manifest() {
    local manifest="$1"
    if ! jq -e --argjson max_version "${ULPM_FORMAT_VERSION:-4}" '
        type == "object" and
        ((.format_version // 1) | type == "number" and . == floor and . >= 1 and . <= $max_version) and
        (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") and (contains("..") | not)) and
        (.name | type == "string" and length > 0 and length <= 128) and
        ((.version // "4.0.0") | type == "string" and length > 0 and length <= 64) and
        (.exec | type == "string" and length > 0 and length <= 4096 and
            (startswith("/") | not) and
            (split("/") | all(.[]; . != "" and . != "." and . != ".."))) and
        ((.icon // "") | type == "string" and length <= 4096 and
            (startswith("/") | not) and
            (split("/") | all(.[]; . != ".."))) and
        ((.chromium // false) | type == "boolean") and
        ((.network // true) | type == "boolean")
    ' "$manifest" >/dev/null 2>&1; then
        error "Manifest validation failed (malformed or prohibited path sequences)."
        return 1
    fi
    return 0
}

appimage_squashfs_offset() {
    local f="$1" class shoff shentsize shnum
    [[ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]] || return 1
    [[ "$(od -An -tu1 -j5 -N1 "$f" 2>/dev/null | tr -d ' \n')" == "1" ]] || return 1
    class="$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' \n')"

    case "$class" in
        2)
            shoff="$(od -An -tu8 -j40 -N8 "$f" 2>/dev/null | tr -d ' \n')"
            shentsize="$(od -An -tu2 -j58 -N2 "$f" 2>/dev/null | tr -d ' \n')"
            shnum="$(od -An -tu2 -j60 -N2 "$f" 2>/dev/null | tr -d ' \n')"
            ;;
        1)
            shoff="$(od -An -tu4 -j32 -N4 "$f" 2>/dev/null | tr -d ' \n')"
            shentsize="$(od -An -tu2 -j46 -N2 "$f" 2>/dev/null | tr -d ' \n')"
            shnum="$(od -An -tu2 -j48 -N2 "$f" 2>/dev/null | tr -d ' \n')"
            ;;
        *) return 1 ;;
    esac

    [[ -n "$shoff" && -n "$shentsize" && -n "$shnum" && "$shnum" -gt 0 ]] || return 1
    echo $((shoff + shentsize * shnum))
}

extract_any_payload() {
    local src="$1" dest="$2"

    if [[ -d "$src" ]]; then
        cp -a "$src/." "$dest/"
    elif [[ "$src" =~ \.(appimage|AppImage)$ ]]; then
        check_dependencies unsquashfs od
        local offset
        if offset="$(appimage_squashfs_offset "$src")" && [[ -n "$offset" ]]; then
            unsquashfs -no-progress -f -d "$dest" -o "$offset" "$src" >/dev/null 2>&1 || {
                (cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1 || unsquashfs -d . "$src" >/dev/null 2>&1)
            }
        else
            (cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1 || unsquashfs -d . "$src" >/dev/null 2>&1)
        fi

        if [[ -d "$dest/squashfs-root" ]]; then
            shopt -s dotglob nullglob
            mv "$dest/squashfs-root"/* "$dest/" 2>/dev/null || true
            rmdir "$dest/squashfs-root" 2>/dev/null || true
            shopt -u dotglob nullglob
        fi
    elif [[ "$src" =~ \.deb$ ]]; then
        check_dependencies dpkg-deb
        dpkg-deb -x "$src" "$dest"
    elif [[ "$src" =~ \.rpm$ ]]; then
        if command -v rpm2cpio &>/dev/null; then
            (cd "$dest" && rpm2cpio "$src" | cpio -idm --quiet 2>/dev/null)
        elif command -v bsdtar &>/dev/null; then
            bsdtar -xf "$src" -C "$dest"
        else
            error "rpm2cpio or bsdtar required to unpack .rpm"
            return 1
        fi
    elif [[ "$src" =~ \.zip$ ]]; then
        check_dependencies unzip
        unzip -q -o "$src" -d "$dest"
    elif [[ "$src" =~ \.(tar\.gz|tgz|tar\.xz|txz|tar\.zst|tar)$ ]]; then
        tar -xf "$src" -C "$dest"
    else
        error "Unsupported archive or file format: $src"
        return 1
    fi
}

is_system_lib() {
    local bname="$1"
    # Kernel & Low-level C runtime ABI
    [[ "$bname" =~ ^(ld-linux|ld-musl|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so|libutil\.so) ]] && return 0
    # Host Graphics & Hardware Acceleration (Bound to Host Driver Stack)
    [[ "$bname" =~ ^(libGL|libGLX|libGLdispatch|libEGL|libGLESv|libdrm|libvulkan|libgbm|libX11|libXext|libXrender|libXrandr|libxcb) ]] && return 0
    # Sound & Display protocols
    [[ "$bname" =~ ^(libasound|libpulse|libwayland-client|libffi) ]] && return 0
    return 1
}

# Resolve real path of library without executing target ELF
find_library_path() {
    local lib_name="$1"
    local search_paths=(
        "/lib" "/lib64" "/usr/lib" "/usr/lib64"
        "/usr/lib/x86_64-linux-gnu" "/usr/lib/aarch64-linux-gnu"
        "/usr/lib/arm-linux-gnueabihf" "/lib/x86_64-linux-gnu"
    )
    for p in "${search_paths[@]}"; do
        if [[ -f "$p/$lib_name" ]]; then
            echo "$p/$lib_name"
            return 0
        fi
    done
    return 1
}

# Static recursive ELF analysis (fixed-point without ldd)
bundle_elf_libraries() {
    local root_dir="$1"
    local lib_dest="$root_dir/lib"
    mkdir -p "$lib_dest"

    check_dependencies readelf

    log "Starting passive recursive dependency tracing..."
    local -A inspected_libs=()
    local added_new=true

    while [ "$added_new" = true ]; do
        added_new=false
        while IFS= read -r elf_file; do
            [[ -f "$elf_file" ]] || continue

            # Extract DT_NEEDED passively via readelf (zero code execution)
            while IFS= read -r needed_lib; do
                [[ -z "$needed_lib" ]] && continue
                [[ -n "${inspected_libs[$needed_lib]:-}" ]] && continue

                inspected_libs["$needed_lib"]=1

                if ! is_system_lib "$needed_lib"; then
                    local host_lib_path
                    if host_lib_path="$(find_library_path "$needed_lib")"; then
                        if [[ ! -f "$lib_dest/$needed_lib" ]]; then
                            cp -L "$host_lib_path" "$lib_dest/$needed_lib" 2>/dev/null || true
                            added_new=true
                        fi
                    fi
                fi
            done < <(readelf -d "$elf_file" 2>/dev/null | awk '/\(NEEDED\)/ { gsub(/[\[\]]/, "", $NF); print $NF }' || true)

        done < <(find "$root_dir" -type f -exec file {} + 2>/dev/null | grep -E 'ELF (32|64)-bit' | cut -d: -f1 || true)
    done
}

auto_sign_package() {
    local pkg="$1"
    if command -v sign_package &>/dev/null; then
        shopt -s nullglob
        local keys=("${ULPM_KEYS_DIR:-}"/*.priv)
        shopt -u nullglob
        if [[ ${#keys[@]} -gt 0 && -n "${ULPM_KEYS_DIR:-}" ]]; then
            info "Signing package with authority key (${keys[0]})..."
            sign_package "$pkg" "${keys[0]}" || warn "Signature failed. Package remained unsigned."
        else
            warn "No Ed25519 private keys found in ${ULPM_KEYS_DIR:-<none>}. Skipping signature."
        fi
    fi
}

cmd_pack() {
    local source_input="${1:-}"
    local raw_name="${2:-}"
    local output_lpk="${3:-}"
    local version_hint="${4:-1.0.0}"

    if [[ -z "$source_input" ]]; then
        error "Usage: ulpm pack <folder|archive|AppImage|deb> [app_name] [output.lpk] [version]"
        return 1
    fi

    check_dependencies mksquashfs jq file readelf

    local base_clean app_name app_id target_arch
    base_clean="$(basename "$source_input")"
    base_clean="${base_clean%%.*}"
    app_name="${raw_name:-$base_clean}"
    app_name="$(echo "$app_name" | tr -cd 'a-zA-Z0-9._-')"

    [[ -z "$app_name" ]] && { error "Malformed package name: '$raw_name'"; return 1; }

    app_id="io.lpk.${app_name,,}"
    target_arch="$(uname -m)"
    output_lpk="${output_lpk:-${app_name}_${target_arch}.lpk}"

    # Pre-structured directories (root/ + meta/)
    if [[ -d "$source_input" && -f "$source_input/meta/manifest.json" && -d "$source_input/root" ]]; then
        log "Pre-structured tree verified. Packaging directly..."
        validate_manifest "$source_input/meta/manifest.json" || return 1
        rm -f "$output_lpk"
        local zstd_lvl="${ULPM_ZSTD_LEVEL:-19}"
        mksquashfs "$source_input" "$output_lpk" -comp zstd -Xcompression-level "$zstd_lvl" -noappend -reproducible
        auto_sign_package "$output_lpk"
        info "Package created: $output_lpk"
        return 0
    fi

    local build_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/ulpm_build.XXXXXX")"
    trap 'rm -rf "${build_dir:-}"' EXIT INT TERM

    mkdir -p "$build_dir/root" "$build_dir/meta"

    log "Extracting assets..."
    extract_any_payload "$source_input" "$build_dir/root"

    # Flatten nested root directories
    shopt -s nullglob
    local entries=("$build_dir/root"/*)
    shopt -u nullglob
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        shopt -s dotglob
        mv "${entries[0]}"/* "$build_dir/root/" 2>/dev/null || true
        rmdir "${entries[0]}" 2>/dev/null || true
        shopt -u dotglob
    fi

    # Secure binary entrypoint detection
    local detected_exec="" f fname
    while IFS= read -r f; do
        fname="$(basename "$f")"
        if [[ "${fname,,}" =~ ^(${app_name,,}|${base_clean,,}|apprun|main)$ ]]; then
            detected_exec="$(realpath --relative-to="$build_dir/root" "$f")"
            break
        fi
    done < <(find "$build_dir/root" -maxdepth 4 -type f -executable 2>/dev/null || true)

    if [[ -z "$detected_exec" ]]; then
        while IFS= read -r f; do
            [[ "$f" =~ \.so(\.[0-9]+)*$ ]] && continue
            if file -b "$f" 2>/dev/null | grep -q "ELF.*executable"; then
                chmod +x "$f" 2>/dev/null || true
                detected_exec="$(realpath --relative-to="$build_dir/root" "$f")"
                break
            fi
        done < <(find "$build_dir/root" -maxdepth 4 -type f 2>/dev/null || true)
    fi

    [[ -z "$detected_exec" ]] && { error "No executable binary identified."; rm -rf "$build_dir"; trap - EXIT; return 1; }

    log "Target entrypoint verified: $detected_exec"

    bundle_elf_libraries "$build_dir/root"

    # Icon extraction
    local best_icon icon_manifest=""
    best_icon="$(find "$build_dir/root" -type f \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null \
        | grep -iE "512|256|128|logo|icon|app" | head -n1 || true)"
    if [[ -n "$best_icon" && -f "$best_icon" ]]; then
        cp -f "$best_icon" "$build_dir/meta/icon.png"
        icon_manifest="meta/icon.png"
    fi

    local is_chromium=false
    if grep -qiE "chromium|electron" "$build_dir/root/$detected_exec" 2>/dev/null || \
       [[ "$detected_exec" =~ (brave|chrome|chromium|electron) ]]; then
        is_chromium=true
    fi

    jq -n \
        --argjson fv "${ULPM_FORMAT_VERSION:-4}" \
        --arg id "$app_id" \
        --arg name "$app_name" \
        --arg version "$version_hint" \
        --arg arch "$target_arch" \
        --arg exec "$detected_exec" \
        --arg icon "$icon_manifest" \
        --argjson chromium "$is_chromium" \
        '{format_version: $fv, id: $id, name: $name, version: $version, arch: $arch,
        exec: $exec, icon: $icon, chromium: $chromium, network: true}' \
        > "$build_dir/meta/manifest.json"

    validate_manifest "$build_dir/meta/manifest.json" || { rm -rf "$build_dir"; trap - EXIT; return 1; }

    log "Assembling SquashFS (Reproducible / Zstandard)..."
    rm -f "$output_lpk"
    local zstd_lvl="${ULPM_ZSTD_LEVEL:-19}"
    mksquashfs "$build_dir" "$output_lpk" -comp zstd -Xcompression-level "$zstd_lvl" -noappend -reproducible

    rm -rf "$build_dir"
    trap - EXIT INT TERM

    auto_sign_package "$output_lpk"
    info "Pack operation complete: $output_lpk"
}
