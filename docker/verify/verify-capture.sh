#!/usr/bin/env bash
# Phase 4 - runtime/capture families: firmware, HTTP captures, a real browser
# through CDP, a Playwright scenario, and PTY process capture. Packet and signal
# families are attempted as well and SKIPPED when the installed REA release does
# not expose them (they are on repository main, not in 6.4.0).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

FIX="$REA_VERIFY_FIXTURES"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/rea-verify-capture.XXXXXX")"

section "firmware (binwalk 3.1.x + unblob 26.6.x)"
if [ -s "$FIX/firmware.bin" ]; then
    check_rea "firmware regions (binwalk)" inspect-firmware-regions "gzip|Zip|zlib|GZIP" \
        -- "$FIX/firmware.bin" --json
    check_rea "firmware extraction (unblob)" extract-firmware "extract|gzip|manifest" \
        -- "$FIX/firmware.bin" "$WORK/fw-out" --json
else
    _skip "firmware" "fixture missing"
fi

section "HTTP captures"
if [ -s "$FIX/session.har" ]; then
    check_rea "HAR 1.2 capture" inspect-web-network-capture "entitlements|200|demo" \
        -- "$FIX/session.har" har --json
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
    sleep 6
    curl -sS -k -x http://127.0.0.1:8098 "http://127.0.0.1:8099/" -o /dev/null 2>>"$WORK/curl.log" || true
    sleep 2
    kill "$(cat "$WORK/mitmdump.pid")" 2>/dev/null || true
    kill "$(cat "$WORK/httpd.pid")" 2>/dev/null || true
    sleep 1
    if [ -s "$WORK/session.mitm" ]; then
        check_rea "native mitmproxy capture decode" inspect-web-network-capture "8099|GET|127.0.0.1" \
            -- "$WORK/session.mitm" mitmproxy --json
    else
        _skip "native mitmproxy capture decode" "mitmdump produced no capture (see $WORK/mitmdump.log)"
    fi
else
    _skip "native mitmproxy capture decode" "mitmdump missing"
fi

section "browser: CDP observation"
# REA refuses file:// targets - views must be HTTP(S) pages in the origin scope -
# so the fixture page is served locally for the browser sections.
python3 -m http.server 8099 --directory "$FIX/www" >"$WORK/fixture-server.log" 2>&1 &
FIXTURE_PID=$!
sleep 1
BROWSER_BIN="$(command -v google-chrome || command -v chromium || true)"
if [ -n "$BROWSER_BIN" ] && [ -s "$FIX/www/index.html" ]; then
    "$BROWSER_BIN" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --user-data-dir="$WORK/chrome-profile" --remote-debugging-port=9222 \
        "http://127.0.0.1:8099/index.html" >"$WORK/chrome.log" 2>&1 &
    echo $! >"$WORK/chrome.pid"
    for _ in $(seq 1 20); do
        curl -fsS http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break
        sleep 1
    done
    check_rea "browser target discovery (CDP)" list-browser-targets "targetId|page|json" \
        -- http://127.0.0.1:9222 --json
    target_id="$(curl -fsS http://127.0.0.1:9222/json/list 2>/dev/null | jq -r '[.[] | select(.type=="page")][0].id // empty')"
    if [ -n "$target_id" ]; then
        check_rea "browser page capture (DOM/scripts)" inspect-web-page "REA verify fixture|results|search" \
            -- http://127.0.0.1:9222 "$target_id" --json
        check_rea "browser screenshot capture" capture-web-screenshot "." \
            -- http://127.0.0.1:9222 "$target_id" --json
    else
        _skip "browser page capture" "no page target exposed"
    fi
    kill "$(cat "$WORK/chrome.pid")" 2>/dev/null || true
else
    _skip "browser CDP observation" "no Chrome-family browser installed"
fi

section "browser: Playwright scenario"
if [ -s "$FIX/browser-scenario.json" ] && [ -d /opt/ms-playwright ]; then
    check_rea "playwright launch + click + DOM capture" capture-browser-scenario "results|licence found|ready" \
        -- "$FIX/browser-scenario.json" --json
else
    _skip "playwright scenario" "playwright browsers or fixture missing"
fi
kill "$FIXTURE_PID" 2>/dev/null || true

section "process behaviour capture (native PTY)"
if [ -s "$FIX/process-scenario.json" ]; then
    check_rea "pty process capture" capture-process "rea-verify process capture" \
        -- "$FIX/process-scenario.json" --json
else
    _skip "pty process capture" "fixture missing"
fi

section "packet captures (tshark 4.x)"
if [ -s "$FIX/fixture.pcap" ]; then
    check_rea "pcap client inspection" inspect-pcap-client "." -- --json
    check_rea "pcap capture: udp fields" inspect-packet-capture "REA-VERIFY-PAYLOAD|udp|127.0.0.1" \
        -- "$FIX/fixture.pcap" --fields ip.addr --fields udp.port --fields data.data --json
    check_rea "pcap summary" inspect-pcap-capture "." -- "$FIX/fixture.pcap" --json
else
    _skip "pcap inspection" "fixture missing"
fi

section "recorded signals (sigrok-cli 0.7.2 + libsigrokdecode)"
if [ -s "$FIX/uart.vcd" ]; then
    check_rea "sigrok decoder inventory" inspect-signal-decoders "uart" -- --json
    check_rea "vcd UART decode" decode-signal-recording "R|E|A|uart" \
        -- "$FIX/uart.vcd" --decoders "uart:rx=rx:baudrate=9600" \
           --input_format vcd --annotations uart=rx_data --format json
else
    _skip "vcd UART decode" "fixture missing"
fi

rm -rf "$WORK" 2>/dev/null || true
