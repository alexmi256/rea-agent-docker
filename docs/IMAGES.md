# The four images: pick an engine, not a toolchain

Most people use exactly one native disassembler. Installing all three engines in
every container means carrying Ghidra *and* Hopper *and* whatever licence-free
corner of IDA you can arrange, and paying for two of them in image size and
build time. So this project builds one image per engine, from one Dockerfile:

| Image | `REA_ENGINE` | Native engine | Auxiliary toolchain | Use it when |
| --- | --- | --- | --- | --- |
| `rea-agent:6.5.0-linux-amd64` | `all` | Ghidra **+** Hopper | full | you want everything in one container, or you want to compare engines on one target |
| `rea-agent-ghidra:6.5.0-linux-amd64` | `ghidra` | Ghidra 12.1.4 | full | you analyse many architectures (the usual case) |
| `rea-agent-hopper:6.5.0-linux-amd64` | `hopper` | Hopper (demo or your licensed DEB) | full | you prefer Hopper's output, or you own a Hopper licence |
| `rea-agent-ida:6.5.0-linux-amd64` | `ida` | **none bundled** - bring your own IDA | full | you own IDA and want REA to drive it (see [ida-variants.md](ida-variants.md)) |

**The auxiliary toolchain is identical in all four.** Firmware extraction
(binwalk, unblob, 7z/cpio/squashfs/sleuthkit/mtools, binfmt+qemu), capture
analysis (tshark, capinfos, sigrok, mitmdump, Chrome CDP, Playwright), managed
code (.NET + ilspycmd), Android (adb, Apktool, JADX), JS/Electron, debuggers
(gdb-multiarch, pwndbg), pwntools/pyelftools/unicorn, cross toolchains and wine
are all present regardless of engine. That is deliberate: those are what REA's
non-native families need, and they are engine-independent.

What follows from that: **the `ida` image is still useful with no IDA at all.**
Artifacts, firmware, captures, `.NET`/JS/Android targets, binary layout and
everything else REA does without a disassembler work out of the box; only the
native analysis commands need IDA registered.

## How an image knows what it is

Each image carries three things that replace the old "assume Ghidra and Hopper
are both here" behaviour:

| Path | Content | Read by |
| --- | --- | --- |
| `/usr/local/share/rea/engine` | `all` / `ghidra` / `hopper` / `ida` | healthcheck, entrypoint, verification harness |
| `/usr/local/share/rea/engine.env` | only the paths this image needs (`GHIDRA_INSTALL_DIR`, `HOPPER_LAUNCHER_PATH`, `IDADIR`, `JAVA_HOME`) plus `REA_ANALYSIS_PROVIDER` for single-engine images | the `rea` wrapper |
| `/usr/local/bin/rea` | wrapper that sources `engine.env`, then execs the real shim | every `rea` invocation |

The wrapper is what makes `docker exec -i <container> rea mcp` work with no
compose environment at all - and what keeps a single-engine image *honest*: an
image without Ghidra never advertises `GHIDRA_INSTALL_DIR`, so REA never sees a
stale path to a missing engine. The healthcheck and the verification harness read
`/usr/local/share/rea/engine` and skip (rather than fail) on checks for engines the image
does not ship, which is why one harness serves all four.

## Pull instead of build (GHCR)

You do not have to build anything. All four images are published to the GitHub
Container Registry by CI on every push to `main`, and the packages are **public**
(no login, no token):

| Image | Engine | Tags |
| --- | --- | --- |
| `ghcr.io/alexmi256/rea-agent` | Ghidra + Hopper | `6.5.0-linux-amd64`, `latest` |
| `ghcr.io/alexmi256/rea-agent-ghidra` | Ghidra | `6.5.0-linux-amd64`, `latest` |
| `ghcr.io/alexmi256/rea-agent-hopper` | Hopper | `6.5.0-linux-amd64`, `latest` |
| `ghcr.io/alexmi256/rea-agent-ida` | no engine (BYO IDA) | `6.5.0-linux-amd64`, `latest` |

```bash
# the compose defaults are already these names, so:
docker compose pull                       # only the active profiles' services (here: rea-agent)
docker compose --profile ghidra up -d rea-ghidra   # pulls that image on demand

# or, explicitly per engine
docker pull ghcr.io/alexmi256/rea-agent-ghidra:6.5.0-linux-amd64
make pull ENGINE=hopper                   # same thing via the Makefile
make pull-all                             # all four (~8 GB each)
make sizes                                # what you now have locally, with sizes
```

A pulled image is a normal rea-agent image: `make verify ENGINE=ghidra` runs the
same harness against it (the resolver in `scripts/image-name.sh` picks the pulled
name), and `docker compose exec rea-ghidra rea doctor --json` works immediately.

Notes:

* **`latest` is per image, not per repo.** There is no "one latest": each engine
  image tracks its own newest build, and the version tag (`6.5.0-linux-amd64`)
  is what you should pin in anything reproducible.
* **Air-gapped transfer.** `docker save ghcr.io/alexmi256/rea-agent-ghidra:6.5.0-linux-amd64 | gzip > rea-ghidra.tgz`
  then `docker load < rea-ghidra.tgz` on the other side.
* **The images are ~8 GB each** and most of that is the auxiliary toolchain, not
  the engine — see the size table below for the per-engine deltas.
* **Rebuilds are unnecessary but supported**: the published names are exactly what
  `make build-ghidra` tags, so building from source *replaces* the pulled image
  rather than creating a second one.

### Publishing your own fork

The workflow publishes `ghcr.io/<repo-owner>/...` automatically — on a fork, the
owner is your account, so the images appear under your namespace and the compose
defaults (which point at `alexmi256`) will no longer match. To publish under your
own account:

1. Update the four `REA_*_IMAGE` names in `.env.example`, and the fallbacks in
   `docker-compose.yml` / `compose.http.yml`, to your own
   `ghcr.io/<you>/...` names (the CI `validate` job fails when these disagree with
   `scripts/image-name.sh`'s resolution and the `docker-compose.yml` defaults -
   it only checks that the docs still *mention* `ghcr.io`, so renaming the docs
   to match is on you).
2. The `build` job declares `permissions: packages: write`, and that alone is
   enough even when the repository's default workflow permission is only *read* —
   verified on this repo, whose default is `read` and whose push succeeded,
   because an explicit `permissions:` block overrides the default. You only need
   **Settings → Actions → General → Workflow permissions** if you *remove* that
   block and then see `denied: permission_denied: write_package`.
3. Keep the `org.opencontainers.image.source` label pointing at *your* repo (it is
   built from `github.server_url`/`github.repository` in CI). It is what links the
   package to the repository, and what makes the package inherit the repository's
   visibility — drop it and your images stay private and unlinked in the UI.
4. Push to `main`; the packages appear under your profile → Packages. To make them
   public (if your repo is public and they did not inherit it): package →
   **Settings → Change visibility → Public**.

## Building

```bash
make build              # the all-engines image         (= scripts/build.sh --engine all)
make build-ghidra       # Ghidra only
make build-hopper       # Hopper only
make build-ida          # engine-less, bring your own IDA
make build-all          # all four, in order

scripts/build.sh --engine ghidra --verify-quick   # build + smoke-verify in one go
scripts/build.sh --engine ghidra --no-cache       # force a full rebuild
```

Build them in the order `make build-all` uses (`all`, `ghidra`, `hopper`, `ida`)
and only the engine layers are compiled each time: every other layer is identical
across the four images, so Docker serves it from cache. Building `ghidra`
directly on a cold cache works fine, it is just slower for the second and third
engine afterwards.

## Running

One service per engine in `docker-compose.yml`. Name the service explicitly - a
bare `--profile ghidra up -d` would also start the default `rea-agent` service,
because a service without a profile always starts:

```bash
docker compose up -d                                  # rea-agent (Ghidra + Hopper)
docker compose --profile ghidra up -d rea-ghidra      # Ghidra only
docker compose --profile hopper up -d rea-hopper      # Hopper only
docker compose --profile ida    up -d rea-ida         # IDA, bring your own

make up ENGINE=hopper         # the same thing, with the service name handled
make up-ghidra  make up-hopper  make up-ida
```

Each service has its own container name (`rea-agent`, `rea-agent-ghidra`,
`rea-agent-hopper`, `rea-agent-ida`) and its own `/home/rea` volume
(`rea-agent-home`, `...-ghidra`, `...-hopper`, `...-ida`). They all share
`./work`, `./targets` and `./config`, so evidence and targets are in one place
whichever engine produced them - but only run one engine container at a time
against the same workspace, or two analyses will race over the same files.

### Talking to the container's MCP surface

```bash
# stdio - what Hermes/Claude Code/Codex spawn (container name, not service name)
docker exec -i rea-agent-ghidra rea mcp

# Streamable HTTP bridge on 127.0.0.1:8811
REA_IMAGE=rea-agent-ghidra:6.5.0-linux-amd64 REA_ENGINE=ghidra \
  docker compose -f docker-compose.yml -f compose.http.yml --profile ghidra up -d rea-mcp-http
make http-up ENGINE=hopper     # same thing, for the image you built
```

For a Hermes MCP entry, only the container name changes between engines:

```yaml
mcp_servers:
  rea:
    command: docker
    args: [exec, -i, rea-agent-ghidra, rea, mcp]     # rea-agent-hopper / rea-agent-ida
    timeout: 1800
    connect_timeout: 120
```

See [HERMES-MCP.md](HERMES-MCP.md) for the full block and the reasoning behind
those timeouts, and [ida-variants.md](ida-variants.md) for IDA licensing.

## Sizing and slimming

Every image is large on purpose (the brief was "a heavy base with a pile of tools
built in"), and the auxiliary toolchain dominates the size - the engine is a
minority of it. Measured on this project's build host:

| Image | Size (`docker image inspect .Size`) |
| --- | --- |
| `rea-agent` (Ghidra + Hopper) | 8.39 GiB — 9,008,689,771 bytes |
| `rea-agent-ghidra` | 8.30 GiB — 8,916,518,011 bytes |
| `rea-agent-hopper` | 7.55 GiB — 8,102,797,549 bytes |
| `rea-agent-ida` | 7.46 GiB — 8,010,625,009 bytes |

Measured with `make sizes` on this build host (amd64); the byte counts move by a
few tens of KB between rebuilds even with identical inputs (layer timestamps), so
treat the GiB figures as the stable number. Read the deltas rather than the
totals: **Ghidra costs ~906 MB and Hopper ~92 MB** on top of the engine-less
`ida` image (Hopper's Qt6/X11 runtime is already in the shared base layers, which
the browser tooling needs anyway). The auxiliary toolchain is the rest, so the
engine choice is a smaller lever on size than you might expect — what you really
buy with a single-engine image is a smaller surface (no second engine's
libraries, licence files or runtime in the container), a quicker build, and a
`rea providers` listing that can only say one thing. If size is the goal, switch
components off instead:

```bash
scripts/build.sh --engine ghidra \
  --arg INSTALL_CHROME=0 --arg INSTALL_PLAYWRIGHT=0 \
  --arg INSTALL_WINE=0 --arg INSTALL_CROSS_TOOLCHAINS=0 --arg INSTALL_PWNDBG=0
```

`INSTALL_CHROME`, `INSTALL_PLAYWRIGHT`, `INSTALL_PWNDBG`, `INSTALL_WINE`,
`INSTALL_CROSS_TOOLCHAINS` and `INSTALL_IDA` are all `1`/`0` (IDA also accepts
`auto`: install `vendor/ida/*.run` if present, never download). Turning one off
only removes that tool's *own* checks from the harness - REA will report the
corresponding family as unavailable, which is honest and expected.

## When one engine is not enough

- The `all` image exists for exactly that, and its `rea providers --json` lists
  both engines; pass `--provider ghidra` / `--provider hopper` per command, or set
  `REA_ANALYSIS_PROVIDER` (auto-selection refuses an ambiguous choice and names
  the candidates rather than guessing).
- To compare engines without rebuilding, run two containers with explicit names
  and separate home volumes, e.g. `docker run --name rea-g -v ./work:/work …
  rea-agent-ghidra:6.5.0-linux-amd64 sleep infinity` alongside the Hopper one.
- Hopper's architecture coverage is narrower than Ghidra's (Ghidra ships MIPS,
  RISC-V, PowerPC, SuperH, 6502, Z80, DOS MZ, and more in the same image). If
  architecture breadth is the reason you are shopping, the Ghidra image is the
  one you want.
