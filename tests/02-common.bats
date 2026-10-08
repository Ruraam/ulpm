#!/usr/bin/env bats

load helpers

setup() {
  setup_tmpdir
  setup_ulpm
}

teardown() {
  teardown_tmpdir
}

@test "detect_arch returns a valid architecture" {
  local arch
  arch=$(detect_arch)
  [[ "$arch" =~ ^(amd64|arm64|armhf|i386|riscv64)$ ]]
}

@test "SYS_ARCH is set" {
  [[ -n "$SYS_ARCH" ]]
}

@test "paths are correctly defined under XDG" {
  [[ "$ULPM_DATA" == *"/ulpm" ]]
  [[ "$ULPM_APPS" == *"/apps" ]]
  [[ "$CACHE_DIR" == *"/ulpm" ]]
  [[ "$CONF_DIR" == *"/ulpm" ]]
}

@test "SIG_MAGIC and footer constants are correct" {
  [ "$SIG_MAGIC" = "LPKSIG01" ]
  [ "$SIG_FOOTER_TOTAL" -eq 104 ]
  [ "$SIG_RAW_LEN" -eq 64 ]
  [ "$SIG_PUB_LEN" -eq 32 ]
}

@test "normalize_target handles file:// URLs" {
  result=$(normalize_target "file:///tmp/test.lpk")
  [ "$result" = "/tmp/test.lpk" ]
}

@test "init_runtime creates required directories" {
  if command -v squashfuse >/dev/null && command -v bwrap >/dev/null; then
    init_runtime
    [ -d "$ULPM_APPS" ]
    [ -d "$CACHE_API_DIR" ]
    [ -d "$TRUSTED_KEYS_DIR" ]
    [ -f "$ULPM_DB" ]
  else
    skip "Missing runtime tools (squashfuse/bwrap)"
  fi
}
