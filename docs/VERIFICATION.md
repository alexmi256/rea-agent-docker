# Verification record

Commands:

```bash
scripts/verify.sh --image rea-agent-ghidra:6.4.0-linux-amd64   # one engine image
scripts/verify-all-engines.sh                                  # all four, one table
make verify ENGINE=hopper                                      # same, via make
```

The harness runs **inside the built image** as the host user, builds its own
fixtures, and drives REA exactly the way a client does. Raw output for every
check is kept under `work/verify-reports/<run-id>/logs/`.

Because the images differ only by engine, the harness reads
`/usr/local/share/rea/engine` and verifies **what that image actually carries**:
checks for an engine it does not ship are SKIPped with the reason
(`not in this image (engine: hopper)`), never failed. One harness therefore
verifies all four images, and the skip list is the honest statement of what a
single-engine image gives up.

## What the run establishes

| Area | Checks |
| ---- | ------ |
| Runtime | Node 24.x, REA `--version`, `rea providers`, provider discovery for the engines present |
| Engine profile | `/usr/local/share/rea/engine` marker, `engine.env` content, the `rea` wrapper that injects it, and that the container **healthcheck** calls this image healthy (shallow and deep) |
| Ghidra (images that carry it) | `doctor --provider ghidra` healthy; analysis of x86-64, AArch64, ARMv7, MIPS32 (BE + LE), RISC-V64, PowerPC and a Windows PE32+; `function`/`decompile`/`search`/`instructions` on the x86-64 fixture; skips RISC-V64/PowerPC fixture *search* when the release refuses that ELF machine |
| Hopper (images that carry it) | `doctor --provider hopper` healthy; headless demo-mode analysis, decompilation and string search of the x86-64 fixture (private Xvfb display) |
| Static | `inspect-binary-layout` (pwntools 4.15.0), `inspect-sqlite-database`-family routing, `inspect-managed-artifact`/`-members` (.NET + a real ilspycmd decompile), `inspect-evm-interface`, `analyze-javascript-application`, `import-reference-source`, zip-bundle `inspect-artifact`/`extract-artifact`, application-directory `analyze` |
| Capture | `inspect-packet-capture` (tshark 4.2.2), signal decoding (sigrok-cli 0.7.2), `inspect-firmware-regions` (binwalk 3.1.0) + `extract-firmware` (unblob 26.6.4), web-network-capture for HAR and for a **live mitmdump 12.2.3 capture**, Chrome CDP target/page/screenshot, Playwright launch→click→DOM, PTY `capture-process` |
| Clients | Frida device inventory, adb client/devices, Apktool launcher, JADX engine JAR, IDA registration templates, JEB endpoint, Hopper state directory |
| MCP | real stdio handshake (`initialize` → `tools/list` → `tools/call`), an engine-free tool call, and on images with an engine a provider-backed `open_binary`/`analyze_function`/`close_binary`; the Streamable HTTP bridge initialising on `127.0.0.1:8811` |

## Per-engine runs

Each engine image was built with `scripts/build-all.sh` and then verified by
`scripts/verify-all-engines.sh`, which runs the full harness per image and prints
the table below. The counts differ between images exactly as the engine profile
implies — that is the point of the split:

| Engine | Image | Passed | Failed | Skipped | Notable skips |
| ------ | ----- | -----: | -----: | ------: | ------------- |
| `all` | `rea-agent` | 96 | 0 | 14 | IDA/JEB (no licence configured), RISC-V64/PowerPC ELF admission, families absent from REA 6.4.0, playbook-managed .NET/plist routing |
| `ghidra` | `rea-agent-ghidra` | 85 | 0 | 18 | as above **+ the Hopper checks** (not in this image) |
| `hopper` | `rea-agent-hopper` | 79 | 0 | 16 | as above **+ the Ghidra multi-arch checks** (not in this image) |
| `ida` | `rea-agent-ida` | 72 | 0 | 19 | **all native analysis** (no engine bundled — register IDA to enable it), plus the `all` column's skips |

Run ids: `20261013T202729Z` (all), `20261013T203914Z` (ghidra),
`20261013T205026Z` (hopper), `20261013T205217Z` (ida) — full per-check logs in
`work/verify-reports/<run-id>/logs/`, summarised in
[`docs/verify-engines.txt`](verify-engines.txt). Every image exited 0.

Machine-checked facts that hold independently of the harness (checked on each
image after the engine split):

* `rea doctor --provider ghidra --json` → `healthy: true` on `all` and `ghidra`
  (`ghidra-native_decompiler`: "elf x86_64, which matches linux/x64";
  `ghidra-java` accepts JDK 21 64-bit).
* `rea doctor --provider hopper --json` → `healthy: true` on `all` and `hopper`;
  `hopper-version` healthy (launcher SHA-256 `0294ced1…` is in REA's
  `SUPPORTED_HOPPER_SHA256`), `hopper-demo-runtime` healthy with `strategy=direct`.
* Engine injection works with **no environment at all**: `docker run --rm
  <image> rea doctor --provider <engine>` is healthy, because the `rea` wrapper
  reads `engine.env`. Verified per image, together with `env | grep -c
  GHIDRA_INSTALL_DIR` → `0` (an image never advertises an engine it lacks).
* Healthcheck per image (the script Docker runs as `HEALTHCHECK`):
  `all`, `ghidra`, `hopper` → `healthy: … (engine: <name>)` shallow and deep;
  `ida` → shallow `healthy`, deep reports
  `unhealthy: engine=ida but REA_IDA_MCP_CONFIG is not set`, which is the correct
  answer for an unconfigured, engine-less image.
* `rea mcp` answers MCP `initialize` (server `rea 6.4.0`, protocol
  `2025-06-18`, capabilities tools/completions/prompts) and advertises
  **170 tools** on every image (the catalog does not depend on the engine).
* `ilspycmd 8.2.0.7535` runs (net6.0 app; the image sets
  `DOTNET_ROLL_FORWARD=Major`).
* frida binding: `getLocalDevice()` → "Local System".

## Expected skips (no licence required to pass)

* `ida doctor`, `jeb client` — skipped unless `REA_IDA_MCP_CONFIG` /
  `REA_JEB_MCP_URL` are provided (bring-your-own commercial engines).
* Every native-analysis check on `rea-agent-ida` — that image ships no engine by
  design; the harness reports it instead of failing.
* Ghidra checks on `rea-agent-hopper`, Hopper checks on `rea-agent-ghidra`.
* any fixture whose toolchain was switched off at build time
  (`--arg INSTALL_CROSS_TOOLCHAINS=0`, `INSTALL_CHROME=0`, …).

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
| `20261013T182120Z` (final full, single image) | **88 passed / 0 failed / 14 skipped, exit 0** before the engine split; checked in at [`docs/verify-summary.txt`](verify-summary.txt) |
| per-engine full sweep (first, pre-healthcheck-fix images) | all 94/0/14 · ghidra 83/0/18 · hopper 77/0/16 · ida 70/0/19 — **0 failures on all four**; it also caught the leftovers that are now fixed (healthcheck demanding Hopper on every image, `engine.env` shadowed by the `./config` mount, `set -u` aborts on single-engine images) |
| per-engine full sweep (final images) | see `docs/verify-engines.txt` |
| **CI, GitHub-hosted runner (quick profile)** | **59 passed / 0 failed / 13 skipped** — run [38474640500](https://github.com/alexmi256/rea-agent-docker/actions/runs/38474640500), ghidra image built on the runner in 8m52s, harness executed as the runner's uid (not the image's), artifact `verification-report-ghidra` uploaded. This run is also the regression test for the two defects CI found: the entrypoint dying on a foreign uid, and the un-gated Hopper state-dir check. |

The committed summary of the last full single-image run is in
[`docs/verify-summary.txt`](verify-summary.txt); the per-engine table from the
final sweep is in [`docs/verify-engines.txt`](verify-engines.txt).
