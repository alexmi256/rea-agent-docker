#!/usr/bin/env bash
# Phase 5 - the auxiliary "client" surfaces REA drives: Frida, adb, Apktool,
# JADX, plus the bring-your-own IDA/JEB registrations.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"

section "Frida (JS instrumentation)"
# REA 6.5.0 is the first release to expose the frida family (list-frida-devices,
# list-frida-processes, instrument-with-frida). The binding was already installed
# and functional in this image, so no image change was needed to pick it up.
check "frida binding resolves from REA" "local device|frida" \
    -- bash -c "cd \"\$(npm root -g)/rea-agents\" && node -e 'const f=require(\"frida\");f.getLocalDevice().then(d=>console.log(\"frida local device:\",d.name))'"
if rea --help 2>/dev/null | grep -qi frida; then
    check "rea frida device inventory" "local|device" -- rea list-frida-devices --json
else
    _skip "rea frida commands" "not exposed by REA $(rea --version 2>/dev/null)"
fi
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
if engine_has ida; then
    check "IDADIR mount" "." -- bash -c "ls -ld \"${IDADIR:-/opt/ida}\""
else
    _skip "IDADIR mount" "not in this image (engine: $(image_engine))"
fi

section "JEB provider (bring your own licence)"
if [ -n "${REA_JEB_MCP_URL:-}" ]; then
    check "jeb client inspection" "." -- rea inspect-jeb-client --json
else
    _skip "jeb client" "REA_JEB_MCP_URL not set (bring your own JEB)"
fi

section "Hopper licence/state layout"
# Engine-gated like every other per-engine check: the state directory exists in
# all four images (the Dockerfile creates it), but it only means anything on an
# image that ships Hopper. It is also only stat-able when the container runs as a
# uid that can traverse $HOME - running as a foreign uid is a supported mode (see
# docs/TROUBLESHOOTING.md), so report that as a skip, not a failure.
hopper_statedir="${HOPPER_STATE_DIR:-/home/rea/.local/share/hopper}"
if ! engine_has hopper; then
    _skip "hopper application-support dir" "not in this image (engine: $(image_engine))"
elif ls -ld "$hopper_statedir" >/dev/null 2>&1; then
    check "hopper application-support dir" "." -- bash -c "ls -ld \"$hopper_statedir\""
else
    _skip "hopper application-support dir" \
        "not traversable as uid $(id -u); run with a uid matching the image user (docs/TROUBLESHOOTING.md)"
fi

section "import-export / comparison surface"
if [ -s "$FIX/Info.plist" ]; then
    check "compare command rejects identical artefacts cleanly" "." \
        -- bash -c "rea compare --help >/dev/null && echo ok"
fi
