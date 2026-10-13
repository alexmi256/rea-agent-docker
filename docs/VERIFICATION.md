# Verification record

Command:

```bash
scripts/verify.sh                 # or: make verify  (inside the compose service)
```

The harness runs **inside the built image** as the host user, builds its own
fixtures, and drives REA exactly the way a client does. Raw output for every
check is kept under `work/verify-reports/<run-id>/logs/`.

## What the run establishes

| Area | Checks |
| ---- | ------ |
| Runtime | Node 24.x, REA `--version`, `rea providers`, provider discovery |
| Ghidra | `doctor --provider ghidra` healthy; analysis of x86-64, AArch64, ARMv7, MIPS32 (BE + LE), RISC-V64, PowerPC and a Windows PE32+; `function`/`decompile`/`search`/`instructions` on the x86-64 fixture |
| Hopper | `doctor --provider hopper` healthy; headless demo-mode analysis, decompilation and string search of the x86-64 fixture (private Xvfb display) |
| Static | `inspect-binary-layout` (pwntools 4.15.0), `inspect-wasm-artifact` (WABT 1.0.42), `inspect-sqlite-database`, `inspect-managed-artifact`/`inspect-managed-members` (.NET + ilspycmd), `inspect-plist`, `inspect-evm-interface`, `analyze-javascript-application`, `import-reference-source` |
| Capture | `inspect-pcap-client`/`inspect-packet-capture` (tshark 4.2.2), `inspect-signal-decoders`/`decode-signal-recording` (sigrok-cli 0.7.2), `inspect-firmware-regions` (binwalk 3.1.0) + `extract-firmware` (unblob 26.6.4), `inspect-web-network-capture` for HAR and for a **capture recorded live through mitmdump 12.2.3**, Chrome CDP target discovery + page + screenshot capture, Playwright scenario (launch → click → DOM/accessibility/URL), PTY `capture-process` |
| Clients | Frida device inventory, `inspect-adb-client`/`list-adb-devices`, `inspect-apktool-client`, JADX engine JAR load, IDA registration acceptance, Hopper state directory |
| MCP | real stdio handshake (`initialize` → `tools/list` → `tools/call`), an engine-free tool call, a Ghidra-backed `open_binary`/`analyze_function`/`close_binary`, and the Streamable HTTP bridge initialising on `127.0.0.1:8811` |

## Expected skips (no licence required to pass)

* `ida doctor`, `jeb client` — skipped unless `REA_IDA_MCP_CONFIG` /
  `REA_JEB_MCP_URL` are provided (bring-your-own commercial engines).
* `managed artifact` — skipped if the .NET SDK cannot build the fixture offline
  (it uses the locally installed SDK and templates, no network).
* any fixture whose toolchain is missing (`--build-arg INSTALL_CROSS_TOOLCHAINS=0`
  or `INSTALL_CHROME=0`).

## Recorded run

See `work/verify-reports/` after running the harness; a copy of the most recent
`summary.txt` for the image built in this repository is checked in at
[`docs/verify-summary.txt`](verify-summary.txt).
