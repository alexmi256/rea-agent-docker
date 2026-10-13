#!/usr/bin/env bash
# Phase 3 - target types that do not need a native engine: ELF layout via
# pwntools, .NET via ilspycmd, Apple plists, EVM bytecode, artifact inspection
# and JavaScript/Electron application graphs.
#
# check_rea is release-aware: command families the installed REA release does
# not expose (they exist on repository main, e.g. sqlite/wasm/go in 6.4.0) are
# SKIPPED rather than failed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"

section "ELF layout (pwntools 4.15.0)"
if [ -s "$FIX/fixture-x86_64.elf" ]; then
    check_rea "binary layout: sections and main symbol" inspect-binary-layout "main" \
        -- "$FIX/fixture-x86_64.elf" --json
else
    _skip "binary layout" "fixture missing"
fi

section "artifact inspection"
if [ -d "$FIX/jsapp" ]; then
    check_rea "inspect-artifact on an application directory" inspect-artifact "package.json|src|jsapp|artifact" \
        -- "$FIX/jsapp" --json
fi
if [ -s "$FIX/session.har" ]; then
    check_rea "inspect-artifact on an archive-like file" inspect-artifact "." -- "$FIX/session.har" --json
fi

section "Apple static formats"
if [ -s "$FIX/Info.plist" ]; then
    check_rea "plist decode" inspect-plist "CFBundleIdentifier|tools.rea.verify" -- "$FIX/Info.plist" --json
else
    _skip "plist" "fixture missing"
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

section "families not in this REA release (informational)"
# These execute when the installed release exposes them, and SKIP otherwise.
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
