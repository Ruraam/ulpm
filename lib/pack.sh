#!/usr/bin/env bash
# ==============================================================================
# lib/pack.sh - Standalone LPK Packaging & Dynamic ELF Library Bundler
# ULPM v4.1.0 Unified Architecture (Pre-Structured, RootFS & Offset-Safe AppImage)
# ==============================================================================

validate_manifest() {
    local manifest="${1:-}"
    local max_version="${ULPM_FORMAT_VERSION:-4}"

    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        error "Manifest file does not exist: ${manifest:-<empty>}"
        return 1
    fi
    if ! [[ "$max_version" =~ ^[0-9]+$ ]] || (( max_version < 1 )); then
        error "ULPM_FORMAT_VERSION must be a positive integer."
        return 1
    fi

    # Supports standard and extended formats (rootfs / recalbox / os / distro)
    if ! jq -e --argjson max_version "$max_version" '
        type == "object" and
        ((.format_version // 1) | type == "number" and . >= 1 and . <= $max_version and floor == .) and
        ((.name // .id) | type == "string" and length > 0)
    ' "$manifest" >/dev/null 2>&1; then
        error "Manifest validation failed."
        return 1
    fi
    return 0
}

bundle_elf_libraries() {
    local root_dir="${1:-}"
    # shellcheck disable=SC2034
    local bin_rel="${2:-}"
    local lib_dest loader

    if [[ -z "$root_dir" || ! -d "$root_dir" ]]; then
        warn "Invalid payload directory; skipping ELF dependency bundling."
        return 0
    fi
    lib_dest="$root_dir/lib"
    mkdir -p -- "$lib_dest" || {
        warn "Cannot create library destination: $lib_dest"
        return 0
    }

    if ! loader="$(find_host_loader 2>/dev/null)" || [[ -z "$loader" || ! -x "$loader" ]]; then
        warn "Dynamic host linker not detected; skipping DT_NEEDED bundling."
        return 0
    fi

    log "Bundling dependencies via host linker ($loader)..."
    local added=1 iterations=0 max_iterations=10
    local bin lib_path bname

    while (( added > 0 && iterations < max_iterations )); do
        added=0
        iterations=$((iterations + 1))

        while IFS= read -r -d '' bin; do
            [[ -f "$bin" ]] || continue
            while IFS= read -r lib_path; do
                [[ "$lib_path" == /* && -f "$lib_path" ]] || continue
                bname="$(basename -- "$lib_path")"

                # Exclude core system and graphics stack to prevent ABI collisions
                if [[ "$bname" =~ ^(ld-linux|ld-musl|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libresolv\.so|libGL|libEGL|libdrm|libvulkan|libX11|libasound|libwayland) ]]; then
                    continue
                fi

                if [[ ! -e "$lib_dest/$bname" ]]; then
                    if cp -L -- "$lib_path" "$lib_dest/$bname" 2>/dev/null; then
                        added=$((added + 1))
                    fi
                elif ! cmp -s -- "$lib_path" "$lib_dest/$bname" 2>/dev/null; then
                    warn "Library name collision for $bname; keeping existing bundled file."
                fi
            done < <(
                "$loader" --list "$bin" 2>/dev/null |
                awk '
                    {
                        for (i = 1; i <= NF; i++) {
                            token = $i
                            if (token ~ /^\//) {
                                sub(/[),;]+$/, "", token)
                                print token
                            }
                        }
                    }
                ' | sort -u
            )
        done < <(find "$root_dir" -xdev -type f \( -perm -0100 -o -name '*.so' -o -name '*.so.*' \) -print0 2>/dev/null)
    done

    if (( iterations >= max_iterations && added > 0 )); then
        warn "ELF dependency bundling reached its iteration limit ($max_iterations)."
    fi
    return 0
}

# Byte offset calculation of SquashFS inside Type-2 AppImage (safe non-exec unpacking)
appimage_squashfs_offset() {
    local f="$1" hdr shoff shentsize shnum
    hdr="$(readelf -h "$f" 2>/dev/null)" || return 1
    shoff="$(sed -nE 's/^ *Start of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n 1)"
    shentsize="$(sed -nE 's/^ *Size of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n 1)"
    shnum="$(sed -nE 's/^ *Number of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n 1)"
    [[ "$shoff" =~ ^[0-9]+$ && "$shentsize" =~ ^[0-9]+$ && "$shnum" =~ ^[0-9]+$ ]] || return 1
    echo $((shoff + shentsize * shnum))
}

_extract_zip_safely() {
    local src="$1" dest="$2"
    if command -v unzip >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$src" "$dest" <<'PY'
import os, sys, zipfile
archive, destination = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            name = item.filename
            normalized = name.replace('\\', '/')
            if normalized.startswith('/') or (len(normalized) >= 2 and normalized[1] == ':') or '\x00' in name:
                raise ValueError('absolute or invalid ZIP path')
            target = os.path.realpath(os.path.join(destination, normalized))
            if target != destination and not target.startswith(destination + os.sep):
                raise ValueError('ZIP entry escapes destination: ' + name)
            zf.extractall(destination)
except Exception as exc:
    print('Safe ZIP extraction failed: {}'.format(exc), file=sys.stderr)
    sys.exit(1)
PY
        else
            local entry
            while IFS= read -r entry; do
                case "$entry" in
                    /*|../*|*/../*|..|*\\*)
                        error "Unsafe ZIP entry path detected: $entry"
                        return 1
                        ;;
                esac
            done < <(unzip -Z1 "$src" 2>/dev/null) || return 1
            unzip -q -o "$src" -d "$dest"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$src" "$dest" <<'PY'
import os, sys, zipfile
archive, destination = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    with zipfile.ZipFile(archive) as zf:
        for item in zf.infolist():
            name = item.filename
            normalized = name.replace('\\', '/')
            if normalized.startswith('/') or (len(normalized) >= 2 and normalized[1] == ':') or '\x00' in name:
                raise ValueError('absolute or invalid ZIP path')
            target = os.path.realpath(os.path.join(destination, normalized))
            if target != destination and not target.startswith(destination + os.sep):
                raise ValueError('ZIP entry escapes destination: ' + name)
            zf.extractall(destination)
except Exception as exc:
    print('Safe ZIP extraction failed: {}'.format(exc), file=sys.stderr)
    sys.exit(1)
PY
    else
        error "Extraction failed: neither 'unzip' nor 'python3' is available on host."
        return 1
    fi
}

extract_any_payload() {
    local src="${1:-}" dest="${2:-}"
    [[ -n "$src" && -n "$dest" ]] || {
        error "extract_any_payload requires a source and destination."
        return 1
    }
    [[ -e "$src" ]] || {
        error "Source target does not exist: $src"
        return 1
    }
    mkdir -p -- "$dest" || return 1

    if [[ -d "$src" ]]; then
        cp -a -- "$src/." "$dest/"
    elif [[ "$src" =~ \.(appimage|AppImage)$ ]]; then
        check_dependencies unsquashfs || return 1
        local extracted=false

        # Default safe non-executing extraction via ELF section offset
        if [[ "${ULPM_ALLOW_APPIMAGE_EXEC:-0}" != "1" ]] && command -v readelf >/dev/null 2>&1; then
            local sq_off
            if sq_off="$(appimage_squashfs_offset "$src")"; then
                if unsquashfs -f -no-progress -d "$dest/squashfs-root" -o "$sq_off" "$src" >/dev/null 2>&1; then
                    extracted=true
                fi
            fi
        fi

        # Fallback to AppImage self-extract if offset failed or explicitly permitted
        if [[ "$extracted" != "true" ]]; then
            if ! (cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1); then
                unsquashfs -d "$dest/squashfs-root" "$src" >/dev/null 2>&1 || {
                    error "Failed to extract AppImage payload: $src"
                    return 1
                }
            fi
        fi

        if [[ -d "$dest/squashfs-root" ]]; then
            cp -a -- "$dest/squashfs-root/." "$dest/" || return 1
            rm -rf -- "$dest/squashfs-root"
        fi
    elif [[ "$src" =~ \.deb$ ]]; then
        if declare -F _deb_extract_archive >/dev/null 2>&1; then
            _deb_extract_archive "$src" "$dest" || return 1
        elif command -v dpkg-deb >/dev/null 2>&1; then
            dpkg-deb -x "$src" "$dest" || return 1
        elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
            local data_tar
            data_tar="$(ar t "$src" 2>/dev/null | grep '^data\.tar' | head -n 1)"
            [[ -n "$data_tar" ]] || return 1
            ar p "$src" "$data_tar" | tar -xf - -C "$dest" --no-same-owner 2>/dev/null || return 1
        else
            error "Extraction failed: neither 'dpkg-deb' nor 'ar'/'tar' available."
            return 1
        fi
    elif [[ "$src" =~ \.tar(\..*)?$|\.tgz$ ]]; then
        tar -xf "$src" -C "$dest" --no-same-owner 2>/dev/null || tar -xf "$src" -C "$dest"
        chmod -R u+w -- "$dest" 2>/dev/null || true
    elif [[ "$src" =~ \.zip$ ]]; then
        _extract_zip_safely "$src" "$dest"
    else
        error "Unsupported source archive or directory format: $src"
        return 1
    fi
}

cmd_pack() (
    local no_scan=false
    [[ "${ULPM_NO_SCAN:-0}" == "1" ]] && no_scan=true

    # Consume any leading flags
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-scan|--fast)
                no_scan=true
                export ULPM_NO_SCAN=1
                shift
                ;;
            *)
                break
                ;;
        esac
    done

    local src="${1:-}"
    local raw_name="${2:-}"
    local out_lpk="${3:-}"
    local ver="${4:-1.0.0}"

    [[ -n "$src" ]] || {
        error "Usage: ulpm pack [--no-scan|--fast] <source> [name] [out.lpk] [version]"
        return 1
    }
    [[ -e "$src" ]] || {
        error "Source target does not exist: $src"
        return 1
    }
    src="$(realpath -- "$src")" || {
        error "Cannot resolve source path: $src"
        return 1
    }
    check_dependencies mksquashfs jq file || return 1

    local zstd_level="${ULPM_ZSTD_LEVEL:-15}"
    if ! [[ "$zstd_level" =~ ^[0-9]+$ ]] || (( zstd_level < 1 || zstd_level > 22 )); then
        error "ULPM_ZSTD_LEVEL must be an integer between 1 and 22."
        return 1
    fi

    local arch
    arch="$(detect_arch)" || arch="x86_64"

    # ======================================================================
    # CASE 1: PRE-STRUCTURED DIRECTORY (meta/manifest.json or manifest.json present)
    # ======================================================================
    if [[ -d "$src" ]] && { [[ -f "$src/meta/manifest.json" ]] || [[ -f "$src/manifest.json" ]]; }; then
        info "Pre-structured package directory detected ($src)."

        local manifest_path="$src/meta/manifest.json"
        [[ -f "$manifest_path" ]] || manifest_path="$src/manifest.json"

        validate_manifest "$manifest_path" || return 1

        local app_name pkg_type
        # Strict priority to .name over .id
        app_name="$(jq -r '.name // .id // empty' "$manifest_path" 2>/dev/null || true)"
        pkg_type="$(jq -r '.type // .kind // empty' "$manifest_path" 2>/dev/null || true)"
        app_name="${raw_name:-${app_name:-$(basename "$src")}}"

        # Strip namespace prefixes if present
        app_name="${app_name#io.lpk.}"
        app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"

        out_lpk="${out_lpk:-${app_name}_${arch}.lpk}"
        [[ "$out_lpk" == *.lpk ]] || out_lpk="${out_lpk}.lpk"
        local out_parent
        out_parent="$(dirname -- "$out_lpk")"
        mkdir -p -- "$out_parent" || return 1
        out_lpk="$(realpath -m -- "$out_lpk")" || return 1

        # Check if scan is required or skipped (RootFS / Recalbox / options / env var)
        local is_system_rootfs=false
        if [[ "$pkg_type" =~ ^(rootfs|os|distro)$ ]] || \
           [[ -d "$src/recalbox" || -d "$src/root/recalbox" || -d "$src/root/etc" || ( -d "$src/etc" && -d "$src/usr" ) ]]; then
            is_system_rootfs=true
        fi

        if [[ "$no_scan" == "true" || "$is_system_rootfs" == "true" || "${ULPM_NO_SCAN:-0}" == "1" ]]; then
            info "RootFS / Recalbox or fast-mode detected: skipping ELF library scan."
        else
            local target_payload="$src"
            [[ -d "$src/root" ]] && target_payload="$src/root"
            bundle_elf_libraries "$target_payload" ""
        fi

        log "Generating SquashFS archive from pre-structured tree ($out_lpk)..."
        rm -f -- "$out_lpk" || return 1

        local mksq_args=(
            "$src"
            "$out_lpk"
            -comp zstd
            -Xcompression-level "$zstd_level"
            -noappend
            -quiet
        )
        if mksquashfs -help 2>&1 | grep -q -- '-reproducible'; then
            mksq_args+=(-reproducible)
        fi

        if ! mksquashfs "${mksq_args[@]}"; then
            error "Failed to create SquashFS archive."
            rm -f -- "$out_lpk"
            return 1
        fi

        log "Sealing package with Ed25519 signature..."
        if ! cmd_sign "$out_lpk" ""; then
            error "Package was created but signing failed: $out_lpk"
            return 1
        fi

        info "Pack complete (Pre-structured): $out_lpk"
        return 0
    fi

    # ======================================================================
    # CASE 2: RAW DIRECTORY OR ARCHIVE (Standard automatic assembly mode)
    # ======================================================================
    local base app_name app_id
    base="$(basename -- "$src")"
    base="${base%%.*}"
    app_name="${raw_name:-$base}"
    app_name="${app_name#io.lpk.}"
    app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"
    [[ -n "$app_name" ]] || {
        error "Application name is empty or contains no supported characters."
        return 1
    }
    [[ "$ver" =~ ^[A-Za-z0-9.+_-]+$ ]] || {
        error "Invalid version string: $ver"
        return 1
    }

    app_id="io.lpk.${app_name,,}"
    out_lpk="${out_lpk:-${app_name}_${arch}.lpk}"
    [[ "$out_lpk" == *.lpk ]] || out_lpk="${out_lpk}.lpk"
    local out_parent
    out_parent="$(dirname -- "$out_lpk")"
    mkdir -p -- "$out_parent" || {
        error "Cannot create output directory: $out_parent"
        return 1
    }
    out_lpk="$(realpath -m -- "$out_lpk")" || {
        error "Cannot resolve output path."
        return 1
    }

    local cache_base build_dir
    cache_base="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    mkdir -p -- "$cache_base" || {
        error "Cannot create build cache: $cache_base"
        return 1
    }
    build_dir="$(mktemp -d "$cache_base/build_XXXXXX")" || {
        error "Unable to create temporary build directory."
        return 1
    }

    trap 'rm -rf -- "$build_dir"' EXIT

    mkdir -p -- "$build_dir/root" "$build_dir/meta" || return 1

    log "Extracting assets from $src..."
    extract_any_payload "$src" "$build_dir/root" || return 1

    local detected_exec="" f
    if [[ -x "$build_dir/root/AppRun" && ! -d "$build_dir/root/AppRun" ]]; then
        detected_exec="AppRun"
    elif [[ -x "$build_dir/root/bin/main" && ! -d "$build_dir/root/bin/main" ]]; then
        detected_exec="bin/main"
    elif [[ -x "$build_dir/root/main" && ! -d "$build_dir/root/main" ]]; then
        detected_exec="main"
    else
        while IFS= read -r -d '' f; do
            if [[ -x "$f" && ! -d "$f" ]] && file -b "$f" 2>/dev/null | grep -qiE 'ELF.*(executable|shared object)|script'; then
                detected_exec="${f#"$build_dir/root/"}"
                break
            fi
        done < <(find "$build_dir/root" -xdev -maxdepth 4 -type f \( -perm -0100 -o -perm -0111 \) -print0 2>/dev/null)
    fi

    if [[ -z "$detected_exec" ]]; then
        error "No executable binary or entry script identified in payload."
        return 1
    fi
    info "Detected entrypoint: $detected_exec"

    if [[ "$no_scan" != "true" && "${ULPM_NO_SCAN:-0}" != "1" ]]; then
        bundle_elf_libraries "$build_dir/root" "$detected_exec"
    else
        info "Skipping ELF library scan (--no-scan)."
    fi

    local format_version="${ULPM_FORMAT_VERSION:-4}"
    if ! [[ "$format_version" =~ ^[0-9]+$ ]] || (( format_version < 1 )); then
        error "ULPM_FORMAT_VERSION must be a positive integer."
        return 1
    fi

    jq -n \
        --argjson fv "$format_version" \
        --arg id "$app_id" \
        --arg name "$app_name" \
        --arg ver "$ver" \
        --arg arch "$arch" \
        --arg exec "$detected_exec" \
        '{format_version: $fv, id: $id, name: $name, version: $ver, arch: $arch, exec: $exec, network: true}' \
        > "$build_dir/meta/manifest.json" || {
            error "Failed to generate manifest."
            return 1
        }

    validate_manifest "$build_dir/meta/manifest.json" || return 1

    log "Generating SquashFS archive ($out_lpk)..."
    rm -f -- "$out_lpk" || return 1

    local mksq_args=(
        "$build_dir"
        "$out_lpk"
        -comp zstd
        -Xcompression-level "$zstd_level"
        -noappend
        -quiet
    )

    if mksquashfs -help 2>&1 | grep -q -- '-reproducible'; then
        mksq_args+=(-reproducible)
    fi

    if ! mksquashfs "${mksq_args[@]}"; then
        error "Failed to create SquashFS archive."
        rm -f -- "$out_lpk"
        return 1
    fi

    log "Sealing package with Ed25519 signature..."
    if ! cmd_sign "$out_lpk" ""; then
        error "Package was created but signing failed: $out_lpk"
        return 1
    fi

    info "Pack complete: $out_lpk"
    return 0
)
