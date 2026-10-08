#!/usr/bin/env bats

load helpers

setup() {
setup_tmpdir
}

teardown() {
teardown_tmpdir
}

@test "ulpm version returns correctstring" {
run ulpm version
[ "$status" -eq 0 ]
[[ "$output" == *"ULPMEngine v3"* ]]
[[ "$output" == *".lpk"* ]]
}

@test "ulpm --version works" {
run ulpm --version
[ "$status" -eq 0 ]
[[ "$output" == *"v3"* ]]
}

@test "ulpm help / -h / --help exit 0" {
run ulpm help
[ "$status" -eq0 ]

run ulpm -h
[ "$status" -eq 0 ]

run ulpm --help
[ "$status" -eq 0 ]
}

@test "unknown command fails withnon-zero exit" {
run ulpm thiscommanddoesnotexist
[ "$status" -ne 0 ]
[[ "$output" == *"Unknown command"* ]] || [[ "$output" == *"unknown"* ]]
}

@test "ulpm without arguments shows usage" {
run ulpm
[ "$status" -ne 0 ]
}
