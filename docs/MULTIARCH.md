# Other architectures: what the container gives you

REA analyses binaries for many architectures; the depth depends on the engine
you point it at and on whether you need to *run* the code or only read it.
These images are built so both are possible.

Which engine you have depends on which image you built: Ghidra in `rea-agent`
and `rea-agent-ghidra`, Hopper in `rea-agent` and `rea-agent-hopper`, none
bundled in `rea-agent-ida` (see [IMAGES.md](IMAGES.md)). The recipes below use
the all-engines service `rea-agent`; swap in your service name
(`rea-ghidra`, `rea-hopper`, `rea-ida`) if you run a single-engine image.

## Architecture coverage of the engines

| Engine            | Architectures it can disassemble/decompile                                        | Notes | Image |
| ----------------- | --------------------------------------------------------------------------------- | ----- | ----- |
| **Ghidra 12.1.4** | x86/x86-64, 16-bit x86 (DOS MZ/COM), ARM/Thumb (32/64), MIPS (32/64, LE/BE, micro), PowerPC, RISC-V, SuperH, 6502/65816, Z80, 68000, Atmel AVR, MSP430, Tricore, ... | The broad engine. The native decompiler for the host (`linux_x86_64`) is shipped and is what REA requires. | `all`, `ghidra` |
| **IDA Pro/Home**  | 60+ processor modules depending on licence tier                                    | Only via your own IDA + MCP registration. IDA **Free** = x86/x86-64 only, cloud decompiler, no idalib. | `all`, `ida` (BYO) |
| **Hopper 6.4.2**  | x86/x86-64, ARM/ARM64 (incl. Mach-O, dylibs), and the container formats of Apple platforms | Weaker on MIPS/PPC/RISC-V. macOS `.app`/FAT binaries and FAT64 are handled by REA's Hopper loader preparation. 6.4.2 is the build REA 6.5.0 admits (launcher digest check). | `all`, `hopper` |

Practical consequence: **Ghidra is the default** for anything unusual. REA's
own docs cover the pinned profiles for MIPS (`MIPS:<LE|BE>:32:default`),
RISC-V (avoids the Andes `default` pitfall), PSP (`Allegrex:LE:32:default`
requires the Ghidra PSP extension) and 16-bit DOS; the relevant env knobs are
in `docker/rea.env.example`.

## What is installed for the non-x86-64 work

| Need                                        | Provided                                                       |
| ------------------------------------------- | -------------------------------------------------------------- |
| Build fixtures for other targets            | cross compilers: `aarch64`, `arm` (gnueabihf), `mips`, `mipsel`, `riscv64`, `powerpc`, `mingw-w64` (PE32+) |
| Run foreign-architecture Linux binaries     | `qemu-user-static` for every qemu target (also usable as `qemu-mips -L /usr/mips-linux-gnu ...`) |
| Run Windows PE binaries                     | `wine` / `wine64`                                              |
| Debug foreign binaries                      | `gdb-multiarch`, `gdbserver` (via `gdb-multiarch --args`), `qemu-*` user-mode gdbstub (`-g 1234`) |
| Emulate instructions statically             | Unicorn 2.1.2 inside REA's pwntools venv (used by `inspect-binary-layout`) |
| Cross-platform core dumps                   | `inspect-recorded-crash` interprets x86-64 **and** AArch64 ELF64 cores |
| Non-Linux formats                           | Mach-O/FAT/FAT64, PE/PE32+, DOS MZ/COM, ELF, raw binary imports, Amiga/C64 containers (Ghidra) |

## Recipes

### Analyse an ARM64 firmware binary with Ghidra

```bash
docker compose exec rea-agent rea analyze /targets/router.bin --provider ghidra --json
# raw/headerless images carry no language hint - pin one:
docker compose exec -e REA_GHIDRA_LANGUAGE_ID="ARM:LE:32:Cortex" \
    rea-agent rea analyze /targets/blob.bin --provider ghidra --json
```

`rea providers --json` and the Ghidra adapter record the effective language and
compiler spec in the analysis profile, and REA fails the session when the
committed profile and the setting disagree - so a mis-pinned language is
reported instead of silently producing wrong pseudocode.

### Run a MIPS binary to observe its behaviour

```bash
docker compose exec rea-agent bash
$ qemu-mips-static -L /usr/mips-linux-gnu /targets/daemon &
$ rea capture-process ./scenario.json --json     # runtime evidence; frida instrumentation
                                                # (list-frida-devices, instrument-with-frida)
                                                # ships with REA 6.5.0
$ gdb-multiarch /targets/daemon -ex 'set sysroot /usr/mips-linux-gnu' ...
```

For pure static analysis of the same file, nothing extra is needed:
`rea decompile /targets/daemon main --provider ghidra --json`.

### Run a Windows PE

```bash
docker compose exec rea-agent bash
$ wine /targets/app.exe
$ rea capture-process ./scenario.json --json      # with executable: "wine"
```

### Cross-build a fixture to compare against a vendor binary

```bash
aarch64-linux-gnu-gcc -O2 -o /work/fixture-aarch64 /work/fixture.c
mips-linux-gnu-gcc   -O2 -static -o /work/fixture-mips /work/fixture.c
```

The verification harness does exactly this: on the images that carry Ghidra it
analyses x86-64, aarch64, armv7, MIPS32 BE, MIPS32 LE, RISC-V64, PowerPC and a
Windows PE32+ through Ghidra on every run (`scripts/verify.sh --only analysis`),
and skips the rest with a reason on the other images.

## Limits worth knowing

* `qemu-user-static` does not cover every architecture (no PowerPC64LE SPE, no
  exotic DSPs). Static analysis still works - only *execution* is limited.
* `wine` will not run 16-bit or driver-level Windows code.
* REA's dynamic families are Linux-only by design (process capture, packet and
  signal decoding use `prlimit`); this is a Linux image, so they are available.
* Kernel modules, hypervisor-protected code and hardware-backed DRM remain
  outside any static tool's reach - REA reports unknowns rather than guessing.
