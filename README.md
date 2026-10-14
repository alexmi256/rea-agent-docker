# rea-agent — Reverse Engineer Anything in a container, MCP-ready

[![ci](https://github.com/alexmi256/rea-agent-docker/actions/workflows/build.yml/badge.svg)](https://github.com/alexmi256/rea-agent-docker/actions/workflows/build.yml)
[![ghcr: rea-agent](https://img.shields.io/badge/ghcr.io-alexmi256%2Frea--agent-2496ED?logo=docker&logoColor=white)](https://github.com/alexmi256/rea-agent-docker/pkgs/container/rea-agent)

A Docker image + Compose stack that runs **[REA](https://rea.tools/)
(`rea-agents`, the "Reverse Engineer Anything" MCP server)** together with every
analysis engine and helper it can drive, so an MCP client — Hermes Agent,
Claude Code, Codex, Cursor, anything that speaks MCP — can do reverse
engineering without installing a single tool on the host.

* **Target:** `linux/amd64` only (deliberate scope; see
  [docs/MULTIARCH.md](docs/MULTIARCH.md) — the *analysed* targets can be any
  architecture).
* **Base:** `ubuntu:24.04` — the distribution REA's Hopper installer and
  Ghidra/JDK bindings are verified against, and the one that resolves every
  pinned helper version from apt.
* **Engines:** Ghidra 12.1.4 (multi-architecture, the default), Hopper 6.4.2
  (public demo, headless via Xvfb), IDA Pro/Home/Free (bring your own licence).
* **Four images, one per engine:** `rea-agent` (Ghidra + Hopper), `rea-agent-ghidra`,
  `rea-agent-hopper`, `rea-agent-ida` (no bundled engine). Same auxiliary
  toolchain in all four — pick the disassembler you actually use:
  [docs/IMAGES.md](docs/IMAGES.md).
* **Published to GHCR:** all four are built and pushed to
  `ghcr.io/alexmi256/…` on every push to `main`, so `docker compose pull` works
  without building anything ([below](#a-pull-a-published-image-recommended--no-build)).
* **Surface:** REA's MCP server, ~170 tools, stdio by default (spawned by the
  client through `docker exec`) or Streamable HTTP via an optional bridge.
* **Verified:** the image ships a harness that actually runs the engines —
  `scripts/verify.sh` builds fixtures for eight architectures/format families
  and analyses them through the providers, then does a real MCP handshake. It is
  engine-aware, so the same harness verifies all four images; the recorded
  per-engine sweep is **96/85/79/72 passed, 0 failed** (all/ghidra/hopper/ida,
  [docs/VERIFICATION.md](docs/VERIFICATION.md)).

---

## Quick start

Two ways in: **pull the published image** (nothing to build) or **build it
yourself**. Both converge on the same image names, so you can switch later
without re-arranging anything.

### A. Pull a published image (recommended — no build)

Images are published to the GitHub Container Registry on every push to `main`:

| Image | Engine |
| ----- | ------ |
| `ghcr.io/alexmi256/rea-agent:6.4.0-linux-amd64` | Ghidra + Hopper |
| `ghcr.io/alexmi256/rea-agent-ghidra:6.4.0-linux-amd64` | Ghidra only |
| `ghcr.io/alexmi256/rea-agent-hopper:6.4.0-linux-amd64` | Hopper only |
| `ghcr.io/alexmi256/rea-agent-ida:6.4.0-linux-amd64` | no engine (bring your own IDA) |

Each also carries a `:latest` tag. The packages are public — no login, no token,
just:

```bash
git clone <this repo> rea-agent-docker && cd rea-agent-docker
cp .env.example .env           # already points at ghcr.io; set REA_UID/REA_GID to your user
docker compose pull            # active profiles only (here: rea-agent) — ~8 GB each
docker compose --profile ghidra up -d rea-ghidra   # pulls that image on demand if skipped
docker compose exec rea-ghidra rea doctor --json
```

### B. Build it yourself

```bash
git clone <this repo> rea-agent-docker && cd rea-agent-docker
cp .env.example .env           # set REA_UID/REA_GID to your host user
make build-ghidra              # ~10-25 min first time; or make build-all for all four
docker compose --profile ghidra up -d rea-ghidra
docker compose exec rea-ghidra rea doctor --json
```

Bare `make build` / `docker compose up -d` builds and runs the all-engines image
(`rea-agent`, Ghidra + Hopper). The per-engine images are
`rea-agent-ghidra`, `rea-agent-hopper` and `rea-agent-ida` — see
[docs/IMAGES.md](docs/IMAGES.md) for what each carries and when to choose it.

Then point your MCP client at it (Hermes block ready to paste:
[`scripts/hermes-mcp.yaml`](scripts/hermes-mcp.yaml)) — only the container name
changes between engines:

```yaml
mcp_servers:
  rea:
    command: "docker"
    args: ["exec", "-i", "rea-agent-ghidra", "rea", "mcp"]   # rea-agent / rea-agent-hopper / rea-agent-ida
    timeout: 1800
    connect_timeout: 120
```

Ask it something with a real target:

```bash
cp suspicious.elf targets/
docker compose exec rea-ghidra rea search /targets/suspicious.elf "licence" --provider ghidra --json
docker compose exec rea-ghidra rea decompile /targets/suspicious.elf main --provider ghidra --json
```

Full walkthrough: [docs/HERMES-MCP.md](docs/HERMES-MCP.md).

---

## What is installed

| Family | Tools | Pinned |
| ------ | ----- | ------ |
| REA | `rea-agents` CLI + MCP server | 6.4.0 (Node 24.21.0) |
| Native engines | Ghidra + JDK 21, Hopper (demo or licensed), IDA (BYO) | Ghidra 12.1.4, Hopper 6.4.2 |
| ELF/core analysis | pwntools + pyelftools + Unicorn in a venv, `gdb` + `gdb-multiarch`, pwndbg | pwntools 4.15.0, pyelftools 0.33, Unicorn 2.1.2, pwndbg 2026.09.15 |
| Firmware | binwalk (built from source), unblob + extractors (`debugfs`, 7z, squashfs, cpio, dtc, lz4/lzop/lzip, cabextract, ...) | binwalk 3.1.0, unblob 26.6.4 |
| Packets / signals | tshark + capinfos, tcpdump, sigrok-cli + libsigrokdecode | TShark 4.2.2, sigrok-cli 0.7.2 |
| Web / HTTP | mitmdump, HAR + SAZ readers, Google Chrome, Playwright Chromium | mitmproxy 12.2.3, playwright-core 1.58.2 |
| Android | jadx-headless-mcp JAR, Apktool, adb | jadx-headless-mcp 0.7.1, Apktool 2.12.1 |
| Managed code | .NET SDK 8 + ilspycmd | ilspycmd 8.2.0.7535 |
| WASM / EVM | WABT, bundled EVMole (npm) | WABT 1.0.42 |
| Dynamic / cross-arch | Frida (npm binding installed and loadable), qemu-user-static (all targets), wine, cross toolchains (aarch64, arm, mips, mipsel, riscv64, powerpc, mingw-w64) | Frida 17.23.2 binding |
| MCP plumbing | uv (for PyPI MCP servers), supergateway (stdio ↔ Streamable HTTP) | uv 0.13.0, supergateway 4.1.0 |

Layer-by-layer detail, and what is deliberately **not** included:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

---

## Licences and secrets

Nothing that requires a licence is baked in. Both are supplied by mount, and
every secret stays outside the image layers:

| Thing | How |
| ----- | --- |
| Licensed Hopper | drop the DEB in `vendor/`, rebuild (`docs/BYO-LICENSES.md`) |
| Hopper activation state | persisted in the `./vendor/hopper-state` mount |
| IDA install | `IDA_INSTALL_DIR=/home/you/ida-pro-9.4` (read-only bind mount) |
| IDA licence | `config/ida/ida.hexlic` → copied to `~/.idapro` at start-up |
| IDA MCP registration | `config/ida-mcp.json` or `setup-ida-mcp.sh <mode>` |
| JEB | `REA_JEB_MCP_URL` pointing at your running, licensed JEB |
| Any extra `REA_*` override | `config/rea.env` (copied from `docker/rea.env.example`) |

**IDA is not redistributable** — a well-known public IDA Dockerfile
(`blacktop/docker-idapro`) was taken down by DMCA notice in January 2026. This
project therefore never downloads IDA; it consumes your own installer/installation
and can run the MCP server for it either inside this container or as a sidecar
(`compose.ida.yml`, `ida/README.md`).

### IDA or IDA Pro — the same program

They are not two engines to choose between. Hex-Rays ships **one** IDA and sells
it under four plans (IDA Free / Classroom / Home / Pro); the `ida.hexlic` licence
file decides what is unlocked, and their install guide applies to "all product
versions: IDA Pro, IDA Home, or IDA Free". The rows that matter for automation
are **idalib** (headless - Pro, Home and Classroom have it, **Free does not**)
and **IDAPython/C++ SDK** (Free has neither), plus decompilers: IDA Pro
decompiles locally, Home and Free use Hex-Rays' cloud service. So IDA Free can
only ever reach REA through the third-party `ida-free-mcp` plugin attached to a
running GUI. Full breakdown, decision table and mounting instructions:
[docs/ida-variants.md](docs/ida-variants.md).

---

## How REA's IDA "own MCP" question resolves

Yes — REA does not embed IDA support: it **adapts an existing upstream IDA MCP
server** (`docs/ida-provider.md` in the REA repo), so you can run that server
wherever your licence lives, inside this container or as a sidecar. Practically:

* **Headless** — `idalib-mcp` (from `mrexodia/ida-pro-mcp`, database-supervisor
  API) or the official Hex-Rays `ida-mcp` server. Needs **idalib**, so IDA Pro,
  IDA Home or IDA Classroom; **IDA Free has no idalib**. This is the profile REA
  was verified against, and the one to use for unattended containers.
* **Attached** — an IDA GUI with `ida-pro-mcp`'s legacy 1.4.0 tools already has
  the original binary open; REA connects through the upstream stdio proxy and
  never saves or closes your database. (Upstream's `main` is 2.0.0 now and
  serves neither supported profile — pin the versions.)
* **Native** — the `ida-free-mcp` plugin for IDA Free, attached, HTTP. The only
  route that works with a free IDA; needs a GUI and IDA Free's cloud decompiler.
* **Sidecar** — any of the above running in another container/VM/host, reached
  over loopback (below).

Because REA accepts only loopback endpoints for IDA/JEB, this container forwards
a remote/sidecar MCP server onto its own `127.0.0.1` (`REA_IDA_MCP_FORWARD`,
implemented with `socat` in the entrypoint). Templates for each profile live in
[`assets/`](assets/), and `scripts/setup-ida-mcp.sh` writes and validates a
registration inside the container. Which IDA edition unlocks which mode, and how
to mount each: [docs/ida-variants.md](docs/ida-variants.md).

---

## Layout

```
Dockerfile                 single multi-stage build; one engine (REA_ENGINE) +
                           engine marker/env/wrapper; binwalk builder stage
docker-compose.yml         four services (rea-agent, -ghidra, -hopper, -ida)
compose.http.yml           optional Streamable HTTP MCP bridge (port 8811)
compose.ida.yml            optional IDA registration overlay (+ sidecar profile)
.env.example               every knob, documented
Makefile                   build / up / doctor / verify / sizes, per engine
vendor/                    bring-your-own artefacts (licences) — gitignored
ida/README.md              how to build your own private IDA MCP sidecar
assets/ida-mcp.*.json      IDA MCP registration templates per profile
docker/entrypoint.sh       overrides, licence placement, loopback forwards
docker/healthcheck.sh      engine-aware readiness probe
docker/rea.env.example     runtime override template (→ config/rea.env)
docker/verify/             the in-image, engine-aware verification harness
scripts/build.sh           build one engine image (path-mapped for DooD)
scripts/build-all.sh       build all four, then report sizes
scripts/verify.sh          run the harness in a throwaway container
scripts/setup-ida-mcp.sh   wire IDA into REA (6 modes)
scripts/hermes-mcp.yaml    paste-ready Hermes MCP block
docs/                      images, architecture, BYO licences, IDA editions,
                           multi-arch, MCP, troubleshooting, verification
.github/workflows/         CI: build + verify per engine, full on demand
```

---

## Verification

Everything below is run *inside the built image*, against fixtures it builds
itself (C for eight targets, WASM, SQLite, .NET, plist, EVM hex, HAR, pcap,
VCD, a firmware blob, a JS app, an HTML page). No external samples are needed
and nothing is downloaded by the harness.

```bash
scripts/verify.sh --quick      # tools + static analysis + MCP handshake (~2 min)
scripts/verify.sh              # everything, including Ghidra multi-arch + Hopper
make verify ENGINE=ghidra      # same, against the Ghidra-only image
make verify ENGINE=hopper      # ... the Hopper-only image
make verify ENGINE=ida         # ... the engine-less IDA image (native checks skip)
```

The harness is engine-aware: it reads `/usr/local/share/rea/engine` and **skips** checks for
engines the image does not ship rather than failing them, so one harness serves
all four images. A skip always states the reason (`not in this image (engine:
hopper)`), and the `ida` image additionally reports that native analysis needs a
registered IDA.

Phases:

| Phase | What it proves |
| ----- | -------------- |
| `tools` | the image's declared engine profile, the engine paths it advertises, and each helper reporting a version REA admits (e.g. WABT must say 1.0.42, sigrok-cli 0.7.2, mitmdump 12.2.3) |
| `analysis` | for the images that have them: `rea doctor --provider ghidra/hopper` healthy; Ghidra analyses **x86-64, aarch64, armv7, MIPS32 BE, MIPS32 LE, RISC-V64, PowerPC, Windows PE32+**; decompiles; string search; Hopper demo-mode analysis of the x86-64 fixture |
| `static` | `inspect-binary-layout` (pwntools), `inspect-wasm-artifact` (WABT), `inspect-sqlite-database`, `inspect-managed-artifact`/`-members` (.NET), `inspect-plist`, `inspect-evm-interface`, `analyze-javascript-application`, `import-reference-source` |
| `capture` | tshark pcap fields/summary, sigrok VCD decode, binwalk regions, unblob extraction, HAR + a **real mitmdump capture**, Chrome CDP target discovery/page/screenshot capture, Playwright scenario (launch+click+DOM), PTY process capture |
| `clients` | Frida device inventory, adb client/devices, Apktool launcher, JADX engine JAR, IDA registration acceptance, JEB endpoint, Hopper state dir |
| `mcp` | a real MCP client (`docker/verify/mcp-probe.mjs`): `initialize` → `tools/list` (~170 tools) → `tools/call` on the first engine-free tool the *installed release* advertises (on 6.4.0 that is `inspect_binary_layout`; SQLite/WASM/Go are `main`-only) → where the image has an engine, `open_binary` + `analyze_function` + `close_binary` through it; then the Streamable HTTP bridge is started and initialised over HTTP |

Reports land in `work/verify-reports/<timestamp>/` — `summary.txt` plus raw
stdout/stderr per check in `logs/`, so a failure is always inspectable.

### Latest result on this machine

See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) — the recorded per-engine
sweep with the exact commands and pass/fail/skip tables, and
[`docs/verify-engines.txt`](docs/verify-engines.txt) for the raw per-engine summaries.
Final sweep (full harness, one run per image): `all` 96 passed / 0 failed / 14
skipped, `ghidra` 85/0/18, `hopper` 79/0/16, `ida` 72/0/19 — every image
exited 0, and every skip is conditional (engine absent from that image, release
catalog, refused ELF machine, unlicensed IDA/JEB).

---

## Operational notes

* **Resources.** Compose sets `shm_size: 1gb` (Chromium/Playwright) and
  `GHIDRA_HEADLESS_MAXMEM=4G`. Ghidra's first query on a large binary imports
  and auto-analyses it, so give the container a few GB of RAM and raise
  `REA_GHIDRA_STARTUP_TIMEOUT_MS` for very large targets — and raise your MCP
  client's timeout to match (`1800` in the Hermes block).
* **User mapping.** The image runs as uid/gid 1000 (`REA_UID`/`REA_GID`); match
  your host user so `work/` stays writable without sudo.
* **Running from inside another container (Docker-outside-of-Docker).** The
  Docker daemon resolves volume and build-context paths on the *host*, so if you
  invoke `scripts/build.sh` / `scripts/verify.sh` from inside a container (e.g.
  Hermes in Docker with the host socket mounted), tell them how to translate:
  `HOST_PATH_MAP=<container-path>=<host-path>` in `.env`, for the Hermes layout
  `HOST_PATH_MAP=/opt/data=/flashcache/hermes`. Empty by default, which is right
  for a normal host and for compose.
* **Image names come from one place.** `scripts/image-name.sh <engine>` resolves
  the image for an engine: it honours `REA_IMAGE` / `REA_GHIDRA_IMAGE` /
  `REA_HOPPER_IMAGE` / `REA_IDA_IMAGE` from `.env` (GHCR names by default) and
  falls back to a plain local name. The Makefile, `scripts/build.sh`,
  `scripts/verify.sh` and compose all use it, so what you build, what you verify
  and what you pull are never different names. CI fails if they drift.
* **Tool-catalog size.** REA ships ~170 tools. The image defaults to
  `REA_MCP_INPUT_SCHEMA_PROFILE=compact` (~290 KB vs ~496 KB of schema per
  request); set `full` if a client needs complete nested schemas.
* **Everything is Linux.** Several REA families (process capture, packet and
  signal decoding, historical source import) are Linux-only by design — the
  container is exactly that host, which is why this is worth doing in Docker at
  all.
* **Known limits.** Hopper's demo cannot save/export and has 30-minute
  sessions; `qemu-user`/`wine` cover most but not all architectures; IDA Free
  cannot do headless. See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## Upstream references

* REA: <https://rea.tools/get-started/> · <https://github.com/morluto/rea>
* REA provider/RPC details used by this project: `docs/installation.md`,
  `docs/ida-provider.md`, `docs/binary-diagnostics.md`,
  `docs/firmware-analysis.md`, `docs/packet-captures.md`,
  `docs/signal-recordings.md`, `docs/wasm-artifacts.md`,
  `docs/web-network-captures.md`, `docs/browser-scenario-contract.md`,
  `docs/process-capture.md` (all in the REA repository).
* IDA MCP: <https://docs.hex-rays.com/core/mcp> ·
  <https://github.com/HexRaysSA/ida-mcp> · <https://github.com/mrexodia/ida-pro-mcp>
* Hopper: <https://www.hopperapp.com/download>
* Ghidra: <https://github.com/NationalSecurityAgency/ghidra/releases>

## Licence

The files in this repository are yours to use under the MIT licence (see
`LICENSE`). Every third-party tool inside the image keeps its own licence and
terms — the full list, plus the components that are deliberately absent, is in
[`docs/THIRD-PARTY-NOTICES.md`](docs/THIRD-PARTY-NOTICES.md). Two of them (IDA,
JEB) are commercial and must be licensed by you; a third (Hopper) is commercial
with a redistributable demo, and only that demo is ever downloaded here. REA
itself is MIT.
