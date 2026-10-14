# Bring-your-own licences: IDA, Hopper, JEB (and what REA does itself)

REA is deliberately a *bring-your-own-engine* tool: it never installs,
activates, or licenses a commercial product, and this image does not either.
What this project does is make the bring-your-own step mechanical.

## Summary

| Engine            | Shipped in the image? | How you supply it                                     | Env / mount                                |
| ----------------- | --------------------- | ----------------------------------------------------- | ------------------------------------------ |
| Ghidra 12.1.x     | yes (`REA_ENGINE=all\|ghidra`) | built in, `/opt/ghidra`                    | `GHIDRA_INSTALL_DIR`, `JAVA_HOME`          |
| Hopper            | yes, **public demo** (`REA_ENGINE=all\|hopper`) | replace `vendor/*.deb` with your licensed package | `HOPPER_LAUNCHER_PATH`, `HOPPER_STATE_DIR` |
| IDA Pro/Home/Free | **no** (never, in any image) | bind-mount your install (+ `ida.hexlic`)       | `IDADIR`, `~/.idapro/`, `REA_IDA_MCP_CONFIG` |
| JEB               | **no**                | run JEB yourself, point REA at its MCP endpoint        | `REA_JEB_MCP_URL`                          |
| Frida / adb tooling | yes (MIT/Apache)    | built in                                              | -                                          |

Which engines each image carries, and why you would pick one:
[docs/IMAGES.md](IMAGES.md). "IDA" is not a separate product from "IDA Pro" -
same program, different licence tier; see [docs/ida-variants.md](ida-variants.md)
for the edition table (idalib / IDAPython / local decompiler availability).

Note on IDA: Hex-Rays enforces its redistribution terms. `blacktop/docker-idapro`
was taken down by DMCA notice in January 2026, which is why this project never
bakes IDA into a distributed image by default (`INSTALL_IDA=auto` only consumes
`vendor/ida/*.run`, something you supply from your own licence).

## Hopper

The Linux packages are public downloads and the demo is fully functional for
REA's use (REA drives the Linux demo headlessly on a private Xvfb display and
chooses demo mode itself). Demo limits: no save/export, no debugger backend,
30-minute sessions.

**Version pin matters.** REA does not just check that Hopper exists: it hashes
the launcher binary and compares it against the launcher digests of the one
Linux package it was validated with per package family
(`SUPPORTED_RELEASES`/`SUPPORTED_HOPPER_SHA256` in
`src/application/LinuxHopper.ts`). For REA 6.4.0 that is **Hopper 6.4.2
(Linux demo)**. A different build makes `rea doctor --provider hopper --json`
report `hopper-version` as `config_drift`.

This image therefore ships the pinned build by default, and derives the
filename from the installed REA package at build time rather than hardcoding
it:

```bash
# inside the image - this is the build's own step; a host shell has no REA:
docker run --rm --entrypoint sh rea-agent-hopper:6.4.0-linux-amd64 -c \
  'grep -rohE "Hopper-[0-9.]+-Linux-demo[.]deb" "$(npm root -g)/rea-agents/dist" | head -1'
```

The launcher digest is printed by the build log
(`Hopper launcher sha256: 0294ced1…`) and is in REA's supported set.

```bash
# default (public demo 6.4.2 - the build REA 6.4.0 pins) - what compose does
make build            # the all-engines image
make build-hopper     # the Hopper-only image

# licensed package: drop the DEB into vendor/ and rebuild
cp ~/Downloads/Hopper-6.4.2-Linux.deb vendor/
scripts/build.sh --engine hopper        # or ENGINE=all / make build
docker compose --profile hopper up -d rea-hopper
docker compose exec rea-hopper rea doctor --provider hopper --json
```

Hopper stores its state (including activation) under its GNUstep application
support directory, which this project mounts as a volume:

```
HOPPER_STATE_DIR=/home/rea/.local/share/hopper     # inside the container
bind source: ./vendor/hopper-state                 # on the host (HOPPER_STATE_VOLUME)
```

Activation is operator-owned. If you have a licence, activate it once (for
example by running Hopper interactively against that state directory) and the
volume keeps the activation across container rebuilds. REA never touches the
credentials.

## IDA

Two supported arrangements.

### A. IDA inside this container (recommended)

Use the engine-less `rea-ida` service - it exists for exactly this, and its image
carries no other engine to confuse the provider choice. (The `rea-agent` service
works too, via the same overlay: `-f docker-compose.yml -f compose.ida.yml up -d
rea-agent` - the base file has to be listed too, or compose only sees the
overlay's service definitions.)

```bash
# 1. point at an existing installation - do not bake IDA into a pushed image
grep -q IDA_INSTALL_DIR .env || cat >>.env <<'EOF'
IDA_INSTALL_DIR=/home/you/ida-pro-9.4
EOF

# 2. supply the licence file (never committed: .gitignore excludes *.hexlic)
mkdir -p config/ida && cp ~/ida.hexlic config/ida/

# 3. build and start the IDA image with the IDA overlay
make build-ida
docker compose -f docker-compose.yml -f compose.ida.yml --profile ida up -d rea-ida
docker compose exec rea-ida ls -l /opt/ida | head
docker compose exec rea-ida ls -l ~/.idapro       # the licence lands here

# 4. install an MCP server for IDA and register it with REA
docker compose exec rea-ida /opt/rea/scripts/setup-ida-mcp.sh idalib
docker compose exec rea-ida rea doctor --provider ida --json
```

`setup-ida-mcp.sh` modes: `idalib` (headless supervisor; IDA Pro/Home/Classroom -
**not IDA Free**, which has no idalib; the shape REA's adapter was verified
against), `official` (Hex-Rays' own `ida-mcp`, IDA 9.4+), `official-http`,
`attached` (GUI already open with `ida-pro-mcp` 1.4.0), `native` (IDA Free via the
`ida-free-mcp` plugin), `sidecar`.

Licence placement, per Hex-Rays docs: `ida.hexlic` goes into the IDA install
directory **or** `$HOME/.idapro` (Windows: `%APPDATA%/Hex-Rays/IDA Pro`). The
entrypoint copies anything you mount at `/etc/rea/ida/*.hexlic` into
`$HOME/.idapro` (or set `IDA_LICENSE_PATH` to a directory).

Baking IDA into a private image is possible (`INSTALL_IDA=1` + `vendor/ida/*.run`,
see the Dockerfile's IDA step) but that image must stay private.

### B. IDA MCP elsewhere (sidecar / VM / another host)

REA only accepts **loopback** endpoints for its IDA adapter, so the container
forwards a remote MCP server onto its own `127.0.0.1`:

```
REA_IDA_MCP_FORWARD=ida-mcp:8745      # where the IDA MCP really is
REA_IDA_MCP_LOCAL_PORT=8745           # where REA looks for it
REA_IDA_MCP_CONFIG=/etc/rea/ida-mcp.json
```

`compose.ida.yml` adds a `ida-mcp` service (profile `ida-sidecar`) that you
point at your own image with `IDA_MCP_IMAGE=...`; `ida/README.md` has a
starting Dockerfile. Note IDA Free has no `idalib`, so headless profiles need
IDA Pro, IDA Home or IDA Classroom; IDA Free only works in the attached GUI
profiles (and its decompiler is Hex-Rays' cloud service). The edition-by-edition
breakdown is in [docs/ida-variants.md](ida-variants.md).

## JEB

JEB serves its own MCP endpoint from a licensed, running client (verified with
JEB 5.48.0 serving `jeb-mcp-server` 1.3.0 over Streamable HTTP). Start it, then:

```
REA_JEB_MCP_URL=http://127.0.0.1:8425/mcp     # literal loopback host required
REA_JEB_MCP_FORWARD=jeb-host:8425             # optional, if JEB runs elsewhere
```

```bash
docker compose exec rea-agent rea inspect-jeb-client --json
```

## What REA itself needs (no licence, already handled)

* Node.js 24 LTS (REA requires 22.19+/24.11+/26+)
* JDK 21 for Ghidra's JVM bridge
* Python 3 for REA's own helper processes
* `prlimit` (util-linux) for the firmware/signal/packet/EVM families
* Several of REA's families are *refused* on non-Linux hosts; this image is
  Linux x64, which is the most capable host REA supports.
