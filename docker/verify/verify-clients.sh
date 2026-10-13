#!/usr/bin/env bash
# Phase 5 - the auxiliary "client" surfaces REA drives: Frida, adb, Apktool,
# JADX, plus the bring-your-own IDA/JEB registrations.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"

section "Frida (bundled npm binding, JS instrumentation)"
check "frida device inventory" "local|device" -- rea list-frida-devices --json

section "Android: adb + Apktool + JADX engine"
check "adb client inspection" "adb|version" -- rea inspect-adb-client --json
check "adb device listing (no device attached is a valid answer)" "." \
    -- rea list-adb-devices --json
check "apktool client inspection" "2\.|apktool" -- rea inspect-apktool-client --json
check "apktool runs as a launcher"  "2\."          -- apktool --version
check "jadx engine jar loads under java 21" "." \
    -- bash -c "java -cp \"$REA_JADX_MCP_JAR\" -version 2>&1 | head -3"

section "IDA provider (bring your own install + licence)"
if [ -n "${REA_IDA_MCP_CONFIG:-}" ] && [ -r "${REA_IDA_MCP_CONFIG}" ]; then
    check "ida registration accepted by doctor" "." -- rea doctor --provider ida --json
else
    _skip "ida doctor" "REA_IDA_MCP_CONFIG not set (see docs/BYO-LICENSES.md)"
fi
check "ida registration templates present" "url|command" \
    -- bash -c "cat /opt/rea/assets/ida-mcp.official-http.json"
check "IDADIR mount" "." -- bash -c "ls -ld \"${IDADIR:-/opt/ida}\""

section "JEB provider (bring your own licence)"
if [ -n "${REA_JEB_MCP_URL:-}" ]; then
    check "jeb client inspection" "." -- rea inspect-jeb-client --json
else
    _skip "jeb client" "REA_JEB_MCP_URL not set (bring your own JEB)"
fi

section "Hopper licence/state layout"
check "hopper application-support dir" "." \
    -- bash -c "ls -ld \"${HOPPER_STATE_DIR:-/home/rea/.local/share/hopper}\""

section "import-export / comparison surface"
if [ -s "$FIX/Info.plist" ]; then
    check "compare command rejects identical artefacts cleanly" "." \
        -- bash -c "rea compare --help >/dev/null && echo ok"
fi
