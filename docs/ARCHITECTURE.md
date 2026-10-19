# What is inside the image, layer by layer

Base: **ubuntu:24.04 (noble), linux/amd64 only**. Every version below is a
build-arg default in the `Dockerfile`, so a rebuild reproduces the same set.

## Why Ubuntu 24.04 and not Debian/Alpine

* REA's automated Hopper installer supports **macOS 12+, Ubuntu 24.04+, Fedora
  41+, Arch** and nothing else; the Hopper Linux package itself is built and
  tested against Ubuntu 24.04.
* Ubuntu 24.04 resolves every pinned auxiliary version REA admits *from apt*
  (sigrok-cli **0.7.2** exactly, TShark 4.x, .NET SDK 8, JDK 21, Qt6 for
  Hopper), which keeps the Dockerfile short and the surface auditable.
* glibc 2.39 is recent enough for the prebuilt Node/Ghidra/WABT artefacts and
  old enough not to break the Hopper demo build.
* Alpine would fight all three engines (musl, no glibc JDK story, no Qt6).

## Layer map

Layers 1-16 are **identical in all four engine images** (the Dockerfile is the
same file; `REA_ENGINE` only changes the last layers). The engine layers are
built last on purpose, so building the second, third and fourth image variant
reuses every shared layer from cache. Notable orderings and pins:

| Layer | Contents | Notable pinned versions |
| ----- | -------- | ----------------------- |
| 1 | build/runtime basics: compilers, `gdb`/`gdb-multiarch`, `strace`, `ltrace`, `binutils`, `elfutils`, `yara`, `upx-ucl`, `nasm`, `qemu-user-static`, `binfmt-support`, X11/EGL/GBM/font stack, `xvfb`, `socat`, `tcpdump`, `util-linux` (prlimit) | Ubuntu 24.04 archives |
| 2 | **Node.js** + npm | 24.22.0 (REA needs 22.19+/24.11+/26+) |
| 3 | **REA** (`rea-agents`) globally installed → `rea` on PATH | 6.7.0 |
| 4 | **WABT** (wasm toolchain), **jadx-headless-mcp** (Android Java engine) and **Wakaru** (JavaScript source recovery) | WABT 1.0.42, jadx-headless-mcp 0.7.1, Wakaru 1.14.0 |
| 5 | **Apktool** launcher (Java wrapper + jar) | 2.12.1 (2.x line REA verified) |
| 6 | **.NET SDK 8** + `ilspycmd` in `/opt/dotnet-tools` | ilspycmd 8.2.0.7535 |
| 7 | Python venvs: **pwntools**, **unblob**, **mitmproxy** | pwntools 4.15.0 + pyelftools 0.33 + Unicorn 2.1.2 (pwntools excludes 2.1.3/2.1.4); unblob 26.6.4; mitmproxy 12.2.3 |
| 8 | firmware/packet/signal tooling: `binwalk` (built from source in a Rust stage), `tshark`/`capinfos`, `sigrok-cli` + `libsigrokdecode`, `adb`, `e2fsprogs`, `sleuthkit`, `squashfs-tools`, `mtools`, `dtc` | binwalk 3.1.0, TShark 4.2.2, sigrok-cli 0.7.2 |
| 9 | **chromium-family browser**: Google Chrome stable + Playwright Chromium (in `/opt/ms-playwright`) | chrome stable, playwright-core 1.58.2's pinned build |
| 10 | **pwndbg** + its venv (for `--debugger-context` on core files) | pwndbg 2026.09.15, git `55596aa` |
| 11 | optional **wine** + cross toolchains (aarch64, arm, mips/mipsel, riscv64, powerpc, mingw-w64) | Ubuntu 24.04 |
| 12 | **uv** and **supergateway** (stdio↔Streamable HTTP MCP bridge) | uv 0.13.1, supergateway 4.2.0 |
| 13 | non-root user `rea` (uid/gid 1000), writable dirs, `ilspycmd`, entrypoint, healthcheck, verification harness, IDA templates | - |
| **17a** | **Ghidra** + native decompiler for `linux_x86_64` (JDK 21 is layer 1 and lives in every image) — `REA_ENGINE=all\|ghidra` | Ghidra 12.1.4 |
| **17b** | **Hopper** (official public demo `.deb`) + Qt6/Xvfb runtime — `REA_ENGINE=all\|hopper` | Hopper 6.6.0 Linux (the build the vendor feed authenticates) |
| **17c** | optional in-image **IDA**, only from `vendor/ida/*.run` — `REA_ENGINE=all\|ida` | off by default |
| **17d** | **engine configuration**: `/usr/local/share/rea/engine`, `/usr/local/share/rea/engine.env`, and the `rea` wrapper that sources it | - |

## Environment contract

The image sets every path REA needs to *find* a helper tool as image-wide `ENV`,
and the engine-specific ones through the wrapper described below - so
`docker exec -i <ctr> rea mcp` behaves exactly like the entrypoint, whichever
engine the image carries.

Always set (engine-independent `ENV`):

```
JAVA_HOME
REA_PWNTOOLS_PYTHON, REA_PWNDBG_GDB, REA_PWNDBG_GDBINIT, REA_PWNDBG_VENV_PATH
REA_WABT_BIN_DIRECTORY, REA_JADX_MCP_JAR, REA_APKTOOL_COMMAND, REA_ADB_PATH
REA_WAKARU_COMMAND (JavaScript source recovery; needs util-linux prlimit)
REA_BINWALK_COMMAND, REA_UNBLOB_COMMAND, REA_TSHARK_COMMAND, REA_CAPINFOS_COMMAND
REA_SIGROK_COMMAND, REA_MITMDUMP_COMMAND, REA_ILSPY_CMD_PATH
REA_BROWSER_NO_SANDBOX, PLAYWRIGHT_BROWSERS_PATH, REA_MCP_INPUT_SCHEMA_PROFILE
REA_ENGINE
```

Engine paths, set per image in `/usr/local/share/rea/engine.env` and injected by the `rea`
wrapper (`/usr/local/bin/rea` → `rea-npm-shim`), so an image never advertises an
engine it does not have:

```
REA_ENGINE=all|ghidra|hopper|ida        # also written to /usr/local/share/rea/engine
GHIDRA_INSTALL_DIR=/opt/ghidra          # all, ghidra
HOPPER_LAUNCHER_PATH, HOPPER_STATE_DIR  # all, hopper
IDADIR=/opt/ida                         # all, ida
REA_ANALYSIS_PROVIDER=ghidra|hopper     # single-engine images only
```

Runtime-only overrides belong in `config/rea.env` (loaded by compose's
`env_file`) or in compose `environment:` (applies to `docker exec` too).
`docker run`/`docker exec` without compose still get the engine paths, because
the wrapper reads the file. The healthcheck, the entrypoint and the verification
harness all read `/usr/local/share/rea/engine` to decide which checks apply.

## Filesystem layout

```
/opt/ghidra                 Ghidra 12.1.4 (GHIDRA_INSTALL_DIR)      [all, ghidra]
/opt/hopper                 Hopper demo + bundled GNUstep libs       [all, hopper]
/opt/ida                    IDA mount point (empty unless you mount INSTALL)  [all, ida]
/opt/venvs/{pwntools,unblob,mitmproxy}
/opt/pwndbg                 pwndbg checkout + .venv
/opt/wabt/bin               wasm2wat, wasm-objdump, wasm-validate
/opt/wakaru/wakaru          Wakaru 1.14.0, REA's JS recovery engine (REA_WAKARU_COMMAND)
/opt/jadx/<jar>             jadx-headless-mcp 0.7.1 (REA_JADX_MCP_JAR)
/opt/dotnet-tools/ilspycmd
/opt/ms-playwright          Playwright Chromium build
/opt/rea/verify             verification harness (engine-aware)
/opt/rea/assets             IDA MCP registration templates
/opt/rea/scripts            setup-ida-mcp.sh
/usr/local/share/rea/engine             engine marker: all | ghidra | hopper | ida
/usr/local/share/rea/engine.env         engine paths + default REA_ANALYSIS_PROVIDER
/usr/local/bin/rea          wrapper that sources engine.env, then the npm shim
/work                       analysis workspace (mounted from ./work)
/targets                    read-only sample drop-box (mounted from ./targets)
/etc/rea                    overrides + secrets (mounted from ./config)
/home/rea                   persistent state: ~/.rea cache, ~/.idapro, Hopper support
```

## What is *not* in the image, on purpose

| Not included | Why |
| ------------ | --- |
| IDA Pro / IDA Home / IDA Free | Hex-Rays does not permit redistribution (a public IDA Dockerfile was DMCA'd in Jan 2026). Your install is mounted into the `ida` image instead — which IDA edition can drive REA headlessly is in `docs/ida-variants.md`. |
| JEB | Commercial, licence-bound, runs as its own MCP server. |
| A licensed Hopper build | Only the public demo is redistributable; licensed DEBs are consumed from `vendor/`. |
| Go toolchain | Not needed by REA (`inspect-go-binary` reads embedded metadata statically). |
| Android SDK/emulator | REA never installs or manages one; `adb` is included so an external device/emulator works. |
| A native analysis engine for **non-x86_64 hosts** | Out of scope: this is an amd64 image. Ghidra *analyses* foreign architectures from here; it does not run on them. |
