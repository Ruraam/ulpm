#!/usr/bin/env bash
# ============================================================================ ==
# lib/run.sh - Direct Sandbox Execution Dispatcher
# ULPM v5.3 Architecture Engine (Profiles, Sandbox Isolation& ABI Support)
# ============================================================================ ==

_run_resolve_target() {
local target="${1:-}"
local apps_dir="${ULPM_APPS_DIR:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/apps}"
local db_file="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"

if declare -Fnormalize_target >/dev/null 2>&1; then
target="$(normalize_target "$target" 2>/dev/null || printf '%s' "$target")"
fi

# 1.Direct path to regular file (resolve symlinks safely to canonical absolute path)
if [[ -f "$target" ]] ; then
local real_target
real_target="$(realpath -e -- "$target" 2>/dev/null || true)"
if [[ -n "$real_target" && -f "$real_target" && -r "$real_target" ]] ; then
printf '%s\n' "$real_target"
return 0
fi
fi

# 2. Direct directory lookups in apps directory
local candidate
for candidate in \
"$apps_dir/$target/$target.lpk" \
"$apps_dir/$target.lpk" \
"$apps_dir/io.lpk.${target,,}.lpk" \
"$apps_dir/io.lpk.${target,,}/io.lpk.${target,,}.lpk" \
"$apps_dir/$target/${target,,}.lpk" \
"$apps_dir/${target,,}/${target,,}.lpk"; do
if [[ -f "$candidate" && -r "$candidate" ]] ;then
realpath -e -- "$candidate" 2>/dev/null && return 0
fi
done

# 3. Lookup inside installed.db (exact match first, then case-insensitive)
if [[ -f "$db_file" && ! -L "$db_file" ]] ; then
local id name _rest
#Pass 1: Strict match
while IFS='|' read -r id name _rest; do
if [[ "$id" == "$target" || "$name" == "$target" ]] ; then
for candidate in \
"$apps_dir/$name/$name.lpk" \
"$apps_dir/$name.lpk" \
"$apps_dir/$id/$id.lpk" \
"$apps_dir/$id.lpk" \
"$apps_dir/io.lpk.${name,,}.lpk"; do
if [[ -f "$candidate" && -r "$candidate" ]] ; then
realpath -e -- "$candidate" 2>/dev/null && return 0
fi
done
fi
done < "$db_file"

# Pass 2: Case-insensitive fallback
while IFS='|' read -r id name _rest; do
if [[ "${id,,}" == "${target,,}" || "${name,,}" == "${target,,}" ]] ; then
for candidate in \
"$apps_dir/$name/$name.lpk" \
"$apps_dir/$name.lpk" \
"$apps_dir/$id/$id.lpk" \
"$apps_dir/$id.lpk" \
"$apps_dir/io.lpk.${name,,}.lpk"; do
if [[ -f "$candidate" && -r "$candidate" ]] ; then
realpath -e -- "$candidate" 2>/dev/null && return 0
fi
done
fi
done < "$db_file"
fi

return 1
}

cmd_run() {
local target=""
local resolved_target=""
local explicit_app_args=0
local arg bind_value
local -a sandbox_opts=()
local -a app_args=()

while(($#)); do
arg="$1"

if (( explicit_app_args )); then
app_args+=("$arg")
shift
continue
fi

case "$arg" in
--)
explicit_app_args=1
shift
;;
# Execution Profiles
--gaming|--strict|--desktop)
sandbox_opts+=("$arg")
shift
;;
# Network Control
--offline|--no-net)
sandbox_opts+=("--offline")
shift
;;
--net)
sandbox_opts+=("--net")
shift
;;
# Hardware & Subsystem Isolation Flags
--no-gpu|--no-audio|--no-gui|--no-input)
sandbox_opts+=("$arg")
shift
;;
# Directory Binds
--bind)
if (($# < 2)) || [[ -z "${2:-}" || "${2:-}" == -- ]] ; then
error "--bind requires a mapping formatted as <host_dir>:<sandbox_dir>."
return 2
fi
bind_value="$2"
if [[ "$bind_value" != *:* || "$bind_value" == :* ||"$bind_value" == *: ]] ; then
error "Invalid --bind mapping '$bind_value'; expected <host_dir>:<sandbox_dir>."
return 2
fi
sandbox_opts+=("--bind" "$bind_value")
shift 2
;;
--bind=*)
bind_value="${arg#--bind=}"
if [[ -z "$bind_value" || "$bind_value" != *:* || "$bind_value" == :* || "$bind_value" == *: ]] ; then
error "Invalid --bind mapping '$bind_value'; expected <host_dir>:<sandbox_dir>."
return 2
fi
sandbox_opts+=("--bind" "$bind_value")
shift
;;
-*)
if [[ -z "$target" ]] ; then
error "Unknown sandbox flag: $arg"
return 2
else
# Argument after target without explicit '--' is treated as application argument
app_args+=("$arg")
shift
fi
;;
*)
if [[ -z "$target" ]] ; then
target="$arg"
else
app_args+=("$arg")
fi
shift
;;
esac
done

if [[ -z "$target" ]] ; then
error "Usage: ulpm run[sandbox_flags] <package.lpk|app_id> [-- app_args...]"
return 2
fi

if ! declare -F lpk_run_isolated >/dev/null 2>&1; then
error "Sandbox runner is unavailable: lpk_run_isolated is not defined."
return 127
fi

resolved_target="$(_run_resolve_target "$target")" || {
error "Target LPK package or installed application not found: '$target'"
return 1
}

local app_rc=0
if (( ${#app_args[@]} > 0 )); then
lpk_run_isolated \
"${sandbox_opts[@]}" \
"$resolved_target" \
-- "${app_args[@]}" || app_rc=$?
else
lpk_run_isolated \
"${sandbox_opts[@]}" \
"$resolved_target" || app_rc=$?
fi

return "$app_rc"
}