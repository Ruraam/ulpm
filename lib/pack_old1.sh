#!/usr/bin/env bash
# ==============================================================================
# lib/pack.sh - Standalone .lpk package creation with metadata & fat-bundling
# ==============================================================================

validate_manifest() {
local manifest="$1"
if ! jq -e --argjson max_version "${ULPM_FORMAT_VERSION:-4}" '
type == "object" and
((.format_version // 1) | type == "number" and . == floor and . >=1 and . <= $max_version) and
(.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") and (contains("..") | not)) and
(.name | type == "string"and length > 0 and length <= 128) and
((.version // "4.0.0") | type =="string" and length > 0 and length <= 64) and
(.exec | type == "string" and length > 0 and length <= 4096 and
(startswith("/") | not) and
(split("/") | all(.[]; . != "" and . != "." and . != ".."))) and
((.icon // "") | type == "string" and length <= 4096 and
(startswith("/") | not) and
(split("/") | all(.[]; . != ".."))) and
((.chromium // false)| type == "boolean") and
((.network // true) | type == "boolean")
' "$manifest" >/dev/null 2>&1; then
error "Invalid or unsafe manifest format."
return 1
fi
return 0
}

appimage_squashfs_offset(){
local f="$1" class shoff shentsize shnum
[[ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" == "7f454c46" ]] || return 1
[[ "$(od -An -tu1 -j5 -N1 "$f" 2>/dev/null | tr -d ' \n')" == "1" ]] || return1
class=$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null| tr -d ' \n')
case "$class" in
2)
shoff=$(od -An -tu8 -j40 -N8 "$f" 2>/dev/null | tr -d' \n')
shentsize=$(od -An -tu2 -j58 -N2 "$f" 2>/dev/null | tr -d ' \n')
shnum=$(od -An -tu2-j60 -N2 "$f" 2>/dev/null | tr -d ' \n')
;;
1)
shoff=$(od -An -tu4 -j32 -N4 "$f" 2>/dev/null | tr -d ' \n')
shentsize=$(od -An -tu2 -j46 -N2 "$f" 2>/dev/null | tr -d'\n')
shnum=$(od -An -tu2 -j48 -N2 "$f"2>/dev/null | tr -d ' \n')
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
if offset=$(appimage_squashfs_offset "$src") && [[ -n "$offset" ]]; then
unsquashfs -no-progress -f -d "$dest" -o "$offset" "$src" >/dev/null 2>&1 || {
(cd "$dest" && "$src" --appimage-extract >/dev/null 2>&1 || unsquashfs -d . "$src" >/dev/null 2>&1)
}
else
(cd "$dest" && "$src"--appimage-extract >/dev/null 2>&1 || unsquashfs -d . "$src" >/dev/null 2>&1)
fi

if [[ -d "$dest/squashfs-root" ]]; then
shopt -s dotglob nullglob
mv "$dest/squashfs-root"/* "$dest/" 2>/dev/null || true
rmdir "$dest/squashfs-root"2>/dev/null || true
shopt -u dotglob nullglob
fi
elif [[ "$src" =~ \.deb$ ]]; then
check_dependencies dpkg-deb
dpkg-deb -x "$src""$dest"
elif [[ "$src" =~ \.rpm$ ]]; then
if command -v rpm2cpio &>/dev/null; then
(cd "$dest" && rpm2cpio "$src" | cpio -idm --quiet 2>/dev/null)
elif command -v bsdtar &>/dev/null; then
bsdtar -xf "$src" -C "$dest"
else
error "rpm2cpio or bsdtar required to unpack .rpm"
return 1
fi
elif[[ "$src" =~ \.zip$ ]]; then
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
[[ "$bname"=~ ^(ld-linux|ld-musl|libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libresolv\.so) ]] && return 0
[[ "$bname" =~ ^(libGL|libGLX|libGLdispatch|libEGL|libGLESv|libdrm|libvulkan|libgbm|libX11|libXext|libXrender|libXrandr) ]] && return 0
[[ "$bname" =~ ^(libasound|libpulse|libwayland-client|libffi|libz\.so|libbz2|liblzma) ]] &&return 0
return 1
}

bundle_elf_libraries() {
local root_dir="$1"
local bin_rel="$2"
local lib_dest="$root_dir/lib"
mkdir -p "$lib_dest"

log "Fat-bundling ELF shared libraries..."

while IFS= read -r binary; do
[[ -f "$binary" ]] || continue
whileIFS= read -r lib; do
[[ -f "$lib" ]] || continue
local lib_name
lib_name="$(basename "$lib")"

if ! is_system_lib "$lib_name"; then
if [[ ! -f "$lib_dest/$lib_name" ]]; then
cp -L "$lib" "$lib_dest/" 2>/dev/null || true
fi
fi
done < <(ldd "$binary" 2>/dev/null | awk '{if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1}' || true)
done < <(find "$root_dir" -type f -exec file {} + 2>/dev/null | grep -E 'ELF (32|64)-bit' | cut -d: -f1 || true)
}

cmd_pack() {
local source_input="${1:-}"
local raw_name="${2:-}"
local output_lpk="${3:-}"
local version_hint="${4:-1.0.0}"

if[[ -z "$source_input" ]]; then
error "Usage: ulpm pack <folder|archive|AppImage|deb> [app_name] [output.lpk] [version]"
exit 1
fi

check_dependencies mksquashfs jq file

local base_clean app_name app_id target_arch
base_clean="$(basename "$source_input")"
base_clean="${base_clean%%.*}"
app_name="${raw_name:-$base_clean}"
app_name="$(echo "$app_name" | tr -cd 'a-zA-Z0-9._-')"

if [[ -z "$app_name" ]]; then
error "Invalid package name: '$raw_name'"
exit 1
fi

app_id="io.lpk.${app_name,,}"
target_arch="$(uname -m)"

if [[ -z "$output_lpk"]]; then
output_lpk="${app_name}_${target_arch}.lpk"
fi

# Case 1: Already structured LPK directory (meta/manifest.json + root/)
if[[ -d "$source_input" && -f "$source_input/meta/manifest.json" && -d "$source_input/root" ]]; then
log "Pre-structured LPK structure detected..."
validate_manifest "$source_input/meta/manifest.json" || exit 1
rm -f "$output_lpk"
mksquashfs "$source_input" "$output_lpk" -comp zstd -Xcompression-level 19 -noappend -reproducible
auto_sign_package "$output_lpk"
info "Package created: $output_lpk"
return 0
fi

local build_dir
build_dir="$(mktemp -d "${ULPM_CACHE_HOME:-/tmp}/build_XXXXXX")"

# Sécurisation du trap avec fallback pour éviter l'erreur "variable sans liaison"
trap 'rm -rf "${build_dir:-}"' EXIT INT TERM

mkdir -p "$build_dir/root" "$build_dir/meta"

log "Extracting payload into temporary tree..."
extract_any_payload "$source_input" "$build_dir/root"

# Flatten if extraction created asingle encompassing subdirectory
shopt -s nullglob
local entries=("$build_dir/root"/*)
shopt -u nullglob
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
shopt -s dotglob
mv "${entries[0]}"/* "$build_dir/root/" 2>/dev/null || true
rmdir "${entries[0]}" 2>/dev/null || true
shopt -u dotglob
fi

# Smart detection of entrypoint binary
local detected_exec="" f fname

# 1. Recherche prioritaire par nom exact de l'application ou AppRun
while IFS= read -r f; do
fname="$(basename "$f")"
if [[ "${fname,,}" =~ ^(${app_name,,}|${base_clean,,}|apprun|main)$ ]]; then
detected_exec="$(realpath --relative-to="$build_dir/root" "$f")"
break
fi
done < <(find "$build_dir/root" -maxdepth 4 -type f -executable 2>/dev/null || true)

# 2. Recherche secondaire : premier binaire ELF quin'est PAS un fichier .so
if [[ -z "$detected_exec" ]]; then
whileIFS= read -r f; do
[[ "$f" =~ \.so(\.[0-9]+)*$ ]] && continue
if file -b "$f" 2>/dev/null | grep -q"ELF.*executable"; then
chmod +x "$f" 2>/dev/null || true
detected_exec="$(realpath --relative-to="$build_dir/root" "$f")"
break
fi
done < <(find "$build_dir/root" -maxdepth 4 -type f2>/dev/null || true)
fi

if [[ -z "$detected_exec" ]];then
error "No executable binary found in package payload."
rm -rf "$build_dir"
trap - EXIT INT TERM
exit 1
fi
log "Detected entrypoint binary: $detected_exec"

# Fat-bundling shared libraries
bundle_elf_libraries "$build_dir/root" "$detected_exec"

# Application icon detection
local best_icon icon_manifest=""
best_icon="$(find "$build_dir/root" -type f \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null \
| grep -iE "512|256|128|logo|icon|app" | head -n1 || true)"
if [[ -n "$best_icon"&& -f "$best_icon" ]]; then
cp -f "$best_icon" "$build_dir/meta/icon.png"
icon_manifest="meta/icon.png"
fi

# Electron / Chromium detection for sandbox flags
local is_chromium=false
if grep -qiE "chromium|electron" "$build_dir/root/$detected_exec" 2>/dev/null || \
[[ "$detected_exec" =~ (brave|chrome|chromium|electron) ]]; then
is_chromium=true
fi

# Generate manifest.json
jq -n \
--argjsonfv "${ULPM_FORMAT_VERSION:-4}" \
--arg id "$app_id" \
--argname "$app_name" \
--arg version "$version_hint" \
--arg arch "$target_arch" \
--arg exec "$detected_exec" \
--arg icon "$icon_manifest" \
--argjson chromium "$is_chromium" \
'{format_version:$fv, id:$id, name:$name, version:$version, arch:$arch,
exec:$exec, icon:$icon, chromium:$chromium, network:true}' \
> "$build_dir/meta/manifest.json"

if ! validate_manifest "$build_dir/meta/manifest.json"; then
rm -rf "$build_dir"
trap - EXITINT TERM
exit 1
fi

log "Compressing SquashFS image with Zstandard (level19)..."
rm -f "$output_lpk"
mksquashfs "$build_dir" "$output_lpk" -comp zstd -Xcompression-level 19 -noappend -reproducible

# Nettoyage et désarmement propre du trap AVANT la signature
rm -rf "$build_dir"
trap - EXIT INT TERM

auto_sign_package "$output_lpk"
info "Successfully generated LPKbundle: $output_lpk"
}

auto_sign_package() {
local pkg="$1"
if command -v sign_package &>/dev/null; then
shopt -s nullglob
local keys=("$ULPM_KEYS_DIR"/*.priv)
shopt -u nullglob
if [[ ${#keys[@]} -gt 0 ]]; then
info "Signing with default key(${keys[0]})..."
sign_package "$pkg" "${keys[0]}" || warn "Failed to sign package."
else
warn "Package built unsigned (no private key found in $ULPM_KEYS_DIR)."
fi
fi
}