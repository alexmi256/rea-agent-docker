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
    # REA 6.8.0 narrowed extract-artifact to a single positional path and picks
    # the destination itself (`output_root` in the result); a second positional
    # is refused outright. Assert the extraction rather than the exit status:
    # containment verified, coverage complete, cleanup accounted for, every
    # reported file non-empty - and then that those files exist on disk.
    check_rea_json "extract-artifact on a zip bundle" extract-artifact \
        '(.normalized_result.containment_verified == true)
         and (.normalized_result.coverage.status == "complete")
         and (.normalized_result.cleanup.verified == true)
         and ((.normalized_result.artifacts | length) > 0)
         and (([.normalized_result.artifacts[]
                | select(.created == true and .bytes_written > 0)] | length)
              == (.normalized_result.artifacts | length))' \
        -- "$FIX/bundle.zip" --json
    extract_out="$LOGDIR/extract-artifact_on_a_zip_bundle.out"
    if [ -s "$extract_out" ]; then
        extract_root="$(jq -r '.normalized_result.output_root // empty' "$extract_out")"
        extract_missing="$(jq -r '.normalized_result.artifacts[].relative_path' "$extract_out" \
            | while read -r rel; do [ -f "$extract_root/$rel" ] || printf '%s ' "$rel"; done)"
        if [ -n "$extract_root" ] && [ -z "$extract_missing" ]; then
            _ok "extracted files exist under the reported output_root"
        else
            _bad "extracted files exist under the reported output_root" \
                 "root=${extract_root:-<none>} missing=${extract_missing:-<none>}"
        fi
    fi
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

section "JavaScript source recovery (Wakaru)"
# REA's own documented chain: recover readable modules from a minified bundle,
# then analyse the recovered tree. The assertions are on schema fields (provider,
# status, per-module status, the fingerprinted executable digest) rather than on
# incidental text, and the digest proves REA ran the audited asset this image pins.
if [ -s "$FIX/jsbundle/bundle.min.js" ]; then
    rm -rf "$FIX/recovered"
    if rea recover-javascript-sources "$FIX/jsbundle/bundle.min.js" "$FIX/recovered" \
           --json >"$FIX/recovery.json" 2>"$FIX/recovery.err"; then
        check_json_file "js recovery: provider is Wakaru" '.provider.id == "wakaru"' "$FIX/recovery.json"
        check_json_file "js recovery: reported version" '.provider.version | startswith("1.14")' "$FIX/recovery.json"
        check_json_file "js recovery: completed with no failures" \
            '.normalized_result.status == "complete" and .normalized_result.failed == 0' "$FIX/recovery.json"
        check_json_file "js recovery: bundle decompiled into a module" \
            '.normalized_result.modules[0].reported_status == "decompiled"' "$FIX/recovery.json"
        check_json_file "js recovery: REA fingerprinted the audited Wakaru build" \
            '.normalized_result.engine.executable.sha256 == "664fa06782a61eda7ed15885134b52525fd565dd77607e642062ceb6cd927c38"' \
            "$FIX/recovery.json"
        check "js recovery: published module file is non-empty" "." \
            -- bash -c "test -s \"$FIX/recovered/modules/bundle.js\" && wc -c <\"$FIX/recovered/modules/bundle.js\""
        check "js recovery: evidence keeps its limitations" "derived artifacts" \
            -- bash -c "jq -r '.normalized_result.limitations[0]' \"$FIX/recovery.json\""
        # recovered modules are a usable analysis input, which is the point of the
        # operation - analyse them with the same tool the jsapp fixture uses
        check_rea "analysis of the recovered module tree" analyze-javascript-application "." \
            -- "$FIX/recovered/modules" --json
    else
        _bad "js source recovery" "recover-javascript-sources exited non-zero; see $FIX/recovery.err"
    fi
else
    _skip "js source recovery" "fixture missing"
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
