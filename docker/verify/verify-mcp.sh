#!/usr/bin/env bash
# Phase 6 - the contract that matters for the end goal: the container's MCP
# surface answers a real client over stdio (exactly how Hermes drives it) and
# optionally over the Streamable HTTP bridge.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

section "MCP over stdio (docker exec / subprocess)"
probe="$LOGDIR/mcp-probe.json"
if node "$DIR/mcp-probe.mjs" >"$probe" 2>"$LOGDIR/mcp-probe.err"; then
    count="$(jq -r '.tools.count' "$probe" 2>/dev/null)"
    if [ "${count:-0}" -gt 50 ]; then
        _ok "mcp initialize + tools/list ($count tools)"
    else
        _bad "mcp tools/list" "only ${count:-0} tools advertised (see $probe)"
    fi
    if jq -e '[.steps | to_entries[] | select(.key|startswith("tools/call:")) | select(.value.isError == false and (.value.bytes // 0) > 0)] | length > 0' "$probe" >/dev/null 2>&1; then
        _ok "mcp tools/call: engine-free tool returned data"
    else
        _bad "mcp tools/call: engine-free tool" "see $probe"
    fi
    key="$(jq -r '.steps | keys[] | select(startswith("tools/call:open_binary"))' "$probe" 2>/dev/null | head -1)"
    if [ -n "$key" ] && jq -e --arg k "$key" '.steps[$k].isError == false' "$probe" >/dev/null 2>&1; then
        _ok "mcp open_binary via ${REA_VERIFY_PROVIDER:-ghidra}"
        if jq -e '[.steps | to_entries[] | select(.key|startswith("tools/call:analyze_function")) | .value.isError == false] | all' "$probe" >/dev/null 2>&1; then
            _ok "mcp analyze_function via ${REA_VERIFY_PROVIDER:-ghidra}"
        else
            _bad "mcp analyze_function" "see $probe"
        fi
    else
        _skip "mcp open_binary/analyze_function" "disabled or fixture missing"
    fi
else
    _bad "mcp initialize/tools handshake" "see $LOGDIR/mcp-probe.json and $LOGDIR/mcp-probe.err"
fi

section "MCP over Streamable HTTP (supergateway bridge)"
if [ "${REA_VERIFY_HTTP:-1}" != "1" ]; then
    _skip "http bridge" "REA_VERIFY_HTTP=0"
elif ! command -v supergateway >/dev/null 2>&1; then
    _skip "http bridge" "supergateway not installed"
else
    log="$LOGDIR/supergateway.log"
    supergateway --stdio "rea mcp" --outputTransport streamableHttp --port 8811 --host 127.0.0.1 \
        >"$log" 2>&1 &
    sg_pid=$!
    ready=0
    for _ in $(seq 1 30); do
        if curl -fsS -o /dev/null -X POST http://127.0.0.1:8811/mcp \
              -H 'content-type: application/json' \
              -H 'accept: application/json, text/event-stream' \
              -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' 2>/dev/null; then
            ready=1; break
        fi
        sleep 1
    done
    if [ "$ready" = "1" ]; then
        body="$(curl -fsS -X POST http://127.0.0.1:8811/mcp \
          -H 'content-type: application/json' \
          -H 'accept: application/json, text/event-stream' \
          -d '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' 2>&1)"
        if printf '%s' "$body" | grep -qE '"result"|serverInfo|rea'; then
            _ok "http bridge initialize"
        else
            _bad "http bridge initialize" "unexpected body: $(printf '%s' "$body" | head -c 200)"
        fi
    else
        _bad "http bridge startup" "no response on 127.0.0.1:8811 (see $log)"
    fi
    kill "$sg_pid" 2>/dev/null || true
    wait "$sg_pid" 2>/dev/null || true
fi
