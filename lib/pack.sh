#!/usr/bin/env bash
# ==============================================================================
# lib/pack.sh - Standalone LPK Packaging & Dynamic ELF Library Bundler
# ==============================================================================

validate_manifest() {
    local manifest="$1"
    if ! jq -e --argjson max_version "${ULPM_FORMAT_VERSION:-4}" '
        type == "object" and
        ((.format_version // 1) | type == "number" and . >= 1 and . <= $max_version) and
        (.id | type == "string" and length > 0) and
        (.name | type == "string" and length > 0) and
        (.exec | type == "string" and length > 0)
    ' "$manifest" >/dev/null 2>&1; then
        error "Manifest validation failed."
        return 1
    fi
    return 0
}

bundle_elf_libraries() {
    local root_dir="$1"
    local bin_rel="$2"
    local lib_dest="$root_dir/lib"
    mkdir -p "$lib_dest"

    local loader
    if ! loader="$(find_host_loader)"; then
        warn "Dynamic host linker not detected; skipping DT_NEEDED bundling."
        return 0
    fi

    log "Bundling dependencies via host loader ($loader)..."
    local added=1
    while [[ $added -gt 0 ]]; do
        added=0
        while IFS= read -r lib_path; do
            if [[ -n "$lib_path" && -f "$lib_path" ]]; then
                local bname
                bname="$(basename "$lib_path")"
                # Exclude critical host graphics/libc libraries
                if [[ ! "$bname" =~ ^(ld-linux|libc\.so|libGL|libEGL|libdrm|libvulkan|libX11|libasound) ]]; then
                    if [[ ! -f "$lib_dest/$bname" ]]; then
                        cp -L "$lib_path" "$lib_dest/$bname" 2>/dev/null || true
                        added=$((added + 1))
                    fi
                fi
            fi
        done < <(
            find "$root_dir" -type f -executable 2>/dev/null | while read -r bin; do
                "$loader" --list "$bin" 2>/dev/null || true
            done | grep -oE '/[^ ]+' || true
        )
    done
}

extract_any_payload() {
    local src="$1" dest="$2"
    if [[ -d "$src" ]]; then
        cp -a "$src/." "$dest/"
    elif [[ "$src" =~ \.(appimage|AppImage)$ ]]; then
        check_dependencies unsquashfs
        (cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1) || unsquashfs -d "$dest" "$src" >/dev/null 2>&1
        if [[ -d "$dest/squashfs-root" ]]; then
            cp -a "$dest/squashfs-root/." "$dest/"
            rm -rf "$dest/squashfs-root"
        fi
    elif [[ "$src" =~ \.deb$ ]]; then
        dpkg-deb -x "$src" "$dest"
    elif [[ "$src" =~ \.tar(\..*)?$|\.tgz$ ]]; then
        tar -xf "$src" -C "$dest"
    elif [[ "$src" =~ \.zip$ ]]; then
        unzip -q -o "$src" -d "$dest"
    else
        error "Unsupported format: $src"
        return 1
    fi
}

cmd_pack() {
    local src="${1:-}"
    local raw_name="${2:-}"
    local out_lpk="${3:-}"
    local ver="${4:-1.0.0}"

    [[ -z "$src" ]] && { error "Usage: ulpm pack <source> [name] [out.lpk] [version]"; return 1; }
    check_dependencies mksquashfs jq file

    local base app_name app_id arch
    base="$(basename "$src")"
    base="${base%%.*}"
    app_name="${raw_name:-$base}"
    app_name="$(echo "$app_name" | tr -cd 'a-zA-Z0-9._-')"
    app_id="io.lpk.${app_name,,}"
    arch="$(detect_arch)"
    out_lpk="${out_lpk:-${app_name}_${arch}.lpk}"

    local build_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME}/build_XXXXXX")"
    trap 'rm -rf "$build_dir"' EXIT INT TERM
    mkdir -p "$build_dir/root" "$build_dir/meta"

    log "Extracting assets..."
    extract_any_payload "$src" "$build_dir/root"

    local detected_exec=""
    while IFS= read -r f; do
        if file -b "$f" 2>/dev/null | grep -q "ELF.*executable"; then
            chmod +x "$f"
            detected_exec="$(realpath --relative-to="$build_dir/root" "$f")"
            break
        fi
    done < <(find "$build_dir/root" -maxdepth 4 -type f 2>/dev/null || true)

    [[ -z "$detected_exec" ]] && { error "No executable identified in payload."; return 1; }

    bundle_elf_libraries "$build_dir/root" "$detected_exec"

    jq -n --argjson fv "${ULPM_FORMAT_VERSION:-4}" --arg id "$app_id" \
        --arg name "$app_name" --arg ver "$ver" --arg arch "$arch" \
        --arg exec "$detected_exec" \
        '{format_version: $fv, id: $id, name: $name, version: $ver, arch: $arch, exec: $exec, network: true}' \
        > "$build_dir/meta/manifest.json"

    log "Generating SquashFS archive..."
    rm -f "$out_lpk"
    mksquashfs "$build_dir" "$out_lpk" -comp zstd -Xcompression-level "${ULPM_ZSTD_LEVEL:-15}" -noappend -reproducible -quiet

    log "Sealing package with Ed25519 signature..."
    cmd_sign "$out_lpk" ""
    info "Pack complete: $out_lpk"
}
