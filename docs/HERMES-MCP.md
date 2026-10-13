# Exposing rea-agent's MCP surface to Hermes (and other clients)

REA serves **stdio only** (`rea mcp`, verified in the package: `scripts/rea.mjs`
routes to `dist/mcp/main.js` for `mcp`/`--mcp` and there is no HTTP transport in
the server). Two ways to consume it from a client that is not in the same
container:

| Path | How | When to use |
| ---- | --- | ----------- |
| stdio via `docker exec` | client spawns `docker exec -i rea-agent rea mcp` | Hermes and other local agents; simplest, no network surface |
| Streamable HTTP | `compose.http.yml` adds a `supergateway` sidecar publishing `:8811` | other containers, remote agents, MCP Inspector, non-`docker exec` clients |

## 1. stdio (recommended for Hermes)

`scripts/hermes-mcp.yaml` is a ready-to-paste block. The essentials:

```yaml
mcp_servers:
  rea:
    command: "docker"
    args: ["exec", "-i", "rea-agent", "rea", "mcp"]
    timeout: 1800          # Ghidra's first query imports + auto-analyses
    connect_timeout: 120
    sampling:
      enabled: false       # REA never asks the client to sample
```

Then restart Hermes. Tools are exposed as `mcp_rea_<tool>`, e.g.
`mcp_rea_open_binary`, `mcp_rea_analyze_function`, `mcp_rea_search_strings`,
`mcp_rea_decompile_function`, `mcp_rea_close_binary`.

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
docker compose -f docker-compose.yml -f compose.http.yml up -d
curl -sS -X POST http://127.0.0.1:8811/mcp \
  -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}'
```

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
      "serverInfo":{"name":"rea","version":"6.4.0"},"instructions":"REA provides ..."}}
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

REA advertises ~170 tools. Schemas dominate the payload:

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
the skill on the Hermes side instead:

```bash
npx skills add morluto/rea --skill reverse-engineer-anything
```

or copy it out of the image (npm's global root is `/usr/local/lib/node_modules`):

```bash
docker cp rea-agent:/usr/local/lib/node_modules/rea-agents/.agents/skills/reverse-engineer-anything \
  ~/.hermes/skills/
```

## 5. Verifying the wiring

```bash
# Handshake + tool catalog + one engine-free tool call + one Ghidra call:
docker compose exec rea-agent /opt/rea/verify/verify-all.sh --only mcp

# Or by hand, the way Hermes does it:
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
| docker exec -i rea-agent rea mcp | head -2
```
