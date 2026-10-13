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

# --- engine awareness --------------------------------------------------------
# Each image declares the engine(s) it ships in /usr/local/share/rea/engine
# (written at build time from the REA_ENGINE build arg; /usr/local/share, not
# /etc/rea, because compose mounts the user's ./config over /etc/rea). Checks for
# an engine the image does not carry are SKIPped, so one harness serves all four
# images.
image_engine() { cat /usr/local/share/rea/engine 2>/dev/null || echo all; }
engine_has() { # engine_has ghidra|hopper|ida
    local e; e="$(image_engine)"
    [ "$e" = "all" ] || [ "$e" = "$1" ]
}

# Default the MCP probe's provider to whatever this image ships, and switch off
# its native-analysis step when the image has no engine (engine=ida with no IDA
# registration) - the handshake itself must still be verified there.
case "$(image_engine)" in
    ghidra) export REA_VERIFY_PROVIDER="${REA_VERIFY_PROVIDER:-ghidra}" ;;
    hopper) export REA_VERIFY_PROVIDER="${REA_VERIFY_PROVIDER:-hopper}" ;;
    all)    export REA_VERIFY_PROVIDER="${REA_VERIFY_PROVIDER:-ghidra}" ;;
    ida)
        if [ -n "${REA_IDA_MCP_CONFIG:-}" ]; then
            export REA_VERIFY_PROVIDER="${REA_VERIFY_PROVIDER:-ida}"
        else
            export REA_VERIFY_MCP_ANALYSIS=0
        fi
        ;;
esac

# Adopt this image's engine paths for the harness's own checks, exactly as the
# `rea` wrapper does for REA. Without this, a single-engine image would leave the
# other engine's variables unset and `set -u` would abort the phase instead of
# skipping it. The defaults below exist only so an unguarded reference can never
# abort; every use is behind engine_has, so a path for an absent engine is never
# actually asserted on.
if [ -r /usr/local/share/rea/engine.env ]; then
    set -a
    # shellcheck disable=SC1091
    . /usr/local/share/rea/engine.env
    set +a
fi
: "${GHIDRA_INSTALL_DIR:=/opt/ghidra}"
: "${HOPPER_LAUNCHER_PATH:=/opt/hopper/bin/Hopper}"
: "${IDADIR:=/opt/ida}"

# --- release-aware helpers ---------------------------------------------------
# REA's catalog differs between the npm release and repository main (main is
# ahead: sqlite/wasm/go/pcap/signal/frida families are not in 6.4.0). A family
# the installed release does not expose is reported as SKIP, never FAIL, so the
# harness stays useful across REA upgrades.
rea_commands() {
    if [ -z "${REA_COMMAND_LIST:-}" ]; then
        REA_COMMAND_LIST="$(rea --help 2>/dev/null | sed -n '/^Commands:/,$p' | awk '{print $1}')"
    fi
    printf '%s\n' "$REA_COMMAND_LIST"
}
rea_has_command() { rea_commands | grep -qx "$1"; }

# check_rea <check-name> <rea-command> <grep-pattern> -- <args...>
check_rea() {
    local name="$1" cmd="$2" pattern="$3"; shift 3
    [ "${1:-}" = "--" ] && shift
    if ! rea_has_command "$cmd"; then
        _skip "$name" "rea $cmd is not in REA $(rea --version 2>/dev/null) (present on main)"
        return 0
    fi
    check "$name" "$pattern" -- rea "$cmd" "$@"
}

# check_rea_json <check-name> <rea-command> <jq-filter> -- <args...>
check_rea_json() {
    local name="$1" cmd="$2" filter="$3"; shift 3
    [ "${1:-}" = "--" ] && shift
    if ! rea_has_command "$cmd"; then
        _skip "$name" "rea $cmd is not in REA $(rea --version 2>/dev/null)"
        return 0
    fi
    check_json "$name" "$filter" -- rea "$cmd" "$@"
}

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
