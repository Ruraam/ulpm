#!/usr/bin/env bash
# ==============================================================================
# lib/pack.sh - Deterministic LPK Packaging & Dynamic ELF Library Bundler
# ULPM v6.0.0 Architecture Engine (v5.3 Deterministic Packaging & Robust Bundler)
# ==============================================================================

validate_manifest() {
    local manifest="${1:-}"
    local max_version="${ULPM_FORMAT_VERSION:-5}"

    if [[ -z "$manifest" || ! -f "$manifest" ]]; then
        error "Manifest file does not exist: ${manifest:-<empty>}"
        return 1
    fi
    if ! [[ "$max_version" =~ ^[0-9]+$ ]] || (( max_version < 1 )); then
        error "ULPM_FORMAT_VERSION must be a positive integer."
        return 1
    fi

    if ! jq -e --argjson max_version "$max_version" '
        type == "object" and
        ((.format_version // 1) | type == "number" and . >= 1 and . <= $max_version and floor == .) and
        ((.name // .id) | type == "string" and length > 0 and length <= 128) and
        (if has("id") then (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not)) else true end) and
        (if has("name") then (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) else true end) and
        (if has("exec") then (.exec | type == "string" and length > 0 and (startswith("/") | not) and (split("/") | all(. != ".." and . != ""))) else true end) and
        (if has("arch") then (.arch | type == "string" and test("^(x86_64|amd64|i386|i686|aarch64|arm64|armv7l|armv7|armhf|riscv64|ppc64le|s390x|loongarch64|mips64|mips|sparc64|all|any|noarch)$"; "i")) else true end) and
        (if has("permissions") then (.permissions | type == "object") else true end)
    ' "$manifest" >/dev/null 2>&1; then
        error "Manifest validation failed for: $manifest"
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
    local -A seen_libs=()

    # Transitive loop to resolve dependencies of dependencies
    while (( added > 0 && iterations < max_iterations )); do
        added=0
        iterations=$((iterations + 1))

        while IFS= read -r -d '' bin; do
            [[ -f "$bin" ]] || continue

            while IFS= read -r lib_path; do
                [[ "$lib_path" == /* && -f "$lib_path" ]] || continue
                bname="$(basename -- "$lib_path")"

                # Exclude core glibc, graphics, audio and display servers provided by host passthrough
                if [[ "$bname" =~ ^(ld-linux|ld-musl|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libresolv\.so|libutil\.so|libnss_|libGL|libEGL|libGLX|libGLdispatch|libdrm|libvulkan|libX11|libxcb|libXau|libasound|libpulse|libpipewire|libwayland) ]]; then
                    continue
                fi

                if [[ -z "${seen_libs["$bname"]:-}" ]]; then
                    seen_libs["$bname"]=1
                    if [[ ! -e "$lib_dest/$bname" ]]; then
                        if cp -L -- "$lib_path" "$lib_dest/$bname" 2>/dev/null; then
                            added=$((added + 1))
                        fi
                    fi
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

appimage_squashfs_offset() {
    local f="$1" hdr shoff shentsize shnum
    hdr="$(readelf -h "$f" 2>/dev/null)" || return 1
    shoff="$(sed -nE 's/^ *Start of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n1)"
    shentsize="$(sed -nE 's/^ *Size of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n 1)"
    shnum="$(sed -nE 's/^ *Number of section headers: *([0-9]+).*/\1/p' <<< "$hdr" | head -n 1)"
    [[ "$shoff" =~ ^[0-9]+$ && "$shentsize" =~ ^[0-9]+$ && "$shnum" =~ ^[0-9]+$ ]] || return 1
    echo $((shoff + shentsize * shnum))
}

_extract_zip_safely() {
    local src="$1" dest="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$src" "$dest" <<'PY'
import os
import pathlib
import stat
import sys
import zipfile

archive, destination = sys.argv[1], os.path.realpath(sys.argv[2])
os.makedirs(destination, exist_ok=True)
max_files = int(os.environ.get("ULPM_ARCHIVE_MAX_FILES", "100000"))
max_bytes = int(os.environ.get("ULPM_ARCHIVE_MAX_BYTES", str(8 * 1024**3)))

def safe_target(name):
    name = name.replace("\\", "/")
    path = pathlib.PurePosixPath(name)
    if (not name or "\x00" in name or path.is_absolute()
        or any(part in ("", ".", "..") for part in path.parts)
        or (len(name) > 1 and name[1] == ":")):
        raise ValueError("unsafe ZIP path: " + repr(name))
    target = os.path.realpath(os.path.join(destination, *path.parts))
    if target != destination and not target.startswith(destination + os.sep):
        raise ValueError("ZIP entry escapes destination: " + name)
    return target

try:
    with zipfile.ZipFile(archive) as zf:
        entries = zf.infolist()
        if len(entries) > max_files:
            raise ValueError("archive contains too many files")
        total_size = sum(item.file_size for item in entries)
        if total_size > max_bytes:
            raise ValueError("archive exceeds configured extraction limits")
        prepared = []
        for item in entries:
            target = safe_target(item.filename.rstrip("/"))
            mode = (item.external_attr >> 16) & 0xffff
            kind = stat.S_IFMT(mode)
            if stat.S_ISLNK(mode) or (kind and kind not in (stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError("symlink/special ZIP entry is forbidden: " + item.filename)
            prepared.append((item, target, mode))
        for item, target, mode in prepared:
            if item.is_dir():
                os.makedirs(target, exist_ok=True)
        written_total = 0
        for item, target, mode in prepared:
            if item.is_dir():
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            current = os.path.dirname(target)
            while current != destination and current.startswith(destination + os.sep):
                if os.path.islink(current):
                    raise ValueError("symlink ancestor in extraction path: " + current)
                current = os.path.dirname(current)
            if os.path.lexists(target):
                if os.path.isdir(target) and not os.path.islink(target):
                    raise ValueError("file conflicts with existing directory: " + item.filename)
                os.unlink(target)
            fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(fd, "wb") as out, zf.open(item, "r") as inp:
                    while True:
                        chunk = inp.read(1024 * 1024)
                        if not chunk:
                            break
                        written_total += len(chunk)
                        if written_total > max_bytes:
                            raise ValueError("actual ZIP expansion exceeds configured size limit")
                        out.write(chunk)
                if mode:
                    os.chmod(target, (mode & 0o777) & ~0o6000)
            except Exception:
                try:
                    os.unlink(target)
                except OSError:
                    pass
                raise
except Exception as exc:
    print("Safe ZIP extraction failed: {}".format(exc), file=sys.stderr)
    sys.exit(1)
PY
    elif command -v unzip >/dev/null 2>&1; then
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
    else
        error "Extraction failed: neither 'python3' nor 'unzip' is available."
        return 1
    fi
}

extract_any_payload() {
    local src="${1:-}" dest="${2:-}"
    [[ -n "$src" && -n "$dest" ]] || {
        error "extract_any_payload requires source and destination."
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

        if command -v readelf >/dev/null 2>&1; then
            local sq_off
            if sq_off="$(appimage_squashfs_offset "$src")"; then
                if unsquashfs -f -no-progress -d "$dest/squashfs-root" -o "$sq_off" "$src" >/dev/null 2>&1; then
                    extracted=true
                fi
            fi
        fi

        if [[ "$extracted" != "true" ]]; then
            unsquashfs -f -no-progress -d "$dest/squashfs-root" "$src" >/dev/null 2>&1 && extracted=true
        fi

        if [[ "$extracted" != "true" && "${ULPM_ALLOW_APPIMAGE_EXEC:-0}" == "1" ]]; then
            warn "Extracting AppImage using host runtime fallback..."
            (cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1) && extracted=true
        fi

        if [[ "$extracted" != "true" ]]; then
            error "Safe AppImage extraction failed. Enable ULPM_ALLOW_APPIMAGE_EXEC=1 only if you trust this binary."
            return 1
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
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$src" "$dest" <<'PY' || return 1
import os, pathlib, sys, tarfile
archive, destination = sys.argv[1], os.path.realpath(sys.argv[2])
os.makedirs(destination, exist_ok=True)
def target_for(name):
    path = pathlib.PurePosixPath(name.replace("\\", "/"))
    if not name or "\x00" in name or path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise ValueError("unsafe TAR path: " + repr(name))
    target = os.path.realpath(os.path.join(destination, *path.parts))
    if target != destination and not target.startswith(destination + os.sep):
        raise ValueError("TAR entry escapes destination: " + name)
    return target
try:
    with tarfile.open(archive, "r:*") as tf:
        for member in tf.getmembers():
            target = target_for(member.name.rstrip("/"))
            if member.isdir():
                os.makedirs(target, exist_ok=True)
            elif member.isfile():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as out, tf.extractfile(member) as inp:
                    out.write(inp.read())
                os.chmod(target, member.mode & 0o777)
            elif member.issym():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                os.symlink(member.linkname, target)
except Exception as exc:
    sys.exit(1)
PY
        else
            tar -xf "$src" -C "$dest" --no-same-owner 2>/dev/null || tar -xf "$src" -C "$dest" || return 1
        fi
        chmod -R u+w -- "$dest" 2>/dev/null || true
    elif [[ "$src" =~ \.zip$ ]]; then
        _extract_zip_safely "$src" "$dest"
    else
        error "Unsupported source format: $src"
        return 1
    fi
}

_is_executable_payload() {
    local target="$1"
    [[ -f "$target" && -x "$target" ]] || return 1

    if command -v file >/dev/null 2>&1; then
        file -b "$target" 2>/dev/null | grep -qiE 'ELF.*(executable|shared object)|script'
        return $?
    fi

    local first_bytes
    first_bytes="$(head -c 16 -- "$target" 2>/dev/null || true)"
    if [[ "$first_bytes" == $'\x7fELF'* ]]; then
        return 0
    fi
    if [[ "$first_bytes" =~ ^[[:space:]]*\#! ]]; then
        return 0
    fi
    return 1
}

normalize_tree_for_reproducibility() {
    local dir="$1"
    [[ -d "$dir" ]] || return 0
    local fixed_epoch="${SOURCE_DATE_EPOCH:-0}"

    find "$dir" -exec touch -h -d "@$fixed_epoch" {} + 2>/dev/null || \
    find "$dir" -exec touch -h -t 197001010000.00 {} + 2>/dev/null || true

    find "$dir" -type d -exec chmod 0755 {} + 2>/dev/null || true
    find "$dir" -type f -perm -0100 -exec chmod 0755 {} + 2>/dev/null || true
    find "$dir" -type f ! -perm -0100 -exec chmod 0644 {} + 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Factored SquashFS Creation & Cryptographic Sealing Helper
# ------------------------------------------------------------------------------

_pack_and_seal() {
    local stage_dir="$1"
    local out_lpk="$2"
    local zstd_level="$3"

    normalize_tree_for_reproducibility "$stage_dir"

    log "Generating deterministic SquashFS archive ($out_lpk)..."
    rm -f -- "$out_lpk"

    local mkfs_epoch="${SOURCE_DATE_EPOCH:-0}"
    local mksq_args=(
        "$stage_dir"
        "$out_lpk"
        -comp zstd
        -Xcompression-level "$zstd_level"
        -noappend
        -all-root
        -mkfs-time "$mkfs_epoch"
        -no-xattrs
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
        error "Package created but cryptographic signature failed: $out_lpk"
        rm -f -- "$out_lpk"
        return 1
    fi

    return 0
}

cmd_pack() {
    local no_scan=false
    local shared_runtime=false
    local runtime_ref=""
    local dependencies_json='[]'
    [[ "${ULPM_NO_SCAN:-0}" == "1" ]] && no_scan=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-scan|--fast)
                no_scan=true
                export ULPM_NO_SCAN=1
                shift
                ;;
            --shared)
                shared_runtime=true
                shift
                ;;
            --runtime)
                if [[ -n "${2:-}" ]]; then
                    runtime_ref="$2"
                    shift 2
                else
                    error "--runtime requires a runtime identifier."
                    return 1
                fi
                ;;
            --dependency|--depends)
                if [[ -n "${2:-}" ]]; then
                    local dep_arg="$2"
                    if [[ "$dep_arg" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)(>=|<=|==|=|>|<)([A-Za-z0-9.+_~-]+)$ ]]; then
                        local dep_op="${BASH_REMATCH[2]}"
                        [[ "$dep_op" == "==" ]] && dep_op="="
                        dependencies_json="$(jq -c --arg id "${BASH_REMATCH[1]}" --arg version "${dep_op}${BASH_REMATCH[3]}" \
                            '. + [{id:$id, version:$version}]' <<< "$dependencies_json")" || return 1
                    elif [[ "$dep_arg" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$dep_arg" != *..* ]]; then
                        dependencies_json="$(jq -c --arg id "$dep_arg" '. + [$id]' <<< "$dependencies_json")" || return 1
                    else
                        error "Invalid dependency '$dep_arg'; use ID or ID>=VERSION."
                        return 2
                    fi
                    shift 2
                else
                    error "--dependency requires a package ID."
                    return 1
                fi
                ;;
            --)
                shift
                break
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
        error "Usage: ulpm pack [--no-scan] [--shared] [--runtime <id>] [--dependency <id>] <source> [name] [out.lpk] [version]"
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
    check_dependencies mksquashfs jq openssl file || return 1

    local zstd_level="${ULPM_ZSTD_LEVEL:-15}"
    if ! [[ "$zstd_level" =~ ^[0-9]+$ ]] || (( zstd_level < 1 || zstd_level > 22 )); then
        error "ULPM_ZSTD_LEVEL must be an integer between 1 and 22."
        return 1
    fi

    local arch
    arch="$(normalize_arch_name "$(detect_arch)")" || arch="amd64"

    local cache_base build_stage
    cache_base="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    mkdir -p -- "$cache_base" || return 1
    build_stage="$(mktemp -d "$cache_base/pack_stage_XXXXXX")" || return 1

    _cleanup_pack_stage() {
        [[ -n "${build_stage:-}" && -d "$build_stage" ]] && rm -rf -- "$build_stage"
    }

    # ==========================================================================
    # CASE 1: PRE-STRUCTURED DIRECTORY
    # ==========================================================================
    if [[ -d "$src" ]] && [[ -f "$src/meta/manifest.json" || -f "$src/manifest.json" ]]; then
        info "Pre-structured package directory detected ($src)."

        if ! cp -a -- "$src/." "$build_stage/"; then
            _cleanup_pack_stage
            return 1
        fi

        local manifest_path="$build_stage/meta/manifest.json"
        [[ -f "$manifest_path" ]] || manifest_path="$build_stage/manifest.json"

        if [[ "$dependencies_json" != '[]' || -n "$runtime_ref" || "$shared_runtime" == true ]]; then
            local merged_manifest
            merged_manifest="$(mktemp "$cache_base/manifest.XXXXXX.json")" || { _cleanup_pack_stage; return 1; }
            jq --arg runtime "$runtime_ref" --argjson shared "$shared_runtime" --argjson deps "$dependencies_json" \
                '.dependencies = (((.dependencies // []) + $deps) | unique_by(if type == "string" then . else .id end))
                | .runtime = (if $runtime != "" then $runtime else .runtime end)
                | .shared = ((.shared // false) or $shared)' \
                "$manifest_path" > "$merged_manifest" || { rm -f -- "$merged_manifest"; _cleanup_pack_stage; return 1; }
            cat -- "$merged_manifest" > "$manifest_path" || { rm -f -- "$merged_manifest"; _cleanup_pack_stage; return 1; }
            rm -f -- "$merged_manifest"
        fi
        validate_manifest "$manifest_path" || { _cleanup_pack_stage; return 1; }

        local app_name pkg_type
        app_name="$(jq -r '.name // .id // empty' "$manifest_path" 2>/dev/null || true)"
        pkg_type="$(jq -r '.type // .kind // empty' "$manifest_path" 2>/dev/null || true)"
        app_name="${raw_name:-${app_name:-$(basename "$src")}}"
        app_name="${app_name#io.lpk.}"
        app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"

        out_lpk="${out_lpk:-${app_name}_${arch}.lpk}"
        [[ "$out_lpk" == *.lpk ]] || out_lpk="${out_lpk}.lpk"
        local out_parent
        out_parent="$(dirname -- "$out_lpk")"
        mkdir -p -- "$out_parent" || { _cleanup_pack_stage; return 1; }
        out_lpk="$(realpath -m -- "$out_lpk")" || { _cleanup_pack_stage; return 1; }

        local is_system_rootfs=false
        if [[ "$pkg_type" =~ ^(rootfs|os|distro)$ ]] ||
           [[ -d "$build_stage/recalbox" || -d "$build_stage/root/recalbox" || -d "$build_stage/root/etc" || (-d "$build_stage/etc" && -d "$build_stage/usr") ]]; then
            is_system_rootfs=true
        fi

        if [[ "$no_scan" == "true" || "$is_system_rootfs" == "true" || "${ULPM_NO_SCAN:-0}" == "1" ]]; then
            info "RootFS / Recalbox or fast-mode: skipping library scan."
        else
            local target_payload="$build_stage"
            [[ -d "$build_stage/root" ]] && target_payload="$build_stage/root"
            bundle_elf_libraries "$target_payload" ""
        fi

        if ! _pack_and_seal "$build_stage" "$out_lpk" "$zstd_level"; then
            _cleanup_pack_stage
            return 1
        fi

        info "Pack complete (Pre-structured): $out_lpk"
        _cleanup_pack_stage
        return 0
    fi

    # ==========================================================================
    # CASE 2: RAW DIRECTORY OR ARCHIVE (Assembly mode Schema v5)
    # ==========================================================================
    local base app_name app_id
    base="$(basename -- "$src")"
    base="${base%%.*}"
    app_name="${raw_name:-$base}"
    app_name="${app_name#io.lpk.}"
    app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"
    [[ -n "$app_name" ]] || {
        error "Application name is empty or contains invalid characters."
        _cleanup_pack_stage
        return 1
    }
    [[ "$ver" =~ ^[A-Za-z0-9.+_:~-]+$ ]] || {
        error "Invalid version string: $ver"
        _cleanup_pack_stage
        return 1
    }

    app_id="io.lpk.${app_name,,}"
    out_lpk="${out_lpk:-${app_name}_${arch}.lpk}"
    [[ "$out_lpk" == *.lpk ]] || out_lpk="${out_lpk}.lpk"
    local out_parent
    out_parent="$(dirname -- "$out_lpk")"
    mkdir -p -- "$out_parent" || { _cleanup_pack_stage; return 1; }
    out_lpk="$(realpath -m -- "$out_lpk")" || { _cleanup_pack_stage; return 1; }

    mkdir -p -- "$build_stage/meta" "$build_stage/root" || { _cleanup_pack_stage; return 1; }

    log "Extracting assets from $src..."
    extract_any_payload "$src" "$build_stage/root" || { _cleanup_pack_stage; return 1; }

    local detected_exec="" f
    if [[ -x "$build_stage/root/AppRun" && ! -d "$build_stage/root/AppRun" ]]; then
        detected_exec="AppRun"
    elif [[ -x "$build_stage/root/bin/main" && ! -d "$build_stage/root/bin/main" ]]; then
        detected_exec="bin/main"
    elif [[ -x "$build_stage/root/main" && ! -d "$build_stage/root/main" ]]; then
        detected_exec="main"
    elif [[ -x "$build_stage/root/bin/$app_name" && ! -d "$build_stage/root/bin/$app_name" ]]; then
        detected_exec="bin/$app_name"
    elif [[ -x "$build_stage/root/usr/bin/$app_name" && ! -d "$build_stage/root/usr/bin/$app_name" ]]; then
        detected_exec="usr/bin/$app_name"
    else
        local scan_list
        scan_list="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/exec_scan.XXXXXX")" || { _cleanup_pack_stage; return 1; }
        find "$build_stage/root" -xdev -maxdepth 4 -type f \( -perm -0100 -o -perm -0111 \) -print0 2>/dev/null > "$scan_list"
        while IFS= read -r -d '' f; do
            if _is_executable_payload "$f"; then
                detected_exec="${f#"$build_stage/root/"}"
                break
            fi
        done < "$scan_list"
        rm -f -- "$scan_list"
    fi

    if [[ -z "$detected_exec" ]]; then
        error "No executable binary or entrypoint identified in payload."
        _cleanup_pack_stage
        return 1
    fi
    info "Detected entrypoint: $detected_exec"

    if [[ "$no_scan" != "true" && "${ULPM_NO_SCAN:-0}" != "1" ]]; then
        bundle_elf_libraries "$build_stage/root" "$detected_exec"
    else
        info "Skipping dynamic library scan."
    fi

    local format_version="${ULPM_FORMAT_VERSION:-5}"
    jq -n \
        --argjson fv "$format_version" \
        --arg id "$app_id" \
        --arg name "$app_name" \
        --arg ver "$ver" \
        --arg arch "$arch" \
        --arg exec "$detected_exec" \
        --arg runtime "$runtime_ref" \
        --argjson shared "$shared_runtime" \
        --argjson dependencies "$dependencies_json" \
        '{
            format_version: $fv,
            id: $id,
            name: $name,
            version: $ver,
            arch: $arch,
            exec: $exec,
            runtime: (if $runtime != "" then $runtime else null end),
            dependencies: $dependencies,
            shared: $shared,
            permissions: {
                network: true,
                audio: true,
                gui: true,
                gpu: true,
                filesystem: {
                    home: "isolated",
                    downloads: "read-write",
                    custom: []
                },
                devices: {
                    dri: true,
                    input: true,
                    hidraw: false,
                    usb: false,
                    kvm: false
                },
                dbus: {
                    session: {
                        talk: [],
                        own: []
                    }
                }
            }
        }' > "$build_stage/meta/manifest.json" || {
            error "Failed to write Schema v5 manifest."
            _cleanup_pack_stage
            return 1
        }

    validate_manifest "$build_stage/meta/manifest.json" || { _cleanup_pack_stage; return 1; }

    if ! _pack_and_seal "$build_stage" "$out_lpk" "$zstd_level"; then
        _cleanup_pack_stage
        return 1
    fi

    info "Pack complete: $out_lpk"
    _cleanup_pack_stage
    return 0
}

# ------------------------------------------------------------------------------
# Package Manifest Reader & Package Inspection (Dual Support v5.3 / v6.0)
# ------------------------------------------------------------------------------

read_package_manifest() {
    local package="${1:-}"
    check_dependencies unsquashfs jq || return 1
    local manifest=""
    manifest="$(unsquashfs -cat "$package" meta/manifest.json 2>/dev/null)" || \
    manifest="$(unsquashfs -cat "$package" lpk.json 2>/dev/null)" || return 1
    jq -e 'type == "object"' <<< "$manifest" >/dev/null 2>&1 || return 1
    printf '%s\n' "$manifest"
}

cmd_inspect() {
    local package="${1:-}" manifest="" rc=0
    [[ -n "$package" ]] || { error 'Usage: ulpm inspect <package.lpk>'; return 2; }
    [[ -f "$package" && -r "$package" ]] || { error "Package not found or unreadable: $package"; return 1; }

    if declare -F verify_package >/dev/null 2>&1; then
        verify_package "$package" || rc=$?
        case "$rc" in
            0) info 'Signature status: valid and trusted.' ;;
            2) warn 'Signature status: unsigned package.' ;;
            3) warn 'Signature status: signature valid, publisher key not trusted.' ;;
            *) error 'Signature status: invalid or unreadable signature.'; return 1 ;;
        esac
    fi

    check_dependencies unsquashfs jq || return 1
    manifest="$(unsquashfs -cat "$package" meta/manifest.json 2>/dev/null)" || \
    manifest="$(unsquashfs -cat "$package" lpk.json 2>/dev/null)" || {
        error 'Could not read package manifest.'
        return 1
    }
    jq -e 'type == "object"' <<< "$manifest" >/dev/null 2>&1 || { error 'Invalid package manifest.'; return 1; }
    printf '%s\n' "$manifest" | jq .
}
