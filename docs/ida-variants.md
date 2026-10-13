# IDA, IDA Pro, IDA Home, IDA Free - what is actually different

**Short answer: IDA and IDA Pro are not two separate programs that both need to
be installed. They are the same program.** Hex-Rays ships one engine and sells it
under four plans - IDA Free, IDA Classroom, IDA Home, IDA Pro - and the licence
file (`ida.hexlic`) is what decides how much of that engine is unlocked. Their
own installation guide puts it plainly:

> "The installation steps are valid for all product versions: IDA Pro, IDA Home,
> or IDA Free."
> — <https://docs.hex-rays.com/getting-started/install-ida>

So "IDA" in REA's docs means "an IDA-family installation"; there is no separate
non-Pro product called IDA that you would install alongside IDA Pro. The name
"IDA Pro" is just the commercial tier of the same tool (historically the tool was
*the* IDA; "Pro" was added when the free tier appeared).

There is one wrinkle worth knowing before you buy anything: **IDA Free is a
separate download with its own installer** (<https://hex-rays.com/ida-free>), not
a licence-gated mode of the paid installer. It is free to download without a
licence at all. Everything else is the same binary tree, unlocked by `ida.hexlic`.

## The plans, and the rows that matter here

From Hex-Rays' own comparison table (<https://hex-rays.com/ida-pro>):

| | IDA Free | IDA Classroom | IDA Home | IDA Pro |
| --- | --- | --- | --- | --- |
| Commercial use | ❌ | ❌ | ❌ | ✅ |
| Disassemblers | x86-32, x86-64 | x86-32/64, ARM-32/64 | 1 of PC, ARM, MIPS, PPC, RISC-V (32/64) | All 60+ |
| Decompilers | cloud only (x86) | cloud only (x86, ARM) | **cloud only** | 2-12 **local** decompilers |
| Debugger | local x86/x64 | local | local / GDB server | local + remote |
| IDAPython + C++ SDK | ❌ | ✅ | ✅ | ✅ |
| **idalib** (headless library) | ❌ | ✅ | ✅ | ✅ |
| Lumina | ❌ | public | public | public **+ private** |
| IDA Feeds | ❌ | ❌ | ❌ | ✅ |

Two rows drive everything else for automation:

- **idalib** is the library that lets IDA run without a GUI. No idalib means no
  headless IDA, which means no IDA worker that a server can drive.
- **IDAPython / C++ SDK** is what most IDA MCP servers are built on. No SDK means
  no script-based integration.

## Which edition can drive REA

REA does not analyse with IDA itself - it adapts an *existing* IDA MCP server
into its native tools (`docs/ida-provider.md` in the REA repository). REA admits
three upstream shapes, and each shape needs a different IDA edition:

| REA mode | Upstream server | Needs idalib? | Needs GUI? | Works with |
| --- | --- | --- | --- | --- |
| **headless** | mrexodia/ida-pro-mcp supervisor (`idb_open`/`idb_list`/`idb_close`) or the official Hex-Rays `ida-mcp` | ✅ yes | no | IDA Pro, IDA Home, IDA Classroom |
| **attached** | mrexodia/ida-pro-mcp **1.4.0** legacy GUI tools | no | ✅ yes (IDA open on the target) | IDA Pro (and Home/Classroom, since they ship IDAPython) |
| **native** | the `ida-free-mcp` plugin over HTTP | no | ✅ yes | **IDA Free**, IDA Pro |

Reading that table:

- **IDA Pro and IDA Home are the comfortable choices.** Both include idalib, so
  REA's headless profile works: REA copies your binary aside, digest-checks it,
  asks the supervisor for its own worker session, analyses, then closes with
  `save: false`. You never run a GUI.
- **IDA Classroom also has idalib**, but its licence forbids commercial use, so
  it is a teaching/learning route rather than a work one.
- **IDA Free is the awkward one.** It has neither idalib nor IDAPython, so
  neither the headless nor the attached-GUI path is available. The only way it
  reaches REA is the third-party `ida-free-mcp` **native plugin** attached to a
  running IDA Free GUI - which means a GUI, an X display, and (because IDA Free
  ships no local decompiler) decompilation through IDA Free's *cloud* service,
  which needs network access and may prompt for consent. That path exists in REA
  and is documented, but it is not the one you want for an unattended container.
- Decompiler quality also differs: IDA Home and Free use **cloud** decompilers;
  only IDA Pro decompiles locally, with 2-12 decompilers of your choice.

## Consequence for these images

Nothing about IDA is downloaded, installed, or licensed by this project - partly
because Hex-Rays does not permit redistribution, and partly because a
redistribution image was taken down by DMCA in January 2026. You bring your own
IDA either way. What changes per edition is only *where the files go*:

| Edition | Bring | Mount | REA mode |
| --- | --- | --- | --- |
| IDA Pro / Home | installer (`*.run`) baked in at build, or an existing install | `${IDA_INSTALL_DIR}:/opt/ida:ro` | headless (`idalib`) |
| IDA Pro | activated `ida.hexlic` | `${IDA_LICENSE_DIR}:/etc/rea/ida:ro` (the entrypoint places it in `$HOME/.idapro`) | headless |
| IDA (floating licence) | nothing - a licence **server** | no file; IDA reads `HEXRAYS_LICENSE_SERVER`/its own config | headless |
| IDA Free | the free installer | `${IDA_INSTALL_DIR}:/opt/ida:ro` | native plugin, attached to a GUI |

Concretely, the IDA Pro / IDA Home headless route in this project is:

```bash
# .env
IDA_INSTALL_DIR=/opt/ida-pro-9.4      # your extracted/installed IDA
IDA_LICENSE_DIR=./config/ida          # contains ida.hexlic

# start the engine-less image with the IDA overlay
docker compose -f docker-compose.yml -f compose.ida.yml --profile ida up -d rea-ida

# register the upstream server once (writes /home/rea/.rea/ida-mcp.json)
docker compose exec rea-ida /opt/rea/scripts/setup-ida-mcp.sh idalib

# validate the registration - this never starts IDA
docker compose exec rea-ida rea doctor --provider ida --json
```

`setup-ida-mcp.sh` accepts `idalib`, `official`, `official-http`, `attached`,
`native` (IDA Free plugin) and `sidecar` (IDA MCP running elsewhere), and never
activates or licenses anything - it only writes a registration file and reports
what REA makes of it.

## Two things that bite people

1. **Give REA the original binary, not an `.idb`/`.i64`.** The attached and
   native profiles bind to IDA's *recorded input hash*, so REA must be handed the
   same file IDA opened, byte for byte. Headless does not care - REA makes its own
   digest-verified copy.
2. **Loopback only.** REA accepts IDA/JEB MCP endpoints on `127.0.0.1` only. An
   upstream server running in another container or host must be published onto
   the container's loopback; the entrypoint does that for you when you set
   `REA_IDA_MCP_FORWARD=<host>:<port>` (see `compose.ida.yml`).
3. **Pin the upstream version.** REA checks the tool profile the server
   advertises against the shape it was verified with. mrexodia/ida-pro-mcp moved
   to 2.0.0 on `main`, which renamed the GUI tools and dropped `idb_close`, and
   serves *neither* admitted profile - it fails at startup with the missing tool
   names. Use a 1.4.0 (attached) or a supervisor build (headless).

## Verification status, stated honestly

REA's own real-provider IDA workflows were run on Windows x64 (IDA 9.3 headless
supervisor, and IDA Pro 9.3 GUI native) and macOS arm64 (IDA Professional 9.1,
headless). REA's documentation explicitly lists *Linux headless engine operation*
as something that "requires their corresponding real workflows before support is
claimed". This project therefore ships the wiring, the templates and the
registration helpers, and verifies everything that does not need your licence -
but it cannot verify an IDA analysis end to end without a licensed install, and
it does not pretend otherwise. `scripts/verify.sh` and the in-image harness mark
every IDA check as a skip with that reason until you provide one.
