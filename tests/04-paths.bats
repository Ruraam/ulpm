#!/usr/bin/env bats

load helpers

setup() {
  setup_tmpdir
  setup_ulpm
}

teardown() {
  teardown_tmpdir
}

@test "ULPM respects XDG_DATA_HOME" {
  [[ "$ULPM_DATA" == "$XDG_DATA_HOME/ulpm" ]]
}

@test "ULPM respects XDG_CACHE_HOME" {
  [[ "$CACHE_DIR" == "$XDG_CACHE_HOME/ulpm" ]]
}

@test "ULPM respects XDG_CONFIG_HOME" {
  [[ "$CONF_DIR" == "$XDG_CONFIG_HOME/ulpm" ]]
}

@test "desktop and icon directories are defined" {
  [[ -n "$DESKTOP_DIR" ]]
  [[ -n "$ICON_DIR" ]]
}
