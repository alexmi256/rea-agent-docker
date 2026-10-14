#!/usr/bin/env bash
# Phase 3 - target types that do not need a native engine: ELF layout via
# pwntools, .NET via ilspycmd, Apple plists, EVM bytecode, artifact inspection
# and JavaScript/Electron application graphs.
#
# check_rea is release-aware: a command family the installed REA release does
# not expose is SKIPPED rather than failed. 6.5.0 ships the sqlite/wasm/go
# families, so those checks now run for real instead of skipping.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"
WORK_ARTIFACT="$(mktemp -d "${TMPDIR:-/tmp}/rea-verify-artifact.XXXXXX")"

section "ELF layout (pwntools 4.15.0)"
if [ -s "$FIX/fixture-x86_64.elf" ]; then
    check_rea "binary layout: sections and main symbol" inspect-binary-layout "main" \
        -- "$FIX/fixture-x86_64.elf" --json
else
    _skip "binary layout" "fixture missing"
fi

section "artifact inspection"
# A directory is not an open_binary target: REA routes JS/Electron directories
# through analyze rather than the native/artifact path, and only files/bundles
# through inspect-artifact.
if [ -d "$FIX/jsapp/src" ]; then
    check_rea "rea analyze on an application directory" analyze "." -- "$FIX/jsapp" --json
fi
if [ -s "$FIX/bundle.zip" ]; then
    check_rea "inspect-artifact on a zip bundle" inspect-artifact "." -- "$FIX/bundle.zip" --json
    check_rea "extract-artifact on a zip bundle" extract-artifact "." -- "$FIX/bundle.zip" "$WORK_ARTIFACT" --json
fi

section "Apple static formats (platform-scoped in REA)"
# REA routes plists through its Apple-platform composite provider, which is not
# available for this input on Linux: it reports capability_unavailable rather
# than guessing. Recorded as a skip with the reason, not a failure.
if [ -s "$FIX/Info.plist" ]; then
    _skip "plist decode" "REA routes plists through the Apple composite provider (unavailable on Linux for this input)"
fi

section "managed code (.NET / ilspycmd)"
DLL="$FIX/dotnet-app/bin/Release/net8.0/VerifyLib.dll"
if [ -s "$DLL" ]; then
    check_rea "managed artifact identity" inspect-managed-artifact "VerifyLib|ILOnly|Managed" \
        -- "$DLL" --json
    check_rea "managed members include License.Describe" inspect-managed-members "Describe|License" \
        -- "$DLL" --json
    check "ilspycmd decompiles the fixture assembly" "class|License" \
        -- "$REA_ILSPY_CMD_PATH" -t VerifyLib.License "$DLL"
else
    _skip "managed artifact" "fixture missing (needs the .NET SDK build)"
fi

section "EVM bytecode"
if [ -s "$FIX/runtime.hex" ]; then
    check_rea "evm interface selectors" inspect-evm-interface "selector|0x|mutability" \
        -- "$FIX/runtime.hex" hex --json
else
    _skip "evm interface" "fixture missing"
fi

section "JavaScript / Electron application graph"
if [ -d "$FIX/jsapp/src" ]; then
    check_rea "js application graph" analyze-javascript-application "license|exporter|main" \
        -- "$FIX/jsapp" --json
    # Round-trip the saved Evidence the way REA's own CLI guide does:
    #   evidence -> projected summary view -> inspect-analysis-view
    if rea analyze-javascript-application "$FIX/jsapp" --json >"$FIX/app-evidence.json" 2>/dev/null; then
        if jq -c '{source: {kind: "inline", evidence: .}, view: {kind: "summary"}}' \
             "$FIX/app-evidence.json" >"$FIX/app-view.json" 2>/dev/null; then
            check_rea "analysis view projection of saved evidence" inspect-analysis-view "." \
                -- "$FIX/app-view.json"
        else
            _skip "analysis view projection" "could not project the evidence file"
        fi
    else
        _skip "analysis view projection" "analysis did not produce evidence"
    fi
else
    _skip "js application graph" "fixture missing"
fi

section "historical source import"
if [ -d "$FIX/jsapp/src" ]; then
    check_rea "reference source import" import-reference-source "." -- "$FIX/jsapp/src" --json
fi

section "families added in REA 6.5.0"
# These were `main`-only through 6.4.0. check_rea runs them when the installed
# release exposes them and SKIPs otherwise, so this block is forward-compatible.
if [ -s "$FIX/fixture.sqlite" ]; then
    check_rea "sqlite schema + row sample" inspect-sqlite-database "settings|license_requests" \
        -- "$FIX/fixture.sqlite" --table settings --row-limit 5 --json
fi
if [ -s "$FIX/module.wasm" ]; then
    check_rea "wasm artifact: imports/exports and WAT" inspect-wasm-artifact "add|checksum|wasm" \
        -- "$FIX/module.wasm" --format json
fi
if [ -s "$FIX/fixture-x86_64.elf" ]; then
    check_rea "go-binary metadata probe" inspect-go-binary "." \
        -- "$FIX/fixture-x86_64.elf" --json
fi
