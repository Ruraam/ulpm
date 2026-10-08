#!/usr/bin/env bats

load helpers

# tests/helpers.bash
ULPM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ULPM_ROOT

[ -x "$ULPM_ROOT/ulpm" ] || echo "WARNING: $ULPM_ROOT/ulpm missing or not executable" >&2

setup() {
  setup_tmpdir
}

teardown() {
  teardown_tmpdir
}

@test "ulpm version returns correct string" {
  run "$ULPM_ROOT/ulpm" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"ULPM Engine v3"* ]]
  [[ "$output" == *".lpk"* ]]
}

@test "ulpm --version works" {
  run "$ULPM_ROOT/ulpm" --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"v3"* ]]
}

@test "ulpm help / -h / --help exit 0" {
  run "$ULPM_ROOT/ulpm" help
  [ "$status" -eq 0 ]

  run "$ULPM_ROOT/ulpm" -h
  [ "$status" -eq 0 ]

  run "$ULPM_ROOT/ulpm" --help
  [ "$status" -eq 0 ]
}

@test "unknown command fails with non-zero exit" {
  run "$ULPM_ROOT/ulpm" thiscommanddoesnotexist
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown command"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "ulpm without arguments shows usage" {
  run "$ULPM_ROOT/ulpm"
  [ "$status" -ne 0 ]
}
