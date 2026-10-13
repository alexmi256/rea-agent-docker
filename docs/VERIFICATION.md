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

## Two different catalogs: the release vs. `main`

REA's repository `main` documents more families than the published npm package.
Checks use `check_rea`, which SKIPs (never fails) a family the *installed*
release does not expose. For **REA 6.4.0** the released CLI/MCP **lacks**:

`inspect-sqlite-database`, `inspect-wasm-artifact`, `inspect-go-binary`,
`inspect-pcap-client`, `inspect-pcap-capture`, `inspect-packet-capture`,
`inspect-signal-decoders`, `decode-signal-recording`, `list-frida-devices`
(the frida family is on `main`; the frida *binding* is installed and verified).

Their tooling (WABT, SQLite, TShark, sigrok-cli, frida) is nonetheless present
and exercised directly, so a later `REA_VERSION` build arg immediately gains
those checks.

## Target-admission limits observed on REA 6.4.0

* **RISC-V64 and PowerPC ELF** fixtures are refused with
  `target_unavailable: unsupported ELF architecture` — the release's artifact
  admission does not accept those `e_machine` values. Ghidra itself is fine:
  x86-64, AArch64, ARMv7, MIPS32 BE/LE and PE32+ all import, analyse, search
  and decompile. The harness reports these as SKIP-with-reason, not failure.
* **Browser views must be HTTP(S) origin pages** — `file://` is refused
  (`target_not_allowed`), so the fixture page is served on
  `http://127.0.0.1:8099` for the CDP and Playwright checks.
* **Playwright scenarios require `browser.executable_path`** plus an HTTP(S)
  URL; the fixture points at the bundled Playwright Chromium.

## Recorded runs

| Run | Result |
| --- | ------ |
| `20261013T165832Z` (quick) | 47 passed / 8 failed / 6 skipped — produced the diagnosis below |
| `20261013T170107Z` (first full) | 82 passed / 3 failed / 14 skipped; every failure was a harness/fixture defect since fixed: missing `check_rea` command argument, `grep -c` exit status, `binary_overview` string assertions, `file://` browser targets, missing Playwright `executable_path`, and the MCP probe choosing a tool that errors on a directory |
| **`20261013T182120Z` (final full)** | **88 passed / 0 failed / 14 skipped, exit 0** — clean; the 14 skips are all conditional (release catalog, refused ELF machines, Apple-provider routing, unlicensed IDA/JEB). Checked in at [`docs/verify-summary.txt`](verify-summary.txt) |

Machine-checked facts that hold independently of the harness:

* `rea doctor --provider ghidra --json` → `healthy: true`, with
  `ghidra-native_decompiler` reporting "elf x86_64, which matches linux/x64"
  and `ghidra-java` accepting JDK 21.0.12.1 64-bit.
* `rea doctor --provider hopper --json` → `healthy: true`; `hopper-version`
  healthy (launcher SHA-256 `0294ced1…` is in REA's `SUPPORTED_HOPPER_SHA256`)
  and `hopper-demo-runtime` healthy with `strategy=direct`.
* `rea mcp` answers MCP `initialize` (server `rea 6.4.0`, protocol
  `2025-06-18`, capabilities tools/completions/prompts) and advertises
  **170 tools**.
* `ilspycmd 8.2.0.7535` runs (it is a net6.0 app; the image sets
  `DOTNET_ROLL_FORWARD=Major`).
* frida binding: `getLocalDevice()` → "Local System".

The committed summary of a full run is in
[`docs/verify-summary.txt`](verify-summary.txt).
