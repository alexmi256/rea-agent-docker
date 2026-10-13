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
for t in fixture-x86_64.elf:linux-x86_64 \
         fixture-aarch64.elf:linux-aarch64 \
         fixture-armv7.elf:linux-armv7 \
         fixture-mips.elf:linux-mips32-be \
         fixture-mipsel.elf:linux-mips32-le \
         fixture-riscv64.elf:linux-riscv64 \
         fixture-ppc.elf:linux-powerpc \
         fixture-win64.exe:windows-pe-x64; do
    file="${t%%:*}"; label="${t##*:}"
    if [ ! -s "$FIX/$file" ]; then _skip "ghidra analyze $label" "fixture missing"; continue; fi
    if command -v timeout >/dev/null 2>&1; then
        check_json "ghidra analyze $label" '[.. | strings] | join(" ") | test("reverse-me|checksum|main")' \
            -- timeout "$TIMEOUT_SECONDS" rea analyze "$FIX/$file" --provider ghidra --json
    else
        check_json "ghidra analyze $label" '[.. | strings] | join(" ") | test("reverse-me|checksum|main")' \
            -- rea analyze "$FIX/$file" --provider ghidra --json
    fi
done

section "ghidra: function and decompiler output"
check_json "ghidra function main (x86_64)" 'true' -- rea function "$TARGET" main --provider ghidra --json
check "ghidra decompile main mentions the fixture strings" "reverse-me|checksum|printf" \
    -- rea decompile "$TARGET" main --provider ghidra --json
check "ghidra string search finds the literal" "reverse-me" \
    -- rea search "$TARGET" "reverse-me" --provider ghidra --json
check "ghidra instructions at entry" "true" \
    -- rea instructions "$TARGET" 0x1000 --provider ghidra --json

section "hopper: headless demo analysis"
if [ -x "${HOPPER_LAUNCHER_PATH:-/nonexistent}" ]; then
    HOPPER_TIMEOUT_SECONDS="${REA_VERIFY_HOPPER_TIMEOUT:-600}"
    if command -v timeout >/dev/null 2>&1; then
        check "hopper analyze x86_64" "reverse-me|checksum|printf|main" \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea analyze "$FIX/fixture-x86_64.elf" --provider hopper --json
        check "hopper decompile main" "reverse-me|checksum|printf" \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea decompile "$FIX/fixture-x86_64.elf" main --provider hopper --json
        check "hopper string search" "reverse-me" \
            -- timeout "$HOPPER_TIMEOUT_SECONDS" rea search "$FIX/fixture-x86_64.elf" "reverse-me" --provider hopper --json
    else
        check "hopper analyze x86_64" "reverse-me|checksum|printf|main" \
            -- rea analyze "$FIX/fixture-x86_64.elf" --provider hopper --json
    fi
else
    _skip "hopper analysis" "no Hopper launcher (bring your own licence)"
fi

section "provider capabilities"
check "providers listing"  "." -- rea providers --json
check "capabilities listing" "." -- rea capabilities --json
