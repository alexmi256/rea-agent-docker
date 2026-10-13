#!/usr/bin/env bash
# Shared helpers for the rea-agent verification harness.
# Sourced by the other verify-*.sh scripts; not executable on its own.

# Idempotent: verify-all.sh sources this once, then every phase script sources
# it again. Re-running the body would reset the counters and the run id.
if [ -n "${REA_VERIFY_LIB_LOADED:-}" ]; then return 0; fi
REA_VERIFY_LIB_LOADED=1

: "${REA_VERIFY_FIXTURES:=/tmp/rea-verify/fixtures}"
: "${REA_VERIFY_OUT:=/work/verify-reports}"

if ! mkdir -p "$REA_VERIFY_OUT" 2>/dev/null; then
    REA_VERIFY_OUT=/tmp/rea-verify/reports
    mkdir -p "$REA_VERIFY_OUT"
fi
RUN_ID="${REA_VERIFY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
REA_VERIFY_RUN_ID="$RUN_ID"
REPORT_DIR="$REA_VERIFY_OUT/$RUN_ID"
LOGDIR="$REPORT_DIR/logs"
mkdir -p "$LOGDIR" "$REA_VERIFY_FIXTURES"
export REA_VERIFY_RUN_ID REA_VERIFY_OUT REA_VERIFY_FIXTURES

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()
SKIPPED_NAMES=()

C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'

section() { printf '\n%s== %s ==%s\n' "$C_B" "$1" "$C_0"; }
_ok()   { PASS=$((PASS + 1)); printf '  %sPASS%s %s\n' "$C_G" "$C_0" "$1"; }
_bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
          printf '  %sFAIL%s %s\n' "$C_R" "$C_0" "$1"
          [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }
_skip() { SKIP=$((SKIP + 1)); SKIPPED_NAMES+=("$1")
          printf '  %sSKIP%s %s%s\n' "$C_Y" "$C_0" "$1" "${2:+ - $2}"; }

logname_for() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# check <name> [grep-pattern|""] -- <command...>
# Passes when the command exits 0 and stdout matches the pattern (if given).
check() {
    local name="$1"; shift
    local pattern=""
    if [ "${1:-}" != "--" ]; then pattern="$1"; shift; fi
    [ "${1:-}" = "--" ] && shift
    local base="$LOGDIR/$(logname_for "$name")"
    "$@" >"$base.out" 2>"$base.err"
    local rc=$?
    if [ $rc -ne 0 ]; then
        _bad "$name" "exit=$rc  out: $base.out  err: $base.err"
        return 1
    fi
    if [ -n "$pattern" ] && ! grep -qE "$pattern" "$base.out"; then
        _bad "$name" "stdout did not match /$pattern/  out: $base.out"
        return 1
    fi
    _ok "$name"
    return 0
}

# check_json <name> <jq-filter> -- <command...>
# REA's --json output must parse and satisfy the filter.
check_json() {
    local name="$1"; shift
    local filter="$1"; shift
    [ "${1:-}" = "--" ] && shift
    local base="$LOGDIR/$(logname_for "$name")"
    "$@" >"$base.out" 2>"$base.err"
    local rc=$?
    if [ $rc -ne 0 ]; then
        _bad "$name" "exit=$rc  err: $base.err"
        return 1
    fi
    if ! jq -e "$filter" <"$base.out" >/dev/null 2>&1; then
        _bad "$name" "jq filter failed: $filter  out: $base.out"
        return 1
    fi
    _ok "$name"
    return 0
}

# check_json_file <name> <jq-filter> <file>
check_json_file() {
    local name="$1" filter="$2" file="$3"
    if [ ! -s "$file" ]; then _bad "$name" "no output at $file"; return 1; fi
    if ! jq -e "$filter" <"$file" >/dev/null 2>&1; then
        _bad "$name" "jq filter failed: $filter  file: $file"
        return 1
    fi
    _ok "$name"
}

have() { command -v "$1" >/dev/null 2>&1; }

require_tool() { # require_tool <binary> <check-name> -> nonzero when missing
    if have "$1"; then return 0; fi
    _skip "$2" "$1 not installed"
    return 1
}

finish() {
    local report="$REPORT_DIR/summary.txt"
    {
        printf 'rea-agent verification\n'
        printf 'run:       %s\n' "$RUN_ID"
        printf 'date:      %s\n' "$(date -u +%FT%TZ)"
        printf 'image:     %s\n' "${REA_IMAGE_ID:-unknown}"
        printf 'platform:  %s\n' "$(uname -srm)"
        printf 'node:      %s\n' "$(node --version 2>/dev/null)"
        printf 'rea:       %s\n' "$(rea --version 2>/dev/null)"
        printf 'passed:    %s\n' "$PASS"
        printf 'failed:    %s\n' "$FAIL"
        printf 'skipped:   %s\n' "$SKIP"
        if [ "$FAIL" -gt 0 ]; then
            printf '\nfailed checks:\n'
            printf '  - %s\n' "${FAILED_NAMES[@]}"
        fi
        if [ "$SKIP" -gt 0 ]; then
            printf '\nskipped checks:\n'
            printf '  - %s\n' "${SKIPPED_NAMES[@]}"
        fi
    } | tee "$report"
    printf '\n%sreport: %s%s\n' "$C_B" "$REPORT_DIR" "$C_0"
    printf 'passed=%s failed=%s skipped=%s\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" -eq 0 ]
}
