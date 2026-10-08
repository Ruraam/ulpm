#!/usr/bin/env bats

load helpers

setup() {
  setup_tmpdir
}

teardown() {
  teardown_tmpdir
}

@test "ulpm list works even with empty database" {
  run "$ULPM_ROOT/ulpm" list
  # Peut sortir 0 ou 1 selon l'implémentation, mais ne doit pas crasher
  [[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "ulpm clean does not crash" {
  run "$ULPM_ROOT/ulpm" clean
  [ "$status" -eq 0 ]
}
