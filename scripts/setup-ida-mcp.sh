#!/usr/bin/env bash
# =============================================================================
# Wire an IDA MCP server into REA. Run inside the rea-agent container:
#
#   docker compose exec rea-agent /opt/rea/scripts/setup-ida-mcp.sh <mode>
#
# Modes
#   idalib          headless idalib supervisor (mrexodia/ida-pro-mcp).
#                   IDA Pro / IDA Home only - IDA Free has no idalib. This is
#                   the profile REA's IDA adapter was verified against.
#   official        official Hex-Rays MCP (`uv tool install ida-mcp`), stdio.
#                   Requires IDA 9.4+ with idalib.
#   official-http   official Hex-Rays MCP served over Streamable HTTP on
#                   loopback; useful to share one IDA instance.
#   attached        an IDA GUI with ida-pro-mcp 1.4.0 legacy tools is already
#                   open on the target (Windows-verified upstream shape).
#   native          ida-free-mcp native plugin over HTTP (IDA Free, attached).
#   sidecar         an IDA MCP server reachable elsewhere; REA reaches it on
#                   127.0.0.1 through REA_IDA_MCP_FORWARD (see compose.ida.yml).
#
# The script only writes a registration file and reports what REA thinks of it;
# it never activates, installs or licenses IDA itself.
# =============================================================================
set -euo pipefail

MODE="${1:-}"
IDA_REG_DIR="${HOME:-/home/rea}/.rea"
IDA_REG_FILE="${REA_IDA_MCP_CONFIG:-$IDA_REG_DIR/ida-mcp.json}"
IDALIB_WORKERS="${IDA_MCP_MAX_WORKERS:-1}"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

require_ida() {
    local dir="${IDADIR:-/opt/ida}"
    if [ ! -d "$dir" ]; then
        echo "IDADIR=$dir does not exist. Bind-mount your IDA installation first" >&2
        echo "(IDA_INSTALL_DIR in .env / compose.ida.yml)." >&2
        exit 1
    fi
    echo "IDADIR=$dir"
    ls "$dir" | head -20
}

write_registration() {
    mkdir -p "$(dirname "$IDA_REG_FILE")"
    cat >"$IDA_REG_FILE"
    echo "wrote $IDA_REG_FILE"
    chmod 0600 "$IDA_REG_FILE"
}

report() {
    echo
    echo "Registration to give REA:"
    echo "  REA_IDA_MCP_CONFIG=$IDA_REG_FILE"
    echo "  REA_ANALYSIS_PROVIDER=ida"
    echo
    echo "Checking with REA (this never starts IDA):"
    rea doctor --provider ida --json 2>&1 | head -60 || true
    echo
    echo "When a target is opened, REA verifies the upstream tool profile against"
    echo "its expected shape; unsupported profiles are reported rather than guessed."
}

case "$MODE" in
    idalib)
        require_ida
        if ! command -v idalib-mcp >/dev/null 2>&1; then
            echo "idalib-mcp not found; installing ida-pro-mcp with uv..."
            uv tool install ida-pro-mcp
        fi
        write_registration <<EOF
{
  "command": "idalib-mcp",
  "args": ["--stdio", "--max-workers", "$IDALIB_WORKERS"],
  "mode": "headless",
  "env": { "IDADIR": "${IDADIR:-/opt/ida}" }
}
EOF
        report
        ;;
    official)
        require_ida
        uv tool install ida-mcp
        write_registration <<EOF
{
  "command": "ida-mcp",
  "args": ["stdio", "--agent=rea-agent"],
  "mode": "headless",
  "env": { "IDADIR": "${IDADIR:-/opt/ida}" }
}
EOF
        report
        ;;
    official-http)
        require_ida
        uv tool install ida-mcp
        write_registration <<'EOF'
{
  "url": "http://127.0.0.1:8737/mcp",
  "mode": "headless"
}
EOF
        echo "Start the server side yourself, e.g.:"
        echo "  ida-mcp http --host 127.0.0.1 --port 8737 &"
        report
        ;;
    attached)
        write_registration <<'EOF'
{
  "command": "python3",
  "args": ["/opt/ida-pro-mcp/server.py", "--ida-rpc", "http://127.0.0.1:13337"],
  "mode": "attached"
}
EOF
        echo "Reminder: the ORIGINAL input binary must be given to REA (not an"
        echo ".idb/.i64 database) and its SHA-256 must match IDA's recorded input."
        report
        ;;
    native)
        write_registration <<'EOF'
{
  "mode": "attached",
  "protocol": "native",
  "url": "http://127.0.0.1:13337/mcp"
}
EOF
        echo "Reminder: ida-free-mcp binds 0.0.0.0 with no listen-address option -"
        echo "restrict it with the host firewall or a loopback-only build."
        report
        ;;
    sidecar)
        write_registration <<EOF
{
  "url": "http://127.0.0.1:${REA_IDA_MCP_LOCAL_PORT:-8745}/mcp",
  "mode": "headless"
}
EOF
        echo "Set REA_IDA_MCP_FORWARD=<host>:<port> so the entrypoint publishes the"
        echo "remote IDA MCP onto 127.0.0.1:${REA_IDA_MCP_LOCAL_PORT:-8745} inside this container."
        report
        ;;
    ""|-h|--help|help) usage ;;
    *) echo "unknown mode: $MODE" >&2; usage ;;
esac
