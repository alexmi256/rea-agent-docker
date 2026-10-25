# Verification record

Commands:

```bash
scripts/verify.sh --image rea-agent-ghidra:6.8.0-linux-amd64   # one engine image
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
| Ghidra (images that carry it) | `doctor --provider ghidra` healthy; analysis of x86-64, AArch64, ARMv7, MIPS32 (BE + LE), RISC-V64, PowerPC and a Windows PE32+; `function`/`decompile`/`search`/`instructions` on the x86-64 fixture; a refusal of any ELF machine the release does not admit is reported as SKIP-with-reason, not failure |
| Hopper (images that carry it) | `doctor --provider hopper` healthy (the launcher digest is the one the vendor's signed release feed authenticates); headless demo-mode analysis, decompilation and string search of the x86-64 fixture (private Xvfb display) |
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
| `all` | `rea-agent` | 107 | 0 | 3 | IDA/JEB (no licence configured), Apple-platform plist routing |
| `ghidra` | `rea-agent-ghidra` | 95 | 0 | 8 | as above **+ the Hopper checks** (not in this image) |
| `hopper` | `rea-agent-hopper` | 88 | 0 | 7 | as above **+ the Ghidra multi-arch checks** (not in this image) |
| `ida` | `rea-agent-ida` | 80 | 0 | 11 | **all native analysis** (no engine bundled — register IDA to enable it), plus the `all` column's skips |

Run ids: `20261014T203245Z` (all), `20261014T204424Z` (ghidra),
`20261014T205559Z` (hopper), `20261014T205739Z` (ida) — full per-check logs in
`work/verify-reports/<run-id>/logs/`, summarised in
[`docs/verify-engines.txt`](verify-engines.txt). Every image exited 0.

The skip count dropped from 14 (`all`) to 3 with the 6.5.0 bump because the
previously `main`-only families (sqlite, wasm, go, pcap, signal, frida) are now
released and run for real. `plist` is the only non-engine, non-licence skip
left on a full-featured image.

Machine-checked facts that hold independently of the harness (checked on each
image after the engine split):

* `rea doctor --provider ghidra --json` → `healthy: true` on `all` and `ghidra`
  (`ghidra-native_decompiler`: "elf x86_64, which matches linux/x64";
  `ghidra-java` accepts JDK 21 64-bit).
* `rea doctor --provider hopper --json` → `healthy: true` on `all` and `hopper`;
  `hopper-version` healthy (the launcher SHA-256 is the one the vendor's signed
  release feed authenticates - `b2271008…` for the shipped Hopper 6.6.0 demo, and
  the image retains that signed evidence so the check also holds offline),
  `hopper-demo-runtime` healthy with `strategy=direct`.
* Engine injection works with **no environment at all**: `docker run --rm
  <image> rea doctor --provider <engine>` is healthy, because the `rea` wrapper
  reads `engine.env`. Verified per image, together with `env | grep -c
  GHIDRA_INSTALL_DIR` → `0` (an image never advertises an engine it lacks).
* Healthcheck per image (the script Docker runs as `HEALTHCHECK`):
  `all`, `ghidra`, `hopper` → `healthy: … (engine: <name>)` shallow and deep;
  `ida` → shallow `healthy`, deep reports
  `unhealthy: engine=ida but REA_IDA_MCP_CONFIG is not set`, which is the correct
  answer for an unconfigured, engine-less image.
* `rea mcp` answers MCP `initialize` (server `rea 6.8.0`, protocol
  `2025-06-18`, capabilities tools/completions/prompts) and advertises
  **229 tools** on every image (the catalog does not depend on the engine).
* `ilspycmd 8.2.0.7535` runs (net6.0 app; the image sets
  `DOTNET_ROLL_FORWARD=Major`).
* frida binding: `getLocalDevice()` → "Local System".

## Expected skips (no licence required to pass)

* `ida doctor`, `jeb client` — skipped unless `REA_IDA_MCP_CONFIG` /
  `REA_JEB_MCP_URL` are provided (bring-your-own commercial engines).
* `plist decode` — REA routes plists through its Apple-platform composite
  provider, which is `capability_unavailable` on Linux for this input.
* Every native-analysis check on `rea-agent-ida` — that image ships no engine by
  design; the harness reports it instead of failing.
* Ghidra checks on `rea-agent-hopper`, Hopper checks on `rea-agent-ghidra`.
* any fixture whose toolchain was switched off at build time
  (`--arg INSTALL_CROSS_TOOLCHAINS=0`, `INSTALL_CHROME=0`, …).

## Release awareness: the catalog is read, not assumed

REA's repository `main` and the published npm package can differ. Checks
therefore use `check_rea`, which reads `rea --help` from the *installed* release
and SKIPs (never fails) any family that release does not expose — so the harness
stays valid across a `REA_VERSION` bump without edits.

**REA 6.5.0 closed the gap that earlier releases had.** The families below were
`main`-only through 6.4.0 and are now part of the released CLI/MCP, so the
harness runs them for real rather than skipping:

`inspect-sqlite-database`, `inspect-wasm-artifact`, `compare-wasm-interfaces`,
`inspect-go-binary`, `inspect-rust-binary`, `inspect-electron-fuses`,
`inspect-pcap-client`, `inspect-pcap-capture`, `inspect-packet-capture`,
`inspect-packet-fields`, `inspect-signal-decoders`, `decode-signal-recording`,
`list-frida-devices`, `list-frida-processes`, `instrument-with-frida`.

Their tooling (WABT 1.0.42, Node's built-in SQLite, TShark, sigrok-cli 0.7.2,
frida 17.23.2) was already in the image, so no dependency changed for this —
only `REA_VERSION`.

## Target admission on REA 6.8.0

* **The Node.js range moved, and it is a gate rather than advice.** 6.8.0
  declares `engines.node: ^22.23.4 || ^24.22.1 || >=26.12.1` (read from the
  published `package.json` *and* `src/domain/runtimeVersion.ts`, which the
  checker re-derives). The previous pin, 24.22.0, satisfied 6.7.0 and is
  **refused** by 6.8.0, so `NODE_VERSION` moves to **24.22.1** in the same
  commit — a REA bump that leaves the runtime behind installs a package that
  will not start.
* **No engine admission moved.** `src/ghidra/GhidraReleasePolicy.ts` is
  byte-identical between 6.7.0 and 6.8.0 (`SUPPORTED_GHIDRA_VERSION` 12.1.4,
  Java major 21), and Hopper is still whatever the vendor's signed feed
  currently offers (6.6.0, launcher `b2271008…`). The engine pins therefore did
  not move, and the harness re-proved both providers on the rebuilt images.
* **The binwalk/unblob requirement left the prose.** In 6.8.0 the literal
  `Binwalk 3.1.x (verified with 3.1.0)` remediation string is gone from
  `CapabilityInventory.ts`; the values now live as structured data in
  `src/contracts/firmware/firmwareToolRequirements.ts`
  (`version: [3, 1, 0]`, `[26, 6, 4]`) and the prose is generated from them. A
  checker that only scraped the prose would have printed `ok` with an empty
  admission for both rows, so `scrape_rea` reads `defineToolRequirement({…})`
  blocks first and falls back to the prose — after the bump both rows show
  `REA 3.1 (verified with 3.1.0)` / `REA 26.6 (verified with 26.6.4)` again.
* **The bundled skill moved to v49 / 229 tools** (was v42 / 207). Verified from
  the shipped catalog (`dist/mcp-catalog.json` → 229 tools), not from the
  release notes; a client that keeps the old skill describes seven fewer
  operational families than the server advertises.
* **`extract-artifact` narrowed to one positional.** 6.8.0 picks the
  destination itself (`output_root` in the result) and refuses a second
  positional outright — the harness check failed with
  `Unexpected positional arguments`. Rather than loosen it, the check now
  asserts the extraction itself: `containment_verified`, `coverage.status ==
  complete`, `cleanup.verified`, every reported artifact `created` with
  `bytes_written > 0`, and then that those files exist under the reported
  `output_root`. That is a stronger claim than the old "exit 0" check made.

## Target admission on REA 6.7.0

* **Hopper is admitted through a signed feed, not a fixed allowlist.** REA 6.6.0
  replaced `SUPPORTED_RELEASES`/`SUPPORTED_HOPPER_SHA256` with the vendor's
  publisher-signed release feed, whose only Linux entry is the *current* demo
  (Hopper 6.6.0, launcher `b2271008…`). A build REA admitted under 6.5.0 is
  refused now, so the image ships the feed's release; the harness asserts the
  launcher digest against the build-time marker
  (`/usr/local/share/rea/hopper-launcher.sha256`) and the operation-level checks
  confirm REA reports `hopper launcher-sha256:b2271008…` in the analysis profile.
  The image also retains the signed evidence, so the same checks hold without
  network access; a *licensed* Hopper goes in through `vendor/` and is admitted by
  its own publisher evidence, which is why that assertion SKIPs rather than fails
  for it.
* **The Ghidra policy file was renamed.** `SUPPORTED_GHIDRA_VERSION` moved from
  `src/ghidra/GhidraInstallationPolicy.ts` to `src/ghidra/GhidraReleasePolicy.ts`
  in the 6.6.x line. The admitted build is still 12.1.4 and the accepted release
  line is 12.1.x; the update checker had to be repointed, or the Ghidra row would
  have gone quiet instead of failing.
* **Kuna is a new caller-supplied provider** (REA 6.6.0+). Like IDA and JEB it is
  never installed by the image, so it reports `provider_missing` by design and is
  recorded as an accepted gap in `docs/UPDATES.md` rather than as a `MISSING` row.

## Target admission on REA 6.5.0

* **RISC-V64 and PowerPC ELF are now admitted.** Through 6.4.0 the harness
  recorded these fixtures as refused with `target_unavailable: unsupported ELF
  architecture`; 6.5.0 adds bounded Ghidra RISC-V and PowerPC profiles, so the
  fixture string is now found on every architecture the harness builds for —
  x86-64, AArch64, ARMv7, MIPS32 BE/LE, RISC-V64, PowerPC, Windows PE32+.
  The harness still reports any future `unsupported ELF architecture` refusal as
  SKIP-with-reason rather than failure, so the check stays honest either way.
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
| **CI publish run (all four, REA 6.4.0)** | run [38481777484](https://github.com/alexmi256/rea-agent-docker/actions/runs/38481777484) — every engine image built on a hosted runner (ida 10m0s, hopper 9m10s, ghidra 11m42s, all-engines longest), quick harness green on each, then published to `ghcr.io/alexmi256/rea-agent[-ghidra\|-hopper\|-ida]` with tags `6.4.0-linux-amd64` and `latest`. Public access verified independently of the CI log: `docker manifest inspect` on all four tags succeeds **anonymously** (no `ghcr.io` credentials on the machine doing the check). |
| **Local per-engine sweep, REA 6.5.0** | all 107/0/3 · ghidra 95/0/8 · hopper 88/0/7 · ida 80/0/11 — **0 failures on all four**, exit 0 on every image. The first pass caught one harness defect (`sigrok decoder inventory` asserted `uart` appeared in the decoder catalog's default 50-of-111 page); fixed by searching with `inspect-signal-decoders --query uart` and re-run. Also newly green relative to 6.4.0: sqlite, wasm, go-binary, pcap ×3, signal ×2, frida, and the RISC-V64/PowerPC ELF searches. |
| **Local per-engine sweep, dependency round (2026-10-15)** | all **120/0/3** · ghidra **108/0/8** · hopper **101/0/7** · ida **93/0/11** — 0 failures on all four, exit 0 on every image; full log in [`docs/verify-engines.txt`](verify-engines.txt). This is the round that bumped Node to 24.22.0, frida to 17.23.3, uv to 0.13.1, supergateway to 4.2.0 and added **Wakaru 1.14.0**, so the count includes 13 new checks: five assert REA's admission rules for the Wakaru binary (absolute path, readable+executable, the `wakaru <semver>` banner, the audited SHA-256, util-linux prlimit) and eight run the operation itself — a minified bundle fixture is recovered, the Evidence is asserted on schema fields (provider `wakaru`, `status: complete`, `failed: 0`, module `decompiled`, and the fingerprinted digest **`664fa067…` proving REA ran the audited asset**), the published module file is checked, and the recovered tree is then analysed with `analyze-javascript-application`. |
| **Local per-engine sweep, REA 6.8.0 (this bump)** | all **121/0/3** · ghidra **109/0/8** · hopper **102/0/7** · ida **94/0/11** — 0 failures on all four, exit 0 on every image; runs `20261025T093139Z` / `20261025T094344Z` / `20261025T095536Z` / `20261025T095733Z`, full log regenerated in [`docs/verify-engines.txt`](verify-engines.txt). Every image carries **one more check** than the 6.7.0 round, and it is an addition rather than a capability: `extract-artifact` lost its second positional in 6.8.0, so the old exit-status check became a JSON assertion on the extraction plus one that the reported files exist under the reported `output_root`. Node moved to 24.22.1 (6.8.0's range refuses 24.22.0), the catalog grew 207 → 229 tools (skill v42 → v49), and no engine admission moved. |
| **Local per-engine sweep, REA 6.7.0** | all **120/0/3** · ghidra **108/0/8** · hopper **101/0/7** · ida **93/0/11** — 0 failures on all four, exit 0 on every image; runs `20261019T014730Z` / `20261019T015922Z` / `20261019T021101Z` / `20261019T021249Z`, full log regenerated in [`docs/verify-engines.txt`](verify-engines.txt). Counts are **identical to the previous round** on every image, which is the expected result: 6.6.0/6.7.0 added no tool family and removed none. The bump's real work was a change of gate — Hopper moved from a fixed launcher-digest allowlist to the vendor's signed release feed (so the pinned 6.4.2 build is refused outright and the image now ships 6.6.0 plus its retained evidence), the Ghidra policy source was renamed, and both had to be re-derived in `scripts/check-updates.py`, which is back to `0 actionable / 0 pending / 0 unknown`. frida moved to 17.24.1. |
| **Build failures this round caught** | Two, both real and both fixed rather than worked around: the Node layer died with `sha256sum: no properly formatted checksum lines found` because `/var/cache/rea-dl` held the *previous* version's `SHASUMS256.txt` under a version-less name (the cached filename is now version-qualified, and the stale file was deliberately left in place to prove the fix, not the cache clean); and `pip` refused `unicorn==2.1.4` with `ResolutionImpossible` because pwntools 4.15.0 declares `unicorn !=2.1.3, !=2.1.4` — so unicorn stays at 2.1.2 and the checker now reports it as `held on 2.1.2: <reason>` instead of as an available update. Neither reached GHCR: the publish step runs only after verification. |

The committed summary of the last full single-image run is in
[`docs/verify-summary.txt`](verify-summary.txt); the per-engine table from the
final sweep is in [`docs/verify-engines.txt`](verify-engines.txt).
