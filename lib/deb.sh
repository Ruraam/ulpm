#!/usr/bin/env bash
# ============================================================================ ==
# lib/deb.sh -Debian Package Downloader & Converter Engine
# ULPM v5.3 Architecture Engine (Hardened Extraction & Isolated Assembly)
# ============================================================================ ==

# Extract a .deb archive using dpkg-deb or fallback to ar+tar with traversal checks
_deb_extract_archive() {
local deb_path="$1" dest_dir="$2"
if command -v dpkg-deb >/dev/null 2>&1; then
dpkg-deb -x "$deb_path" "$dest_dir"
elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
local data_tar
data_tar="$(ar t "$deb_path" 2>/dev/null | grep '^data\.tar' | head -n 1)"
[[ -n "$data_tar" ]] || return 1

local tar_tmp
tar_tmp="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/deb_data.XXXXXX")" || return 1
ar p "$deb_path" "$data_tar" > "$tar_tmp" || { rm -f -- "$tar_tmp"; return 1; }

# Secure extraction using Python engine if available, or verified tar
if command -v python3 >/dev/null 2>&1; then
if ! extract_any_payload "$tar_tmp" "$dest_dir"; then
rm -f -- "$tar_tmp"
return 1
fi
else
if tar -tf "$tar_tmp" 2>/dev/null | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
rm -f -- "$tar_tmp"
error "Debian data archive contains unsafe directory traversals: $deb_path"
return 1
fi

# Handle zstd, xz, gz explicitly if auto-compress fails
if [[ "$data_tar" == *.zst ]] ; then
if command -vzstd >/dev/null 2>&1; then
zstd -dc "$tar_tmp"| tar -xf - -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp"; return 1; }
else
tar --auto-compress -xf "$tar_tmp" -C "$dest_dir" --no-same-owner 2>/dev/null || {
rm -f -- "$tar_tmp"
error "zstd decompressor required to unpack $deb_path"
return 1
}
fi
elif [[ "$data_tar" == *.xz ]] ; then
if command -v xz >/dev/null 2>&1; then
xz -dc "$tar_tmp" | tar -xf - -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp"; return 1;}
else
tar --auto-compress -xf "$tar_tmp" -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp";return 1; }
fi
elif [[ "$data_tar" == *.gz ]] ; then
if command -v gzip >/dev/null 2>&1; then
gzip -dc "$tar_tmp" | tar -xf - -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp"; return 1; }
else
tar --auto-compress -xf "$tar_tmp" -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp"; return 1; }
fi
else
tar -xf "$tar_tmp" -C "$dest_dir" --no-same-owner 2>/dev/null || \
tar --auto-compress -xf "$tar_tmp" -C "$dest_dir" --no-same-owner 2>/dev/null || { rm -f -- "$tar_tmp"; return 1; }
fi
fi
rm -f --"$tar_tmp"
chmod -R u+w "$dest_dir" 2>/dev/null || true
else
error "Neither 'dpkg-deb' nor 'ar'/'tar' isavailable to extract .deb packages."
return 1
fi
}

_deb_read_control_field() {
local deb_path="$1" field="$2"
if command -v dpkg-deb >/dev/null 2>&1; then
dpkg-deb -f "$deb_path" "$field" 2>/dev/null || true
elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
local ctrl_tar
ctrl_tar="$(ar t "$deb_path" 2>/dev/null |grep '^control\.tar' | head -n 1)"
[[ -n "$ctrl_tar" ]] || return 0

local decomp_cmd="cat"
case "$ctrl_tar" in
*.zst) command -v zstd >/dev/null 2>&1 && decomp_cmd="zstd -dc";;
*.xz)  command -v xz >/dev/null 2>&1 && decomp_cmd="xz -dc" ;;
*.gz)  command -v gzip >/dev/null 2>&1 && decomp_cmd="gzip -dc" ;;
esac

ar p "$deb_path" "$ctrl_tar" | $decomp_cmd 2>/dev/null | \
tar -xOf - ./control control 2>/dev/null | \
awk -v f="$field" 'tolower($1) == tolower(f ":") { $1=""; sub(/^[[:space: ]]+/, ""); print; exit }' || true
fi
}

resolve_github_deb_asset() {
local target="${1:-}"
local repo_path tag="" endpoint release_json arch arch_regex
local candidate_urls selected_url

[[ -n "$target" ]] || {
error "A GitHub repository is required."
return 1
}

if [[ "$target" == *"@"* ]] ; then
tag="${target##*@}"
target="${target%@*}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || {
error "InvalidGitHub release tag. Use letters, digits, dot, underscore or hyphen."
return 1
}
fi

repo_path="$(printf '%s' "$target" | sed -E 's#^https?://github\.com/##; s#/$##; s#\.git$##')"
if [[ ! "$repo_path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ; then
error "Invalid GitHub repository: '$repo_path'."
return 1
fi

if [[ -n "$tag" ]] ; then
endpoint="repos/${repo_path}/releases/tags/${tag}"
else
endpoint="repos/${repo_path}/releases/latest"
fi

log "Querying GitHub release for '$repo_path'..."
release_json="$(fetch_github_api "$endpoint" 15)" || {
error "Failed to retrieve GitHub release metadata for '$repo_path'."
return 1
}

check_dependencies jq || return 1

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
| select((.name //"") | test($regex; "i"))
| .browser_download_url // empty
' <<<"$release_json")" || {
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

selected_url="$(grep -ivE '(^|[._+ -])all([._+ -]|$)' <<< "$candidate_urls"| head -n 1 || true)"
[[ -n "$selected_url" ]] || selected_url="$(head -n 1 <<< "$candidate_urls")"
if [[ -z "$selected_url" ]] ; then
error "No compatible Debian package (.deb) found for architecture '$arch'."
return 1
fi

printf '%s\n' "$selected_url"
}

_deb_download_direct_lib_deps() {
local package_name="${1:-}"
local target_dir="${2:-.}"
[[ -n "$package_name" ]] || return 0
command -vapt-cache >/dev/null 2>&1 || return 0
command -v apt-get > /dev/null 2>&1 || return 0

local tmp_dep_file
tmp_dep_file="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/apt_deps.XXXXXX")" || return 0

apt-cache depends --no-recommends --no-suggests "$package_name" 2>/dev/null \
| awk '/^[[:space:]]*Depends:[[:space: ]]+(lib|[a-z0-9+-]+lib)/{print $2}' \
| sed -E 's/^<([^>]+)>$/\1/' \
| grep -vE '^(libc6|base-files|dpkg|debconf|perl-base|coreutils)$' \
| grep -vE '^<.*>$' \
| sort -u > "$tmp_dep_file" || true

local -a deps=()
local dep_line
while IFS= read -r dep_line || [[ -n "$dep_line" ]] ; do
[[ -n "$dep_line" ]] && deps+=("$dep_line")
done < "$tmp_dep_file"
rm -f -- "$tmp_dep_file"

if (( ${#deps[@]} > 0 )); then
log "Downloading ${#deps[@]} library dependency package(s)..."
( cd "$target_dir" && apt-get download "${deps[@]}" 2>/dev/null ) || true
fi
}

cmd_deb_pack() {
local -a pack_passthrough=()
while [[ $# -gt 0 ]] ; do
case "$1" in
--no-scan|--fast|--shared)
pack_passthrough+=("$1")
shift
;;
--runtime)
if [[ -n "${2:-}" ]] ; then
pack_passthrough+=("$1" "$2")
shift 2
else
error "--runtime requires an argument."
return 1
fi
;;
*)
break
;;
esac
done

local pkg_input="${1:-}"
local app_name_hint="${2:-}"
local out_pkg="${3:-}"
local pkg_ver="${4:-}"
local build_dir

[[ -n "$pkg_input" ]] || {
error "Usage: ulpmdeb-pack [flags] <pkg|file.deb|github_repo> [name][out.lpk] [version]"
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

_cmd_deb_pack_work "$pkg_input" "$app_name_hint" "$out_pkg" "$pkg_ver" "$build_dir" "${pack_passthrough[@]}"
}

_cmd_deb_pack_work() {
local pkg_input="${1:-}"
local app_name_hint="${2:-}"
local out_pkg="${3:-}"
local pkg_ver="${4:-}"
local build_dir="${5:-}"
shift 5 2>/dev/null || shift $#
local -a extra_pack_flags=("$@")

local deb_dir="$build_dir/debs"
local root_dir="$build_dir/root"
local app_name="$app_name_hint"
local extracted_name="" deb_url deb_filename deb_file
local -a downloaded_debs=()
local native_arch deb_arch

_cleanup_deb_build() {
[[ -n "${build_dir:-}" && -d "$build_dir" ]] && rm -rf -- "$build_dir"
}

mkdir -p "$deb_dir" "$root_dir" || {
error "Could not prepare temporary Debian build directories."
_cleanup_deb_build
return 1
}

# CASE 0: GitHub repository.
if [[ "$pkg_input" =~ ^https?://github\.com/ || "$pkg_input" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(@.+)?$ ]] ; then
check_dependencies curl jq || { _cleanup_deb_build; return 1; }
deb_url="$(resolve_github_deb_asset "$pkg_input")" || { _cleanup_deb_build; return 1; }
deb_filename="$(basename "${deb_url%%\?*}")"
[[ "$deb_filename" == *.deb && "$deb_filename" != ".deb" ]] || {
error "Theselected GitHub asset does not have a valid .deb filename."
_cleanup_deb_build
return 1
}

[[ "$deb_url" == https://github.com/* || "$deb_url" == https://objects.githubusercontent.com/* || "$deb_url" == https://release-assets.githubusercontent.com/* ]] || {
error "Refusing unexpected GitHub asset URL: $deb_url"
_cleanup_deb_build
return 1
}
log "Downloading remote Debian asset: $deb_filename"
local -a curl_opts=(-fL --retry 2 --connect-timeout 15 --max-time 600)
if [[ -t 1 ]] ; then
curl_opts+=(--progress-bar)
else
curl_opts+=(-sS)
fi
curl "${curl_opts[@]}" "$deb_url" -o "$deb_dir/$deb_filename" || {
error "Download failed: $deb_url"
_cleanup_deb_build
return 1
}
pkg_input="$deb_dir/$deb_filename"
fi

# CASE 1: Local .deb file.
if [[ -L "$pkg_input" ]] ; then
error "Refusing a symbolic link as Debian package input: $pkg_input"
_cleanup_deb_build
return 1
fi

if [[ -f "$pkg_input" && "$pkg_input" == *.deb ]] ; then
log "Processing local Debian package: $(basename "$pkg_input")"
extracted_name="$(_deb_read_control_field "$pkg_input" Package)"
[[ -n "$app_name" ]] || app_name="${extracted_name:-$(basename "$pkg_input" .deb)}"
[[ -n "$pkg_ver" ]]  || pkg_ver="$(_deb_read_control_field "$pkg_input" Version)"

if [[ ! -f "$deb_dir/$(basename "$pkg_input")" ]] ; then
cp -- "$pkg_input" "$deb_dir/" || {
error "Could not copy Debian package into build directory."
_cleanup_deb_build
return 1
}
fi

if [[ -n "$extracted_name" ]] ; then
log "Resolving direct library dependencies for '$extracted_name'..."
_deb_download_direct_lib_deps "$extracted_name" "$deb_dir" || true
fi
else
# CASE2: APT package name.
check_dependencies apt-get apt-cache || { _cleanup_deb_build; return 1; }
[[ -n "$app_name" ]] || app_name="$pkg_input"

log "Downloading primary package '$pkg_input'..."
(
cd "$deb_dir" || exit 1
if ! apt-get download "$pkg_input"; then
error "Failed to download primary package:$pkg_input"
exit 1
fi
) || { _cleanup_deb_build; return 1; }
_deb_download_direct_lib_deps "$pkg_input" "$deb_dir"
fi

shopt -s nullglob
downloaded_debs=("$deb_dir"/*.deb)
shopt -u nullglob

if (( ${#downloaded_debs[@]} == 0 )); then
error "No Debian packages were downloaded or extracted."
_cleanup_deb_build
return 1
fi

if [[ -z "$pkg_ver" ]] ; then
for deb_file in "${downloaded_debs[@]}"; do
local cur_pkg
cur_pkg="$(_deb_read_control_field "$deb_file" Package)"
if [[ "$cur_pkg" == "$app_name" || "$cur_pkg" == "$extracted_name" ]] ; then
pkg_ver="$(_deb_read_control_field "$deb_file" Version)"
break
fi
done
[[ -n "$pkg_ver" ]] || pkg_ver="$(_deb_read_control_field "${downloaded_debs[0]}" Version)"
fi

# Strip Debian Epoch (e.g. "1:2.0.4" -> "2.0.4") to maintain valid SemVer/filename format
pkg_ver="${pkg_ver#*:}"
pkg_ver="$(printf '%s'"${pkg_ver:-1.0.0}" | tr -cd 'A-Za-z0-9.+_~-')"

log "Extracting ${#downloaded_debs[@]} package archive(s)..."
native_arch="$(dpkg --print-architecture 2>/dev/null || detect_arch 2>/dev/null || true)"
for deb_file in "${downloaded_debs[@]}"; do
deb_arch="$(_deb_read_control_field "$deb_file" Architecture)"
if [[ "$deb_arch" != all && -n "$native_arch" && "$deb_arch" != "$native_arch" ]] ; then
warn "Skipping incompatible package $(basename "$deb_file") (arch: $deb_arch;host: $native_arch)."
continue
fi
if ! _deb_extract_archive "$deb_file" "$root_dir"; then
warn "Failed to extract archive: $(basename "$deb_file")"
fi
done

if [[ -z "$(find "$root_dir" -mindepth 1 -print -quit 2>/dev/null)" ]] ; then
error "No files could be extracted from the Debian package set."
_cleanup_deb_build
return 1
fi

local cand_bin entry_found=0 rel_target
for cand_bin in "$root_dir/usr/bin/$app_name" "$root_dir/bin/$app_name" "$root_dir/usr/games/$app_name"; do
if [[ -x "$cand_bin" && ! -d "$cand_bin" ]] ; then
rel_target="${cand_bin#"$root_dir/"}"
cat <<'EOF' > "$root_dir/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$HERE/bin:$HERE/usr/games:$PATH"

EXTRA_LIBS=""
for d in "$HERE"/usr/lib/*-linux-* "$HERE"/lib/*-linux-*"$HERE"/usr/lib64 "$HERE"/lib64 "$HERE"/usr/lib32 "$HERE"/lib32; do
if [ -d "$d" ]; then
EXTRA_LIBS="${EXTRA_LIBS:+$EXTRA_LIBS:}$d"
fi
done

export LD_LIBRARY_PATH="$HERE/lib:$HERE/usr/lib:$HERE/lib64:$HERE/usr/lib64${EXTRA_LIBS:+:$EXTRA_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOF
printf 'exec "$HERE/%q" "$@"\n' "$rel_target" >> "$root_dir/AppRun"
chmod 0755 "$root_dir/AppRun"
entry_found=1
break
fi
done

if (( entry_found == 0 )); then
local scan_list
scan_list="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/deb_exec.XXXXXX")" || { _cleanup_deb_build; return 1; }
find "$root_dir/usr/bin" "$root_dir/bin" "$root_dir/usr/games" -maxdepth 1 -type f -print0 2>/dev/null > "$scan_list"
while IFS= read -r -d '' cand_bin; do
if [[ -x "$cand_bin" && ! -d "$cand_bin" ]] ; then
rel_target="${cand_bin#"$root_dir/"}"
cat <<'EOF' > "$root_dir/AppRun"
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$HERE/bin:$HERE/usr/games:$PATH"

EXTRA_LIBS=""
for d in "$HERE"/usr/lib/*-linux-* "$HERE"/lib/*-linux-* "$HERE"/usr/lib64 "$HERE"/lib64 "$HERE"/usr/lib32 "$HERE"/lib32; do
if [ -d "$d" ];then
EXTRA_LIBS="${EXTRA_LIBS:+$EXTRA_LIBS:}$d"
fi
done

export LD_LIBRARY_PATH="$HERE/lib:$HERE/usr/lib:$HERE/lib64:$HERE/usr/lib64${EXTRA_LIBS:+:$EXTRA_LIBS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
EOF
printf 'exec "$HERE/%q" "$@"\n' "$rel_target" >> "$root_dir/AppRun"
chmod 0755 "$root_dir/AppRun"
entry_found=1
break
fi
done < "$scan_list"
rm -f -- "$scan_list"
fi

# Strip system-level glibc & graphics/sound loaders(Must resolve dynamically to host kernel stack)
find "$root_dir" \( -type f -o -type l \) \( \
-name 'ld-linux*.so*' -o \
-name 'ld-*.so*' -o \
-name 'libc.so*' -o \
-name'libpthread.so*' -o \
-name 'libdl.so*' -o \
-name 'librt.so*' -o \
-name 'libresolv.so*' -o\
-name 'libutil.so*' -o \
-name 'libm.so*'-o \
-name 'libGL.so*' -o \
-name 'libEGL.so*' -o \
-name 'libGLX.so*' -o \
-name' libGLdispatch.so*' -o \
-name 'libdrm.so*' -o \
-name 'libvulkan.so*' -o \
-name 'libasound.so*'-o \
-name 'libpulse.so*' -o \
-name 'libpipewire*.so*' -o \
-name 'libwayland*.so*' \
\) -delete 2>/dev/null || true

log "Handing over assembled Debian payload to bundler (Version: $pkg_ver)..."
local pack_rc=0
cmd_pack "${extra_pack_flags[@]}" "$root_dir" "$app_name" "$out_pkg" "$pkg_ver" || pack_rc=$?

_cleanup_deb_build
return "$pack_rc"
}