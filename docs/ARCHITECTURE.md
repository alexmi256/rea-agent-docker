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

| Layer | Contents | Notable pinned versions |
| ----- | -------- | ----------------------- |
| 1 | build/runtime basics: compilers, `gdb`/`gdb-multiarch`, `strace`, `ltrace`, `binutils`, `elfutils`, `yara`, `upx-ucl`, `nasm`, `qemu-user-static`, `binfmt-support`, X11/EGL/GBM/font stack, `xvfb`, `socat`, `tcpdump`, `util-linux` (prlimit) | Ubuntu 24.04 archives |
| 2 | **Node.js** + npm | 24.21.0 (REA needs 22.19+/24.11+/26+) |
| 3 | **REA** (`rea-agents`) globally installed → `rea` on PATH | 6.4.0 |
| 4 | **Ghidra** + JDK 21, native decompiler for `linux_x86_64` | Ghidra 12.1.4, OpenJDK 21 |
| 5 | **Hopper** (official public demo `.deb`) + Qt6/Xvfb runtime | Hopper 6.5.0 Linux |
| 6 | optional in-image **IDA** (only from `vendor/ida/*.run`) | off by default |
| 7 | **WABT** (wasm toolchain) and **jadx-headless-mcp** (Android Java engine) | WABT 1.0.42, jadx-headless-mcp 0.7.1 |
| 8 | **Apktool** launcher (Java wrapper + jar) | 2.12.1 (2.x line REA verified) |
| 9 | **.NET SDK 8** + `ilspycmd` in `/opt/dotnet-tools` | ilspycmd 8.2.0.7535 |
| 10 | Python venvs: **pwntools**, **unblob**, **mitmproxy** | pwntools 4.15.0 + pyelftools 0.33 + Unicorn 2.1.2; unblob 26.6.4; mitmproxy 12.2.3 |
| 11 | firmware/packet/signal tooling: `binwalk` (built from source in a Rust stage), `tshark`/`capinfos`, `sigrok-cli` + `libsigrokdecode`, `adb`, `e2fsprogs`, `sleuthkit`, `squashfs-tools`, `mtools`, `dtc` | binwalk 3.1.0, TShark 4.2.2, sigrok-cli 0.7.2 |
| 12 | **chromium-family browser**: Google Chrome stable + Playwright Chromium (in `/opt/ms-playwright`) | chrome stable, playwright-core 1.58.2's pinned build |
| 13 | **pwndbg** + its venv (for `--debugger-context` on core files) | pwndbg 2026.09.15, git `55596aa` |
| 14 | optional **wine** + cross toolchains (aarch64, arm, mips/mipsel, riscv64, powerpc, mingw-w64) | Ubuntu 24.04 |
| 15 | **uv** and **supergateway** (stdio↔Streamable HTTP MCP bridge) | uv 0.13.0, supergateway 4.1.0 |
| 16 | non-root user `rea` (uid/gid 1000), writable dirs, entrypoint, healthcheck, verification harness, IDA templates | - |

## Environment contract

The image sets every path REA needs to *find* a tool, as image-wide `ENV`
(not a sourced file), so `docker exec -i <ctr> rea mcp` behaves exactly like the
entrypoint:

```
JAVA_HOME, GHIDRA_INSTALL_DIR, HOPPER_LAUNCHER_PATH, HOPPER_STATE_DIR, IDADIR
REA_PWNTOOLS_PYTHON, REA_PWNDBG_GDB, REA_PWNDBG_GDBINIT, REA_PWNDBG_VENV_PATH
REA_WABT_BIN_DIRECTORY, REA_JADX_MCP_JAR, REA_APKTOOL_COMMAND, REA_ADB_PATH
REA_BINWALK_COMMAND, REA_UNBLOB_COMMAND, REA_TSHARK_COMMAND, REA_CAPINFOS_COMMAND
REA_SIGROK_COMMAND, REA_MITMDUMP_COMMAND, REA_ILSPY_CMD_PATH
REA_BROWSER_NO_SANDBOX, PLAYWRIGHT_BROWSERS_PATH, REA_MCP_INPUT_SCHEMA_PROFILE
```

Runtime-only overrides belong in `config/rea.env` (loaded by the entrypoint) or
in compose `environment:` (applies to `docker exec` too).

## Filesystem layout

```
/opt/ghidra                 Ghidra 12.1.4 (GHIDRA_INSTALL_DIR)
/opt/hopper                 Hopper 6.5.0 demo + bundled GNUstep libs
/opt/ida                    IDA mount point (empty unless you mount INSTALL)
/opt/venvs/{pwntools,unblob,mitmproxy}
/opt/pwndbg                 pwndbg checkout + .venv
/opt/wabt/bin               wasm2wat, wasm-objdump, wasm-validate
/opt/jadx/<jar>             jadx-headless-mcp 0.7.1 (REA_JADX_MCP_JAR)
/opt/dotnet-tools/ilspycmd
/opt/ms-playwright          Playwright Chromium build
/opt/rea/verify             verification harness
/opt/rea/assets             IDA MCP registration templates
/opt/rea/scripts            setup-ida-mcp.sh
/work                       analysis workspace (mounted from ./work)
/targets                    read-only sample drop-box (mounted from ./targets)
/etc/rea                    overrides + secrets (mounted from ./config)
/home/rea                   persistent state: ~/.rea cache, ~/.idapro, Hopper support
```

## What is *not* in the image, on purpose

| Not included | Why |
| ------------ | --- |
| IDA Pro / IDA Home / IDA Free | Hex-Rays does not permit redistribution (a public IDA Dockerfile was DMCA'd in Jan 2026). See `docs/BYO-LICENSES.md`. |
| JEB | Commercial, licence-bound, runs as its own MCP server. |
| A licensed Hopper build | Only the public demo is redistributable; licensed DEBs are consumed from `vendor/`. |
| Go toolchain | Not needed by REA (`inspect-go-binary` reads embedded metadata statically). |
| Android SDK/emulator | REA never installs or manages one; `adb` is included so an external device/emulator works. |
| A native analysis engine for **non-x86_64 hosts** | Out of scope: this is an amd64 image. Ghidra *analyses* foreign architectures from here; it does not run on them. |
