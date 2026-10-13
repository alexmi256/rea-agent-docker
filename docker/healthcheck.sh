#!/usr/bin/env bash
# =============================================================================
# rea-agent container healthcheck
#
# Fast, read-only: verifies the REA runtime, its host prerequisites and the
# analysis engines it is expected to expose. Set REA_HEALTHCHECK_DEEP=1 to add
# `rea doctor --provider ghidra --json` (validates the Ghidra/JDK install).
# =============================================================================
set -uo pipefail

fail() { printf 'unhealthy: %s\n' "$*" >&2; exit 1; }

command -v rea  >/dev/null 2>&1 || fail "rea is not on PATH"
command -v node >/dev/null 2>&1 || fail "node is not on PATH"

# The image declares which engine(s) it ships; only those are required here.
engine="$(cat /etc/rea/engine 2>/dev/null || echo all)"
case "$engine" in
    all|ghidra)
        [ -x "${GHIDRA_INSTALL_DIR:-/opt/ghidra}/support/analyzeHeadless" ] || fail "engine=$engine but Ghidra is missing at ${GHIDRA_INSTALL_DIR:-/opt/ghidra}"
        command -v java >/dev/null 2>&1 || fail "engine=$engine but java is not on PATH"
        ;;
esac
case "$engine" in
    all|hopper)
        [ -x "${HOPPER_LAUNCHER_PATH:-/opt/hopper/bin/Hopper}" ] || fail "engine=$engine but the Hopper launcher is missing"
        ;;
esac
case "$engine" in
    all|ida)
        [ -d "${IDADIR:-/opt/ida}" ] || fail "engine=$engine but IDADIR=${IDADIR:-/opt/ida} does not exist"
        ;;
esac

version="$(rea --version 2>/dev/null)" || fail "rea --version failed"
[ -n "$version" ] || fail "rea --version produced no output"

node -e '
const [maj, min] = process.versions.node.split(".").map(Number);
const ok = (maj === 22 && min >= 19) || (maj === 24 && min >= 11) || maj >= 26;
process.exit(ok ? 0 : 1);
' || fail "Node.js $(node --version) is not a version REA supports"

[ -x "${GHIDRA_INSTALL_DIR:-/opt/ghidra}/support/analyzeHeadless" ] || fail "Ghidra is not installed at ${GHIDRA_INSTALL_DIR:-/opt/ghidra}"
[ -x "${GHIDRA_INSTALL_DIR:-/opt/ghidra}/Ghidra/Features/Decompiler/os/linux_x86_64/decompile" ] || fail "Ghidra native decompiler missing"
command -v java >/dev/null 2>&1 || fail "java is not on PATH"
[ -x "${HOPPER_LAUNCHER_PATH:-/opt/hopper/bin/Hopper}" ] || fail "Hopper launcher missing at ${HOPPER_LAUNCHER_PATH:-/opt/hopper/bin/Hopper}"

# Provider discovery exercises REA's own engine detection (no target needed).
rea providers --json >/dev/null 2>&1 || fail "rea providers failed"

if [ "${REA_HEALTHCHECK_DEEP:-0}" = "1" ]; then
    case "$engine" in
        all|ghidra) rea doctor --provider ghidra --json >/dev/null 2>&1 || fail "rea doctor --provider ghidra reported a problem" ;;
        hopper)     rea doctor --provider hopper  --json >/dev/null 2>&1 || fail "rea doctor --provider hopper reported a problem" ;;
        ida)        [ -n "${REA_IDA_MCP_CONFIG:-}" ] || fail "engine=ida but REA_IDA_MCP_CONFIG is not set" ;;
    esac
fi

printf 'healthy: rea %s on node %s (engine: %s)\n' "$version" "$(node --version)" "$engine"
