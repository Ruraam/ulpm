#!/usr/bin/env bash
# ==============================================================================
# lib/deb.sh - Debian Package Downloader & Converter Engine
# ULPM v4.1.0
# ==============================================================================

# Extract a .deb archive using dpkg-deb or fallback to ar+tar
_deb_extract_archive() {
    local deb_path="$1" dest_dir="$2"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -x "$deb_path" "$dest_dir"
    elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        local data_tar
        data_tar="$(ar t "$deb_path" 2>/dev/null | grep '^data\.tar' | head -n 1)"
        [[ -n "$data_tar" ]] || return 1
        ar p "$deb_path" "$data_tar" | tar -xf - -C "$dest_dir" --no-same-owner 2>/dev/null || return 1
        chmod -R u+w "$dest_dir" 2>/dev/null || true
    else
        error "Neither 'dpkg-deb' nor 'ar'/'tar' is available to extract .deb packages."
        return 1
    fi
}

_deb_read_control_field() {
    local deb_path="$1" field="$2"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb -f "$deb_path" "$field" 2>/dev/null || true
    elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        local ctrl_tar
        ctrl_tar="$(ar t "$deb_path" 2>/dev/null | grep '^control\.tar' | head -n 1)"
        [[ -n "$ctrl_tar" ]] || return 0
        ar p "$deb_path" "$ctrl_tar" | tar -xOf - ./control 2>/dev/null | awk -v f="$field:" 'tolower($1) == tolower(f) {print $2; exit}' || true
    fi
}

# Resolve a GitHub repository to a compatible .deb release asset.
resolve_github_deb_asset() {
    local target="${1:-}"
    local repo_path tag="" endpoint release_json arch arch_regex
    local candidate_urls selected_url

    [[ -n "$target" ]] || {
        error "A GitHub repository is required."
        return 1
    }

    if [[ "$target" == *"@"* ]]; then
        tag="${target##*@}"
        target="${target%@*}"
        [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
            error "Invalid GitHub release tag. Use letters, digits, dot, underscore or hyphen."
            return 1
        }
    fi

    repo_path="$(printf '%s' "$target" | sed -E 's#^https?://github\.com/##; s#/$##; s#\.git$##')"
    if [[ ! "$repo_path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        error "Invalid GitHub repository: '$repo_path'."
        return 1
    fi

    if [[ -n "$tag" ]]; then
        endpoint="repos/${repo_path}/releases/tags/${tag}"
    else
        endpoint="repos/${repo_path}/releases/latest"
    fi

    log "Querying GitHub release for '$repo_path'..."
    release_json="$(fetch_github_api "$endpoint" 15)" || {
        error "Failed to retrieve GitHub release metadata for '$repo_path'."
        return 1
    }

    command -v jq >/dev/null 2>&1 || {
        error "The 'jq' command is required to inspect GitHub release metadata."
        return 1
    }

    arch="$(detect_arch)" || {
        error "Unable to detect target architecture."
        return 1
    }
    [[ -n "$arch" ]] || {
        error "Detected architecture is empty."
        return 1
    }
    case "$arch" in
        arm64|aarch64)
            arch_regex='(^|[._+ -])(arm64|aarch64|arm-64|armv8|arm64v8|all)([._+ -]|$)'
            ;;
        x86_64|amd64)
            arch_regex='(^|[._+ -])(amd64|x86_64|x86-64|x64|all)([._+ -]|$)'
            ;;
        armv7l|armhf|armv7)
            arch_regex='(^|[._+ -])(armhf|armv7|armv7l|arm32|armel|all)([._+ -]|$)'
            ;;
        i386|i686)
            arch_regex='(^|[._+ -])(i386|i686|x86|all)([._+ -]|$)'
            ;;
        *)
            arch_regex="(^|[._+ -])(${arch}|all)([._+ -]|$)"
            ;;
    esac

    candidate_urls="$(jq -r --arg regex "$arch_regex" '
        .assets[]?
        | select((.name // "") | endswith(".deb"))
        | select((.name // "") | test($regex; "i"))
        | .browser_download_url // empty
    ' <<< "$release_json")" || {
        error "Invalid GitHub release metadata for '$repo_path'."
        return 1
    }

    case "$arch" in
        arm64|aarch64)
            candidate_urls="$(grep -ivE '(^|[._+ -])(x86_64|x86-64|amd64|i386|i686)([._+ -]|$)' <<< "$candidate_urls" || true)"
            ;;
        x86_64|amd64)
            candidate_urls="$(grep -ivE '(^|[._+ -])(arm|armhf|arm64|aarch64|armv[0-9]+)([._+ -]|$)' <<< "$candidate_urls" || true)"
            ;;
        armv7l|armhf|armv7)
            candidate_urls="$(grep -ivE '(^|[._+ -])(x86_64|x86-64|amd64|i386|i686|arm64|aarch64)([._+ -]|$)' <<< "$candidate_urls" || true)"
            ;;
    esac

    selected_url="$(grep -ivE '(^|[._+ -])all([._+ -]|$)' <<< "$candidate_urls" | head -n 1 || true)"
    [[ -n "$selected_url" ]] || selected_url="$(head -n 1 <<< "$candidate_urls")"
    if [[ -z "$selected_url" ]]; then
        error "No compatible Debian package (.deb) found for architecture '$arch'."
        return 1
    fi

    printf '%s\n' "$selected_url"
}

_deb_download_direct_lib_deps() {
    local package_name="${1:-}"
    [[ -n "$package_name" ]] || return 0
    command -v apt-cache >/dev/null 2>&1 || return 0
    command -v apt-get >/dev/null 2>&1 || return 0

    local -a deps=()
    mapfile -t deps < <(
        apt-cache depends --no-recommends --no-suggests "$package_name" 2>/dev/null \
        | awk '/^[[:space:]]*Depends:[[:space:]]+lib/ {print $2}' \
        | sed -E 's/^<([^>]+)>$/\1/' \
        | grep -vE '^(libc6|base-files|dpkg|debconf|perl-base|coreutils)$' \
        | grep -vE '^<.*>$' \
        | sort -u
    )

    if ((${#deps[@]} > 0)); then
        log "Downloading ${#deps[@]} library dependency package(s)..."
        apt-get download "${deps[@]}" 2>/dev/null || true
    fi
}

cmd_deb_pack() {
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"
    local build_dir

    [[ -n "$pkg_input" ]] || {
        error "Usage: ulpm deb-pack <pkg|file.deb|github_repo> [name] [out.lpk]"
        return 1
    }

    local build_parent="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
    mkdir -p -- "$build_parent" || {
        error "Could not create temporary build parent: $build_parent"
        return 1
    }
    build_dir="$(mktemp -d "$build_parent/deb_build_XXXXXX")" || {
        error "Could not create temporary Debian build directory."
        return 1
    }

    _cmd_deb_pack_work "$pkg_input" "$app_name_hint" "$out_pkg" "$build_dir"
}

_cmd_deb_pack_work() (
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"
    local build_dir="${4:-}"
    local deb_dir="$build_dir/debs"
    local root_dir="$build_dir/root"
    local app_name="$app_name_hint"
    local extracted_name="" deb_url deb_filename deb_file
    local -a downloaded_debs=()
    local native_arch deb_arch

    trap 'rm -rf -- "$build_dir"' EXIT
    mkdir -p "$deb_dir" "$root_dir" || {
        error "Could not prepare temporary Debian build directories."
        return 1
    }

    # CASE 0: GitHub repository.
    if [[ "$pkg_input" =~ ^https?://github\.com/ || "$pkg_input" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(@.+)?$ ]]; then
        check_dependencies curl jq || return 1
        deb_url="$(resolve_github_deb_asset "$pkg_input")" || return 1
        deb_filename="$(basename "${deb_url%%\?*}")"
        [[ "$deb_filename" == *.deb && "$deb_filename" != ".deb" ]] || {
            error "The selected GitHub asset does not have a valid .deb filename."
            return 1
        }

        [[ "$deb_url" == https://github.com/* || "$deb_url" == https://objects.githubusercontent.com/* || "$deb_url" == https://release-assets.githubusercontent.com/* ]] || {
            error "Refusing unexpected GitHub asset URL: $deb_url"
            return 1
        }
        log "Downloading remote Debian asset: $deb_filename"
        local -a curl_opts=(-fL --retry 2 --connect-timeout 15 --max-time 600)
        if [[ -t 1 ]]; then
            curl_opts+=(--progress-bar)
        else
            curl_opts+=(-sS)
        fi
        curl "${curl_opts[@]}" "$deb_url" -o "$deb_dir/$deb_filename" || {
            error "Download failed: $deb_url"
            return 1
        }
        pkg_input="$deb_dir/$deb_filename"
    fi

    # CASE 1: Local .deb file.
    if [[ -L "$pkg_input" ]]; then
        error "Refusing a symbolic link as Debian package input: $pkg_input"
        return 1
    fi

    if [[ -f "$pkg_input" && "$pkg_input" == *.deb ]]; then
        log "Processing local Debian package: $(basename "$pkg_input")"
        extracted_name="$(_deb_read_control_field "$pkg_input" Package)"
        [[ -n "$app_name" ]] || app_name="${extracted_name:-$(basename "$pkg_input" .deb)}"

        if [[ ! -f "$deb_dir/$(basename "$pkg_input")" ]]; then
            cp -- "$pkg_input" "$deb_dir/" || {
                error "Could not copy Debian package into build directory."
                return 1
            }
        fi

        if [[ -n "$extracted_name" ]]; then
            log "Resolving direct library dependencies for '$extracted_name'..."
            (cd "$deb_dir" && _deb_download_direct_lib_deps "$extracted_name") || true
        fi
    else
        # CASE 2: APT package name.
        check_dependencies apt-get apt-cache || return 1
        [[ -n "$app_name" ]] || app_name="$pkg_input"

        log "Downloading primary package '$pkg_input'..."
        (
            cd "$deb_dir" || exit 1
            if ! apt-get download "$pkg_input"; then
                error "Failed to download primary package: $pkg_input"
                exit 1
            fi
            _deb_download_direct_lib_deps "$pkg_input"
        ) || return 1
    fi

    shopt -s nullglob
    downloaded_debs=("$deb_dir"/*.deb)
    shopt -u nullglob

    if (( ${#downloaded_debs[@]} == 0 )); then
        error "No Debian packages were downloaded or extracted."
        return 1
    fi

    log "Extracting ${#downloaded_debs[@]} package archive(s)..."
    native_arch="$(dpkg --print-architecture 2>/dev/null || detect_arch 2>/dev/null || true)"
    for deb_file in "${downloaded_debs[@]}"; do
        deb_arch="$(_deb_read_control_field "$deb_file" Architecture)"
        if [[ "$deb_arch" != all && -n "$native_arch" && "$deb_arch" != "$native_arch" ]]; then
            warn "Skipping incompatible package $(basename "$deb_file") (arch: $deb_arch; host: $native_arch)."
            continue
        fi
        if ! _deb_extract_archive "$deb_file" "$root_dir"; then
            warn "Failed to extract archive: $(basename "$deb_file")"
        fi
    done

    if [[ -z "$(find "$root_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        error "No files could be extracted from the Debian package set."
        return 1
    fi

    # Guarantee an authoritative entrypoint for the application
    local cand_bin entry_found=0
    for cand_bin in "$root_dir/usr/bin/$app_name" "$root_dir/bin/$app_name" "$root_dir/usr/games/$app_name"; do
        if [[ -x "$cand_bin" ]]; then
            mkdir -p -- "$root_dir/bin"
            ln -sf -- "${cand_bin#"$root_dir/"}" "$root_dir/AppRun" 2>/dev/null || true
            entry_found=1
            break
        fi
    done

    # Fallback entrypoint if the binary name does not match $app_name exactly
    if ((entry_found == 0)); then
        while IFS= read -r -d '' cand_bin; do
            if [[ -x "$cand_bin" && ! -d "$cand_bin" ]]; then
                mkdir -p -- "$root_dir/bin"
                ln -sf -- "${cand_bin#"$root_dir/"}" "$root_dir/AppRun" 2>/dev/null || true
                entry_found=1
                break
            fi
        done < <(find "$root_dir/usr/bin" "$root_dir/bin" "$root_dir/usr/games" -maxdepth 1 -type f -print0 2>/dev/null)
    fi

    # Strip glibc/loader internals that MUST match the host kernel
    find "$root_dir" \( -type f -o -type l \) \( \
        -name 'ld-linux*.so*' -o \
        -name 'ld-*.so*' -o \
        -name 'libc.so*' -o \
        -name 'libpthread.so*' -o \
        -name 'libdl.so*' -o \
        -name 'librt.so*' -o \
        -name 'libresolv.so*' -o \
        -name 'libm.so*' \
    \) -delete 2>/dev/null || true

    log "Handing over payload to bundler..."
    cmd_pack "$root_dir" "$app_name" "$out_pkg"
)
