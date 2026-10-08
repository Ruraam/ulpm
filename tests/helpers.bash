#!/usr/bin/env bash
# helpers.bash - Shared setup for ULPM bats tests

ULPM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ULPM_ROOT

chmod +x "$ULPM_ROOT/ulpm" 2>/dev/null || true
export PATH="$ULPM_ROOT:$PATH"
export ULPM_BIN="$ULPM_ROOT/ulpm"

[ -x "$ULPM_ROOT/ulpm" ] || echo "WARNING: $ULPM_ROOT/ulpm missing or not executable" >&2

setup_ulpm() {
export LIB_DIR="$ULPM_ROOT/lib"
source "$LIB_DIR/common.sh"
}

setup_tmpdir() {
TEST_TMP="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/ulpm-test.XXXXXX")"
export TEST_TMP
export HOME="$TEST_TMP/home"
export XDG_DATA_HOME="$TEST_TMP/data"
export XDG_CACHE_HOME="$TEST_TMP/cache"
export XDG_CONFIG_HOME="$TEST_TMP/config"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
}

teardown_tmpdir() {
if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
rm -rf -- "$TEST_TMP"
fi
return 0
}

assert_equal() {
if [[ "$1" != "$2"]]; then
echo "Expected: '$2'"
echo "Actual:   '$1'"
return 1
fi
}
