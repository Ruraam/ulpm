#!/usr/bin/env bash
# ============================================================================ ==
# lib/stream.sh - Ephemeral RAM Streaming Engine
# ULPM v5.3 Architecture Engine (RAM Streamer & Sandbox Profiles Passthrough)
# ============================================================================ ==

resolve_stream_url() {
local uri="${1:-}"

[[ -n "$uri" ]] || {
error "A stream URL, local package, or GitHub repository is required."
return 1
}

# Direct HTTP(S) URLs
if [[ "$uri" =~ ^https?:// ]] ; then
printf '%s\n' "$uri"
return 0
fi

# Local file path or file:// URI
if [[ "$uri" == file://* ]] ; then
local local_path="${uri#file://}"
if declare -F normalize_target >/dev/null 2>&1; then
local_path="$(normalize_target "$uri" 2>/dev/null || printf '%s' "$local_path")"
local_path="${local_path#file://}"
fi
local resolved
resolved="$(realpath -e -- "$local_path" 2>/dev/null || true)"
[[ -n "$resolved" && -f "$resolved" && -r "$resolved" ]] || {
error "The fileURI does not refer to a readable regular file: $local_path"
return 1
}
printf 'file://%s\n' "$resolved"
return 0
fi

if [[ -f "$uri" ]] ; then
local resolved
resolved="$(realpath -e -- "$uri" 2>/dev/null || true)"
[[ -n "$resolved" && -f "$resolved" && -r "$resolved" ]] || {
error "Cannot access local package file: $uri"
return 1
}
printf 'file://%s\n' "$resolved"
return 0
fi

# GitHub shorthand: owner/repo, optionally owner/repo@tag
if [[ "$uri" =~ ^([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+)(@([A-Za-z0-9._-]+))?$ ]] ; then
check_dependencies curl jq || return 1

local owner="${BASH_REMATCH[1]}"
local repo="${BASH_REMATCH[2]}"
local tag="${BASH_REMATCH[4]:-}"
local endpoint="releases/latest"
if [[ -n "$tag" ]] ; then
endpoint="releases/tags/${tag}"
fi

local arch arch_regex universal_regex
arch="$(detect_arch)" || {
error "Unable todetect target architecture."
return 1
}
case "${arch,,}" in
amd64|x86_64|x86-64)
arch_regex='(^|[._+ -])(amd64|x86_64|x86-64|x64)([._+ -]|$)'
;;
arm64|aarch64)
arch_regex='(^|[._+ -])(arm64|aarch64|arm-64|armv8)([._+ -]|$)'
;;
armhf|armv7|armv7l)
arch_regex='(^|[._+ -])(armhf|armv7|armv7l|arm32)([._+ -]|$)'
;;
i386|i686|x86)
arch_regex='(^|[._+ -])(i386|i686|x86)([._+ -]|$)'
;;
*)
arch_regex="(^|[._+ -])(${arch})([._+ -]|$)"
;;
esac
universal_regex='(^|[._+ -])(all|any|universal|noarch|no-arch)([._+ -]|$)'

log "Resolving GitHub release for ${owner}/${repo} (${arch})..."
local release_json
release_json="$(fetch_github_api "repos/${owner}/${repo}/${endpoint}" 15)" || {
error "Failed to fetch GitHub release metadata for '${owner}/${repo}'."
return 1
}

local download_url
download_url="$(jq -er --arg arch_re "$arch_regex" --arg universal_re "$universal_regex" '
if (.assets | type) != "array" then error("missing assets array") elseend
| ([.assets[]? | select((.name | type) == "string")
| select(.name | test("\\.lpk$"; "i"))
| select(.name | test($arch_re;"i"))
| .browser_download_url? | select(type == "string")][0] //empty)
// ([.assets[]? | select((.name | type) == "string")
| select(.name | test("\\.lpk$"; "i"))
| select(.name | test($universal_re; "i"))
| .browser_download_url? | select(type == "string")][0]// empty)
// ([.assets[]? | select((.name | type) == "string")
|select(.name | test("\\.lpk$"; "i"))
| .browser_download_url? |select(type == "string")][0] // empty)
// empty
' <<< "$release_json" 2>/dev/null)" || download_url=""

if [[ -z "$download_url" ]] ; then
error "No .lpk release asset found in ${owner}/${repo} for architecture '${arch}'."
return 1
fi

if [[ ! "$download_url" =~ ^https://(([a-zA-Z0-9._-]+\.)?githubusercontent\.com|github\.com)/ ]] ; then
error "GitHub returned anunexpected asset download URL: $download_url"
return 1
fi

printf '%s\n' "$download_url"
return 0
fi

error "Unsupported stream source. Use an HTTP(S) URL, local .lpk file, or owner/repo[@tag]."
return 1
}

cmd_stream() {
local source_input="${1:-}"
if [[ -z "$source_input" ]] ; then
error "Usage: ulpm stream <url|local.lpk|owner/repo[@tag]>[sandbox_flags] [-- app_args...]"
return 1
fi
shift

local -a sandbox_opts=()
local -a app_args=()
local parsing_app_args=0

while (($#)); do
if (( parsing_app_args )); then
app_args+=("$1")
elif [[ "$1" == "--" ]] ; then
parsing_app_args=1
elif [[ "$1" == "--bind" ]] ; then
if (($# < 2)) || [[ -z "${2:-}" || "${2:-}" == -- ]] ; then
error "--bind requires a mapping formatted as <host_dir>:<sandbox_dir>."
return 2
fi
sandbox_opts+=("--bind" "$2")
shift
elif [[ "$1" == "--bind="* ]] ; then
sandbox_opts+=("$1")
elif [[ "$1" =~ ^--(gaming|strict|desktop|offline|no-net|net|no-gpu|no-audio|no-gui|no-input)$ ]] ; then
sandbox_opts+=("$1")
else
parsing_app_args=1
app_args+=("$1")
fi
shift
done

check_dependencies curl || return 1

local target_url
target_url="$(resolve_stream_url "$source_input")" || return 1

local ram_base="/dev/shm"
local free_kb=0
if [[ -d "$ram_base" && -w "$ram_base" ]] ; then
free_kb="$(df -k "$ram_base" 2>/dev/null | awk 'NR>1 {print $4}' | head -n1)"
[[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
fi

# Fallback to runtime directory if /dev/shm has less than 256MB free
if (( free_kb < 262144 )) || [[ ! -w "$ram_base" ]] ; then
ram_base="${XDG_RUNTIME_DIR:-${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/tmp}"
fi
mkdir -p --"$ram_base" 2>/dev/null || ram_base="/tmp"

local tmp_lpk=""
tmp_lpk="$(
umask 077
mktemp "${ram_base%/}/ulpm_stream_XXXXXX.lpk"
)" || {
error "Unable to create volatile package in '$ram_base'."
return 1
}

_ulpm_stream_cleanup() {
if [[ -n "${tmp_lpk:-}" && -f "$tmp_lpk" ]] ; then
: > "$tmp_lpk" 2>/dev/null || true
rm -f -- "$tmp_lpk"
tmp_lpk=""
fi
}

trap '_ulpm_stream_cleanup; exit 130' INT
trap '_ulpm_stream_cleanup;exit 143' TERM
trap '_ulpm_stream_cleanup; exit 129' HUP
trap '_ulpm_stream_cleanup' EXIT

log "Streaming package into volatile memory (storage: $ram_base)..."

local curl_opts=(-fL --retry 2 --connect-timeout 20)
if [[ -t 2 ]] ;then
curl_opts+=(--progress-bar)
else
curl_opts+=(-sS)
fi

local auth_header=() token
if declare -F get_github_token >/dev/null 2>&1 && token="$(get_github_token)"; then
auth_header=(-H "Authorization: Bearer $token")
fi

if [[ "$target_url" == file://* ]] ; then
local source_file="${target_url#file://}"
if ! cp -- "$source_file" "$tmp_lpk"; then
_ulpm_stream_cleanup
error "Failed to copy local package: $source_file"
return 1
fi
elif ! curl "${auth_header[@]}" "${curl_opts[@]}" "$target_url" -o "$tmp_lpk"; then
_ulpm_stream_cleanup
error "Failed to stream package from: $target_url"
return 1
fi

if [[ ! -s "$tmp_lpk" ]] ; then
_ulpm_stream_cleanup
error "Streamed package payload is empty."
return 1
fi

if ! declare -F cmd_run >/dev/null 2>&1; then
_ulpm_stream_cleanup
error "The ULPM run dispatcher (cmd_run) is unavailable."
return 1
fi

local stream_rc=0
if (( ${#app_args[@]} > 0 )); then
cmd_run "${sandbox_opts[@]}" "$tmp_lpk" -- "${app_args[@]}" || stream_rc=$?
else
cmd_run "${sandbox_opts[@]}" "$tmp_lpk" || stream_rc=$?
fi

_ulpm_stream_cleanup
trap- INT TERM HUP EXIT
return "$stream_rc"
}