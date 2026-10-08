#!/usr/bin/env bash
# helpers.bash - Shared setup for ULPM bats tests

setup_ulpm() {
  export ULPM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  export LIB_DIR="$ULPM_ROOT/lib"

  source "$LIB_DIR/common.sh"
}

setup_tmpdir() {
  export TEST_TMP=$(mktemp -d /tmp/ulpm-test.XXXXXX)
  export XDG_DATA_HOME="$TEST_TMP/data"
  export XDG_CACHE_HOME="$TEST_TMP/cache"
  export XDG_CONFIG_HOME="$TEST_TMP/config"
  export HOME="$TEST_TMP/home"
  mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
}

teardown_tmpdir() {
  [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf -- "$TEST_TMP"
}

assert_equal() {
  if [[ "$1" != "$2" ]]; then
    echo "Expected: '$2'"
    echo "Actual:   '$1'"
    return 1
  fi
}
