#!/usr/bin/env bash
# Phase 3 - target types that do not need a native engine: ELF layout via
# pwntools, WASM via WABT, SQLite, .NET via ilspycmd, Apple plists, EVM
# bytecode, and JavaScript/Electron application graphs.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"

section "ELF layout / crash tooling (pwntools 4.15.0)"
if [ -s "$FIX/fixture-x86_64.elf" ]; then
    check "binary layout: sections and main symbol" "main" \
        -- rea inspect-binary-layout "$FIX/fixture-x86_64.elf" --json
    check "go-binary probe reports non-Go cleanly" "." \
        -- rea inspect-go-binary "$FIX/fixture-x86_64.elf" --json
else
    _skip "binary layout" "fixture missing"
fi

section "WebAssembly (WABT 1.0.42)"
if [ -s "$FIX/module.wasm" ]; then
    check "wasm artifact: imports/exports and WAT" "add|checksum|wasm" \
        -- rea inspect-wasm-artifact "$FIX/module.wasm" --format json
else
    _skip "wasm artifact" "fixture missing"
fi

section "SQLite"
if [ -s "$FIX/fixture.sqlite" ]; then
    check "sqlite schema + row sample" "settings|license_requests" \
        -- rea inspect-sqlite-database "$FIX/fixture.sqlite" --table settings --row-limit 5 --json
else
    _skip "sqlite" "fixture missing"
fi

section "managed code (.NET / ilspycmd)"
DLL="$FIX/dotnet-app/bin/Release/net8.0/VerifyLib.dll"
if [ -s "$DLL" ]; then
    check "managed artifact identity" "VerifyLib|ILOnly|Managed" \
        -- rea inspect-managed-artifact "$DLL" --json
    check "managed members include License.Describe" "Describe|License" \
        -- rea inspect-managed-members "$DLL" --json
else
    _skip "managed artifact" "fixture missing (needs dotnet build)"
fi

section "Apple static formats"
if [ -s "$FIX/Info.plist" ]; then
    check "plist decode" "CFBundleIdentifier|tools.rea.verify" \
        -- rea inspect-plist "$FIX/Info.plist" --json
else
    _skip "plist" "fixture missing"
fi

section "EVM bytecode"
if [ -s "$FIX/runtime.hex" ]; then
    check "evm interface selectors" "selector|0x|mutability" \
        -- rea inspect-evm-interface "$FIX/runtime.hex" hex --json
else
    _skip "evm interface" "fixture missing"
fi

section "JavaScript / Electron application graph"
if [ -d "$FIX/jsapp/src" ]; then
    check "js application graph" "license|exporter|main" \
        -- rea analyze-javascript-application "$FIX/jsapp" --json
    check "js feature trace" "." \
        -- rea trace-application-feature "$FIX/jsapp" '"licence"' --json
else
    _skip "js application graph" "fixture missing"
fi

section "historical source import"
if [ -d "$FIX/jsapp/src" ]; then
    check "reference source import" "." \
        -- rea import-reference-source "$FIX/jsapp/src" --json
fi
