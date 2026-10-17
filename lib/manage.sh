#!/usr/bin/env bash
# ============================================================================ ==
# lib/manage.sh - Application Lifecycle & Desktop Integration Engine
# ULPM v5.3 Architecture Engine(Permissions, Overrides, Runtimes, Rollback & DB)
# ============================================================================ ==

refresh_desktop_environment() {
local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
local apps_dir="$data_home/applications"
local icons_base="$data_home/icons/hicolor"
[[ -d "$apps_dir" ]] || mkdir -p "$apps_dir" 2>/dev/null || true
if command -v update-desktop-database > /dev/null 2>&1; then
update-desktop-database "$apps_dir" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
[[ -d "$icons_base" ]] && gtk-update-icon-cache -q -t "$icons_base" 2>/dev/null || true
fi
}

_desktop_escape_value() {
local value="$1"
value=${value//\\/\\\\}
value=${value//$'\n'/ }
value=${value//$'\r'/}
value=${value//\;/\\;}
value=${value//\#/\\#}
printf '%s' "$value"
}

_valid_app_id() {
[[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]
}

_safe_managed_dir() {
local path="${1:-}" resolved
[[ -n "$path" ]] || return 1
resolved="$(readlink -m -- "$path" 2>/dev/null)" || return 1
[[ -n "$resolved" && "$resolved" != / && "$resolved" != "$HOME" ]]
}

_manage_resolve_installed_lpk() {
local target="${1:-}"
local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"

if [[ -f "$target" ]] ; then
printf '%s\n' "$target"
return 0
fi

local candidate
for candidate in \
"$apps_dir/$target/$target.lpk" \
"$apps_dir/$target.lpk" \
"$apps_dir/io.lpk.${target,,}.lpk" \
"$apps_dir/io.lpk.${target,,}/io.lpk.${target,,}.lpk" \
"$apps_dir/${target,,}/${target,,}.lpk"; do
if [[ -f "$candidate" && -r "$candidate" ]] ; then
printf '%s\n' "$candidate"
return 0
fi
done

if [[ -f "$db_file" ]] ; then
local id name _rest
while IFS='|' read -r id name _rest; do
if [[ "$id" == "$target" || "$name" == "$target" || "${id,,}" == "${target,,}" || "${name,,}" == "${target,,}" ]] ; then
for candidate in \
"$apps_dir/$name/$name.lpk" \
"$apps_dir/$name.lpk" \
"$apps_dir/$id/$id.lpk" \
"$apps_dir/$id.lpk" \
"$apps_dir/io.lpk.${name,,}.lpk"; do
if [[ -f "$candidate" && -r "$candidate" ]] ; then
printf '%s\n' "$candidate"
return 0
fi
done
fi
done < "$db_file"
fi
return 1
}

write_desktop_launcher() {
local app_id="${1:-}" app_name="${2:-}"
local desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
local launcher exec_bin safe_name
_valid_app_id "$app_id" || { error "Invalid application IDfor desktop launcher: $app_id"; return 1; }
[[ -n "$app_name" ]] || { error "Application name is empty."; return 1; }
mkdir -p "$desktop_dir" || return 1
launcher="$desktop_dir/$app_id.desktop"
exec_bin="${ULPM_BIN:-ulpm}"
safe_name="$(_desktop_escape_value "$app_name")"
exec_bin=${exec_bin//\\/\\\\}
exec_bin=${exec_bin//\"/\\\"}

cat > "$launcher" <<EOF_DESKTOP
[Desktop Entry]
Type=Application
Name=$safe_name
Exec="$exec_bin" run "$app_id" %u
Icon=$app_id
Categories=Utility;Network;AudioVideo;Graphics;Development;
Terminal=false
StartupWMClass=$app_id
X-ULPM-Package=$safe_name
EOF_DESKTOP
chmod 644 "$launcher"
}

_manage_cleanup_install() {
local tmp_lpk="${1:-}" mnt_tmp="${2:-}"
if [[ -n "$mnt_tmp" && -d "$mnt_tmp" ]] ; then
if declare -F safe_unmount >/dev/null 2>&1; then
safe_unmount "$mnt_tmp" >/dev/null 2>&1 || true
fi
rm -rf -- "$mnt_tmp" 2>/dev/null || true
fi
[[ -n "$tmp_lpk" ]] && rm -f -- "$tmp_lpk"
if [[ "${ULPM_TRANSACTION_ACTIVE:-0}" != 1 ]] ; then
release_lock >/dev/null 2>&1 || true
fi
}

# ============================================================================ ==
# Declarative Permissions & Overrides Inspector / Modifier
# ============================================================================ ==

cmd_permissions() {
local action="show" target=""
if [[ "${1:-}" == "reset" ]] ; then
action="reset"
target="${2:-}"
else
target="${1:-}"
fi

[[ -n "$target" ]] || {
error "Usage: ulpm permissions [reset] <app_name|app_id>"
return 1
}

local lpk_file
lpk_file="$(_manage_resolve_installed_lpk "$target")" || {
error "Application package not found for target: $target"
return 1
}

local manifest_raw
manifest_raw="$(unsquashfs -cat "$lpk_file" meta/manifest.json 2>/dev/null)" || \
manifest_raw="$(unsquashfs -cat "$lpk_file" lpk.json 2>/dev/null)" || {
error "Could not read manifest from $lpk_file"
return 1
}

local app_id
app_id="$(jq -r '.id // .name' <<< "$manifest_raw")"

if [[ "$action" == "reset" ]] ; then
manifest_reset_overrides "$app_id"
return 0
fi

local tmp_m effective_json
tmp_m="$(mktemp "${TMPDIR:-/tmp}/ulpm-perm.XXXXXX.json")" || return 1
printf '%s' "$manifest_raw" > "$tmp_m"
effective_json="$(manifest_resolve_effective "$tmp_m" "$app_id")"
rm -f -- "$tmp_m"

local override_file="${ULPM_OVERRIDES_DIR:-$HOME/.config/ulpm/overrides}/${app_id}.json"

printf '%s\n' '============================================================================== =='
printf '\033[1mEffective Sandbox Permissions for [%s]\033[0m\n' "$app_id"
if [[ -f "$override_file" ]] ; then
printf '  \033[1;33m[!] User Overrides Active (%s)\033[0m\n' "$override_file"
else
printf '  \033[0;90m[i] Default package permissions (No local overrides)\033[0m\n'
fi
printf '%s\n' '--------------------------------------------------------------------------------'

local net gpu audio gui home dl dri input hidraw usb kvm
net="$(jq -r 'if has("permissions") then .permissions.network else (.network // true) end' <<< "$effective_json")"
gpu="$(jq -r '.permissions.gpu // true'<<< "$effective_json")"
audio="$(jq -r '.permissions.audio // true' <<< "$effective_json")"
gui="$(jq -r '.permissions.gui // true' <<< "$effective_json")"
home="$(jq -r '.permissions.filesystem.home // "isolated"' <<< "$effective_json")"
dl="$(jq -r '.permissions.filesystem.downloads // "read-write"' <<< "$effective_json")"

dri="$(jq -r '.permissions.devices.dri // true' <<< "$effective_json")"
input="$(jq -r '.permissions.devices.input // true' <<< "$effective_json")"
hidraw="$(jq -r '.permissions.devices.hidraw // false' <<< "$effective_json")"
usb="$(jq -r '.permissions.devices.usb // false' <<< "$effective_json")"
kvm="$(jq -r '.permissions.devices.kvm // false' <<< "$effective_json")"

_fmt_bool() {
if [[ "$1" == "true" ]] ; then
printf '\033[0;32mAllowed\033[0m'
else
printf '\033[0;31mBlocked\033[0m'
fi
}

printf '  %-24s : %b\n' 'Network Access' "$(_fmt_bool "$net")"
printf '  %-24s : %b\n' 'Direct GPU / DRI' "$(_fmt_bool "$gpu")"
printf '  %-24s :%b\n' 'Audio (Pulse/PipeWire)' "$(_fmt_bool "$audio")"
printf '  %-24s : %b\n' 'Display (GUI/Wayland/X11)' "$(_fmt_bool "$gui")"
printf '  %-24s : \033[1m%s\033[0m\n' 'Filesystem Home' "$home"
printf '  %-24s : \033[1m%s\033[0m\n' 'Host Downloads' "$dl"
printf '  %-24s : DRI: %b | Input: %b | HID: %b | USB: %b | KVM: %b\n' \
'Hardware Devices' "$(_fmt_bool "$dri")" "$(_fmt_bool "$input")" "$(_fmt_bool "$hidraw")" "$(_fmt_bool "$usb")" "$(_fmt_bool "$kvm")"

local custom_paths
custom_paths="$(jq -r '.permissions.filesystem.custom[]? | "- \(.path) (\(.mode))"' <<< "$effective_json" 2>/dev/null || true)"
if [[ -n "$custom_paths" ]] ; then
printf '  %-24s :\n%s\n''Custom Bind Paths' "$custom_paths"
fi

local dbus_talk
dbus_talk="$(jq -r '.permissions.dbus.session.talk[]? | "  - \(@text)"' <<< "$effective_json" 2>/dev/null || true)"
if [[ -n "$dbus_talk" ]] ; then
printf '  %-24s :\n%s\n' 'D-Bus Filter Rules' "$dbus_talk"
fi
printf '%s\n' '============================================================================== =='
}

cmd_override() {
local target="${1:-}"
shift || true

[[ -n "$target" && $# -gt 0 ]] || {
error "Usage: ulpm override <app_name|app_id> <options|key=val...>"
printf '%s\n' "Examples:"
printf '%s\n' "  ulpm override firefox --no-net"
printf '%s\n' "  ulpm override blender --share-home"
printf '%s\n' "ulpm override retroarch --gaming"
printf '%s\n' "  ulpm override myapp permissions.devices.kvm=true"
return 1
}

local lpk_file
lpk_file="$(_manage_resolve_installed_lpk "$target")" || {
error "Application package not found: $target"
return 1
}

local app_id
app_id="$(unsquashfs -cat "$lpk_file" meta/manifest.json 2>/dev/null | jq -r '.id // .name' || true)"
[[ -n "$app_id" ]] || app_id="$target"

while [[ $# -gt 0 ]] ; do
case "$1" in
--no-net|--offline)
manifest_set_override "$app_id" '.permissions.network' "false"
;;
--net)
manifest_set_override "$app_id" '.permissions.network' "true"
;;
--no-gpu)
manifest_set_override "$app_id" '.permissions.gpu' "false"
manifest_set_override "$app_id" '.permissions.devices.dri' "false"
;;
--gpu)
manifest_set_override "$app_id" '.permissions.gpu' "true"
manifest_set_override "$app_id" '.permissions.devices.dri' "true"
;;
--isolate-home)
manifest_set_override "$app_id" '.permissions.filesystem.home' '"isolated"'
;;
--share-home|--share-home-rw)
manifest_set_override "$app_id"'.permissions.filesystem.home' '"read-write"'
;;
--share-home-ro)
manifest_set_override "$app_id" '.permissions.filesystem.home' '"read"'
;;
--gaming)
manifest_set_override "$app_id" '.permissions.gpu' "true"
manifest_set_override "$app_id" '.permissions.audio' "true"
manifest_set_override "$app_id" '.permissions.devices.dri' "true"
manifest_set_override "$app_id" '.permissions.devices.input' "true"
manifest_set_override "$app_id" '.permissions.devices.hidraw' "true"
manifest_set_override "$app_id" '.permissions.devices.usb'"true"
;;
--strict)
manifest_set_override "$app_id" '.permissions.network' "false"
manifest_set_override "$app_id" '.permissions.gpu' "false"
manifest_set_override "$app_id" '.permissions.devices.dri' "false"
manifest_set_override "$app_id" '.permissions.filesystem.home' '"isolated"'
manifest_set_override "$app_id" '.permissions.filesystem.downloads' '"none"'
;;
*=*)
local k="${1%%=*}" v="${1#*=}"
[[ "$k" =~ ^\. ]] || k=".$k"
manifest_set_override "$app_id" "$k" "$v"
;;
*)
error "Unrecognized override instruction: $1"
return 1
;;
esac
shift
done
}

# ============================================================================ ==
# Shared Hybrid Runtimes Management
# ============================================================================ ==

_manage_runtime_cleanup() {
local mount_dir="${1:-}" stage_dir="${2:-}"
if [[ -n "$mount_dir" && -d "$mount_dir" ]] ; then
safe_unmount "$mount_dir" >/dev/null 2>&1 || true
rm -rf -- "$mount_dir" 2>/dev/null || true
fi
[[ -n "$stage_dir" && -d "$stage_dir" ]] && rm -rf -- "$stage_dir"
release_lock >/dev/null 2>&1 || true
}

cmd_runtime() {
local subcmd="${1:-list}"
local runtimes_dir="${ULPM_RUNTIMES_DIR:-$HOME/.local/share/ulpm/runtimes}"
_safe_managed_dir "$runtimes_dir" || { error "Refusing unsafe runtime directory: $runtimes_dir"; return 1; }
mkdir -p -- "$runtimes_dir" || return 1

case "$subcmd" in
list)
info "Available Shared Runtimes:"
printf '%s\n' '--------------------------------------------------------------------------------'
printf '%-64s %-12s %-15s\n' "RUNTIME ID / VERSION / ARCH / ABI" "SIZE" "PATH"
printf '%s\n' '--------------------------------------------------------------------------------'
local -a runtime_manifests=() runtime_dirs=()
local tmp_scan
tmp_scan="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/runtime_scan.XXXXXX")" || return 1
find "$runtimes_dir" -mindepth 2 -maxdepth 7 -type f -path '*/meta/manifest.json' -print0 2>/dev/null > "$tmp_scan"
while IFS= read -r -d '' rd; do runtime_manifests+=("$rd"); done < "$tmp_scan"
find "$runtimes_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null > "$tmp_scan"
while IFS= read -r -d '' rd; do runtime_dirs+=("$rd"); done < "$tmp_scan"
rm -f -- "$tmp_scan"

if (( ${#runtime_manifests[@]} == 0 && ${#runtime_dirs[@]} ==0 )); then
printf '  No shared runtimes installed.\n'
else
local rdr_id sz r_version r_arch r_abi
for rd in "${runtime_manifests[@]}"; do
r_id="$(jq -r '.id // "?"' "$rd" 2>/dev/null)"
r_version="$(jq -r '.version // "1.0.0"' "$rd" 2>/dev/null)"
r_arch="$(jq -r '.arch // "all"' "$rd" 2>/dev/null)"
r_abi="$(jq -r '.runtime_abi // .abi // "generic"' "$rd" 2>/dev/null)"
sz="$(du -sh -- "$(dirname "$(dirname "$rd")")" 2>/dev/null | cut -f1)"
printf '%-64.64s %-12s %-15s\n' "$r_id@$r_version/$r_arch/$r_abi" "${sz:--}" "$(dirname "$(dirname "$rd")")"
done
for rd in "${runtime_dirs[@]}"; do
[[ -f "$rd/meta/manifest.json" ]] || continue
r_id="$(basename -- "$rd")"
sz="$(du -sh -- "$rd" 2>/dev/null | cut -f1)"
printf '%-64.64s %-12s %-15s\n' "$r_id (legacy)" "${sz:--}" "$rd"
done
fi
printf '%s\n' '--------------------------------------------------------------------------------'
;;
install)
local r_src="${2:-}"
[[ -n "$r_src" && -f "$r_src" && -r "$r_src" ]] || { error "Usage: ulpm runtime install <shared-runtime.lpk>"; return 1; }
check_dependencies unsquashfs jq || return 1
acquire_lock10 || return 1
local stage="" runtime_old="" r_id manifest_raw runtime_dest rc=1

stage="$(mktemp -d "$runtimes_dir/.runtime-stage.XXXXXX")" || { release_lock; return 1; }

if ! check_package_signature "$r_src"; then
_manage_runtime_cleanup "" "$stage"
return 1
fi

manifest_raw="$(unsquashfs -cat "$r_src" meta/manifest.json 2>/dev/null)" || \
manifest_raw="$(unsquashfs -cat "$r_src" lpk.json 2>/dev/null)" || {
error "Runtime package has no valid manifest."
_manage_runtime_cleanup "" "$stage"
return 1
}

r_id="$(jq -r '.id // empty' <<< "$manifest_raw")"
local runtime_arch
runtime_arch="$(jq -r '.arch // "all"' <<< "$manifest_raw")"
if ! is_arch_compatible "$runtime_arch"; then
error "Runtime architecture '$runtime_arch' is incompatible withhost '$(detect_arch)'."
_manage_runtime_cleanup "" "$stage"
return 1
fi
if [[ "$(jq -r '.shared // false' <<< "$manifest_raw")" != true ]] ; then
error "Package is not marked as a shared runtime (manifest field shared=true required)."
_manage_runtime_cleanup "" "$stage"
return 1
fi
_valid_app_id "$r_id" || {
error "Invalid runtime ID in manifest: $r_id"
_manage_runtime_cleanup "" "$stage"
return 1
}

log "Extracting runtime payload..."
if ! unsquashfs -f -d "$stage" "$r_src" >/dev/null 2>&1; then
error "Failed to extract runtime payload."
_manage_runtime_cleanup "" "$stage"
return 1
fi

local runtime_version runtime_abi
runtime_version="$(jq -r '.version // "1.0.0"' <<< "$manifest_raw")"
runtime_abi="$(jq -r '.runtime_abi // .abi // "generic"' <<< "$manifest_raw")"
runtime_version="$(printf '%s' "$runtime_version" | tr -cd 'A-Za-z0-9.+_-')"
runtime_abi="$(printf '%s' "$runtime_abi" | tr -cd 'A-Za-z0-9.+_-')"
[[ -n "$runtime_version" ]] || runtime_version='1.0.0'
[[ -n "$runtime_abi" ]] || runtime_abi='generic'

runtime_dest="$runtimes_dir/$r_id/$runtime_version/$runtime_arch/$runtime_abi"
mkdir -p -- "$(dirname -- "$runtime_dest")" || { _manage_runtime_cleanup "" "$stage"; return 1; }
[[ ! -L "$runtime_dest" ]] || {
error "Refusing symlinked runtime destination: $runtime_dest"
_manage_runtime_cleanup "" "$stage"
return 1
}

if [[ -e "$runtime_dest" ]] ; then
runtime_old="$(mktemp -d "$runtimes_dir/.runtime-old.XXXXXX")" || { _manage_runtime_cleanup "" "$stage"; return 1; }
rmdir -- "$runtime_old" || { _manage_runtime_cleanup "" "$stage"; return 1; }
mv -- "$runtime_dest" "$runtime_old" || { _manage_runtime_cleanup "" "$stage"; return 1; }
fi
if mv -- "$stage" "$runtime_dest"; then
[[ -n "$runtime_old" ]] && rm -rf -- "$runtime_old"
sync_dir "$(dirname -- "$runtime_dest")"
info "Runtime '$r_id' installed successfully."
rc=0
else
[[ -n "$runtime_old" && -d "$runtime_old" ]] && mv -- "$runtime_old" "$runtime_dest" 2>/dev/null || true
error "Could not commit runtimeinstallation."
fi
release_lock
return "$rc"
;;
*)
error "Unknown runtime sub-command: $subcmd (supported: list, install)"
return 1
;;
esac
}

# ============================================================================ ==
# Core Application Management
# ============================================================================ ==

cmd_install() {
local source="${1:-}"
[[ -n "$source" ]] || { error "Usage: ulpm install <package.lpk|url>"; return 1; }
if [[ "${ULPM_TRANSACTION_ACTIVE:-0}" != 1 ]] ; then acquire_lock 10 || return 1; fi

local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
mkdir -p "$cache_home/tmp" "$cache_home" || { _manage_cleanup_install "" ""; return 1; }
local tmp_lpk
tmp_lpk="$(mktemp "$cache_home/tmp/install_XXXXXX.lpk")" || { _manage_cleanup_install "" ""; return 1; }

local raw_target="$source"
source="$(normalize_target "$source")" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Could not resolve package target."
return 1
}
if [[ -f "$source" ]] ; then
cp -- "$source" "$tmp_lpk" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Could notcopy package file."
return 1
}
elif [[ "$source" =~ ^https?:// ]] ; then
check_dependencies curl || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }
log "Downloading $source..."
local curl_opts=(-fL --retry 2 --connect-timeout 15)
if [[ -t 2 ]] ; then curl_opts+=(--progress-bar); else curl_opts+=(-sS); fi
curl "${curl_opts[@]}" "$source" -o "$tmp_lpk" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Download failed: $source"
return 1
}
else
_manage_cleanup_install "$tmp_lpk" ""
error "Source package not found: $source"
return 1
fi
[[ -s "$tmp_lpk" ]] || {
_manage_cleanup_install "$tmp_lpk" ""
error "Downloaded package is empty."
return 1
}

if ! check_package_signature "$tmp_lpk"; then
_manage_cleanup_install "$tmp_lpk" ""
return 1
fi
check_dependencies unsquashfs jq || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }

local manifest_raw
manifest_raw="$(unsquashfs -cat "$tmp_lpk" meta/manifest.json 2>/dev/null)" || \
manifest_raw="$(unsquashfs -cat "$tmp_lpk" lpk.json 2>/dev/null)" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Package manifest not found in $tmp_lpk."
return 1
}
jq -e 'type == "object"' <<< "$manifest_raw" >/dev/null 2>&1 || {
_manage_cleanup_install "$tmp_lpk" ""
error "Invalid package manifest JSON."
return 1
}

if declare -F _deps_check_manifest >/dev/null 2>&1 && [[ "$(jq '(.dependencies // []) | length' <<< "$manifest_raw")" -gt 0 ]] ; then
local tmp_m_json
tmp_m_json="$(mktemp "$cache_home/tmp/m_check_XXXXXX.json")" || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }
printf '%s' "$manifest_raw" > "$tmp_m_json"
if ! _deps_check_manifest "$tmp_m_json"; then
rm -f -- "$tmp_m_json"
_manage_cleanup_install "$tmp_lpk" ""
error "Resolve declared dependencies before installingthis package (see 'ulpm deps resolve <app-id>')."
return 1
fi
rm -f -- "$tmp_m_json"
fi

local app_id app_name app_version
app_id="$(jq -r '.id // empty' <<< "$manifest_raw")"
app_name="$(jq -r '.name // empty' <<< "$manifest_raw")"
app_version="$(jq -r '.version // "1.0.0"' <<< "$manifest_raw")"
app_name="${app_name:-$(basename -- "$source" .lpk)}"
app_name="$(printf '%s' "$app_name" | tr -cd 'a-zA-Z0-9._-')"
[[ -n "$app_name" && ${#app_name} -le 128 ]] || {
_manage_cleanup_install "$tmp_lpk" ""
error "Unsafe or empty application name in package manifest."
return 1
}

if [[ -z "$app_id" ]] ; then
local id_slug
id_slug="${app_name,,}"
id_slug="${id_slug// /-}"
id_slug="$(printf '%s' "$id_slug" | sed -E 's/[^a-z0-9._-]+/-/g; s/^[.-]+//; s/[.-]+$//')"
[[ -n "$id_slug" ]] ||id_slug="app"
app_id="io.lpk.$id_slug"
fi
_valid_app_id "$app_id" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Invalid application ID in package manifest: $app_id"
return 1
}
app_version="$(printf '%s' "$app_version" | tr -cd 'A-Za-z0-9.+_-')"
[[ -n "$app_version" &&${#app_version} -le 64 ]] || app_version="1.0.0"

local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
local icon_dir="$data_home/icons/hicolor/256x256/apps"
local icon_dir_512="$data_home/icons/hicolor/512x512/apps"
mkdir -p "$icon_dir" "$icon_dir_512" || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }

local tmp_icon="$icon_dir/$app_id.png"
local tmp_icon_512="$icon_dir_512/$app_id.png"
if unsquashfs -cat "$tmp_lpk" meta/icon.png > "$tmp_icon" 2>/dev/null || \
unsquashfs -cat "$tmp_lpk" icon.png > "$tmp_icon" 2>/dev/null; then
if [[ -s "$tmp_icon" ]] && [[ "$(head -c 8 -- "$tmp_icon" 2>/dev/null)" == $'\x89PNG\r\n\x1a\n' ]] ; then
chmod 644 "$tmp_icon" 2>/dev/null || true
cp -f -- "$tmp_icon" "$tmp_icon_512" 2>/dev/null || true
else
rm -f -- "$tmp_icon" "$tmp_icon_512"
fi
else
rm -f -- "$tmp_icon" "$tmp_icon_512"
fi

local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
_safe_managed_dir "$apps_dir" || {
_manage_cleanup_install "$tmp_lpk" ""
error "Refusing unsafe application directory: $apps_dir"
return 1
}
mkdir -p "$apps_dir" "$(dirname -- "$db_file")" || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }
local dest_dir="$apps_dir/$app_name"
[[ ! -L "$dest_dir" ]] || {
_manage_cleanup_install "$tmp_lpk" ""
error "Refusing to install through a symlinked application directory:$dest_dir"
return 1
}
mkdir -p -- "$dest_dir" || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }

local source_origin="${INSTALL_ORIGIN:-$raw_target}"
if [[ "$source_origin" == *$'\n'* || "$source_origin" == *$'\r'* || \
"$source_origin" == *$'\t'* || "$source_origin" == *'|'* || "$source_origin" == *[[:cntrl:]]* ]] ; then
source_origin="local"
fi

local final_pkg="$dest_dir/$app_name.lpk" staged_pkg="" pkg_backup="" db_dir db_tmp db_mode old_version="" old_origin=""
local history_dir="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/history" history_file=""

if [[ -f "$db_file" ]] ; then
old_version="$(awk -F'|' -v id="$app_id" '$1 == id { print $3; exit }' "$db_file")"
old_origin="$(awk -F'|' -v id="$app_id" '$1 == id { print $5; exit }' "$db_file")"
fi
old_version="$(printf '%s' "$old_version" | tr -cd 'A-Za-z0-9.+_-')"
[[ ! -L "$final_pkg" ]] || {
_manage_cleanup_install "$tmp_lpk" ""
error "Refusing symlinked installed package: $final_pkg"
return 1
}
[[ ! -e "$final_pkg" || -f "$final_pkg" ]] || {
_manage_cleanup_install "$tmp_lpk" ""
error "Installed package path is not aregular file: $final_pkg"
return 1
}
staged_pkg="$(mktemp "$dest_dir/.${app_name}.lpk.new.XXXXXX")" || { _manage_cleanup_install "$tmp_lpk" ""; return 1; }
cp -- "$tmp_lpk" "$staged_pkg" || { rm -f -- "$staged_pkg"; _manage_cleanup_install "$tmp_lpk" ""; return 1; }
chmod 644 -- "$staged_pkg" || { rm -f -- "$staged_pkg"; _manage_cleanup_install "$tmp_lpk" ""; return 1; }

db_dir="$(dirname -- "$db_file")"
mkdir -p -- "$db_dir" || { rm -f -- "$staged_pkg";_manage_cleanup_install "$tmp_lpk" ""; return 1; }
[[ ! -L "$db_file" ]] || {
rm -f -- "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
error "Refusing symlinked package database: $db_file"
return 1
}
db_tmp="$(mktemp "$db_dir/.installed.db.XXXXXX")" || { rm -f -- "$staged_pkg"; _manage_cleanup_install "$tmp_lpk" ""; return 1; }
if [[ -f "$db_file" ]] ; then
awk -F'|' -v id="$app_id" -v name="$app_name" '$1 != id && $2 != name' "$db_file" > "$db_tmp" || {
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}
fi
printf '%s|%s|%s|%s|%s\n' "$app_id" "$app_name" "$app_version" "$(date +%s)" "$source_origin" >> "$db_tmp" || {
rm -f --"$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}
db_mode="$(stat -c '%a' -- "$db_file" 2>/dev/null || stat -f '%Lp' -- "$db_file" 2>/dev/null || printf '600')"
chmod "$db_mode" "$db_tmp" || {
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}

if [[ -e "$final_pkg" ]] ; then
pkg_backup="$(mktemp "$dest_dir/.${app_name}.lpk.old.XXXXXX")" || {
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}
rm -f --"$pkg_backup" || {
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}
mv -- "$final_pkg" "$pkg_backup" || {
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
return 1
}
fi
sync_file "$staged_pkg"
if ! mv -- "$staged_pkg" "$final_pkg"; then
[[ -n "$pkg_backup" && -e "$pkg_backup" ]] && mv -- "$pkg_backup" "$final_pkg" 2>/dev/null || true
rm -f -- "$db_tmp" "$staged_pkg"
_manage_cleanup_install "$tmp_lpk" ""
error "Could not commit new application package."
return 1
fi
sync_file "$db_tmp"
if ! mv -f -- "$db_tmp" "$db_file"; then
rm -f -- "$final_pkg"
[[ -n "$pkg_backup" && -e "$pkg_backup" ]] && mv -- "$pkg_backup" "$final_pkg" 2>/dev/null || true
rm -f -- "$db_tmp"
_manage_cleanup_install "$tmp_lpk" ""
error "Could not commit package database update; previous package was restored."
return 1
fi
sync_dir "$db_dir"
sync_dir "$dest_dir"

if [[ -n "$pkg_backup" && -f "$pkg_backup" ]] ; then
if mkdir -p -- "$history_dir"; then
local ts_token
ts_token="$(date +%s%N2>/dev/null || true)"
[[ "$ts_token" =~ ^[0-9]+$ ]] || ts_token="$(date +%s)_$RANDOM"
history_file="$history_dir/${app_id}__${ts_token}__${old_version:-previous}__$$.lpk"
if ! mv -- "$pkg_backup" "$history_file"; then
warn "Previous packageis still available at $pkg_backup; could not move it to history."
else
chmod 600 -- "$history_file" 2>/dev/null || true
local history_meta="${history_file%.lpk}.json"
local meta_content
meta_content="$(jq -n --arg id "$app_id" --arg name "$app_name" --arg version "$old_version" --arg origin "$old_origin" --arg package "${history_file##*/}" '{id: $id, name: $name, version: $version, origin: $origin, package: $package}')"
durable_write "$history_meta" "$meta_content" 600 || {
warn "Retained previous package without rollback metadata: $history_file"
}
fi
else
warn "Could not create package history; previous version retained at $pkg_backup."
fi
fi

if ! write_desktop_launcher "$app_id" "$app_name"; then
warn "Package installed, but desktop launcher creation failed."
fi

refresh_desktop_environment
info "Successfully installed '$app_name' ($app_id v$app_version)."
_manage_cleanup_install "$tmp_lpk" ""
return 0
}

# ============================================================================ ==
# Rollback & History Engines (Bidirectional Rotation)
# ============================================================================ ==

cmd_history() {
local target="${1:-}"
local history_dir="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/history"

[[ -d "$history_dir" ]] || { info "No history snapshots available."; return 0; }

info "Locally Retained Application Snapshots:"
printf '%s\n' '--------------------------------------------------------------------------------'
printf '%-30s %-15s %-20s %s\n' "APP ID" "VERSION" "SNAPSHOT DATE" "PACKAGE ARTIFACT"
printf '%s\n' '--------------------------------------------------------------------------------'

shopt -s nullglob
local meta_files=("$history_dir"/*.json)
shopt -u nullglob

if (( ${#meta_files[@]} == 0)); then
printf '  No snapshots recorded.\n'
else
local m id ver pkg ts
for m in "${meta_files[@]}"; do
id="$(jq -r '.id // empty' "$m" 2>/dev/null)"
[[ -n "$target" && "$target" != "$id" ]] && continue
ver="$(jq -r '.version // "unknown"' "$m" 2>/dev/null)"
pkg="$(jq -r '.package // empty' "$m" 2>/dev/null)"
ts="$(basename -- "$m" | cut -d'_' -f3 2>/dev/null || stat -c '%y' "$m" 2>/dev/null || echo '-')"
printf '%-30.30s %-15.15s %-20.20s %s\n'"$id" "$ver" "$ts" "$pkg"
done
fi
printf '%s\n' '--------------------------------------------------------------------------------'
}

cmd_rollback() {
local target="${1:-}"
[[ -n "$target" ]] || { error "Usage: ulpm rollback <app_name|app_id>"; return 1; }
acquire_lock 10 || return 1

local history_dir="${ULPM_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ulpm}/history"
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share}/ulpm}/installed.db"
local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"

[[ -d "$history_dir" ]] || { release_lock; error "No rollback history available."; return 1; }

local app_id="$target" app_name="$target" cur_version="" cur_origin="local"
if [[ -f "$db_file" ]] ; then
local id name ver time origin
while IFS='|' read -r id name ver time origin; do
if [[ "$name" == "$target" || "$id" == "$target" || "${name,,}" == "${target,,}" || "${id,,}" == "${target,,}" ]] ; then
app_id="$id"
app_name="$name"
cur_version="$ver"
cur_origin="$origin"
break
fi
done < "$db_file"
fi

local latest_meta=""
latest_meta="$(find "$history_dir" -maxdepth 1 -type f -name "${app_id}__*.json" 2>/dev/null | sort -t'_' -k3,3nr |head -n 1)"
[[ -n "$latest_meta" && -f "$latest_meta" ]] || {
release_lock
error "No historical snapshots found for '$target' ($app_id)."
return 1
}

local roll_pkg roll_ver roll_name roll_origin
roll_pkg="$history_dir/$(jq -r '.package // empty' "$latest_meta")"
roll_ver="$(jq -r '.version // "1.0.0"' "$latest_meta")"
roll_name="$(jq -r '.name // empty' "$latest_meta")"
roll_origin="$(jq -r '.origin// "local"' "$latest_meta")"
[[ -n "$roll_name" ]] || roll_name="$app_name"

[[ -f "$roll_pkg" ]] || {
release_lock
error "Historical archive file is missing: $roll_pkg"
return 1
}

log "Rolling back '$roll_name' ($app_id) to version $roll_ver..."

local dest_dir="$apps_dir/$roll_name"
local final_pkg="$dest_dir/$roll_name.lpk"
mkdir -p -- "$dest_dir" || { release_lock;return 1; }

# Preserve current version into history before rolling back (so undo is possible)
if [[ -f "$final_pkg" ]] ; then
local ts_token
ts_token="$(date +%s%N2>/dev/null || true)"
[[ "$ts_token" =~ ^[0-9]+$ ]] || ts_token="$(date +%s)_$RANDOM"
local swap_history_file="$history_dir/${app_id}__${ts_token}__${cur_version:-previous}__$$.lpk"
local swap_meta_file="${swap_history_file%.lpk}.json"
cp -- "$final_pkg" "$swap_history_file" 2>/dev/null || true
if [[ -f "$swap_history_file" ]] ; then
local swap_meta
swap_meta="$(jq -n --arg id "$app_id" --arg name "$roll_name" --arg version "$cur_version" --arg origin "$cur_origin" --arg package "$(basename -- "$swap_history_file")" \
'{id: $id, name: $name, version: $version, origin:$origin, package: $package}')"
durable_write "$swap_meta_file" "$swap_meta" 600 || true
fi
fi

local tmp_target
tmp_target="$(mktemp "$dest_dir/.rollback.XXXXXX.lpk")" || { release_lock; return 1; }
cp -- "$roll_pkg" "$tmp_target" || { rm -f -- "$tmp_target"; release_lock; return 1; }
chmod 644-- "$tmp_target"
sync_file "$tmp_target"
mv -f -- "$tmp_target" "$final_pkg" || { release_lock; return 1; }
sync_dir "$dest_dir"

# Update installed.db atomically
local db_dir db_tmp
db_dir="$(dirname --"$db_file")"
db_tmp="$(mktemp "$db_dir/.installed.db.rollback.XXXXXX")" || { release_lock; return 1; }
awk -F'|' -v id="$app_id" -v name="$roll_name" '$1 != id && $2 != name' "$db_file" > "$db_tmp" || { rm -f -- "$db_tmp"; release_lock; return 1; }
printf '%s|%s|%s|%s|%s\n' "$app_id" "$roll_name" "$roll_ver" "$(date +%s)" "$roll_origin" >> "$db_tmp" || { rm -f -- "$db_tmp"; release_lock; return 1; }
chmod 600 "$db_tmp"
sync_file "$db_tmp"
mv -f -- "$db_tmp" "$db_file" || { rm -f -- "$db_tmp"; release_lock; return 1; }
sync_dir "$db_dir"

# Remove the historicalentry that was just restored
rm -f -- "$roll_pkg" "$latest_meta"

write_desktop_launcher "$app_id" "$roll_name"
refresh_desktop_environment
release_lock
info "Rollback completed successfully: '$roll_name' is now at v$roll_ver."
}

cmd_upgrade() {
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
[[ -f "$db_file" && -s "$db_file" ]] || { info "No installed applications to upgrade."; return 0; }

log "Checkingfor available application updates..."
local -a update_targets=()
local id name ver time origin

# Preload targets to prevent I/O deadlock during write operations
while IFS='|' read -rid name ver time origin; do
[[ -n "$id" && -n "$origin" ]] || continue
if [[ "$origin" =~ ^https?:// ]] ; then
update_targets+=("$name|$id|$origin")
fi
done < "$db_file"

local updated_count=0 item
for item in "${update_targets[@]}"; do
name="${item%%|*}"
origin="${item##*|}"
info "Checking remote update for $name..."
if cmd_install "$origin" < /dev/null; then
(( updated_count++ ))
fi
done

if (( updated_count > 0 ));then
info "$updated_count application(s) upgraded successfully."
else
info "All installedapplications are up to date."
fi
}

cmd_integrate() {
local data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
local mime_dir="$data_home/mime" desk_dir="$data_home/applications"
mkdir -p "$mime_dir/packages" "$desk_dir" || return 1

cat > "$mime_dir/packages/ulpm-lpk.xml" <<'EOF_MIME'
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info ">
<mime-type type="application/x-lpk">
<comment>ULPM Package Bundle</comment>
<comment xml:lang="fr">Paquet d'application ULPM</comment>
<icon name="package-x-generic"/>
<glob pattern="*.lpk"/>
<glob pattern="*.LPK"/>
</mime-type>
</mime-info>
EOF_MIME

local handler_bin="${ULPM_BIN:-ulpm}"
handler_bin=${handler_bin//\\/\\\\}
handler_bin=${handler_bin//\"/\\\"}

cat > "$desk_dir/ulpm-handler.desktop" <<EOF_HANDLER
[Desktop Entry]
Type=Application
Name=ULPM Package Runner
Name[fr]=Exécuteur de paquetsULPM
GenericName=Package Runner
Comment=Run sandboxed .lpk applications directly
Comment[fr]=Exécuter des paquets autonomes LPK
Exec="$handler_bin" run %f
Icon=package-x-generic
Terminal=false
NoDisplay=false
MimeType=application/x-lpk;
Categories=System;Utility;
StartupNotify=true
EOF_HANDLER

chmod 644 "$mime_dir/packages/ulpm-lpk.xml" "$desk_dir/ulpm-handler.desktop"
command -v update-mime-database >/dev/null 2>&1 && update-mime-database "$mime_dir" >/dev/null2>&1 || true
refresh_desktop_environment

nautilus -q 2>/dev/null || true
thunar -q 2>/dev/null || true
kbuildsycoca5 2>/dev/null || kbuildsycoca6 2>/dev/null || true

info "MIME association and desktop integration registered."
}

cmd_list() {
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
info "Installed ULPM Applications:"
printf '%s\n' '--------------------------------------------------------------------------------'
printf '%-25s %-15s %-12s %-24s\n' NAME VERSION SIZE ID
printf '%s\n' '--------------------------------------------------------------------------------'
if [[ -s "$db_file" ]] ; then
while IFS='|' read -r id name ver _ origin; do
[[ -n "$name" ]] || continue
local sz='-'
if [[ -f "$apps_dir/$name/$name.lpk" ]] ; then
sz="$(du -sh -- "$apps_dir/$name/$name.lpk" 2>/dev/null | cut -f1)"
elif [[ -f "$apps_dir/$name.lpk" ]] ; then
sz="$(du -sh -- "$apps_dir/$name.lpk" 2>/dev/null | cut -f1)"
fi
printf '%-25.25s %-15.15s %-12s %-24.24s\n' "$name" "$ver" "$sz" "$id"
done < "$db_file"
fi
printf '%s\n' '--------------------------------------------------------------------------------'
}

cmd_remove() {
local purge=false target=''
while [[ $# -gt 0 ]] ; do
case "$1" in
--purge) purge=true; shift ;;
--) shift; break ;;
-*) error "Unknown remove option: $1"; return 1 ;;
*)
if [[ -z "$target" ]] ; then
target="$1"
else
error "Only one application may be removed at a time."
return 1
fi
shift
;;
esac
done
[[ -n "$target" ]] || { error "Usage: ulpm remove [--purge] <app_name|app_id>"; return 1; }
acquire_lock 10 || return 1

local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
local apps_dir="${ULPM_APPS_DIR:-$HOME/.local/share/ulpm/apps}"
_safe_managed_dir "$apps_dir" || { release_lock; error "Refusing unsafe application directory: $apps_dir";return 1; }
local resolved_id='' resolved_name='' id name _rest
if [[ -s "$db_file" ]] ; then
while IFS='|' read -r id name _rest; do
if [[ "$id" == "$target" || "$name" == "$target" || "${id,,}" == "${target,,}" || "${name,,}" == "${target,,}" ]] ; then
resolved_id="$id"; resolved_name="$name"; break
fi
done < "$db_file"
fi
local app_name="${resolved_name:-$target}" app_id="${resolved_id:-io.lpk.${target,,}}"
[[ "$app_name" != */* && "$app_name" != . && "$app_name" != .. ]] || { release_lock; error "Unsafe application name."; return 1; }
_valid_app_id "$app_id" || { release_lock; error "Unsafe application ID."; return 1;}

local app_dir="$apps_dir/$app_name" app_file="$apps_dir/$app_name.lpk"
[[ ! -L "$app_dir" && ! -L "$app_file" ]] || {
release_lock
error "Refusing symlinked application path for '$app_name'."
return 1
}
local backup_dir="" moved_dir=0 moved_file=0
backup_dir="$(mktemp -d "$apps_dir/.remove-backup.XXXXXX")" || { release_lock; return 1; }
if [[ -e "$app_dir" ]] ; then
mv -- "$app_dir" "$backup_dir/appdir" || { rm -rf -- "$backup_dir"; release_lock; return 1; }
moved_dir=1
fi
if [[ -e "$app_file" ]] ; then
mv -- "$app_file" "$backup_dir/appfile" || {
[[ "$moved_dir" == 1 ]] && mv -- "$backup_dir/appdir" "$app_dir" 2>/dev/null || true
rm -rf -- "$backup_dir"
release_lock
return 1
}
moved_file=1
fi

if declare -F db_remove_entry >/dev/null 2>&1;then
if ! db_remove_entry "$app_id" "$app_name"; then
[[ "$moved_dir" == 1 && -e "$backup_dir/appdir" ]] && mv -- "$backup_dir/appdir" "$app_dir" 2>/dev/null || true
[[ "$moved_file" == 1 && -e "$backup_dir/appfile" ]] && mv -- "$backup_dir/appfile" "$app_file" 2>/dev/null || true
rm -rf -- "$backup_dir"
release_lock
error "Package database update failed; application files were restored."
return 1
fi
elif [[ -f "$db_file" ]] ; then
local db_tmp
db_tmp="$(mktemp "$(dirname -- "$db_file")/.installed.db.XXXXXX")" || {
[[ "$moved_dir" == 1 && -e "$backup_dir/appdir" ]] && mv -- "$backup_dir/appdir" "$app_dir" 2>/dev/null || true
[[ "$moved_file" == 1 && -e "$backup_dir/appfile" ]] && mv -- "$backup_dir/appfile" "$app_file" 2>/dev/null || true
rm -rf -- "$backup_dir"
release_lock
return 1
}
if ! awk -F'|' -v id="$app_id" -v name="$app_name" '$1 != id && $2 != name' "$db_file" > "$db_tmp" || ! mv -f -- "$db_tmp" "$db_file"; then
rm -f -- "$db_tmp"
[[ "$moved_dir" == 1 && -e "$backup_dir/appdir" ]] && mv -- "$backup_dir/appdir" "$app_dir" 2>/dev/null || true
[[ "$moved_file" == 1 && -e "$backup_dir/appfile" ]] && mv -- "$backup_dir/appfile" "$app_file" 2>/dev/null || true
rm -rf -- "$backup_dir"
release_lock
return 1
fi
fi
rm -rf -- "$backup_dir" || warn "Could not remove temporary backup directory: $backup_dir"
sync_dir "$apps_dir"
rm -f -- "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$app_id.desktop"
rm -f -- "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps/$app_id.png"
rm -f -- "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps/$app_id.png"

if [[ "$purge" == true ]] ; then
log "Purging persistent user sandbox state & overrides..."
rm -rf -- "$HOME/.var/app/$app_name"
[[ "$app_id" != "$app_name" ]] && rm -rf -- "$HOME/.var/app/$app_id"
rm -f -- "${ULPM_OVERRIDES_DIR:-$HOME/.config/ulpm/overrides}/${app_id}.json"
fi

refresh_desktop_environment
release_lock
info "Application '$app_name' removed successfully."
}

cmd_clean() {
local cache_home="${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}"
_safe_managed_dir "$cache_home" || { error "Refusing unsafe cache path: $cache_home"; return 1; }
log "Purgingtemporary storage & orphaned sessions..."
if [[ -d "$cache_home" ]] ; then
if command -v mountpoint >/dev/null 2>&1; then
local tmp_mnt_scan
tmp_mnt_scan="$(mktemp "${ULPM_CACHE_HOME:-/tmp}/clean_scan.XXXXXX")" || return 1
find "$cache_home" -maxdepth 2 -type d -name 'mnt_*' -print0 2>/dev/null > "$tmp_mnt_scan"
while IFS= read -r -d '' pt; do
if declare -F safe_unmount >/dev/null 2>&1; then safe_unmount "$pt" || true; fi
done < "$tmp_mnt_scan"
rm -f -- "$tmp_mnt_scan"
fi
for pattern in "$cache_home"/mnt_* "$cache_home"/tmp/* "$cache_home"/build_* "$cache_home"/wrap_ai_*; do
[[ -e "$pattern" || -L "$pattern" ]] || continue
if command -v mountpoint >/dev/null 2>&1 && mountpoint -q -- "$pattern" 2>/dev/null; then
warn "Skipping active mount point: $pattern"
continue
fi
rm -rf -- "$pattern"
done
fi
info "Cleanup complete."
}

cmd_search() {
local query="$*"
[[ -n "$query" ]] || { error "Usage: ulpm search <keyword>"; return 1; }
check_dependencies curl jq || return 1
local is_debian_like=false
if [[ -r /etc/os-release ]] && grep -qiE '^(ID|ID_LIKE)=.*(debian|ubuntu)' /etc/os-release; then
is_debian_like=true
elif command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
is_debian_like=true
fi
local arch arch_regex
arch="$(detect_arch)"
case "$arch" in
arm64|aarch64) arch_regex='arm64|aarch64|arm-64|armv8|arm64v8|all' ;;
x86_64|amd64)  arch_regex='amd64|x86_64|x86-64|x64|all' ;;
armv7l|armhf)  arch_regex='armv7|armhf|armv7l|all' ;;
*)             arch_regex="$arch|all";;
esac
info "Searching for '$query' across GitHub Releases and Repositories..."

local -a global_targets=() global_types=() global_labels=()
local display_idx=1 gh_query raw_results raw_count
gh_query="$(printf '%s' "$query" | sed 's/ /+/g')"
raw_results="$(fetch_github_api "search/repositories?q=${gh_query}+in:name&sort=stars&order=desc&per_page=10" 15)" || raw_results=''
raw_count="$(jq -r '.items | length // 0' <<< "$raw_results" 2>/dev/null || printf '0')"

if [[ "$raw_count" =~ ^[0-9]+$ ]] && ((raw_count > 0 )); then
printf '\n\033[1;32m[ GitHub Upstream Releases ]\033[0m\n%s\n' '--------------------------------------------------------------------------------'
local full_name stars desc
while IFS=$'\t' read -r full_namestars desc; do
[[ -n "$full_name" ]] || continue
printf '[%d]\033[1m%-35s\033[0m (★ %s)\n      %s\n' "$display_idx" "$full_name" "$stars" "${desc:-No description}"
global_targets+=("$full_name")
global_types+=("github")
global_labels+=("$full_name")
(( display_idx++ ))
done < <(jq -r '.items[]? | [.full_name, (.stargazers_count|tostring), (.description // "No description")] | @tsv' <<< "$raw_results" 2>/dev/null)
printf '%s\n' '--------------------------------------------------------------------------------'
fi

if declare -F repo_search_entries >/dev/null 2>&1; then
local repo_matches
repo_matches="$(repo_search_entries "$query" 2>/dev/null || true)"
if [[ -n "$repo_matches" ]] ;then
printf '\n\033[1;36m[ Static Repositories ]\033[0m\n%s\n' '--------------------------------------------------------------------------------'
local r_id r_name r_ver r_url
while IFS=$'\t' read -r r_idr_name r_ver r_url; do
[[ -n "$r_id" ]] || continue
printf '[%d] \033[1m%-25s\033[0m (v%s) [%s]\n' "$display_idx" "$r_name" "$r_ver" "$r_id"
global_targets+=("$r_url")
global_types+=("lpk_url")
global_labels+=("$r_name")
(( display_idx++))
done <<< "$repo_matches"
printf '%s\n' '--------------------------------------------------------------------------------'
fi
fi

if (( ${#global_targets[@]} == 0 )); then
info "No packages or upstream repositories found matching '$query'."
return 0
fi

if [[ -t 0 && -t 1 ]] ; then
printf '\n%b' "${C_CYAN}Enter number to install (or press Enter to cancel): ${C_RESET}"
local selection=""
read -r selection || return 0
if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#global_targets[@]} )); then
local idx=$((selection - 1))
local chosen_target="${global_targets[$idx]}"
local chosen_type="${global_types[$idx]}"

if [[ "$chosen_type" == "github" ]] ; then
if [[ "$is_debian_like" == true ]] && declare -F cmd_deb_pack >/dev/null 2>&1; then
log "Selected GitHub package: $chosen_target. Fetchingdeb asset..."
cmd_deb_pack "$chosen_target"
else
error "Automatic GitHubpackaging requires Debian/Ubuntu base or 'ulpm deb-pack'."
return 1
fi
else
log "Installingselected package: ${global_labels[$idx]}..."
cmd_install "$chosen_target"
fi
fi
fi
}