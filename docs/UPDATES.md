# Keeping rea-agent-docker up to date

Everything in this image is pinned on purpose, so "is it out of date?" is a real
question with a mechanical answer:

```bash
make check-updates          # or: scripts/check-updates.py
```

It reads every pin out of `Dockerfile`, asks each upstream what it currently
ships, and prints one row per component in about five seconds.

Exit status follows the policy below — `1` only when the image is **wrong now**
(a pin older than what REA admits, a capability REA advertises with no tool
installed, repo files that disagree, or a new `rea-agents` release, which is the
trigger to move everything). A merely-newer upstream release is reported as
`OUTDATED` and does **not** fail the check, because by policy it waits for the
next REA release.

| mode | use |
| --- | --- |
| `scripts/check-updates.py` | human table, grouped, with the reason on every row |
| `--quiet` | only the actionable rows |
| `--json` | stable shape: `summary`, `rea_admissions`, `rows[]` (each with `source`) |
| `--markdown` | a table for a CI step summary |
| `--only rea,hopper` / `--skip actions` | narrow by key or group (run `--json` to list keys) |
| `--no-fail` | report, never exit non-zero |

A weekly job runs it and fails when something moves — see
[Automation](#automation). The full procedure for each kind of bump is below.

---

## The rule that matters: upstream latest is not the target

Two references exist for nearly every row, and they usually disagree:

1. **what upstream ships** — the newest release anywhere, and
2. **what REA admits** — the builds and version banners the pinned REA release
   was verified against.

REA *refuses* what it does not admit, rather than guessing:

* Hopper is validated by the **SHA-256 of its launcher binary**; a build outside
  the admitted set fails engine validation.
* Ghidra is validated against **one exact release**; a newer one reports
  `config_drift` while looking correctly installed.
* Helper tools are validated by **version banner** (`REA_WABT_BIN_DIRECTORY`,
  `REA_BINWALK_COMMAND`, `REA_UNBLOB_COMMAND`, `REA_TSHARK_COMMAND`,
  `REA_SIGROK_COMMAND`, `REA_JADX_MCP_JAR`, `REA_PWNTOOLS_PYTHON`, …). A newer
  tool can be rejected; an older one is a capability gap.

So for those rows, **chasing the newest release is the wrong move and falling
behind REA's admitted version is the breakage**. The checker enforces exactly
that distinction, and it reads the admitted versions *live out of REA's source at
the pinned release*
(`raw.githubusercontent.com/morluto/rea/rea-agents-<REA_VERSION>/…`), so bumping
REA re-derives the expectations instead of relying on this document's memory.

| which reference governs | components |
| --- | --- |
| **REA admits (exact)** | Ghidra, Hopper package + launcher digest (read from the vendor's signed feed), JDK major, binwalk, unblob, WABT, TShark, sigrok-cli, jadx-headless-mcp, pwntools, Wakaru |
| **REA floor only** | apktool (≥ 2.7.0 — we hold 2.x deliberately: 3.x changes the output layout) |
| **no REA constraint** | ilspycmd (only has to be runnable), mitmproxy, pyelftools, unicorn, uv, supergateway, frida, playwright, Chrome, .NET, adb |
| **npm/GitHub latest** | rea-agents itself, Node.js (within REA's `engines` range), GitHub Actions majors |
| **nothing to pin** | `ubuntu:24.04`, apt-installed tshark/capinfos/sigrok-cli/adb/openjdk/clang-cross — a rebuild picks up the current packages |

---

## The general loop

### When to bump at all

**Do not bump anything unless REA itself is out of date.** The pins exist to
match the REA release the image ships, and REA validates engines by digest and
helper tools by version banner; a third-party bump made on its own schedule is
how you end up running builds REA never verified. So the trigger is a new
`rea-agents`: read what it admits, move the pins to that, and rebuild.

Two exceptions, and only these:

1. **A drift `BEHIND-REA` on any row** — our pin is older than what the *current*
   REA admits, i.e. the image is already wrong. Fix immediately.
2. **A capability gap (`MISSING`)** — REA advertises an operation whose tool we do
   not ship. Also already wrong, and it looks like a broken install to a user.

Everything else (`OUTDATED`, `info`) waits for the next REA release. The reason to
hold is not conservatism for its own sake: `docs/VERIFICATION.md` records which
builds were actually exercised together, and bumping out of step invalidates that
without adding any verified capability.

### The loop

1. `make check-updates` — see what moved and why it matters.
2. Bump the pin in the `Dockerfile` (`ARG …`), and in `.env.example` if it is
   mirrored there.
3. `make check-updates` again — the row should go green.
4. Build the *affected* engine image and run the harness. Do not skip this: the
   pins are exactly the inputs the checks assert on.
   ```bash
   make build-ghidra                      # or build / build-hopper / build-ida
   scripts/verify.sh --engine ghidra      # full harness for that image
   ```
5. Update docs that *name* versions (README, `docs/ARCHITECTURE.md`,
   `docs/MULTIARCH.md`, `docs/IMAGES.md`, `docs/VERIFICATION.md`) and the size
   table if it changed (`make sizes`).
6. Commit with the upstream URL and the check you ran; push. CI re-validates and
   republishes under the new tag.

Bumping more than one component at a time is how you lose track of which change
broke a check — the harness names the phase, so keep the commit small and the
message specific.

---

## A. REA itself (`rea-agents`)

The only bump that touches everything, because REA re-defines what the image
must contain.

**What to check before bumping:**

* the release's own `engines.node` (the checker prints it) — our `NODE_VERSION`
  must satisfy it, or REA refuses to run at all;
* the release's admitted engine builds (**the checker's `REA admits` column now
  changes to match the new release** — that is the point of reading it live);
* whether an admission **moved**: the Ghidra policy file was renamed
  (`GhidraInstallationPolicy.ts` → `GhidraReleasePolicy.ts`) and Hopper left the
  source for the vendor's signed feed in the 6.6.x line. A stale path or an
  empty admission shows up as a row that goes quiet, so check that each engine
  row still shows the version REA expects rather than merely `ok`;
* whether the release adds or renames tool families. REA's docs and `main` run
  ahead of the published package, so a family in the repo may not exist in the
  package you install, and vice versa. The harness reports absent families as
  explicit *skips*, which is how you tell "not in this release" from "broken";
* the bundled skill (`skills/reverse-engineer-anything` inside the package) —
  its `tool_count` and version identify which release it describes.

**Where the release string lives** (all of it must agree; CI `validate` fails if
it does not):

| file | what |
| --- | --- |
| `Dockerfile` | `ARG REA_VERSION` |
| `.env.example` | `REA_VERSION`, `REA_IMAGE`, `REA_GHIDRA_IMAGE`, `REA_HOPPER_IMAGE`, `REA_IDA_IMAGE` (tag suffix `<version>-linux-amd64`) |
| `docker-compose.yml` | the four `image:` fallbacks |
| `compose.http.yml` | the sidecar's image fallback |
| docs | README quick start + table, `docs/IMAGES.md`, `docs/VERIFICATION.md` |

**Procedure:**

```bash
make check-updates --only rea          # confirm the new release, read engines.node
# bump REA_VERSION in Dockerfile + .env.example, and the tag suffix in the four
# image names (both compose files + .env.example)
scripts/image-name.sh ghidra           # tags now resolve with the new suffix
make build-all                         # all four, shared layers cached
scripts/verify-all-engines.sh          # 4 × full harness
```

Then push: GHCR gets `ghcr.io/alexmi256/rea-agent[-ghidra|-hopper|-ida]:<new>-linux-amd64`
plus a per-image `latest`. Old tags stay, so pinned users are unaffected —
`latest` is per image and always the newest build of *that* image, which is why
anything reproducible should pin the version tag (see `docs/IMAGES.md`).

**Watch for on a REA bump:**

* a **new admitted engine version** → the engine pins must move too (section B);
* a **new helper requirement** → a row appears as `MISSING` (section D);
* **renamed/removed tools** → the harness's tool inventory checks change; update
  `docker/verify/*` assertions rather than loosening them.

---

## B. Engines

### Ghidra (exact version)

REA's adapter is verified against one build (`SUPPORTED_GHIDRA_VERSION` in
`src/ghidra/GhidraReleasePolicy.ts`), and a different one reports
`config_drift` while everything still looks installed.

```bash
make check-updates --only ghidra       # compares pin, upstream and REA's version
# bump GHIDRA_VERSION *and* GHIDRA_ZIP together (the zip name carries both the
# version and the build date), leave GHIDRA_SHA256 empty to verify against the
# release, then:
make build --no-cache                 # the engine layer must rebuild
docker compose exec rea-agent rea doctor --provider ghidra --json
```

The JDK matters too: `SUPPORTED_GHIDRA_JAVA_MAJOR` (21 today) is the major Ghidra
declares bounds for. We install `openjdk-21-jdk-headless` from apt, so a Java
*patch* needs nothing but a rebuild.

### Hopper (a signed feed, not a version)

Since REA 6.6.0 the gate is no longer a fixed allowlist: REA authenticates the
installed launcher against the vendor's **publisher-signed release feed**, and the
feed only ever lists its **current** release. So the package is pinned by version
*and* by the feed's own row:

```
Dockerfile:  HOPPER_DEMO_VERSION / HOPPER_DEB_SHA1 / HOPPER_DEB_BYTES
             HOPPER_DEB_URL (empty = derive from the feed)
             HOPPER_LAUNCHER_SHA256  (the feed's main_exe_hash)
             HOPPER_RELEASES_URL / HOPPER_PUBLIC_KEY_URL
REA source:  src/application/HopperReleaseFeed.ts   → the feed schema
             src/application/LinuxHopperPublisher.ts → verification + evidence cache
```

The build reads the feed and **fails** if the pinned values no longer match it,
verifies the downloaded package (byte length + SHA-1) and the installed launcher
(before install: the feed's `main_exe_hash`), then bakes the signed evidence
(`release.json` + `public-key.asc` + the package bytes) into
`/home/rea/.cache/rea/hopper-releases/<main_exe_hash>/` so REA admits the build
without network access. `make check-updates` re-derives every one of those values
from the same feed, so the pin and the check cannot drift apart.

A licensed build may legitimately report drift while working — that is a
vendor-licence difference, not a broken install. Never download a licensed build:
Hopper ships as the vendor's **demo package** only (see `docs/BYO-LICENSES.md`).

### IDA / JEB (never installed)

Commercial engines are bring-your-own registrations (`REA_IDA_MCP_CONFIG`,
`REA_JEB_MCP_URL`) and are never downloaded, by design — see
`docs/BYO-LICENSES.md` and `docs/ida-variants.md`. The checker tracks
`mrexodia/ida-pro-mcp` as information only, because that is the upstream that
users install *outside* the image. Headless IDA needs `idalib`, so IDA Free
cannot do it.

---

## C. REA-admitted helper tools

One `ARG` each, one locator variable each. Bump the `ARG`; the tool must report
the version REA admits.

| tool | pin | installed by | REA locator | harness phase |
| --- | --- | --- | --- | --- |
| binwalk | `BINWALK_VERSION` | `cargo install --locked --version` (crates.io) | `REA_BINWALK_COMMAND` | `static` |
| unblob | `UNBLOB_VERSION` | `pip install "unblob==…"` into `/opt/venvs/unblob` | `REA_UNBLOB_COMMAND` | `static` |
| WABT | `WABT_VERSION` | GitHub release tarball + sha256, `/opt/wabt` | `REA_WABT_BIN_DIRECTORY` | `static` |
| jadx-headless-mcp | `JADX_MCP_VERSION` | GitHub release jar, `/opt/jadx` | `REA_JADX_MCP_JAR` | `static` |
| Wakaru | `WAKARU_VERSION` + `WAKARU_LINUX_X64_SHA256` | GitHub release asset, `/opt/wakaru` | `REA_WAKARU_COMMAND` | `tools` + `static` |
| apktool | `APKTOOL_VERSION` | GitHub release jar + wrapper script | `REA_APKTOOL_COMMAND` | `static` |
| pwntools / pyelftools / unicorn | `PWTOOLS_VERSION` / `PYELFTOOLS_VERSION` / `UNICORN_VERSION` | one venv, `/opt/venvs/pwntools` | `REA_PWNTOOLS_PYTHON` | `static` |
| TShark / capinfos | — (apt) | `apt-get install tshark` | `REA_TSHARK_COMMAND`, `REA_CAPINFOS_COMMAND` | `capture` |
| sigrok-cli | — (apt) | `apt-get install sigrok-cli` | `REA_SIGROK_COMMAND` | `capture` |
| adb | — (apt) | `apt-get install adb` | `REA_ADB_PATH` | `tools` |
| ilspycmd | `ILSPYCMD_VERSION` | `dotnet tool install --tool-path` | `REA_ILSPY_CMD_PATH` | `static` |

Notes:

* **`REA_WABT_BIN_DIRECTORY` points at a directory, not a binary** — the whole
  WABT release has to be extracted, so a WABT bump changes the tarball name too
  (`wabt-<ver>-linux-x64.tar.gz`, verified against its published `.sha256`).
* **Apktool is deliberately held at 2.x.** REA's floor is 2.7.0 and 3.x changes
  the output layout; the checker reports 3.x as optional rather than required.
* **Wakaru is pinned twice on purpose**: `WAKARU_VERSION` (the release) and
  `WAKARU_LINUX_X64_SHA256` (the exact asset). REA fingerprints the executed
  binary and its docs record the digest of the build it audited, so a matching
  version number is not enough — the checker compares our digest with REA's own
  documented value (`wakaru binary digest` row), and the harness re-checks it in
  the image. Install the **release asset**, never the `node_modules/.bin` shim.
* **Some pins are held by another pin, and that is not an oversight.** Unicorn is
  the live example: 2.1.4 is newer upstream, but pwntools 4.15.0 declares
  `unicorn !=2.1.3, !=2.1.4`, so pip refuses it (`ResolutionImpossible`) — the
  build fails loudly rather than installing something inconsistent. The checker
  reports these as `info` with `held on <pin>: <reason>` (the `HELD` map in
  `scripts/check-updates.py`) instead of as an available update. When you add an
  entry there, put the constraint in the `Dockerfile` comment too: the build and
  the checker should tell the same story.
* **ilspycmd has no admitted version** — REA only requires a runnable binary, so
  the checker reports a newer NuGet release as information. Every `.NET` fixture
  in the harness exercises it, so bumping is cheap but not free.
* **apt tools are not pinned.** A rebuild picks up Ubuntu's security updates;
  that is the intended update path for tshark, sigrok-cli, adb and the JDK.

## D. Adding a tool REA advertises but we do not ship

This is the `MISSING` status, and it is the most valuable row the checker
produces: REA advertises a capability whose tool is absent, so the tool reports
`provider_missing` at call time.

**Worked example — Wakaru (as of REA 6.5.0).** REA's own remediation string says:

> On Linux x64, provide an absolute `REA_WAKARU_COMMAND` for Wakaru ^1.13.0
> (verified with 1.14.0) and util-linux prlimit;

Procedure:

1. read the remediation text for the exact requirement — never guess it, it is
   in `src/application/CapabilityInventory.ts` of the pinned release;
2. install it the same way as the other Node-based tools (`npm install --global`
   in the build stage), then locate it with the `ENV` REA expects
   (`REA_WAKARU_COMMAND=/opt/…/wakaru`);
3. add a harness assertion to the right phase (this one belongs in `static`,
   next to the other JavaScript checks);
4. `make build && scripts/verify.sh` — the skip should turn into a pass;
5. document it in `docs/ARCHITECTURE.md` (what the image ships) and here.

If you deliberately do **not** want it, add it to the accepted-gaps list below
with the reason, so the row is expected rather than surprising.

### Accepted gaps

| gap | why |
| --- | --- |
| IDA / JEB | licensable vendor software: bring-your-own by design, never downloaded |
| Hopper licensed builds | same; only the vendor demo package is installed |
| **Kuna** (caller-supplied static-analysis provider, REA 6.6.0+) | REA expects a *caller-installed* Kuna and does not ship one; the image is the caller's environment, so an uninstalled Kuna is `provider_missing` by design, exactly like IDA |
| Apple composite providers (plist etc.) | provider-scoped, not a host capability |

Wakaru was the first real `MISSING` row produced by the checker — REA 6.5.0
advertised `recover_javascript_sources` while the image shipped nothing for it, so
the capability reported `provider_missing`. The procedure above is what fixed it;
the section stays as the worked example.

---

## E. Our own tools (no REA gate)

`uv`, `supergateway`, `frida`, `mitmproxy`, `playwright`, Chrome, the .NET SDK
and the cross toolchains are ours, not REA's — bump them freely, then run the
phase that exercises them:

| tool | pin | proves it |
| --- | --- | --- |
| frida | `FRIDA_VERSION` (npm `frida`, `--allow-scripts=frida`) | `clients` phase (`getLocalDevice()`) |
| supergateway | `SUPERGATEWAY_VERSION` | `mcp` phase (HTTP bridge handshake) |
| uv | `UV_VERSION` | build stage (`uv --version`) |
| mitmproxy | `MITMPROXY_VERSION` | `capture` phase |
| playwright / Chrome | unpinned | `clients` phase (Chromium launch) |
| .NET SDK | apt `dotnet-sdk-8.0` | `static` phase (`ilspycmd`) |

A frida bump deserves a second look at the harness rather than a glance at the
version: frida's install scripts are skipped by npm unless
`--allow-scripts=frida` is passed, and the version is referenced from
`rea-agents/node_modules` by symlink.

## F. Base image and CI plumbing

**`ubuntu:24.04`** is deliberately unpinned: a rebuild picks up the current point
release. The checker prints the tag's current digest and date so you can see
whether a rebuild would move anything. Ubuntu 24.04 is not arbitary — REA's
Hopper installer supports macOS 12+/Ubuntu 24.04+/Fedora 41+/Arch, and 24.04
resolves every pinned helper from apt (`docs/MULTIARCH.md`).

**GitHub Actions majors** are checked too, because a stale major is what triggers
the Node-runtime deprecation warning on runners:

| action | current | note |
| --- | --- | --- |
| `actions/checkout` | `@v7` | Node 24 from v5 |
| `actions/upload-artifact` | `@v7` | Node 24 only from **v6** |
| `docker/login-action` | `@v4` | Node 24 only from **v4** |

The trap is that these boundaries differ per action — pinning everything to the
same major is exactly how you end up with one warning left.

---

## Automation

`.github/workflows/updates.yml` runs the checker **weekly (Mondays 06:17 UTC)**
and on manual dispatch. It needs no Docker, no build and no package permissions,
and it is separate from the image build on purpose: a red `updates` run means
"a version moved", not "the image is broken".

* the markdown report lands in the run summary
  (Actions → *updates* → the run → **Summary**);
* the JSON report is uploaded as the `update-check` artifact;
* the job **fails when the image is wrong now** — a pin behind what REA admits, a
  capability REA advertises with no tool installed, repo files that disagree, or a
  new REA release. Merely-newer upstream releases are listed in the summary as
  waiting for the next release and do not fail the run;
* it warns when a row could **not be checked** (`unknown`). An unverifiable row
  is not a pass: it means a lookup failed, so that run proved nothing about the
  component. The job sets `GH_TOKEN` so GitHub-sourced rows use the
  authenticated rate limit, and the fetcher falls back to plain HTTPS when `gh`
  is missing or unauthenticated.

Locally the same check is `make check-updates` (or `make check-updates-json`).
CI's `validate` job additionally syntax-checks the script and proves it starts
without network, so a broken checker can never be the reason the weekly job is
quiet.

### Extending the checker

Everything lives in `scripts/check-updates.py`:

* **a new upstream version to watch** → add a row in `check_tools`
  (pypi/github/npm/nuget dicts) or `check_misc`, and pass through `tool_row`
  when REA has an admission for it;
* **a new REA admission pattern** → add a regex to the `patterns` dict in
  `scrape_rea` (keys match the checker's own component keys) and point the row at
  it via `admissions.tool("<key>")`;
* **a new REA source file** → add it to `REA_SOURCES` (REA moves these: the
  Ghidra policy moved from `GhidraInstallationPolicy.ts` to
  `GhidraReleasePolicy.ts` in 6.6.x, Hopper left the source entirely, and in
  6.8.0 binwalk/unblob left the `CapabilityInventory` remediation prose for
  `src/contracts/firmware/firmwareToolRequirements.ts` — a row that loses its
  source still prints `ok`, so a bump is where you check each row still *shows*
  the admitted value);
* **a requirement that becomes structured data** → prefer parsing the data over
  the prose it generates (`scrape_rea` reads `defineToolRequirement({…})`
  blocks first and only falls back to the remediation string): prose can be
  reworded without changing the gate, and a reworded string silently stops
  matching;
* **an admission that lives outside REA's source** → `scrape_rea` already does
  this for Hopper: `admissions.hopper_feed` is the vendor's signed release feed
  (`HOPPER_FEED_URL`), which is what REA itself now validates against;
* **a new local consistency rule** → add it to the coherence row in `check_rea`
  (that is where "the release string must agree everywhere" lives).

Keep two habits: every row carries the URL it came from, and a failed lookup is
reported as `unknown` + reason — never as "up to date". A check that silently
passes when it cannot see upstream is worse than no check.

---

## Traps worth remembering

* **The download cache is shared across builds and keyed by filename, not by
  version.** `/var/cache/rea-dl` is a `--mount=type=cache` target: `[ -f x ] ||
  curl … x` skips the download when `x` is already there. So any cached file whose
  name does not carry the version is *stale the moment the pin moves* — Node's
  `SHASUMS256.txt` failed this way during the 24.21→24.22 bump ("no properly
  formatted checksum lines found", because the cached file still described the old
  tarball). Fix the name (`SHASUMS256-${NODE_VERSION}.txt`), don't delete the
  cache: a version-qualified name makes the workspace self-healing and keeps the
  warm cache useful. Check for this pattern on every cached download — the ones
  that are deliberately version-less (Google Chrome's `google-chrome.deb`, "always
  current stable") are the exception, not the rule.
* **`config_drift` from `rea doctor` is not an install failure.** It usually
  means the engine build is newer than the admitted one.
* **A Hopper version number proves nothing** — the gate is the launcher digest
  the vendor's signed feed authenticates for the *current* release, so re-pinning
  the package is only half the bump: `HOPPER_LAUNCHER_SHA256` and the retained
  evidence move with it.
* **The Hopper feed only ever offers its current release.** The pinned demo's
  download URL 404s once the vendor ships the next one, so a feed move has to be
  fixed by bumping the pins, not by pinning the old URL harder; `make
  check-updates` reports it as `BEHIND-REA` the moment it happens.
* **"Newer" and "admitted" can point in opposite directions.** jadx-headless-mcp
  is the live example: we pin 0.7.1 because REA 6.8.0 admits 0.7.1, while npm
  still only publishes 0.7.0. The checker reports that as fine, and it is.
* **GHCR tags are per image.** There is no repo-wide `latest`; bumps add tags and
  leave old ones in place.
* **The image size table drifts** with dependency changes — refresh it with
  `make sizes` when you touch the pins that carry weight (Ghidra ~900 MB, Hopper
  ~92 MB deltas are documented in `docs/IMAGES.md`).
* **Evidence beats intent**: after any bump, the harness has to run and its
  skips have to be read.
