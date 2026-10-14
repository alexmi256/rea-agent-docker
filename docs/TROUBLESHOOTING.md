# Troubleshooting

Start here:

```bash
# `rea-agent` is the all-engines service - substitute the service you actually
# started (`rea-ghidra`, `rea-hopper`, `rea-ida`); compose exec takes services,
# plain `docker exec` takes container names (`rea-agent-ghidra`, ...).
docker compose exec rea-agent rea doctor --json            # everything REA can see
docker compose exec rea-agent rea doctor --provider ghidra --json
docker compose exec rea-agent rea doctor --provider hopper --json
docker compose exec rea-agent /opt/rea/verify/verify-all.sh --quick
docker compose logs --tail 50 rea-agent
```

The verification harness writes raw stdout/stderr for every check under
`work/verify-reports/<run-id>/logs/`, so a failing check always has evidence.

## Build problems

**`cargo install binwalk` fails with `feature edition2024 is required`**
The builder stage pins a Rust toolchain that must be >= 1.85 (binwalk resolves
floating dependencies). Bump `FROM rust:<version>-bookworm` in the Dockerfile.

**Hopper `.deb` fails to configure / `apt` cannot satisfy `libqt6gui6`**
On Ubuntu 24.04 the Qt6 packages are the `*t64` variants that *provide* the
unversioned names; `apt-get install ./hopper.deb` resolves them. Installing with
bare `dpkg -i` does not - leave the Dockerfile's use of `apt-get install ./…`.

**`INSTALL_IDA=1` but IDA is missing from the image**
The IDA step only consumes `vendor/ida/*.run`; it never downloads. Check that the
file is present in the build context (`vendor/` is copied to `/opt/rea-vendor`)
and that the installer supports `--mode unattended --prefix`.

**Ghidra download is 570 MB and re-runs often**
The build keeps downloads in a BuildKit cache mount
(`/var/cache/rea-dl`); they survive rebuilds. Do not `--no-cache` casually.
To pin the archive, set `GHIDRA_SHA256` (the first build prints the digest it
saw on the `sha256sum` line of the build log).

## Ghidra

**First query times out**
Ghidra imports + auto-analyses on the first query. Default provider deadline is
330 s; this project raises it (`REA_GHIDRA_STARTUP_TIMEOUT_MS=900000`). Raise
further for very large targets **and** raise the MCP client's timeout to match -
a client that gives up earlier reports a failure while Ghidra keeps working.
`rea doctor --provider ghidra --json` validates the installation only.

**`native_decompiler` reported missing/incompatible**
REA inspects the executable header of
`$GHIDRA_INSTALL_DIR/Ghidra/Features/Decompiler/os/linux_x86_64/decompile`.
The Linux x64 release archive ships it; if you replaced Ghidra with a source
build, build the native component for `linux_x86_64`.

**Analysis hangs in one analyzer (Swift/Objective-C, packed targets)**
```bash
echo 'REA_GHIDRA_DISABLED_ANALYZERS=Objective-C Message Analyzer' >> config/rea.env
```
Unknown analyzer names abort the import rather than silently ignoring the
override, so a wrong name fails loudly.

**Wrong processor for a raw/headerless image**
```bash
REA_GHIDRA_LANGUAGE_ID=ARM:LE:32:Cortex
REA_GHIDRA_COMPILER_SPEC_ID=default
```
Both are checked against the installation's `.ldefs` and recorded in the
analysis profile.

**Memory**
`GHIDRA_HEADLESS_MAXMEM` (default 4G in compose) bounds the Ghidra JVM heap.
Keep at least ~2× the largest target's expected working set free on the host;
`docker stats rea-agent` shows the real figure.

## Hopper

**`rea doctor --provider hopper --json` is unhealthy (`hopper-version`
`config_drift`)**
REA matches the Hopper *launcher's SHA-256* against the single Linux build it
validated per package family. REA 6.4.0 pins Hopper 6.4.2 (demo), which is what
this image installs; a licensed or hand-built Hopper will report drift even
though it may analyse fine. To check which build your REA expects:

```bash
docker run --rm ghcr.io/alexmi256/rea-agent:latest bash -c \
  'grep -rhoE "Hopper-[0-9.]+-Linux-demo[.a-z]+" "$(npm root -g)/rea-agents/dist" | sort -u'
```

**`ldd /opt/hopper/bin/Hopper` shows missing libraries**
REA's Linux path also needs Xvfb, Python 3 and the X11/XTEST libraries (all
installed in this image). Add anything else the launcher reports.

**Analysis fails with a licence/demo dialog**
On macOS the demo/licence prompt must be completed in a user session; on Linux
REA picks demo mode on its own private Xvfb display. If you own a licence,
activate it once and persist `HOPPER_STATE_DIR` (mounted as
`./vendor/hopper-state`).

**Second session complains about ownership**
Hopper's Linux demo reserves one application per user; close the owning REA
session (or MCP connection) before starting another. A CLI command and an MCP
session cannot hold Hopper simultaneously.

## IDA / JEB

**`capability_unavailable` / `provider_unavailable`**
`rea doctor --provider ida --json` checks the registration without starting IDA.
Then `rea providers --json` and `binary_session` report what actually came up.
Common causes: `REA_IDA_MCP_CONFIG` unset or unreadable; IDA MCP not running;
IDA Free used with a headless profile (Free has no `idalib`); an upstream
`ida-pro-mcp` from `main` (2.0.0 renamed the GUI tools and dropped `idb_close`,
so neither supported profile matches - pin 1.4.0 or a build serving
`idb_open`/`idb_list`/`idb_close`).

**`REA_IDA_MCP_FORWARD` set but nothing answers**
The entrypoint's `socat` forward logs to `/var/log/rea/ida-forward.log`. Confirm
the target host resolves from inside the container (`getent hosts <name>`), that
both containers share a network, and that the port is the MCP port.

**IDA refuses the target**
REA requires the **original input binary** for attached profiles and its SHA-256
must match what IDA recorded - an `.idb`/`.i64` path is rejected by design.

## Tools and permissions

**`unblob` fails with a sandbox error**
unblob enables a Landlock sandbox by default. If the Docker seccomp profile
blocks Landlock syscalls, either relax it (`security_opt: ["seccomp=unconfined"]`
in compose, only if you accept the reduction) or let REA report the actionable
error - it deliberately will not retry with `--no-sandbox`.

**Browser/Playwright checks fail**
Chromium needs shared memory: keep `shm_size` >= 1 GB. Running as a non-root
user, Chromium must not use its own sandbox - `REA_BROWSER_NO_SANDBOX=1` is the
image default. Playwright's browsers live in `/opt/ms-playwright`
(`PLAYWRIGHT_BROWSERS_PATH`).

**`/work` is not writable**
The container runs as uid/gid 1000 by default. Either match your host user
(`REA_UID=$(id -u) REA_GID=$(id -g)` in `.env`) or make `work/` group-writable.

**frida / adb report no devices**
Both are "no device attached" answers, not failures: Frida lists the local
device (the bundled binding), adb lists attached emulators/phones. For hardware
in another container, use `adb connect <host>:<port>`, and mount the Android
platform-tools if you want a different adb version (`REA_ADB_PATH`).

## MCP clients

**Tools do not appear in Hermes**
Restart Hermes after editing `config.yaml` (MCP servers are discovered at
startup, no hot reload). Check the container is running
(`docker ps --filter name=rea-agent`), then confirm the handshake by hand:
`docker exec -i rea-agent rea mcp` and paste an `initialize` request.

**A tool call times out in the client but works in the container**
The client's own per-call timeout is shorter than the provider's first-query
work. Raise `timeout` on the `mcp_servers.rea` entry (1800 s is a sane default
for Ghidra).

**Every REA command fails with `configuration_invalid`**
You passed an *empty* `REA_*` variable. REA validates its settings and rejects
zero-length strings:

```
REA configuration is invalid: REA_ANALYSIS_PROVIDER: Too small: expected string
to have >=1 characters; REA_IDA_MCP_CONFIG must be absolute; ...
```

The usual cause is `VAR: ${VAR:-}` in a compose `environment:` map (or an
`--env-file` whose file contains `REA_ANALYSIS_PROVIDER=`). Keep an unset knob
*undefined*: put optional settings in `config/rea.env` (loaded via compose
`env_file`, which only defines present variables) and never list them with an
empty default. Comment a line out instead of blanking it.

**Frida tools do not appear in the MCP catalog**
REA 6.4.0 (the npm release) ships no frida tools — the family exists on
repository `main` and will arrive in a later release. The image installs and
verifies the frida binding (`getLocalDevice()` returns the local system), so a
later `REA_VERSION` build arg picks it up with no other change. `rea --help`
is the ground truth: if it lists no frida command, the release you installed
has none.

**HTTP bridge unreachable**
`REA_MCP_HTTP_BIND` defaults to `127.0.0.1` on the Docker host. Containerised
clients cannot use that address; see `docs/HERMES-MCP.md` §2.

## Engine selection (the four images)

**`rea doctor --provider ghidra` fails on the Hopper/IDA image (or vice versa)**
Expected. Each image carries one engine; the healthcheck and the verification
harness skip checks for engines the image does not ship, but a *manual*
`doctor --provider <other-engine>` will report it as unavailable. Ask the image
what it is:

```bash
docker compose exec <service> cat /usr/local/share/rea/engine      # all | ghidra | hopper | ida
docker compose exec <service> cat /usr/local/share/rea/engine.env  # the paths it advertises
docker compose exec <service> rea providers --json
```

**A tool call reports no provider, or `provider_unavailable`, for a target**
The image has no engine for that target. `rea-ida` ships none at all until you
register an upstream IDA MCP (`setup-ida-mcp.sh`, see `docs/ida-variants.md`);
the Ghidra-only and Hopper-only images cover different architecture sets (Ghidra
broad, Hopper x86/ARM/Apple formats). Use the `all` image, or run two engine
containers named explicitly.

**`docker exec` cannot find the engine although compose works**
Engine paths come from `/usr/local/share/rea/engine.env` via the `/usr/local/bin/rea`
wrapper. If that wrapper is replaced - e.g. by running `npm install -g
rea-agents` or `rea update` inside the container - the injection is lost. Rebuild
the image (`scripts/build.sh --engine <engine>`) instead of updating REA in
place.

**Two engine containers fighting over `./work`**
All four services share `./work`, `./targets` and `./config` deliberately, so
evidence lands in one place. Run one engine container at a time, or give each its
own workspace mount.

**Build fails with `groupadd: GID '1000' already exists`**
Handled: Ubuntu 24.04 ships a stock `ubuntu` user at uid/gid 1000, so the image
reuses an existing group and renames that stock user to `rea` when the requested
uid is taken. If you maintain your own copy of the Dockerfile, do the same, or
build with `REA_UID`/`REA_GID` set to free ids (`id -u` / `id -g`).

**`mkdir: cannot create directory '/tmp/rea/home': Permission denied`**
The container was started as a uid the image does not know (compose `user:`, CI,
`docker run -u 1001`), so `$HOME` is not writable and the entrypoint fell back to
`/tmp/rea/home`. Fixed in the image: the scratch dir is mode 1777 and the fallback
now tries `$REA_HOME_FALLBACK`, then `/tmp/rea/home`, then a `mktemp -d`, and
continues with a warning instead of aborting. If you see the warning, either build
with `REA_UID`/`REA_GID` matching your user (`id -u`/`id -g`) or fix the volume's
ownership once: `docker compose exec -u 0 rea-agent chown -R $(id -u):$(id -g) /home/rea`.

**`docker compose pull` says denied / manifest unknown / not found**
The GHCR packages are public, so `denied` usually means one of three things:
you are pulling a name that does not exist yet (check
`ghcr.io/alexmi256/rea-agent-ghidra:6.4.0-linux-amd64` exactly — tags are
per-image, there is no repo-wide `latest`), you are offline/behind a proxy that
blocks `ghcr.io`, or a fork is asking for the upstream namespace. If *your own*
pushed package is private, fix it once in the UI: package → **Settings → Change
visibility → Public** (or add the `org.opencontainers.image.source` label so the
package inherits the repository's visibility).

**A build or verify step uses a different image than compose**
All of them resolve names through `scripts/image-name.sh <engine>`, which reads
`REA_IMAGE` / `REA_GHIDRA_IMAGE` / `REA_HOPPER_IMAGE` / `REA_IDA_IMAGE` from
`.env`. Print what any engine resolves to:

```bash
scripts/image-name.sh ghidra          # or all | hopper | ida
make sizes                            # what is actually present locally
```

If you see a plain `rea-agent-ghidra:6.4.0-linux-amd64`, your `.env` is missing
the GHCR values (copy them from `.env.example`).

**A `--profile <engine> up -d` starts two containers**
By design: a compose service without a profile always starts, so
`--profile ghidra up -d` also starts the default `rea-agent`. Name the service
(`docker compose --profile ghidra up -d rea-ghidra`) or use `make up ENGINE=…`.
