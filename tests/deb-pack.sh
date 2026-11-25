#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=lib/deb.sh
source "$ROOT_DIR/lib/deb.sh"

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
export ULPM_CACHE_HOME="$test_dir/cache"
mkdir -p "$test_dir/repo" "$test_dir/config" "$test_dir/lists/partial"

build_deb() {
    local output="$1" name="$2" version="$3" relationships="$4"
    local stage="$test_dir/stage"
    rm -rf -- "$stage"
    mkdir -p "$stage/DEBIAN" "$stage/usr/bin" "$stage/usr/share/$name"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: ULPM Tests <tests@example.invalid>\nDescription: ULPM integration fixture\n%s' \
        "$name" "$version" "$relationships" > "$stage/DEBIAN/control"
    touch "$stage/usr/share/$name/marker"
    printf '#!/bin/sh\nexit 0\n' > "$stage/usr/bin/$name"
    chmod +x "$stage/usr/bin/$name"
    dpkg-deb --root-owner-group --build "$stage" "$output" >/dev/null
}

build_deb "$test_dir/repo/ulpm-test-data.deb" ulpm-test-data 2 \
    $'Depends: ulpm-test-unavailable | ulpm-test-leaf (>= 2)\n'
build_deb "$test_dir/repo/ulpm-test-leaf.deb" ulpm-test-leaf 2 ''
build_deb "$test_dir/ulpm-test-app.deb" ulpm-test-app 1 \
    $'Pre-Depends: ulpm-test-data (= 2)\n'
(
    cd "$test_dir/repo"
    dpkg-scanpackages . /dev/null > Packages
)

printf 'deb [trusted=yes] file:%s ./\n' "$test_dir/repo" > "$test_dir/sources.list"
export APT_CONFIG="$test_dir/apt.conf"
cat > "$APT_CONFIG" <<APT
Dir::Etc::parts "$test_dir/config";
Dir::Etc::main "/dev/null";
Dir::Etc::sourcelist "$test_dir/sources.list";
Dir::Etc::sourceparts "$test_dir/config";
Dir::State::lists "$test_dir/lists";
Acquire::Languages "none";
APT
apt-get update >/dev/null

# Check the assembled payload at the handoff to compression and signing.
cmd_pack() {
    [[ -x "$1/AppRun" ]] &&
        [[ -f "$1/usr/share/ulpm-test-app/marker" ]] &&
        [[ -f "$1/usr/share/ulpm-test-data/marker" ]] &&
        [[ -f "$1/usr/share/ulpm-test-leaf/marker" ]] || return 1
    touch "$test_dir/pack-called"
}

cmd_deb_pack "$test_dir/ulpm-test-app.deb"
[[ -f "$test_dir/pack-called" ]]
rm "$test_dir/pack-called" "$test_dir/repo/ulpm-test-leaf.deb"
if cmd_deb_pack "$test_dir/ulpm-test-app.deb"; then
    printf '%s\n' 'Expected a missing required download to fail.' >&2
    exit 1
fi
[[ ! -e "$test_dir/pack-called" ]]
