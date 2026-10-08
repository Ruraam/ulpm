#!/usr/bin/env bats

load helpers

setup() {
setup_tmpdir
setup_ulpm
}

teardown() {
teardown_tmpdir
}

@test "has_sig_footer returns false on normal file" {
local f="$TEST_TMP/normal.txt"
echo "hello" > "$f"
run has_sig_footer "$f"
[ "$status" -ne 0 ]
}

@test "SIG_MAGIC_HEX is correctly computed" {
[[ -n "$SIG_MAGIC_HEX" ]]
[[ ${#SIG_MAGIC_HEX} -eq 16 ]]   # 8 bytes → 16 hex chars
}

@test "hex_tail works on small file" {
local f="$TEST_TMP/small.bin"
printf 'ABCDEFGH' > "$f"
result=$(hex_tail "$f" 4 | tr '[:lower:]' '[:upper:]')
[[ "$result" == *"45464748"* ]]  # EFGH
}
