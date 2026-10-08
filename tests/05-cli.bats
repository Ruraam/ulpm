#!/usr/bin/env bats

load helpers

setup() {
setup_tmpdir
}

teardown() {
teardown_tmpdir
}

@test "ulpm listworks even with empty database" {
run ulpm list
[[ "$status" -eq 0 || "$status" -eq 1 ]]
}

@test "ulpm clean does not crash" {
run ulpm clean
[ "$status" -eq 0 ]
}
