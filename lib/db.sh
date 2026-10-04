#!/usr/bin/env bash
# db.sh - Database helpers (flock-protected)

# Line format: id|name|version|repo|timestamp|signing-key-fingerprint

db_replace_entry() {
local id="$1" line="${2:-}"
local escaped_id
escaped_id=$(printf '%s\n' "$id" | sed -e 's/[]\/$*.^[]/\\&/g')
mkdir -p "${ULPM_LOCK%/*}" 2>/dev/null || true
(
if command -v flock &>/dev/null; then
flock -x 9
fi
sed -i "/^${escaped_id}|/d" "$ULPM_DB" 2>/dev/null || true
if [[ -n "$line" ]]; then
echo "$line" >> "$ULPM_DB"
fi
) 9>"$ULPM_LOCK"
}