#!/usr/bin/env bash
# =============================================================================
# rea-agent verification harness - run inside the container:
#
#   docker compose exec rea-agent /opt/rea/verify/verify-all.sh
#   docker run --rm -v "$PWD/work:/work" \
#     ghcr.io/alexmi256/rea-agent-ghidra:6.4.0-linux-amd64 /opt/rea/verify/verify-all.sh --quick
#
# Phases (each writes raw stdout/stderr under <report>/logs):
#   1 tools      tool presence + versions
#   2 analysis   Ghidra across 8 architectures, Hopper demo mode
#   3 static     ELF/WASM/SQLite/.NET/plist/EVM/JS
#   4 capture    pcap, signal, firmware, HAR + mitmproxy, browser, PTY
#   5 clients    frida, adb, apktool, jadx, IDA/JEB registration
#   6 mcp        real MCP client handshake (stdio + HTTP bridge)
#
# Options:  --quick          skip the slow phases (2 and 6's analysis step)
#           --only LIST      comma-separated phases: tools,analysis,static,capture,clients,mcp
#           --no-fixtures    reuse fixtures from an earlier run
# =============================================================================
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ONLY="tools,analysis,static,capture,clients,mcp"
QUICK=0
BUILD_FIXTURES=1
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1; ONLY="tools,static,clients,mcp"; shift ;;
        --only) ONLY="$2"; shift 2 ;;
        --only=*) ONLY="${1#*=}"; shift ;;
        --no-fixtures) BUILD_FIXTURES=0; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# shellcheck source=lib.sh
. "$DIR/lib.sh"

export REA_VERIFY_FIXTURES
export REA_IMAGE_ID="${REA_IMAGE_ID:-$(cat /etc/rea/image-id 2>/dev/null || true)}"
[ "$QUICK" = "1" ] && export REA_VERIFY_MCP_ANALYSIS=0

printf '%srea-agent verification%s  run=%s  out=%s\n' "$C_B" "$C_0" "$RUN_ID" "$REPORT_DIR"

if [ "$BUILD_FIXTURES" = "1" ]; then
    section "fixtures"
    if bash "$DIR/fixtures.sh" 2>&1 | tee "$LOGDIR/fixtures.log"; then :; else
        _bad "fixture generation" "see $LOGDIR/fixtures.log"
    fi
fi

phase_enabled() { case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

for phase in tools analysis static capture clients mcp; do
    if phase_enabled "$phase"; then
        # shellcheck disable=SC1090
        . "$DIR/verify-$phase.sh"
    else
        _skip "phase: $phase" "not selected"
    fi
done

finish
