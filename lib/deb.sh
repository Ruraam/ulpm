#!/usr/bin/env bash
# ==============================================================================
# lib/deb.sh - Debian Package Downloader & Converter Engine
# ==============================================================================

resolve_github_deb_asset() {
    local target="$1"
    local repo_path tag=""

    if [[ "$target" == *"@"* ]]; then
        tag="${target##*@}"
        target="${target%@*}"
    fi

    repo_path="$(printf '%s' "$target" | sed -E 's#^https?://github.com/##; s#/$##; s#\.git$##')"

    local endpoint
    if [[ -n "$tag" ]]; then
        endpoint="repos/${repo_path}/releases/tags/${tag}"
    else
        endpoint="repos/${repo_path}/releases/latest"
    fi

    log "Querying GitHub release for '$repo_path'..."
    local release_json
    release_json="$(fetch_github_api "$endpoint" 15)" || {
        error "Failed to retrieve GitHub release metadata for '$repo_path'."
        return 1
    }

    local arch arch_regex
    arch="$(detect_arch)"
    if [[ "$arch" == "arm64" ]]; then
        arch_regex="arm64|aarch64|arm-64|armv8|arm64v8|all"
    elif [[ "$arch" == "x86_64" ]]; then
        arch_regex="amd64|x86_64|x86-64|x64|all"
    else
        arch_regex="$arch|all"
    fi

    local candidate_urls
    candidate_urls="$(jq -r --arg regex "$arch_regex" '
        .assets[]? | select((.name | endswith(".deb")) and (.name | test($regex; "i"))) | .browser_download_url
    ' <<< "$release_json")"

    # Strict negative filtering against architecture conflicts
    if [[ "$arch" == "arm64" ]]; then
        candidate_urls="$(grep -ivE "x86|amd64|i386|i686" <<< "$candidate_urls" || true)"
    elif [[ "$arch" == "x86_64" ]]; then
        candidate_urls="$(grep -ivE "(^|[^a-z0-9])(arm|aarch64?|armv[0-9]+)([^a-z0-9]|$)" <<< "$candidate_urls" || true)"
    fi

    local selected_url
    selected_url="$(head -n1 <<< "$candidate_urls")"

    if [[ -z "$selected_url" ]]; then
        error "No compatible Debian package (.deb) found for architecture '$arch'."
        return 1
    fi

    printf '%s\n' "$selected_url"
}

cmd_deb_pack() {
    local pkg_input="${1:-}"
    local app_name_hint="${2:-}"
    local out_pkg="${3:-}"

    [[ -z "$pkg_input" ]] && { error "Usage: ulpm deb-pack <pkg|file.deb|github_repo> [name] [out.lpk]"; return 1; }

    check_dependencies dpkg-deb

    local build_dir
    build_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/deb_build_XXXXXX")"
    trap 'rm -rf "${build_dir:-}"' RETURN

    local deb_dir="$build_dir/debs"
    local root_dir="$build_dir/root"
    mkdir -p "$deb_dir" "$root_dir"

    local app_name="$app_name_hint"

    # CASE 0: Remote GitHub repository (e.g., owner/repo, https://github.com/..., or owner/repo@tag)
    if [[ "$pkg_input" =~ ^https?://github\.com/ || "$pkg_input" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+(@.+)?$ ]]; then
        check_dependencies curl jq
        local deb_url
        deb_url="$(resolve_github_deb_asset "$pkg_input")" || return 1
        local deb_filename
        deb_filename="$(basename "$deb_url")"

        log "Downloading remote Debian asset: $deb_filename"
        local curl_opts=(-fL --retry 2)
        [[ -t 1 ]] && curl_opts+=(--progress-bar) || curl_opts+=(-sS)
        curl "${curl_opts[@]}" "$deb_url" -o "$deb_dir/$deb_filename" || {
            error "Download failed: $deb_url"
            return 1
        }
        pkg_input="$deb_dir/$deb_filename"
    fi

    # CASE 1: Local .deb file provided (or downloaded from GitHub above)
    if [[ -f "$pkg_input" && "$pkg_input" =~ \.deb$ ]]; then
        log "Processing local Debian package: $(basename "$pkg_input")"
        local extracted_name
        extracted_name="$(dpkg-deb -f "$pkg_input" Package 2>/dev/null || true)"
        [[ -z "$app_name" ]] && app_name="${extracted_name:-$(basename "$pkg_input" .deb)}"

        # If it was a purely local file (not already in deb_dir), copy it
        if [[ ! -f "$deb_dir/$(basename "$pkg_input")" ]]; then
            cp -f "$pkg_input" "$deb_dir/"
        fi

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
