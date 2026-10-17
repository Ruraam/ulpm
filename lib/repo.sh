#!/usr/bin/env bash
# ============================================================================ ==
# lib/repo.sh - Signed repository indexes, mirrors and package distribution
# ULPM v5.3 Architecture Engine (Hardened Verification & Pinned Signatures)
# ============================================================================ ==

_repo_name_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "${1:-}" != *..* ]] ; }
_repo_root() { printf '%s\n' "${ULPM_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/ulpm}/repos"; }
_repo_cache_root() { printf '%s\n' "${ULPM_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/ulpm}/repos";}
_repo_config() { printf '%s/%s.json\n' "$(_repo_root)" "$1"; }
_repo_key() { printf '%s/%s.pub\n' "$(_repo_root)" "$1"; }
_repo_cache() { printf '%s/%s\n' "$(_repo_cache_root)" "$1"; }

_repo_fetch() {
local url="$1" dest="$2"
case "$url" in
https://*|http://*)
check_dependencies curl || return 1
curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 "$url" -o "$dest" || return 1
;;
file://*)
local f
f="$(normalize_target "$url")" || return 1
[[ -f "$f" ]] || return 1
cp -- "$f" "$dest" || return 1
;;
/*|./*|../*)
[[ -f "$url" ]] || return 1
cp -- "$url" "$dest" || return 1
;;
*)
error "Repository URL must be HTTPS or a local directory/fileURL: $url"
return 1
;;
esac
}

_repo_base_url() {
local base="$1"
base="${base%/}"
printf '%s\n' "$base"
}

_repo_verify_index() {
local name="$1" index="$2" sig="$3" pub="$4"
[[ -f "$index" && -s "$index" && -f "$sig" && -s "$sig" && -f "$pub" && -r "$pub" ]] || {
error "Repository index, signature, or pinned key missing for '$name'."
return 1
}
_crypto_is_ed25519_key "$pub" public || {
error "Invalid pinnedrepository key for '$name'."
return 1
}

local pinned_key
pinned_key="$(_repo_key "$name")"
if [[ -f "$pinned_key" && "$pub" != "$pinned_key" ]] ; then
if ! cmp -s "$pub" "$pinned_key"; then
error "Presented key does not match pinned key for repository'$name'."
return 1
fi
fi

local expected_fingerprint actual_fingerprint
expected_fingerprint="$(jq -r '.key_fingerprint_sha256 // empty' "$(_repo_config "$name")" 2>/dev/null || true)"
if declare -F crypto_fingerprint >/dev/null 2>&1; then
actual_fingerprint="$(crypto_fingerprint "$pub" 2>/dev/null || true)"
fi
if [[ -z "$actual_fingerprint" ]] ; then
actual_fingerprint="$(openssl pkey -pubin -in "$pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
fi

[[ -n "$expected_fingerprint" && -n "$actual_fingerprint" && "$actual_fingerprint" == "$expected_fingerprint" ]] || {
error "Pinned repositorykey fingerprint mismatch for '$name'."
return 1
}

openssl pkeyutl -verify -rawin -pubin -inkey "$pub" -sigfile "$sig" -in "$index" > /dev/null 2>&1 || {
error "Repository index signature verification failed for '$name'."
return 1
}

jq -e '
type == "object" and
.format == "ulpm-repository-v1" and
(.packages | type == "array") and
(([.packages[] | (.id + "|" + .arch)] | unique | length) == (.packages | length)) and
all(.packages[];
(.id | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$") and (contains("..") | not)) and
(.name | type == "string" and length > 0 and (length <= 256)) and
(.version | type == "string" and length > 0 and (length <= 128)) and
(.arch | type == "string" and test("^(x86_64|amd64|aarch64|arm64|armhf|armv7l|armv7|i386|i686|riscv64|ppc64le|s390x|loongarch64|all|any)$")) and
(.file | type == "string" and test("^[A-Za-z0-9._+-]+\\.lpk$") and(contains("..") | not)) and
(.sha256 | test("^[0-9a-f]{64}$")) and
((.dependencies // []) | type == "array") and
((.runtime // null) | type == "string" or type == "null") and
((.runtime_abi // null) | type == "string" or type == "null") and
((.abi // null) | type == "string" or type == "null") and
all((.dependencies // [])[];
(type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$") and (contains("..") | not)) or
(type == "object" and
(.id | type == "string" and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$") and (contains("..") | not)) and
((.version // "") | type == "string")
)
)
)
' "$index" >/dev/null 2>&1 || {
error "Repository index schema invalid for '$name'."
return 1
}
}

repo_search_entries() {
local query="${1:-}"
[[ -n "$query" ]] || return 0
local root; root="$(_repo_cache_root)"
[[ -d "$root" ]] || return 0

local f repo_name_check base_url
shopt -s nullglob
local indexes=("$root"/*/index.json)
shopt -u nullglob

for f in "${indexes[@]}"; do
repo_name_check="$(basename "$(dirname "$f")")"
base_url=""
if [[ -f "$(dirname "$f")/base-url" ]] ; then
base_url="$(head -n 1 "$(dirname "$f")/base-url" | tr -d '\r\n')"
fi

jq -r --arg q "$query" --arg repo "$repo_name_check" --arg base "$base_url" '
.packages[]
| select(((.id + " " + .name + " " + (.description // ""))
| ascii_downcase | contains($q | ascii_downcase)))
| [.id, .name, .version, (if $base != "" then($base + "/" + .file) else .file end)] | @tsv
' "$f" 2>/dev/null || true
done
}

cmd_repo() {
local action="${1:-}"; shift || true
case "$action" in
list)
local root; root="$(_repo_root)";mkdir -p -- "$root"
local f name url enabled
shopt -s nullglob
local configs=("$root"/*.json)
shopt -u nullglob
if (( ${#configs[@]} == 0 )); then info 'No repositories configured.'; return 0; fi
printf '%-18s %-8s%s\n' NAME STATUS URL
for f in "${configs[@]}"; do
name="$(basename -- "$f" .json)"
url="$(jq -r '.url // "?"' "$f" 2>/dev/null || printf '?')"
enabled="$(jq -r '.enabled // true' "$f" 2>/dev/null || printf false)"
printf '%-18s %-8s %s\n' "$name" "$([[ "$enabled" == true ]] && printf enabled || printf disabled)" "$url"
done
;;
add)
local name="${1:-}" url="${2:-}" pub="${3:-}"
_repo_name_ok "$name" || {
error 'Usage: ulpm repo add <name> <https-url|local-dir> <publisher-public-key.pub>'
return 2
}
[[ -n "$url" && -n "$pub" && -f "$pub" && -r "$pub" ]] || {
error 'A repository URLand readable Ed25519 public key file are required.'
return 2
}
_crypto_is_ed25519_key "$pub" public || {
error 'Repositorykey must be an Ed25519 public key.'
return 1
}
case "$url" in
https://*|http://*) ;;
/*|./*|../*|file://*)
local local_url; local_url="$(normalize_target "$url")" || return 1
[[ -d "$local_url" ]] || {
error 'Local repository must be an existing directory containing index.json and index.json.sig.'
return 1
}
url="$(cd -- "$local_url" && pwd -P)" || return 1
;;
*) error 'Repository URL must be HTTPS or a local directory.'; return 1 ;;
esac
local root dest key_tmp fingerprint
root="$(_repo_root)"; mkdir -p -- "$root" || return 1
dest="$(_repo_config "$name")"
[[ ! -e "$dest" && ! -L "$dest" ]] || {
error "Repository '$name' already exists;remove it first to replace its key."
return 1
}
key_tmp="$(mktemp "$root/.${name}.pub.XXXXXX")" || return 1
cp -- "$pub" "$key_tmp" && chmod 644 "$key_tmp" || { rm -f -- "$key_tmp"; return 1; }
sync_file "$key_tmp"
mv -- "$key_tmp" "$(_repo_key "$name")" || { rm -f -- "$key_tmp"; return 1; }
sync_dir "$root"

if declare -F crypto_fingerprint >/dev/null 2>&1; then
fingerprint="$(crypto_fingerprint "$(_repo_key "$name")" 2>/dev/null || true)"
fi
if [[ -z "$fingerprint" ]] ; then
fingerprint="$(openssl pkey -pubin -in "$(_repo_key "$name")" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
fi

if ! jq -n --arg name "$name" --arg url "${url%/}" --arg fingerprint "$fingerprint" \
'{schema:1, name:$name, url:$url, key_fingerprint_sha256:$fingerprint, enabled:true}' > "$dest.tmp"
then
rm -f -- "$dest.tmp" "$(_repo_key "$name")"
return 1
fi
chmod 600 "$dest.tmp"
sync_file "$dest.tmp"
mv -f -- "$dest.tmp" "$dest" || {
rm -f -- "$dest.tmp" "$(_repo_key "$name")"
return 1
}
sync_dir "$root"

info "Repository '$name' configured. Pinned publisher-key SHA-256: $fingerprint"
if ! cmd_repo update "$name"; then
warn "Repository remains configured but its index couldnot be verified."
return 1
fi
cmd_trust "$pub" || {
error "Repository index is valid, but the publisher key could not be added to the LPK trust store."
return 1
}
;;
remove|rm)
local name="${1:-}"; _repo_name_ok "$name" || {
error 'Usage: ulpm repo remove <name>'
return 2
}
local cfg key cache root
cfg="$(_repo_config "$name")"
key="$(_repo_key "$name")"
cache="$(_repo_cache "$name")"
root="$(_repo_root)"
[[ -f "$cfg" ]] || { error "Repository not found: $name"; return 1; }
rm -f -- "$cfg" "$key" || return 1
rm -rf -- "$cache"
sync_dir "$root"
info "Repository '$name' removed."
;;
enable|disable)
local name="${1:-}" cfg state tmp
_repo_name_ok "$name" || {
error "Usage: ulpm repo $action <name>"
return 2
}
cfg="$(_repo_config "$name")"
[[ -f "$cfg" ]] || { error "Repositorynot found: $name"; return 1; }
state=true; [[ "$action" == disable ]] && state=false
tmp="$(mktemp "$(dirname "$cfg")/.${name}.XXXXXX")" || return 1
jq --argjson enabled "$state" '.enabled=$enabled' "$cfg" > "$tmp" && \
chmod 600 "$tmp" && sync_file "$tmp" && mv -f -- "$tmp" "$cfg" || { rm -f -- "$tmp"; return 1; }
sync_dir "$(dirname "$cfg")"
info "Repository '$name' $action."
;;
verify)
local requested="${1:-}" root f name count failures=0
root="$(_repo_cache_root)"; mkdir -p -- "$root"
shopt -s nullglob
local indexes=("$root"/*/index.json)
shopt -u nullglob
for f in "${indexes[@]}"; do
name="$(basename "$(dirname "$f")")"
[[ -z "$requested" || "$requested" == "$name" ]] || continue
if _repo_verify_index "$name" "$f" "$(_repo_cache "$name")/index.json.sig" "$(_repo_key "$name")"; then
count="$(jq '.packages | length' "$f")"
info "Verified repository '$name' ($count packages)."
else
failures=$((failures +1))
fi
done
(( failures == 0 )) || return 1
;;
update|refresh)
local only="${1:-}" root f name url cache index_tmp sig_tmp
root="$(_repo_root)"; mkdir -p -- "$root" "$(_repo_cache_root)"
local -a configs=()
if [[ -n "$only" ]] ; then
_repo_name_ok "$only" || { error 'Invalid repository name.'; return 2; }
configs=("$(_repo_config "$only")")
[[ -f "${configs[0]}" ]] || { error "Repository not found: $only"; return 1; }
else
shopt -s nullglob
configs=("$root"/*.json)
shopt -u nullglob
fi
(( ${#configs[@]} )) || { info 'No repositories configured.'; return 0; }
local failures=0 updated=0
for f in "${configs[@]}"; do
name="$(basename -- "$f" .json)"
[[ "$(jq -r '.enabled // true' "$f" 2>/dev/null)" == true ]] || continue
url="$(jq -r '.url // empty' "$f" 2>/dev/null)"
cache="$(_repo_cache "$name")"
mkdir -p -- "$cache" || { failures=$((failures + 1)); continue; }
index_tmp="$(mktemp "$cache/.index.XXXXXX")" || { failures=$((failures + 1)); continue; }
sig_tmp="$(mktemp "$cache/.sig.XXXXXX")" || { rm -f -- "$index_tmp"; failures=$((failures + 1)); continue; }
local base
base="$(_repo_base_url "$url")"
local fetch_ok=1
if [[ "$url" == /* || "$url" == ./* || "$url" == ../* || "$url" == file://* ]] ; then
local dir
dir="$(normalize_target "$url")" || dir=''
if [[ -d "$dir" ]] ; then
cp -- "$dir/index.json" "$index_tmp" 2>/dev/null || fetch_ok=0
cp -- "$dir/index.json.sig" "$sig_tmp" 2>/dev/null || fetch_ok=0
else
fetch_ok=0
fi
else
_repo_fetch "$base/index.json" "$index_tmp" || fetch_ok=0
_repo_fetch "$base/index.json.sig" "$sig_tmp" || fetch_ok=0
fi
if (( fetch_ok == 0 )) || ! _repo_verify_index "$name" "$index_tmp" "$sig_tmp" "$(_repo_key "$name")"; then
error "Could not update repository '$name'; keeping previous cached index."
rm -f -- "$index_tmp" "$sig_tmp"
failures=$((failures + 1))
continue
fi
sync_file "$index_tmp"
sync_file "$sig_tmp"
mv -f -- "$index_tmp" "$cache/index.json" && \
mv -f -- "$sig_tmp" "$cache/index.json.sig" || {
rm -f -- "$index_tmp" "$sig_tmp"
failures=$((failures + 1))
continue
}
durable_write "$cache/base-url" "$base" 644 || {
error "Could not save the base URL for repository '$name'."
failures=$((failures + 1))
continue
}
info "Updated '$name': $(jq '.packages | length' "$cache/index.json") packages."
updated=$((updated + 1))
done
(( failures == 0 )) || {
error "$failures repository update(s) failed; $updated succeeded."
return 1
}
;;
search)
local query="${*:-}"
[[ -n "$query" ]] || { error 'Usage: ulpm repo search <query>'; return 2; }
cmd_repo update || warn 'Some repositoryindexes could not be refreshed; searching cached indexes.'
local root; root="$(_repo_cache_root)";local found=0 f
shopt -s nullglob
for f in "$root"/*/index.json; do
local repo_name_check
repo_name_check="$(basename "$(dirname "$f")")"
_repo_verify_index "$repo_name_check" "$f" \
"$(_repo_cache "$repo_name_check")/index.json.sig" \
"$(_repo_key "$repo_name_check")" || {
warn "Ignoring invalid cached index: $repo_name_check"
continue
}
local search_matches
search_matches="$(jq -r --arg q "$query" --arg repo "$repo_name_check" '
.packages[]
| select(((.id + " " + .name + " " + (.description // ""))
| ascii_downcase | contains($q | ascii_downcase)))
|[.id, .name, .version, .arch, .file, $repo] | @tsv
' "$f" 2>/dev/null || true)"
if [[ -n "$search_matches" ]] ; then
while IFS=$'\t' read -r id name version arch file repo_name; do
printf '%-32s %-22s %-12s %-8s[%s]\n' "$id" "$name" "$version" "$arch" "$repo_name"
found=1
done <<< "$search_matches"
fi
done
shopt -u nullglob
(( found ==1 )) || info 'No matching packages found in cached repository indexes.'
;;
install)
local target="${1:-}" repo_name="${2:-}"
[[ -n "$target" ]] || { error 'Usage: ulpmrepo install <app-id> [repository]'; return 2; }
if [[ -n "$repo_name" ]] ; then
_repo_name_ok "$repo_name" || { error "Invalid repositoryname: $repo_name"; return 2; }
cmd_transaction install "$target" --repo "$repo_name"
else
cmd_transaction install "$target"
fi
;;
index|create-index)
local dir="${1:-}" priv="${2:-}"
[[ -n "$dir" && -d "$dir" && -n "$priv" && -f "$priv" && -r "$priv" ]] || {
error 'Usage: ulpm repo index <package-directory> <publisher-private-key>'
return 2
}
_crypto_is_ed25519_key "$priv" private || {
error 'Index signing key must be an Ed25519 private key.'
return 1
}
check_dependencies jq unsquashfs openssl sha256sum || return 1
local out="$dir/index.json" tmp sig_tmp
tmp="$(mktemp "$dir/.index.XXXXXX")" || return 1
sig_tmp="$(mktemp "$dir/.index.sig.XXXXXX")" || { rm -f -- "$tmp"; return 1; }

_cleanup_repo_index() {
rm -f -- "$tmp" "$sig_tmp"
}

local packages='[]' pkg manifest id name version arch file hash desc deps \
runtime runtime_abi abi
shopt -s nullglob
local lpk_files=("$dir"/*.lpk)
shopt -u nullglob
for pkg in "${lpk_files[@]}"; do
[[ -f "$pkg" ]] || continue
manifest="$(unsquashfs -cat "$pkg" meta/manifest.json 2>/dev/null)" || manifest=''
[[ -n "$manifest" ]] && jq -e 'type == "object"' <<< "$manifest" >/dev/null 2>&1 || {
warn "Skipping invalid LPK: $(basename "$pkg")"
continue
}
id="$(jq -r '.id // empty' <<< "$manifest")"
name="$(jq -r '.name // empty' <<< "$manifest")"
version="$(jq -r '.version// "1.0.0"' <<< "$manifest")"
arch="$(jq -r '.arch // "all"' <<< "$manifest")"
desc="$(jq -r '.description // ""' <<< "$manifest")"
deps="$(jq -c '.dependencies // []' <<< "$manifest")"
runtime="$(jq -r '.runtime // ""' <<< "$manifest")"
runtime_abi="$(jq -r '.runtime_abi //""' <<< "$manifest")"
abi="$(jq -r '.abi // ""' <<< "$manifest")"
is_safe_app_id "$id" && [[ -n "$name" ]] || {
warn "Skipping manifest with invalid id/name: $(basename "$pkg")"
continue
}
file="$(basename "$pkg")"
[[ "$file" != *..* ]] || continue
hash="$(sha256sum "$pkg" | awk '{print $1}')"
packages="$(jq -c \
--arg id "$id" --arg name "$name" --arg version "$version" \
--arg arch "$arch" --arg file "$file" --arg sha256 "$hash" \
--arg description "$desc" --argjson dependencies "$deps" \
--arg runtime "$runtime" --arg runtime_abi "$runtime_abi" \
--arg abi "$abi" \
'. + [{
id: $id, name: $name, version: $version, arch: $arch,
file: $file, sha256: $sha256,description: $description,
dependencies: $dependencies,
runtime: (if $runtime == "" then null else $runtime end),
runtime_abi: (if $runtime_abi == "" then null else $runtime_abi end),
abi: (if $abi == "" then null else $abi end)
}]' <<< "$packages")" || { _cleanup_repo_index; return 1; }
done
if ! jq -e '([.[] | (.id + "|" + .arch)] | unique | length) == length' \
<<< "$packages" >/dev/null
then
_cleanup_repo_index
error 'Repository directory contains multiple versions for the same package ID and architecture; publish one current version per ID/architecture.'
return 1
fi

local gen_time
if [[ -n "${SOURCE_DATE_EPOCH:-}" ]] ; then
gen_time="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
else
gen_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

if ! jq -nS --arg generated "$gen_time" --argjson packages "$packages" \
'{format:"ulpm-repository-v1", generated:$generated, packages:($packages | sort_by(.id, .arch))}' > "$tmp"; then
_cleanup_repo_index
return 1
fi

if ! openssl pkeyutl -sign -rawin -inkey "$priv" -in "$tmp" -out "$sig_tmp"; then
_cleanup_repo_index
return 1
fi
chmod 644 "$tmp" "$sig_tmp"
sync_file "$tmp"
sync_file "$sig_tmp"
if ! mv -f -- "$tmp" "$out" || ! mv -f -- "$sig_tmp" "$dir/index.json.sig"; then
_cleanup_repo_index
return 1
fi
sync_dir "$dir"

info "Signed deterministic repository index created: $out ($(jq '.packages | length' "$out") packages)."
;;
*)
error 'Usage: ulpm repo <list|add|remove|enable|disable|update|verify|search|install|index> ...'
return 2
;;
esac
}

cmd_upgrade() {
local target="${1:-}"; shift || true
if [[ -n "$target" ]] ; then
is_safe_app_id "$target" || {
error "Targeted upgrade expects a package ID: $target"
return 2
}
cmd_transaction install "$target"
return $?
fi

local db="${ULPM_DB:-${ULPM_DATA_HOME:-$HOME/.local/share/ulpm}/installed.db}"
[[ -f "$db" && -s "$db" ]] || { info 'No installed applications found.'; return 0; }

cmd_repo update || warn 'Repositoryrefresh had errors; using verified cached indexes.'

local -a installed_entries=()
local line
while IFS= read -r line || [[ -n "$line" ]] ; do
[[ -n "$line" ]] && installed_entries+=("$line")
done < "$db"

local id name version _timestamp origin f repo cfg key row candidate_version best_version
local -a repo_targets=()
local raw_arch host_arch
raw_arch="$(detect_arch)"
host_arch="$(normalize_arch_name "$raw_arch")"
local updated_standalone=0

for line in "${installed_entries[@]}"; do
IFS='|' read -r id name version _timestamp origin <<< "$line"
[[ -n "$id" ]] || continue

if [[ "$origin" =~ ^https?:// ]] ; then
info "Checking standalone update for $name ($id)..."
if cmd_install "$origin" < /dev/null; then
(( updated_standalone++))
fi
continue
fi

[[ "$origin" == repo:* ]] || continue
best_version=''
shopt -s nullglob
local indexes=("$(_repo_cache_root)"/*/index.json)
shopt -u nullglob
for f in "${indexes[@]}"; do
repo="$(basename "$(dirname "$f")")"
cfg="$(_repo_config "$repo")"
key="$(_repo_key "$repo")"
[[ -f "$cfg" && -f "$key" && "$(jq -r '.enabled // true' "$cfg" 2>/dev/null)" == true ]] || continue
_repo_verify_index "$repo" "$f" "$(_repo_cache "$repo")/index.json.sig" "$key" >/dev/null 2>&1 || continue

local rows
rows="$(jq -c --arg id "$id" --arg arch "$host_arch" '
.packages[] | select(
.id == $id and (
.arch == $arch or
.arch == "all"or
.arch == "any" or
($arch == "amd64" and (.arch == "x86_64" or .arch == "x86-64")) or
($arch == "arm64" and (.arch == "aarch64" or .arch == "arm-64")) or
($arch == "armhf" and (.arch == "armv7l" or .arch == "armv7"))
)
)
' "$f" 2>/dev/null || true)"

[[ -n "$rows" ]] || continue

while IFS= read -r row; do
[[ -n "$row" ]] || continue
candidate_version="$(jq -r '.version' <<< "$row")"
local cmp=0
semver_compare "$candidate_version" "${best_version:-0}" || cmp=$?
if [[ -z "$best_version" ]] || (( cmp == 1 )); then
best_version="$candidate_version"
fi
done <<< "$rows"
done

local upgrade_cmp=0
semver_compare "$best_version" "$version" || upgrade_cmp=$?
if [[ -n "$best_version" ]] && (( upgrade_cmp == 1 )); then
repo_targets+=("$id")
fi
done

if (( ${#repo_targets[@]} > 0 )); then
info "Preparingatomic transaction for ${#repo_targets[@]} repository upgrade(s)."
ULPM_SKIP_REPO_REFRESH=1 cmd_transaction install "${repo_targets[@]}"
elif (( updated_standalone == 0)); then
info 'All tracked applications and repository packages are up to date.'
fi
}