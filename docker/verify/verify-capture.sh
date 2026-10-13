#!/usr/bin/env bash
# Phase 4 - runtime/capture families: packets, signals, firmware, HTTP captures,
# a real browser through CDP, a Playwright scenario, and PTY process capture.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rea-verify-capture.XXXXXX")"

section "packet captures (tshark 4.x)"
check "pcap client inspection"  "." -- rea inspect-pcap-client --json
if [ -s "$FIX/fixture.pcap" ]; then
    check "pcap capture: udp fields" "REA-VERIFY-PAYLOAD|udp|127.0.0.1" \
        -- rea inspect-packet-capture "$FIX/fixture.pcap" --fields ip.addr --fields udp.port --fields data.data --json
    check "pcap summary" "." -- rea inspect-pcap-capture "$FIX/fixture.pcap" --json
else
    _skip "pcap inspection" "fixture missing"
fi

section "recorded signals (sigrok-cli 0.7.2 + libsigrokdecode)"
check "sigrok decoder inventory" "uart" -- rea inspect-signal-decoders --json
if [ -s "$FIX/uart.vcd" ]; then
    check "vcd UART decode" "R|E|A|uart" \
        -- rea decode-signal-recording "$FIX/uart.vcd" --decoders "uart:rx=rx:baudrate=9600" \
           --input_format vcd --annotations uart=rx_data --format json
else
    _skip "vcd UART decode" "fixture missing"
fi

section "firmware (binwalk 3.1.x + unblob 26.6.x)"
if [ -s "$FIX/firmware.bin" ]; then
    check "firmware regions (binwalk)" "gzip|Zip|zlib|GZIP" \
        -- rea inspect-firmware-regions "$FIX/firmware.bin" --json
    check "firmware extraction (unblob)" "extract|gzip|manifest" \
        -- rea extract-firmware "$FIX/firmware.bin" "$WORK/fw-out" --json
else
    _skip "firmware" "fixture missing"
fi

section "HTTP captures"
if [ -s "$FIX/session.har" ]; then
    check "HAR 1.2 capture" "entitlements|200|demo" \
        -- rea inspect-web-network-capture "$FIX/session.har" har --json
else
    _skip "HAR capture" "fixture missing"
fi

# Native mitmproxy capture: record a real request through mitmdump, then decode.
if command -v python3 >/dev/null 2>&1 && [ -x "${REA_MITMDUMP_COMMAND:-}" ]; then
    python3 -m http.server 8099 --directory "$WORK" >"$WORK/httpd.log" 2>&1 &
    echo $! >"$WORK/httpd.pid"
    sleep 1
    "$REA_MITMDUMP_COMMAND" -q -w "$WORK/session.mitm" --set confdir="$WORK/mitm" --listen-port 8098 \
        >"$WORK/mitmdump.log" 2>&1 &
    echo $! >"$WORK/mitmdump.pid"
    sleep 5
    curl -sS -k -x http://127.0.0.1:8098 "http://127.0.0.1:8099/" -o /dev/null 2>>"$WORK/curl.log" || true
    sleep 2
    kill "$(cat "$WORK/mitmdump.pid")" 2>/dev/null || true
    kill "$(cat "$WORK/httpd.pid")" 2>/dev/null || true
    sleep 1
    if [ -s "$WORK/session.mitm" ]; then
        check "native mitmproxy capture decode" "8099|GET|127.0.0.1" \
            -- rea inspect-web-network-capture "$WORK/session.mitm" mitmproxy --json
    else
        _skip "native mitmproxy capture decode" "mitmdump produced no capture (see $WORK/mitmdump.log)"
    fi
else
    _skip "native mitmproxy capture decode" "mitmdump missing"
fi

section "browser: CDP observation"
BROWSER_BIN="$(command -v google-chrome || command -v chromium || true)"
if [ -n "$BROWSER_BIN" ] && [ -s "$FIX/www/index.html" ]; then
    "$BROWSER_BIN" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --user-data-dir="$WORK/chrome-profile" --remote-debugging-port=9222 \
        "file://$FIX/www/index.html" >"$WORK/chrome.log" 2>&1 &
    echo $! >"$WORK/chrome.pid"
    for _ in $(seq 1 20); do
        curl -fsS http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break
        sleep 1
    done
    check "browser target discovery (CDP)" "targetId|page|json" \
        -- rea list-browser-targets http://127.0.0.1:9222 --json
    target_id="$(curl -fsS http://127.0.0.1:9222/json/list 2>/dev/null | jq -r '[.[] | select(.type=="page")][0].id // empty')"
    if [ -n "$target_id" ]; then
        check "browser page capture (DOM/scripts)" "REA verify fixture|results|search" \
            -- rea inspect-web-page http://127.0.0.1:9222 "$target_id" --json
        check "browser screenshot capture" "." \
            -- rea capture-web-screenshot http://127.0.0.1:9222 "$target_id" --json
    else
        _skip "browser page capture" "no page target exposed"
    fi
    kill "$(cat "$WORK/chrome.pid")" 2>/dev/null || true
else
    _skip "browser CDP observation" "no Chrome-family browser installed"
fi

section "browser: Playwright scenario"
if [ -s "$FIX/browser-scenario.json" ] && [ -d /opt/ms-playwright ]; then
    check "playwright launch + click + DOM capture" "results|licence found|ready" \
        -- rea capture-browser-scenario "$FIX/browser-scenario.json" --json
else
    _skip "playwright scenario" "playwright browsers or fixture missing"
fi

section "process behaviour capture (native PTY)"
if [ -s "$FIX/process-scenario.json" ]; then
    check "pty process capture" "rea-verify process capture" \
        -- rea capture-process "$FIX/process-scenario.json" --json
else
    _skip "pty process capture" "fixture missing"
fi

rm -rf "$WORK" 2>/dev/null || true
