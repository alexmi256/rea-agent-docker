#!/usr/bin/env bash
# Builds the sample artefacts the verification checks analyse. Everything is
# generated locally - nothing is downloaded, and nothing here is copyrighted
# third-party material. Missing toolchains degrade to "fixture absent" and the
# dependent checks are skipped rather than failed.
set -uo pipefail

FIX="${REA_VERIFY_FIXTURES:-/tmp/rea-verify/fixtures}"
mkdir -p "$FIX"

cat >"$FIX/hello.c" <<'EOF'
#include <stdio.h>
#include <string.h>

/* Several call boundaries so decompilers have something to chew on. */
static int checksum(const char *s) {
    int acc = 0;
    for (size_t i = 0; i < strlen(s); i++) acc = (acc * 31 + (unsigned char)s[i]) & 0xffff;
    return acc;
}

static int scale(int v, int factor) {
    return (v * factor) ^ 0x5a5a;
}

int main(int argc, char **argv) {
    const char *msg = argc > 1 ? argv[1] : "reverse-me";
    int sum = checksum(msg);
    printf("checksum=%d scaled=%d\n", sum, scale(sum, 7));
    return sum == 0;
}
EOF

cat >"$FIX/hello.zig" <<'EOF'
unused placeholder (kept out of the build)
EOF
rm -f "$FIX/hello.zig"

build_native() { # build_native <name> <compiler>
    local out="$FIX/$1" cc="$2"
    command -v "$cc" >/dev/null 2>&1 || return 1
    "$cc" -O1 -o "$out" "$FIX/hello.c" >/dev/null 2>&1 || return 1
    [ -s "$out" ] || return 1
}

build_static() { # build_static <name> <compiler>
    local out="$FIX/$1" cc="$2"
    command -v "$cc" >/dev/null 2>&1 || return 1
    "$cc" -O1 -static -o "$out" "$FIX/hello.c" >/dev/null 2>&1 || return 1
    [ -s "$out" ] || return 1
}

echo "building C fixtures in $FIX"
build_native fixture-x86_64.elf gcc            && echo "  + fixture-x86_64.elf"
build_static fixture-aarch64.elf aarch64-linux-gnu-gcc  && echo "  + fixture-aarch64.elf (aarch64)"
build_static fixture-armv7.elf   arm-linux-gnueabihf-gcc && echo "  + fixture-armv7.elf (arm)"
build_static fixture-mips.elf    mips-linux-gnu-gcc      && echo "  + fixture-mips.elf (big-endian MIPS32)"
build_static fixture-mipsel.elf  mipsel-linux-gnu-gcc    && echo "  + fixture-mipsel.elf (little-endian MIPS32)"
build_static fixture-riscv64.elf riscv64-linux-gnu-gcc   && echo "  + fixture-riscv64.elf (riscv64)"
build_static fixture-ppc.elf     powerpc-linux-gnu-gcc   && echo "  + fixture-ppc.elf (PowerPC)"

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    x86_64-w64-mingw32-gcc -O1 -o "$FIX/fixture-win64.exe" "$FIX/hello.c" >/dev/null 2>&1 \
        && echo "  + fixture-win64.exe (PE32+)"
fi

# --- WebAssembly (WABT) ------------------------------------------------------
cat >"$FIX/module.wat" <<'EOF'
(module
  (memory (export "memory") 1)
  (func $add (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func (export "checksum") (param i32 i32) (result i32)
    local.get 0
    i32.const 31
    i32.mul
    local.get 1
    i32.xor))
EOF
if [ -x /opt/wabt/bin/wat2wasm ]; then
    /opt/wabt/bin/wat2wasm "$FIX/module.wat" -o "$FIX/module.wasm" >/dev/null 2>&1 \
        && echo "  + module.wasm"
fi

# --- SQLite ------------------------------------------------------------------
python3 - <<PY >/dev/null 2>&1 && echo "  + fixture.sqlite"
import sqlite3
con = sqlite3.connect("$FIX/fixture.sqlite")
con.executescript("""
CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE license_requests(id INTEGER PRIMARY KEY, payload BLOB);
INSERT INTO settings VALUES ('endpoint','https://example.invalid/api'),('mode','offline');
INSERT INTO license_requests(payload) VALUES (x'deadbeef');
""")
con.commit(); con.close()
PY

# --- HAR 1.2 -----------------------------------------------------------------
cat >"$FIX/session.har" <<'EOF'
{
  "log": {
    "version": "1.2",
    "creator": { "name": "rea-agent-verify", "version": "1" },
    "entries": [
      {
        "startedDateTime": "2026-01-01T00:00:00.000Z",
        "time": 12,
        "request": {
          "method": "GET",
          "url": "http://127.0.0.1:8080/api/entitlements?user=demo",
          "httpVersion": "HTTP/1.1",
          "headers": [{ "name": "Accept", "value": "application/json" }],
          "queryString": [{ "name": "user", "value": "demo" }],
          "cookies": [],
          "headersSize": -1,
          "bodySize": 0
        },
        "response": {
          "status": 200,
          "statusText": "OK",
          "httpVersion": "HTTP/1.1",
          "headers": [{ "name": "Content-Type", "value": "application/json" }],
          "cookies": [],
          "content": { "size": 25, "mimeType": "application/json", "text": "{\"plan\":\"pro\",\"seats\":3}" },
          "redirectURL": "",
          "headersSize": -1,
          "bodySize": 25
        },
        "cache": {},
        "timings": { "send": 1, "wait": 10, "receive": 1 }
      }
    ]
  }
}
EOF
echo "  + session.har"

# --- Apple plist + keyed archive-ish + Mach-O-free static samples ------------
cat >"$FIX/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>tools.rea.verify</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
EOF
echo "  + Info.plist"

# --- JavaScript/Electron-ish application tree --------------------------------
mkdir -p "$FIX/jsapp/src" "$FIX/jsapp/resources"
cat >"$FIX/jsapp/package.json" <<'EOF'
{
  "name": "rea-verify-app",
  "version": "1.0.0",
  "main": "src/main.js",
  "type": "commonjs"
}
EOF
cat >"$FIX/jsapp/src/main.js" <<'EOF'
const { readEntitlements } = require('./license');
const { exportReport } = require('./exporter');

function run(userId) {
    const entitlements = readEntitlements(userId);
    return exportReport(userId, entitlements);
}
module.exports = { run };
EOF
cat >"$FIX/jsapp/src/license.js" <<'EOF'
function readEntitlements(userId) {
    const cache = new Map();
    if (cache.has(userId)) return cache.get(userId);
    const value = { plan: 'pro', seats: 3, featureFlags: ['export', 'sync'] };
    cache.set(userId, value);
    return value;
}
module.exports = { readEntitlements };
EOF
cat >"$FIX/jsapp/src/exporter.js" <<'EOF'
function exportReport(userId, entitlements) {
    return JSON.stringify({ userId, entitlements, exportedAt: 'fixed' });
}
module.exports = { exportReport };
EOF
echo "  + jsapp/"

# --- Minified bundle for JavaScript source recovery (Wakaru) ------------------
# A deliberately minified, single-IIFE bundle: this is the shape REA's
# recover_javascript_sources exists for (unpack a production bundle back into
# readable modules), and it is written here rather than downloaded so the
# harness stays offline and deterministic.
mkdir -p "$FIX/jsbundle"
cat >"$FIX/jsbundle/bundle.min.js" <<'EOF'
(function(){"use strict";var n=0;function c(){n++;return "click "+n}function d(a){return a.map(function(x){return x*2})}window.addEventListener("load",function(){document.body.addEventListener("click",c),console.log("app ready",d([1,2,3]))})})();
EOF
echo "  + jsbundle/bundle.min.js"

# --- Web page for CDP / Playwright captures ----------------------------------
mkdir -p "$FIX/www"
cat >"$FIX/www/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>REA verify fixture</title></head>
<body>
  <h1 id="title">verify</h1>
  <input id="search" value="reverse engineering">
  <button id="go" onclick="document.querySelector('#results').dataset.state='ready';document.querySelector('#results').textContent='licence found';">Search</button>
  <div id="results" data-state="idle">no results</div>
  <script>window.__fixture = { build: 'verify-1' };</script>
</body>
</html>
EOF
echo "  + www/index.html"

# --- PCAP (tshark) -----------------------------------------------------------
if command -v text2pcap >/dev/null 2>&1; then
    python3 - <<PY >/dev/null 2>&1 && echo "  + fixture.pcap"
import struct
# minimal Ethernet/IPv4/UDP datagram with an ASCII payload
payload = b"REA-VERIFY-PAYLOAD"
udp = struct.pack("!HHHH", 5353, 4444, 8 + len(payload), 0) + payload
ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 0x1234, 0, 64, 17, 0,
                 bytes([127, 0, 0, 1]), bytes([127, 0, 0, 1])) + udp
frame = bytes.fromhex("ffffffffffff0011223344550800") + ip
with open("$FIX/fixture.pcap", "wb") as fh:
    fh.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
    fh.write(struct.pack("<IIII", 1700000000, 0, len(frame), len(frame)))
    fh.write(frame)
PY
fi

# --- VCD (sigrok UART) -------------------------------------------------------
python3 - <<PY >/dev/null 2>&1 && echo "  + uart.vcd"
# 9600 8N1 UART waveform sampled at 1 MHz, carrying "REA\r\n"
data = "REA\r\n"
bit_period = 104.1666
samples = []
value = 1  # idle high
for ch in data:
    bits = [0] + [(ord(ch) >> i) & 1 for i in range(8)] + [1]
    for b in bits:
        samples.append((int(len(samples) * bit_period * 1000), b))
    samples.append((int(len(samples) * bit_period * 1000), 1))
end = int(len(samples) * bit_period * 1000 / 10 + 2000)
lines = ["\$timescale 1us \$end", "\$scope module logic \$end", "\$var wire 1 ! rx \$end", "\$upscope \$end", "\$enddefinitions \$end", "\$dumpvars", "1!"]
for ts, b in samples:
    lines.append(f"#{ts}")
    lines.append(f"{b}!")
lines.append(f"#{end}")
open("$FIX/uart.vcd", "w").write("\n".join(lines) + "\n")
PY

# --- Firmware blob (binwalk regions + unblob extraction) ---------------------
python3 - <<PY >/dev/null 2>&1 && echo "  + firmware.bin"
import gzip, io, os, struct, zipfile
out = bytearray()
out += b"\\x00" * 512                      # leading padding
inner = b"rootfs config: http://127.0.0.1/ota\\n" * 4
out += gzip.compress(inner)                # gzip member (binwalk + unblob)
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("manifest.json", '{"device":"verify","fw":"1.0"}')
    zf.writestr("extras/license.txt", "licence text")
out += buf.getvalue()                      # zip member
out += b"\\x00" * 256
open("$FIX/firmware.bin", "wb").write(bytes(out))
PY

# --- EVM runtime bytecode ----------------------------------------------------
cat >"$FIX/runtime.hex" <<'EOF'
6080604052348015600f57600080fd5b506004361060285760003560e01c8063
2e64cec114602d5780636057361d14604b575b600080fd5b6033605f565b6040
5190815260200160405180910390f35b60596004803603810190605591906075
565b6062565b005b6000819050919050565b8060008190555050565b600080fd
5b600082825260208201905092915050565b60006020828403121560a157
EOF
tr -d '\n ' <"$FIX/runtime.hex" >"$FIX/runtime-clean.hex" && mv "$FIX/runtime-clean.hex" "$FIX/runtime.hex"
echo "  + runtime.hex"

# --- process-capture scenario + browser scenario -----------------------------
cat >"$FIX/process-scenario.json" <<'EOF'
{
  "executable": "node",
  "arguments": ["-e", "console.log('rea-verify process capture'); process.exitCode = 0;"],
  "timeout_ms": 15000
}
EOF
PW_CHROME="$(ls -d /opt/ms-playwright/chromium-*/chrome-linux/chrome 2>/dev/null | head -1)"
cat >"$FIX/browser-scenario.json" <<EOF
{
  "browser": { "mode": "launch", "executable_path": "${PW_CHROME:-/usr/bin/google-chrome}" },
  "start_url": { "url": "http://127.0.0.1:8099/index.html" },
  "actions": [
    { "step_id": "settle", "action": "wait_for_timeout", "duration_ms": 200 },
    { "step_id": "click", "action": "click", "locator": { "kind": "css", "selector": "#go" }, "timeout_ms": 10000 },
    { "step_id": "ready", "action": "wait_for", "locator": { "kind": "css", "selector": "#results[data-state='ready']" }, "state": "visible", "timeout_ms": 10000 }
  ],
  "capture": { "at_end": ["dom", "accessibility", "url"] }
}
EOF
echo "  + process-scenario.json, browser-scenario.json"

# --- a real archive for inspect-artifact / extract-artifact -------------------
if command -v zip >/dev/null 2>&1 && [ -d "$FIX/jsapp" ]; then
    ( cd "$FIX" && rm -f bundle.zip && zip -qr bundle.zip jsapp ) >/dev/null 2>&1 \
        && echo "  + bundle.zip"
fi

# --- .NET assembly (managed analysis / ilspycmd) ------------------------------
if command -v dotnet >/dev/null 2>&1; then
    dotnet_dir="$FIX/dotnet-app"
    if [ ! -f "$dotnet_dir/bin/Release/net8.0/VerifyLib.dll" ]; then
        mkdir -p "$dotnet_dir"
        (
            cd "$dotnet_dir" || exit 1
            dotnet new classlib -n VerifyLib -o . --force 2>&1 | tail -3
            cat >License.cs <<'EOF'
namespace VerifyLib;
public sealed class License {
    public string Plan { get; init; } = "pro";
    public int Seats { get; init; } = 3;
    public string Describe(string user) => $"{user}:{Plan}/{Seats}";
}
EOF
            rm -f Class1.cs
            dotnet build -c Release 2>&1 | tail -5
        ) 2>&1 | sed 's/^/  dotnet: /'
    fi
    if [ -f "$dotnet_dir/bin/Release/net8.0/VerifyLib.dll" ]; then
        echo "  + dotnet-app/bin/Release/net8.0/VerifyLib.dll"
    else
        echo "  - .NET fixture not built (see the dotnet: lines above)"
    fi
fi

echo "fixtures ready in $FIX"
