#!/usr/bin/env bash
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PASSED=0
FAILED=0

assert() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        (( PASSED++ )) || true
    else
        echo -e "${RED}[FAIL]${NC} $desc"
        (( FAILED++ )) || true
    fi
}

echo "=== Starting ULPM test suite ==="

assert "ulpm doctor runs successfully" ./bin/ulpm doctor

assert_fail() {
    local desc="$1"
    shift
    if ! "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} $desc"
        (( PASSED++ )) || true
    else
        echo -e "${RED}[FAIL]${NC} $desc (unexpected success)"
        (( FAILED++ )) || true
    fi
}

assert_fail "ulpm rejects an unknown command" ./bin/ulpm invalid_command

echo "--------------------------------"
echo "Results: $PASSED passed, $FAILED failed"

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
