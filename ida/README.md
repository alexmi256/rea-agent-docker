# Running an IDA MCP server as a sidecar

IDA itself is never shipped by this repo. If you want REA to use IDA while
keeping the IDA install in its own container, build your own private image
here and point `IDA_MCP_IMAGE` at it.

REA's IDA adapter talks to an *existing* upstream MCP registration. Two
families are supported (see `assets/ida-mcp.*.json` and
`docs/BYO-LICENSES.md`):

| Upstream                                        | Registration                     | Notes                                                      |
| ----------------------------------------------- | -------------------------------- | ---------------------------------------------------------- |
| Official Hex-Rays MCP (`HexRaysSA/ida-mcp`)     | `ida-mcp http --host --port`     | IDA 9.4+, idalib, headless; **recommended**                |
| `mrexodia/ida-pro-mcp` (`idalib-mcp`)           | `idalib-mcp --stdio`             | IDA Pro/Home (not Free); worker supervisor API              |
| `mrexodia/ida-pro-mcp` GUI (legacy 1.4.0)       | stdio proxy to GUI RPC           | attached profile: binary must already be open in the GUI    |
| `0xshlomil/ida-free-mcp` plugin                 | `{"mode":"attached","protocol":"native","url":...}` | IDA Free, GUI attached, plugin binds 0.0.0.0 (firewall it) |

## Minimal private sidecar image

```dockerfile
# ida/Dockerfile - NOT built by this project; build it yourself.
FROM ubuntu:24.04

ARG IDA_INSTALLER=ida-pro_94_x64linux.run

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

# uv provides the official `ida-mcp` entry point
RUN curl -LsSf https://astral.sh/uv/0.13.0/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

COPY ${IDA_INSTALLER} /tmp/ida.run
RUN chmod +x /tmp/ida.run \
 && /tmp/ida.run --mode unattended --prefix=/opt/ida --unattendedmodeui none \
 && rm /tmp/ida.run

ENV IDADIR=/opt/ida PATH=/opt/ida:$PATH
# Activation state (mounted at runtime, never baked in):
VOLUME /home/ida/.idapro

EXPOSE 8745
ENTRYPOINT ["uvx", "ida-mcp"]
CMD ["http", "--host", "0.0.0.0", "--port", "8745"]
```

Then, in `.env`:

```
IDA_MCP_IMAGE=my-private-ida-mcp:9.4
IDA_INSTALL_DIR=/path/with/readable/ida          # optional, for REA-side reads
IDA_LICENSE_DIR=/path/with/ida.hexlic
```

and start it with the profile:

```bash
docker compose -f docker-compose.yml -f compose.ida.yml --profile ida-sidecar up -d
```

## Pointing REA at it

REA enforces loopback endpoints for IDA, so the rea-agent container forwards
the sidecar onto its own `127.0.0.1:8745` (see `docker/entrypoint.sh`):

```
REA_IDA_MCP_FORWARD=ida-mcp:8745
REA_IDA_MCP_LOCAL_PORT=8745
REA_IDA_MCP_CONFIG=/etc/rea/ida-mcp.json     # {"url":"http://127.0.0.1:8745/mcp","mode":"headless"}
```

Verify without starting IDA:

```bash
docker compose exec rea-agent rea doctor --provider ida --json
docker compose exec rea-agent rea function /targets/app.exe main --provider ida --json
```

Remember: only the *original input binary* may be handed to REA for an
attached IDA profile - not an `.idb`/`.i64` database - and its SHA-256 must
match what IDA recorded.
