#!/usr/bin/env bash
# Run as a regular user on a FUSE-capable host with a native Debian slim rootfs tar.
set -euo pipefail

archive=$(realpath -e -- "${1:?Usage: bash tests/rootfs-fuse-offline.sh /path/to/debian-rootfs.tar.gz}")
repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
[[ $(id -u) != 0 ]] || { echo 'Run this test as an unprivileged user.' >&2; exit 1; }
[[ -c /dev/fuse && -r /dev/fuse && -w /dev/fuse ]] || { echo 'Accessible /dev/fuse required.' >&2; exit 1; }

work=$(mktemp -d "$HOME/ulpm-rootfs-test.XXXXXX")
trap 'rm -rf --one-file-system -- "$work"' EXIT
mkdir -p "$work/rootfs" "$work/home"
export HOME="$work/home"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
export ULPM_STRICT_SIGNATURES=1 ULPM_ALLOW_UNSIGNED=0 ULPM_UNSAFE_NO_SANDBOX=0

# Exercise packaging from a real rootfs whose virtual mount targets are absent.
tar --extract --file="$archive" --directory="$work/rootfs" --no-same-owner \
    --anchored --exclude=./proc --exclude=proc --exclude=./sys --exclude=sys \
    --exclude=./dev --exclude=dev
for path in proc sys dev; do
    [[ ! -e "$work/rootfs/$path" ]]
done

cat > "$work/rootfs/usr/bin/launch.sh" <<'PROBE'
#!/bin/sh
set -eu
# The root mount itself must be a read-only SquashFUSE mount. An extracted
# copy would have the backing filesystem type of the host's cache directory.
awk '$5 == "/" && $6 ~ /(^|,)ro(,|$)/ {
    for (i = 7; i < NF; i++) if ($i == "-" && $(i+1) ~ /^fuse\.squashfuse(_ll)?$/) {
        print "root filesystem:", $(i+1), $6
        ok = 1
    }
} END { exit !ok }' /proc/self/mountinfo
test -r /proc/self/status && test -d /sys/devices && test -c /dev/null || exit 1
if touch /etc/ulpm-write-probe; then exit 1; fi
echo writable > /tmp/ulpm-write-probe
test "$#" -eq 1
case "$1" in net:\[*\]) ;; *) exit 1 ;; esac
guest_net=$(readlink /proc/self/ns/net)
test "$guest_net" != "$1"
awk -F: 'NR > 2 { gsub(/[[:space:]]/, "", $1); if ($1 == "lo") loopback = 1; else other = 1 }
         END { exit !(loopback && !other) }' /proc/net/dev
printf 'offline namespace: host %s, guest %s, loopback only\n' "$1" "$guest_net"
echo ULPM_ROOTFS_FUSE_OFFLINE_OK
PROBE
chmod +x "$work/rootfs/usr/bin/launch.sh"

ulpm=(bash "$repo/bin/ulpm")
"${ulpm[@]}" keygen
ULPM_ZSTD_LEVEL=3 "${ulpm[@]}" pack "$work/rootfs" debian-fuse-test "$work/debian.lpk"
host_net=$(readlink /proc/self/ns/net)
"${ulpm[@]}" run --offline --no-gui --no-gpu --no-input --no-audio \
    "$work/debian.lpk" -- "$host_net" | tee "$work/launch.log"
grep -Fxq ULPM_ROOTFS_FUSE_OFFLINE_OK "$work/launch.log"
