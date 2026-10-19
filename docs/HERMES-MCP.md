# Exposing rea-agent's MCP surface to Hermes (and other clients)

REA serves **stdio only** (`rea mcp`, verified in the package: `scripts/rea.mjs`
routes `mcp`/`--mcp` to `dist/main.js` and there is no HTTP transport in the
server). Two ways to consume it from a client that is not in the same
container:

| Path | How | When to use |
| ---- | --- | ----------- |
| stdio via `docker exec` | client spawns `docker exec -i <container> rea mcp` | Hermes and other local agents; simplest, no network surface |
| Streamable HTTP | `compose.http.yml` adds a `supergateway` sidecar publishing `:8811` | other containers, remote agents, MCP Inspector, non-`docker exec` clients |

## 0. Which container?

There is one image per engine and one compose service per image, so the only
thing that changes in everything below is the container name
([docs/IMAGES.md](IMAGES.md)):

| You started | Container | Engine | Provider for native work |
| --- | --- | --- | --- |
| `docker compose up -d` | `rea-agent` | Ghidra + Hopper | `--provider ghidra` / `--provider hopper` per call |
| `... --profile ghidra up -d rea-ghidra` | `rea-agent-ghidra` | Ghidra | `ghidra` (already the image default) |
| `... --profile hopper up -d rea-hopper` | `rea-agent-hopper` | Hopper | `hopper` (already the image default) |
| `... --profile ida up -d rea-ida` | `rea-agent-ida` | none — your IDA | `ida`, once registered ([ida-variants.md](ida-variants.md)) |

The single-engine images set `REA_ANALYSIS_PROVIDER` inside
`/usr/local/share/rea/engine.env`, so the agent does not have to name an engine on every
call. Override it with `REA_ANALYSIS_PROVIDER=…` in `config/rea.env` if the
target needs a different one (an image with one engine simply reports the other
as unavailable rather than guessing).

## 1. stdio (recommended for Hermes)

`scripts/hermes-mcp.yaml` is a ready-to-paste block. The essentials:

```yaml
mcp_servers:
  rea:
    command: "docker"
    args: ["exec", "-i", "rea-agent-ghidra", "rea", "mcp"]   # or rea-agent / rea-agent-hopper / rea-agent-ida
    timeout: 1800          # Ghidra's first query imports + auto-analyses
    connect_timeout: 120
    sampling:
      enabled: false       # REA never asks the client to sample
```

Then restart Hermes (or reload MCP in the running session). Hermes registers
MCP tools as `mcp__<server>__<tool>` — double underscore either side of the
server name — so this server's tools appear as `mcp__rea__<tool>`, e.g.
`mcp__rea__open_binary`, `mcp__rea__analyze_function`,
`mcp__rea__search_strings`, `mcp__rea__procedure_pseudo_code`,
`mcp__rea__close_binary`.

Why this shape works:

* Hermes filters the environment of stdio MCP subprocesses down to
  `PATH`/`HOME`/`XDG_*`, which is all `docker` needs - no secrets cross into the
  container.
* `docker exec` needs no published ports and therefore no networking changes
  when Hermes itself runs inside a container with the Docker socket mounted.
* The long-lived service keeps REA's caches and provider sessions warm between
  tool calls.

Give it targets it can read: put samples in `./targets` (mounted read-only at
`/targets`) and ask for analysis with the container paths:

> Open /targets/app.elf with REA, find how the licence check works, and show me
> the pseudocode with source locations.

## 2. Streamable HTTP bridge

```bash
# with the engine you built (REA_IMAGE/REA_ENGINE must match that image)
REA_IMAGE=rea-agent-ghidra:6.7.0-linux-amd64 REA_ENGINE=ghidra \
  docker compose -f docker-compose.yml -f compose.http.yml --profile ghidra up -d rea-mcp-http
# or: make http-up ENGINE=ghidra

curl -sS -X POST http://127.0.0.1:8811/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
```

The bridge sidecar is engine-agnostic: it runs `rea mcp` from whichever image you
give it, and that image's `/usr/local/share/rea/engine.env` supplies the engine paths, so it
carries any of the four engines (it no longer depends on a particular service
being up).

`supergateway` bridges `rea mcp` (stdio) to `streamableHttp` on port 8811. Bind
address is `REA_MCP_HTTP_BIND` (default `127.0.0.1`, i.e. host loopback only).
If the client is another container, either widen the bind **and** put both on
one user-defined network, or keep the stdio path.

Caveat for containerised clients: `127.0.0.1` inside a container is that
container's own loopback. A client in a different container must use the host
gateway (e.g. `host.docker.internal`, or the `docker0` address), not
`127.0.0.1`.

Verified handshake (in-image, current build):

```bash
$ curl -sS -X POST http://127.0.0.1:8811/mcp \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
data: {"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true},
      "completions":{},"prompts":{"listChanged":true}},
      "serverInfo":{"name":"rea","version":"6.7.0"},"instructions":"REA provides ..."}}
```

Notes for HTTP clients:

* The response is an SSE frame — parse the `data:` line, not the raw body.
* The compose service starts the bridge with `--stateful`, so `initialize`
  returns an `mcp-session-id` header that follow-up calls must send. Drop
  `--stateful` (and keep one session per client) if your client cannot carry
  that header.
* A `-32603 "MCP server process failed"` from the bridge means the child
  `rea mcp` exited: usually an invalid REA configuration in the container's
  environment (see the empty-`REA_*` entry in docs/TROUBLESHOOTING.md).

## 3. Tool catalog size

REA advertises ~207 tools. Schemas dominate the payload:

| Profile   | Payload per request (measured upstream) | Notes |
| --------- | --------------------------------------- | ----- |
| `full`    | ~496 KB (~120k tokens on o200k)          | default upstream |
| `compact` | ~290 KB (~68k tokens)                    | image default; REA still validates full inputs |

Set `REA_MCP_INPUT_SCHEMA_PROFILE=full` if a client feature needs complete
nested schemas. `REA_MCP_MAX_RESPONSE_BYTES` caps individual tool results.

## 4. Optional: REA's bundled workflow skill

REA ships an agent workflow (`reverse-engineer-anything`) that teaches the
investigation loop. This image does not run `rea setup --client hermes`, because
that would have to write into Hermes' own config from inside a container. Load
the skill on the Hermes side instead.

Install the revision that matches the release in your image. The skill is
versioned with the package: `REA_VERSION` in `.env` selects `rea-agents@<version>`,
which ships exactly one skill `metadata.version`/`tool_count`. A skill from a
different revision describes tools the server does not advertise - in either
direction - so match the release you built.

### Route 1 (default): copy the skill out of the image

The package the image installed from already carries the matching copy (npm's
global root is `/usr/local/lib/node_modules`, and the skill sits in the package's
plain `skills/` directory), so this needs no network and cannot mismatch:

```bash
# Hermes' skills root is $HERMES_HOME/skills when HERMES_HOME is set (it often
# is for a containerised Hermes, e.g. /opt/data), otherwise ~/.hermes/skills.
# The container name is the only thing that changes between engines.
skills_root="${HERMES_HOME:-$HOME/.hermes}/skills"
docker cp rea-agent-ghidra:/usr/local/lib/node_modules/rea-agents/skills/reverse-engineer-anything \
  "$skills_root/"
```

If another client of yours reads the `~/.agents/skills` convention, put the same
copy there - or make one path point at the other - so the two cannot drift.

### Route 2: extract it from the pinned npm tarball

No container needed, and version-matched by construction:

```bash
REA_VERSION="$(grep -m1 '^REA_VERSION=' .env | cut -d= -f2)"   # keep in step with the image
npm pack "rea-agents@${REA_VERSION}"
tar -xzf "rea-agents-${REA_VERSION}.tgz" package/skills/reverse-engineer-anything
cp -r package/skills/reverse-engineer-anything "$skills_root/"
```

For a given version this is byte-identical to the copy inside the image.

### Do not install from repository main

```bash
npx skills add morluto/rea --skill reverse-engineer-anything   # NOT version-matched
```

This takes the skill from repository `main`, which tracks unreleased work. That
is why the version-matched routes above are the default. Note that as of REA
6.7.0 (npm release, skill v42) `main` and the release currently agree — but this
route is *unversioned*, so it starts to describe tools your server does not
advertise the moment `main` moves ahead again. Use it only if you deliberately
build from `main`.

### Verify the match

Ask the image which skill revision it expects, then compare your installed copy:

```bash
# jq ships inside the image, so run it there - nothing is needed on the client:
docker exec rea-agent-ghidra sh -c 'rea doctor --format json 2>/dev/null | tail -1 \
  | jq -r ".identity | \"cli \(.cli_package_version) | skill v\(.expected_skill_version) | tools \(.catalog.counts.mcp_tools)\""'
# cli 6.7.0 | skill v42 | tools 207

grep -E '^  (version|tool_count):' "$skills_root/reverse-engineer-anything/SKILL.md"
#   version: "42"
#   tool_count: 207
```

Both numbers must agree. `rea doctor` itself exits non-zero whenever it reports
any unrelated finding (a single-engine image has no Hopper or IDA), so read the
values rather than the exit code. `rea doctor --skill` is not a substitute: it
inspects the skill directories *inside the container*, which cannot see a skill
installed on the client side, and reports `skill: identity is missing` when run
that way.

## 5. Verifying the wiring

```bash
# Handshake + tool catalog + one engine-free tool call, for the engine you ran:
docker compose exec rea-ghidra /opt/rea/verify/verify-all.sh --only mcp
# (...and the native analysis step runs through that image's own engine)

# Or by hand, the way Hermes does it:
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| docker exec -i rea-agent-ghidra rea mcp | head -2   # container name, not the compose service
```
