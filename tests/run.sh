#!/usr/bin/env bash
# ==============================================================================
# ULPM lightweight test suite (no external test framework required)
# ==============================================================================
set -Eeuo pipefail
export NO_COLOR=1

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ulpm-tests.XXXXXX")"
trap 'rm -rf -- "$TEST_TMP"' EXIT

export HOME="$TEST_TMP/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME"

export ULPM_LIB_DIR="$ROOT_DIR/lib"
export ULPM_DATA_HOME="$XDG_DATA_HOME/ulpm"
export ULPM_CONFIG_HOME="$XDG_CONFIG_HOME/ulpm"
export ULPM_CACHE_HOME="$XDG_CACHE_HOME/ulpm"
export ULPM_STATE_HOME="$XDG_STATE_HOME/ulpm"
export ULPM_APPS_DIR="$ULPM_DATA_HOME/apps"
export ULPM_KEYS_DIR="$ULPM_CONFIG_HOME/keys"
export ULPM_DB="$ULPM_DATA_HOME/installed.db"
mkdir -p "$ULPM_DATA_HOME" "$ULPM_CONFIG_HOME" "$ULPM_CACHE_HOME" "$ULPM_STATE_HOME" \
    "$ULPM_APPS_DIR" "$ULPM_KEYS_DIR"

# shellcheck source=lib/utils.sh
source "$ULPM_LIB_DIR/utils.sh"
# shellcheck source=lib/crypto.sh
source "$ULPM_LIB_DIR/crypto.sh"
# shellcheck source=lib/sandbox.sh
source "$ULPM_LIB_DIR/sandbox.sh"
# shellcheck source=lib/manage.sh
source "$ULPM_LIB_DIR/manage.sh"

TESTS=0
FAILURES=0

pass() {
    TESTS=$((TESTS + 1))
    printf 'ok %d - %s\n' "$TESTS" "$1"
}

fail() {
    TESTS=$((TESTS + 1))
    FAILURES=$((FAILURES + 1))
    printf 'not ok %d - %s\n' "$TESTS" "$1" >&2
}

assert_true() {
    local label="$1"
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}

assert_false() {
    local label="$1"
    shift
    if "$@"; then fail "$label"; else pass "$label"; fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

# Identifier validation
for bad_name in '' '.' '..' 'a/b' 'a|b' '-unsafe' $'a\nb'; do
    assert_false "reject unsafe app name '${bad_name//$'\n'/\\n}'" is_safe_app_name "$bad_name"
done
assert_true "accept normal app name" is_safe_app_name "firefox-esr"

# Sandbox fail-closed policy
assert_false "refuse unsandboxed execution by default" \
    env ULPM_UNSAFE_NO_SANDBOX=0 bash -c "source '$ULPM_LIB_DIR/utils.sh'; source '$ULPM_LIB_DIR/sandbox.sh'; _ulpm_refuse_unsandboxed test >/dev/null 2>&1"
assert_true "allow explicit unsafe override" \
    env ULPM_UNSAFE_NO_SANDBOX=1 bash -c "source '$ULPM_LIB_DIR/utils.sh'; source '$ULPM_LIB_DIR/sandbox.sh'; _ulpm_refuse_unsandboxed test >/dev/null 2>&1"

# Cryptography, trailer and publisher fingerprint
if ! command -v openssl >/dev/null 2>&1; then
    fail "openssl is required for crypto tests"
else
    if cmd_keygen testkey >/dev/null 2>&1; then
        pass "generate Ed25519 keypair"
    else
        fail "generate Ed25519 keypair"
    fi

    PAYLOAD="$TEST_TMP/payload.lpk"
    head -c 4096 /dev/urandom > "$PAYLOAD"
    cp -- "$PAYLOAD" "$TEST_TMP/unsigned.lpk"

    if cmd_sign "$PAYLOAD" "$ULPM_KEYS_DIR/testkey.priv" >/dev/null 2>&1; then
        pass "sign package trailer"
    else
        fail "sign package trailer"
    fi

    assert_true "verify signed package" verify_package "$PAYLOAD"
    assert_true "detect signature magic" has_sig_magic "$PAYLOAD"

    expected_fp="$(crypto_fingerprint "$ULPM_KEYS_DIR/testkey.pub")"
    actual_fp="$(package_publisher_fingerprint "$PAYLOAD" 2>/dev/null || true)"
    assert_eq "publisher fingerprint matches key fingerprint" "$expected_fp" "$actual_fp"

    cp -- "$PAYLOAD" "$TEST_TMP/tampered.lpk"
    printf 'X' | dd of="$TEST_TMP/tampered.lpk" bs=1 seek=10 conv=notrunc status=none 2>/dev/null
    verify_rc=0
    verify_package "$TEST_TMP/tampered.lpk" >/dev/null 2>&1 || verify_rc=$?
    assert_eq "detect tampered payload" "1" "$verify_rc"

    unsigned_rc=0
    verify_package "$TEST_TMP/unsigned.lpk" >/dev/null 2>&1 || unsigned_rc=$?
    assert_eq "detect unsigned package" "2" "$unsigned_rc"

    assert_false "no fingerprint for unsigned package" \
        package_publisher_fingerprint "$TEST_TMP/unsigned.lpk"
fi

# Publisher pinning policy and database persistence
assert_true "accept first install without pin" _manage_check_publisher_pin '' 'newfp' demo
assert_true "accept unchanged pin" _manage_check_publisher_pin 'samefp' 'samefp' demo
assert_false "reject publisher key change" _manage_check_publisher_pin 'oldfp' 'newfp' demo
assert_false "reject unsigned upgrade over a pinned app" _manage_check_publisher_pin 'oldfp' '' demo
assert_true "allow explicit key rotation" \
    env ULPM_ALLOW_KEY_ROTATION=1 bash -c "source '$ULPM_LIB_DIR/utils.sh'; source '$ULPM_LIB_DIR/manage.sh'; _manage_check_publisher_pin oldfp newfp demo >/dev/null 2>&1"

DB_FILE="$TEST_TMP/installed.db"
FP="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
assert_true "store database entry with fingerprint" \
    _db_upsert_entry "$DB_FILE" 'io.lpk.demo' 'demo' '1.0.0' 'local' "$FP"
assert_eq "read stored publisher fingerprint" "$FP" \
    "$(_db_get_publisher_fingerprint "$DB_FILE" 'io.lpk.demo' 'demo')"

printf '%s\n' 'io.lpk.legacy|legacy|0.9.0|1700000000|local' > "$TEST_TMP/legacy.db"
assert_false "legacy 5-field entry has no fingerprint" \
    _db_get_publisher_fingerprint "$TEST_TMP/legacy.db" 'io.lpk.legacy' 'legacy'

# End-to-end install: publisher pinning across an upgrade
if command -v mksquashfs >/dev/null 2>&1 && command -v unsquashfs >/dev/null 2>&1; then
    E2E_DIR="$TEST_TMP/e2e"
    mkdir -p "$E2E_DIR/apps" "$E2E_DIR/cache/tmp"
    ULPM_DB="$E2E_DIR/installed.db"
    ULPM_APPS_DIR="$E2E_DIR/apps"
    ULPM_LOCK="$E2E_DIR/installed.db.lock"
    ULPM_CACHE_HOME="$E2E_DIR/cache"
    export ULPM_DB ULPM_APPS_DIR ULPM_LOCK ULPM_CACHE_HOME

    build_test_lpk() {
        local version="$1" out="$2" stage="$E2E_DIR/stage-$1"
        mkdir -p "$stage/meta" "$stage/bin"
        printf '#!/bin/sh\necho demo\n' > "$stage/bin/demo"
        chmod 755 "$stage/bin/demo"
        printf '{"id":"io.lpk.e2e","name":"e2e-demo","version":"%s","arch":"all","exec":"bin/demo"}\n' "$version" \
            > "$stage/meta/manifest.json"
        rm -f "$out"
        mksquashfs "$stage" "$out" -noappend -quiet >/dev/null
    }

    if cmd_keygen e2e-k1 >/dev/null 2>&1 && cmd_keygen e2e-k2 >/dev/null 2>&1; then
        E2E_P1="$E2E_DIR/demo-1.0.0.lpk"
        E2E_P2="$E2E_DIR/demo-1.0.1.lpk"
        build_test_lpk 1.0.0 "$E2E_P1"
        build_test_lpk 1.0.1 "$E2E_P2"
        cmd_sign "$E2E_P1" "$ULPM_KEYS_DIR/e2e-k1.priv" >/dev/null 2>&1
        cmd_sign "$E2E_P2" "$ULPM_KEYS_DIR/e2e-k2.priv" >/dev/null 2>&1

        assert_true "e2e install signed package" cmd_install "$E2E_P1"

        if ULPM_ALLOW_KEY_ROTATION=0 cmd_install "$E2E_P2" >/dev/null 2>&1; then
            fail "e2e reject silent publisher key rotation"
        else
            pass "e2e reject silent publisher key rotation"
        fi

        if ULPM_ALLOW_KEY_ROTATION=1 cmd_install "$E2E_P2" >/dev/null 2>&1; then
            pass "e2e allow explicit publisher key rotation"
        else
            fail "e2e allow explicit publisher key rotation"
        fi

        E2E_FP2="$(package_publisher_fingerprint "$E2E_P2" 2>/dev/null || true)"
        assert_eq "e2e store rotated fingerprint in database" "$E2E_FP2" \
            "$(cut -d'|' -f6 "$ULPM_DB")"

        if PROOT_TMP_DIR="$E2E_DIR" "$ROOT_DIR/bin/ulpm" run --no-gui "$E2E_P1" \
            > "$E2E_DIR/failclosed.out" 2>&1; then
            fail "e2e refuse unsandboxed execution"
        else
            pass "e2e refuse unsandboxed execution"
        fi
        if grep -q 'Refusing to execute' "$E2E_DIR/failclosed.out"; then
            pass "e2e print fail-closed diagnostic"
        else
            fail "e2e print fail-closed diagnostic"
        fi

        if PROOT_TMP_DIR="$E2E_DIR" ULPM_UNSAFE_NO_SANDBOX=1 "$ROOT_DIR/bin/ulpm" run --no-gui "$E2E_P1" \
            > "$E2E_DIR/unsafe.out" 2>&1; then
            pass "e2e honor explicit unsafe override"
        else
            fail "e2e honor explicit unsafe override"
        fi
        if grep -q 'demo' "$E2E_DIR/unsafe.out"; then
            pass "e2e direct execution reached application"
        else
            fail "e2e direct execution reached application"
        fi
    else
        fail "e2e generate test keypairs"
    fi
fi

printf '\n%d tests, %d failure(s)\n' "$TESTS" "$FAILURES"
(( FAILURES == 0 ))
