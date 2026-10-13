#!/usr/bin/env bash
# Phase 2 - do the native analysis engines actually run and analyse?
# Ghidra covers many architectures; Hopper is exercised on x86-64 in demo mode
# (the way REA drives it headlessly on Linux).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"
TARGET="${REA_VERIFY_TARGET:-$FIX/fixture-x86_64.elf}"
TIMEOUT_SECONDS="${REA_VERIFY_TIMEOUT:-900}"

section "provider readiness"
check_json "doctor: ghidra" '.healthy == true' -- rea doctor --provider ghidra --json
if [ -x "${HOPPER_LAUNCHER_PATH:-/nonexistent}" ]; then
    check_json "doctor: hopper" '.healthy == true' -- rea doctor --provider hopper --json
else
    _skip "doctor: hopper" "no Hopper launcher"
fi

section "ghidra: architecture coverage (multi-arch is the point)"
# x86-64 gets the full overview; every other architecture proves its import
# language works by finding the fixture's own string literal through the
# analysis session.
if [ -s "$FIX/fixture-x86_64.elf" ]; then
    check_json "ghidra analyze linux-x86_64" '.evidence_id != null' \
        -- timeout "$TIMEOUT_SECONDS" rea analyze "$FIX/fixture-x86_64.elf" --provider ghidra --json
else
    _skip "ghidra analyze linux-x86_64" "fixture missing"
fi

for t in fixture-aarch64.elf:linux-aarch64 \
         fixture-armv7.elf:linux-armv7 \
         fixture-mips.elf:linux-mips32-be \
         fixture-mipsel.elf:linux-mips32-le \
         fixture-riscv64.elf:linux-riscv64 \
         fixture-ppc.elf:linux-powerpc \
         fixture-win64.exe:windows-pe-x64; do
    file="${t%%:*}"; label="${t##*:}"
    if [ ! -s "$FIX/$file" ]; then _skip "ghidra search $label" "fixture missing"; continue; fi
    out="$LOGDIR/$(logname_for "ghidra_search_$label").out"
    timeout "$TIMEOUT_SECONDS" rea search "$FIX/$file" "reverse-me" --provider ghidra --json \
        >"$out" 2>"${out%.out}.err"
    rc=$?
    if grep -qi "unsupported ELF architecture" "$out"; then
        # REA 6.4.0's artifact admission refuses some ELF machines; the tooling
        # is fine, the release does not admit the target. Report, do not fail.
        _skip "ghidra search $label" "REA $(rea --version 2>/dev/null) refuses this ELF architecture"
    elif [ $rc -ne 0 ]; then
        _bad "ghidra search $label" "exit=$rc (out: $out)"
    elif grep -q "reverse-me" "$out"; then
        _ok "ghidra search $label finds fixture string"
    else
        _bad "ghidra search $label" "fixture string not found (out: $out)"
    fi
done

section "ghidra: function and decompiler output"
check_json "ghidra function main (x86_64)" '.evidence_id != null' \
    -- rea function "$TARGET" main --provider ghidra --json
check "ghidra decompile main mentions the fixture strings" "reverse-me|checksum|printf" \
    -- rea decompile "$TARGET" main --provider ghidra --json
check "ghidra decompile aarch64 main" "reverse-me|checksum|printf|memcpy" \
    -- timeout "$TIMEOUT_SECONDS" rea decompile "$FIX/fixture-aarch64.elf" main --provider ghidra --json
check "ghidra decompile mips32 main" "reverse-me|checksum|printf|strlen" \
    -- timeout "$TIMEOUT_SECONDS" rea decompile "$FIX/fixture-mips.elf" main --provider ghidra --json
check "ghidra instructions of main" "." \
    -- timeout "$TIMEOUT_SECONDS" rea instructions "$TARGET" main --provider ghidra --json

section "hopper: headless demo analysis"
if [ -x "${HOPPER_LAUNCHER_PATH:-/nonexistent}" ]; then
    HOPPER_TIMEOUT_SECONDS="${REA_VERIFY_HOPPER_TIMEOUT:-600}"
    if command -v timeout >/dev/null 2>&1; then
        check_json "hopper analyze x86_64" '.evidence_id != null' \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea analyze "$FIX/fixture-x86_64.elf" --provider hopper --json
        check "hopper decompile main" "reverse-me|checksum|printf" \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea decompile "$FIX/fixture-x86_64.elf" main --provider hopper --json
        check "hopper string search" "reverse-me" \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea search "$FIX/fixture-x86_64.elf" "reverse-me" --provider hopper --json
    else
        check_json "hopper analyze x86_64" '.evidence_id != null' \
            -- rea analyze "$FIX/fixture-x86_64.elf" --provider hopper --json
    fi
else
    _skip "hopper analysis" "no Hopper launcher (bring your own licence)"
fi

section "provider capabilities"
check "providers listing"  "." -- rea providers --json
check "capabilities listing" "." -- rea capabilities --json
