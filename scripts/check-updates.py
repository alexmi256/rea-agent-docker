#!/usr/bin/env python3
# =============================================================================
# check-updates.py - is this repo behind its upstreams?
#
#   scripts/check-updates.py              # table for humans
#   scripts/check-updates.py --json       # machine-readable
#   scripts/check-updates.py --markdown   # for a CI step summary
#   scripts/check-updates.py --only rea,hopper,wakaru
#   scripts/check-updates.py --no-fail    # report, never exit non-zero
#
# What it does: reads every pinned version out of the Dockerfile, asks each
# upstream what it currently ships, and compares that against TWO references:
#
#   1. the newest thing upstream ships, and
#   2. what the pinned REA release actually ADMITS.
#
# Exit status follows the project's update policy (docs/UPDATES.md):
#   1 = the image is wrong NOW - a pin is older than what REA admits
#       (`BEHIND-REA`), REA advertises a capability with no tool installed
#       (`MISSING`), repo files disagree (`MISMATCH`), or a new REA release exists
#       (`NEW REA`, the trigger to move everything).
#   0 = nothing wrong. `OUTDATED` rows (newer upstream, nothing REA admits) are
#       reported and deliberately do NOT fail: by policy they wait for the next
#       rea-agents release.
#
# (2) is the one that matters for the engine and helper tools. REA 6.7.0 admits
# Ghidra 12.1.4, the Linux Hopper demo the publisher-signed vendor feed currently
# offers (Hopper 6.6.0 - the fixed launcher-digest allowlist is gone), Binwalk
# 3.1.x, Unblob 26.6.x, WABT 1.0.42, sigrok-cli 0.7.2, TShark 4.x,
# jadx-headless-mcp 0.7.1, pwntools 4.15.0, Wakaru ^1.13.0 - and it refuses
# builds that do not match (Hopper by the feed's authenticated launcher digest,
# the rest by version banner). So "newest upstream" is
# frequently the WRONG target for those rows: chasing apktool 3.x or ilspycmd 11
# is a judgement call, while falling behind REA's admitted WABT is a breakage.
#
# Those expectations are read live from REA's own source - and, for Hopper, from
# the vendor release feed REA itself reads - at the pinned release tag, so
# bumping REA_VERSION automatically re-derives them - which is what
# makes docs/UPDATES.md a procedure rather than a memory test.
#
# Every row carries the URL it was derived from, and a failed lookup is reported
# as unknown-with-reason rather than being silently treated as up to date.
# No credentials are used or printed; stdlib only (uses `gh` if present, for the
# higher authenticated GitHub rate limit).
# =============================================================================
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

PROJECT_DIR = Path(__file__).resolve().parent.parent
DOCKERFILE = PROJECT_DIR / "Dockerfile"
ENV_EXAMPLE = PROJECT_DIR / ".env.example"
WORKFLOW_DIR = PROJECT_DIR / ".github" / "workflows"

REA_REPO = "morluto/rea"
REA_RAW = "https://raw.githubusercontent.com/{repo}/rea-agents-{version}/{path}"

# REA source files that carry the admitted-version tables.
REA_SOURCES = {
    "node": "src/domain/runtimeVersion.ts",
    "ghidra": "src/ghidra/GhidraReleasePolicy.ts",
    "tools": "src/application/CapabilityInventory.ts",
}

# Hopper is not in REA's source any more: since 6.6.0 the admitted Linux build is
# whatever the publisher-signed vendor release feed currently offers
# (src/application/HopperReleaseFeed.ts + LinuxHopperPublisher.ts), and the feed
# only ever lists its current release. So read the feed REA reads.
HOPPER_FEED_URL = "https://www.hopperapp.com/include/files-api.php?request=releases&public=true"
HOPPER_FAMILY = "Ubuntu / Mint"

# Statuses that mean "the image is wrong right now" - these fail the check.
# `outdated` is deliberately NOT here: this project's policy is that a newer
# upstream release waits for the next REA release, so a merely-newer tool is
# reported but must not turn the weekly job red (see docs/UPDATES.md).
ACTIONABLE = {"behind-rea", "missing", "mismatch", "new-rea"}
# Reported, never failing: newer upstream, no REA release shipped it yet.
PENDING = {"outdated"}

# Components deliberately held back from a newer upstream, with the reason. These
# are reported as `info` ("held") rather than as pending updates, so a reader can
# see the decision instead of assuming an oversight.
HELD = {
    "unicorn": "pwntools 4.15.0 declares unicorn !=2.1.3,!=2.1.4 - pip refuses 2.1.4",
}
STATUS_LABEL = {
    "ok": "ok",
    "outdated": "OUTDATED",
    "new-rea": "NEW REA",
    "behind-rea": "BEHIND-REA",
    "ahead": "ahead",
    "missing": "MISSING",
    "mismatch": "MISMATCH",
    "info": "info",
    "unknown": "unknown",
}


# --------------------------------------------------------------------------- #
# tiny version helpers
# --------------------------------------------------------------------------- #
def vparse(value: str | None) -> tuple[int, ...] | None:
    """'v1.2.3', 'Ghidra_12.1.4_build', '8.2.0.7535' -> comparable tuple."""
    if not value:
        return None
    match = re.search(r"(\d+(?:\.\d+)+)", value)
    if not match:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def vpad(a: tuple[int, ...], b: tuple[int, ...]) -> tuple[tuple[int, ...], tuple[int, ...]]:
    width = max(len(a), len(b))
    return a + (0,) * (width - len(a)), b + (0,) * (width - len(b))


def compare(ours: str | None, theirs: str | None) -> int | None:
    """-1 ours older, 0 equal, 1 ours newer, None incomparable."""
    a, b = vparse(ours), vparse(theirs)
    if a is None or b is None:
        if ours and theirs and ours.strip() == theirs.strip():
            return 0
        return None
    a, b = vpad(a, b)
    return (a > b) - (a < b)


def major(value: str | None) -> int | None:
    parsed = vparse(value)
    return parsed[0] if parsed else None


# --------------------------------------------------------------------------- #
# fetching
# --------------------------------------------------------------------------- #
class Fetcher:
    def __init__(self, timeout: float, jobs: int) -> None:
        self.timeout = timeout
        self.jobs = jobs
        self._use_gh = shutil.which("gh") is not None
        self._cache: dict[str, object] = {}

    def json(self, url: str) -> object:
        if url in self._cache:
            cached = self._cache[url]
            if isinstance(cached, Exception):
                raise cached
            return cached
        try:
            result = self._json_uncached(url)
        except Exception as exc:  # noqa: BLE001 - reported per row
            self._cache[url] = exc
            raise
        self._cache[url] = result
        return result

    def _json_uncached(self, url: str) -> object:
        errors: list[str] = []
        if self._use_gh and "api.github.com/repos/" in url:
            path = url.split("api.github.com/", 1)[1]
            try:
                proc = subprocess.run(
                    ["gh", "api", path],
                    capture_output=True,
                    text=True,
                    timeout=self.timeout + 10,
                    check=False,
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    return json.loads(proc.stdout)
                errors.append(f"gh api {path}: {proc.stderr.strip()[:100] or 'no output'}")
            except Exception as exc:  # noqa: BLE001
                errors.append(f"gh api {path}: {exc}")
            # Fall through: an unauthenticated `gh` (the normal state on a GitHub
            # runner without GH_TOKEN) must not turn every GitHub-sourced row into
            # "unknown" when plain HTTPS would have answered.
        request = urllib.request.Request(
            url,
            headers={
                "User-Agent": "rea-agent-docker-update-check",
                "Accept": "application/vnd.github+json, application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8", "replace"))
        except Exception as exc:  # noqa: BLE001
            if errors:
                raise RuntimeError("; ".join([*errors, f"https: {exc}"])) from exc
            raise

    def text(self, url: str) -> str:
        if url in self._cache:
            cached = self._cache[url]
            if isinstance(cached, Exception):
                raise cached
            return str(cached)
        try:
            request = urllib.request.Request(
                url, headers={"User-Agent": "rea-agent-docker-update-check"}
            )
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                value = response.read().decode("utf-8", "replace")
        except Exception as exc:  # noqa: BLE001
            self._cache[url] = exc
            raise
        self._cache[url] = value
        return value


# --------------------------------------------------------------------------- #
# pins
# --------------------------------------------------------------------------- #
def read_pins() -> tuple[dict[str, str], dict[str, str]]:
    def parse(path: Path, prefix: str) -> dict[str, str]:
        pins: dict[str, str] = {}
        if not path.exists():
            return pins
        pattern = re.compile(rf"^{prefix}([A-Z0-9_]+)=(.*)$")
        for line in path.read_text().splitlines():
            match = pattern.match(line.strip())
            if match:
                pins[match.group(1)] = match.group(2).strip().strip('"')
        return pins

    return parse(DOCKERFILE, r"ARG "), parse(ENV_EXAMPLE, r"")


# --------------------------------------------------------------------------- #
# rows
# --------------------------------------------------------------------------- #
@dataclass
class Row:
    key: str
    label: str
    group: str
    status: str
    pinned: str | None = None
    upstream: str | None = None
    admits: str | None = None
    source: str = ""
    note: str = ""
    hint: str = ""

    def as_dict(self) -> dict[str, object]:
        return {
            "key": self.key,
            "label": self.label,
            "group": self.group,
            "status": self.status,
            "actionable": self.status in ACTIONABLE,
            "pinned": self.pinned,
            "upstream": self.upstream,
            "admits": self.admits,
            "source": self.source,
            "note": self.note,
            "hint": self.hint,
        }


@dataclass
class ReaAdmissions:
    """What the pinned REA release says it accepts."""

    version: str
    node_range: str | None = None
    ghidra: str | None = None
    ghidra_java_major: str | None = None
    hopper_feed: dict[str, str] = field(default_factory=dict)
    tools: dict[str, dict[str, str]] = field(default_factory=dict)
    errors: dict[str, str] = field(default_factory=dict)

    def tool(self, name: str) -> dict[str, str] | None:
        return self.tools.get(name)


def scrape_rea(fetcher: Fetcher, version: str) -> ReaAdmissions:
    """Read REA's admitted-version tables out of its source at the pinned tag."""
    admissions = ReaAdmissions(version=version)

    def raw(name: str) -> str | None:
        url = REA_RAW.format(repo=REA_REPO, version=version, path=REA_SOURCES[name])
        try:
            return fetcher.text(url)
        except Exception as exc:  # noqa: BLE001
            admissions.errors[name] = f"{url}: {exc}"
            return None

    node = raw("node")
    if node:
        match = re.search(r'SUPPORTED_NODE_VERSION_RANGE\s*=\s*"([^"]+)"', node)
        if match:
            admissions.node_range = match.group(1)

    ghidra = raw("ghidra")
    if ghidra:
        match = re.search(r'SUPPORTED_GHIDRA_VERSION\s*=\s*"([^"]+)"', ghidra)
        if match:
            admissions.ghidra = match.group(1)
        match = re.search(r"SUPPORTED_GHIDRA_JAVA_MAJOR\s*=\s*(\d+)", ghidra)
        if match:
            admissions.ghidra_java_major = match.group(1)

    # Hopper: read the vendor feed instead of REA's source - REA itself admits a
    # Linux build only against this feed's current release, and the old
    # SUPPORTED_RELEASES/SUPPORTED_HOPPER_SHA256 tables are gone from the source.
    try:
        feed = fetcher.json(HOPPER_FEED_URL)
        row = feed.get(HOPPER_FAMILY) if isinstance(feed, dict) else None
        if isinstance(row, dict) and row:
            admissions.hopper_feed = {str(k): str(v) for k, v in row.items()}
        else:
            admissions.errors["hopper"] = f"{HOPPER_FEED_URL}: no '{HOPPER_FAMILY}' release row"
    except Exception as exc:  # noqa: BLE001
        admissions.errors["hopper"] = f"{HOPPER_FEED_URL}: {exc}"

    tools = raw("tools")
    if tools:
        # Ordered: first pattern that matches wins, so keep specific ones first.
        patterns = {
            "pwntools": r"pwntools (\d+(?:\.\d+)*)",
            "wabt": r"WABT (\d+(?:\.\d+)*)",
            "binwalk": r"Binwalk (\d+(?:\.\d+)*)x[^\n]*?verified with (\d+(?:\.\d+)*)",
            "unblob": r"Unblob (\d+(?:\.\d+)*)x[^\n]*?verified with (\d+(?:\.\d+)*)",
            "tshark": r"TShark (\d+)\.x",
            "sigrok-cli": r"sigrok-cli (\d+(?:\.\d+)*)",
            "jadx-headless-mcp": r"jadx-headless-mcp (\d+(?:\.\d+)*)",
            "apktool": r"Apktool (\d+(?:\.\d+)*) or newer",
            "wakaru": r"Wakaru \^?(\d+(?:\.\d+)*) \(verified with (\d+(?:\.\d+)*)\)",
            "ilspycmd": r"ilspycmd (\d+(?:\.\d+)*)",
        }
        for name, pattern in patterns.items():
            match = re.search(pattern, tools)
            if not match:
                continue
            groups = [g for g in match.groups() if g]
            admissions.tools[name] = {
                "required": groups[0],
                "verified": groups[1] if len(groups) > 1 else groups[0],
            }
    return admissions


# --------------------------------------------------------------------------- #
# individual checks
# --------------------------------------------------------------------------- #
def npm_latest(fetcher: Fetcher, package: str) -> dict[str, object]:
    return fetcher.json(f"https://registry.npmjs.org/{package}/latest")  # type: ignore[return-value]


def pypi_latest(fetcher: Fetcher, package: str) -> str:
    data = fetcher.json(f"https://pypi.org/pypi/{package}/json")
    return data["info"]["version"]  # type: ignore[index]


def github_latest(fetcher: Fetcher, repo: str) -> str:
    data = fetcher.json(f"https://api.github.com/repos/{repo}/releases/latest")
    return data["tag_name"]  # type: ignore[index]


def launchpad_noble(fetcher: Fetcher, binary: str) -> str:
    series = "https%3A%2F%2Fapi.launchpad.net%2F1.0%2Fubuntu%2Fnoble%2Famd64"
    url = (
        "https://api.launchpad.net/1.0/ubuntu/+archive/primary"
        f"?ws.op=getPublishedBinaries&binary_name={binary}&exact_match=true"
        f"&distro_arch_series={series}&status=Published"
    )
    data = fetcher.json(url)
    entries = data["entries"]  # type: ignore[index]
    if not entries:
        raise RuntimeError("no published noble binary")
    return sorted({e["binary_package_version"] for e in entries})[-1]


def unknowable(row: Row, exc: Exception) -> Row:
    row.status = "unknown"
    reason = str(exc).strip() or exc.__class__.__name__
    row.note = f"lookup failed: {reason[:160]}"
    return row


def check_rea(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    rows: list[Row] = []
    pinned = pins.get("REA_VERSION", "")
    row = Row("rea", "rea-agents (npm)", "REA core", "ok", pinned=pinned,
              source="https://registry.npmjs.org/rea-agents/latest")
    try:
        data = npm_latest(fetcher, "rea-agents")
        latest = str(data["version"])
        row.upstream = latest
        order = compare(pinned, latest)
        if order is None:
            row.status = "unknown"
            row.note = "could not compare versions"
        elif order < 0:
            row.status = "new-rea"
            row.hint = ("a new REA is the trigger for everything else: read what it admits "
                        "(the columns below re-derive), move the pins to match, rebuild and "
                        "run the harness (docs/UPDATES.md)")
        node_engines = str((data.get("engines") or {}).get("node", ""))
        if node_engines:
            row.note = f"engines.node: {node_engines}"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)

    # the release string has to agree across every file that carries it
    _, env_pins = read_pins()
    env_text = ENV_EXAMPLE.read_text() if ENV_EXAMPLE.exists() else ""
    compose_path = PROJECT_DIR / "docker-compose.yml"
    compose = compose_path.read_text() if compose_path.exists() else ""
    http_compose = PROJECT_DIR / "compose.http.yml"
    http_text = http_compose.read_text() if http_compose.exists() else ""
    expected_tag = f"{pinned}-linux-amd64"
    probe = Row("rea-coherence", "release string in repo files", "REA core", "ok", pinned=pinned)
    problems = []
    if env_pins.get("REA_VERSION") and env_pins["REA_VERSION"] != pinned:
        problems.append(f".env.example REA_VERSION={env_pins['REA_VERSION']}")
    for path, text in ((Path(".env.example"), env_text),
                       (Path("docker-compose.yml"), compose),
                       (Path("compose.http.yml"), http_text)):
        if text and expected_tag not in text:
            problems.append(f"{path} does not use :{expected_tag}")
    if compose and pinned not in env_text:
        problems.append(f".env.example does not mention {pinned}")
    if problems:
        probe.status = "mismatch"
        probe.note = "; ".join(problems)
        probe.hint = "make the release string agree everywhere (CI validate checks this too)"
    rows.append(probe)
    return rows


def check_node(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    pinned = pins.get("NODE_VERSION", "")
    row = Row("node", "Node.js", "REA core", "ok", pinned=pinned,
              admits=admissions.node_range,
              source="https://nodejs.org/dist/index.json")
    try:
        index = fetcher.json("https://nodejs.org/dist/index.json")
        line_major = str(major(pinned) or "")
        same_line = [d for d in index if str(d["version"]).startswith(f"v{line_major}.")]
        lts = [d for d in index if d.get("lts")]
        if same_line:
            newest = str(same_line[0]["version"])
            row.upstream = newest.lstrip("v")
            order = compare(pinned, newest)
            if order is not None and order < 0:
                row.status = "outdated"
                row.hint = "bump NODE_VERSION; keep within REA's engines range"
        if lts:
            row.note = f"latest LTS line: {lts[0]['version']} ({lts[0].get('lts')})"
            if str(lts[0]["version"]).lstrip("v") != row.upstream:
                row.note += f"; {line_major}.x is not the newest LTS line"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)

    # REA's range is an admission gate: our runtime must satisfy it
    if admissions.node_range and vparse(pinned):
        clauses = [c.strip() for c in admissions.node_range.split("||")]
        satisfied = False
        for clause in clauses:
            match = re.match(r"\^?(\d+)\.(\d+)\.(\d+)$", clause)
            if match:
                line, minor, patch = (int(g) for g in match.groups())
                if major(pinned) == line and (vparse(pinned) or (0,)) >= (line, minor, patch):
                    satisfied = True
            elif clause.startswith(">="):
                floor = vparse(clause)
                if floor and (vparse(pinned) or (0,)) >= floor:
                    satisfied = True
        if not satisfied:
            row.status = "behind-rea"
            row.note = f"Node {pinned} does not satisfy REA {admissions.version} range {admissions.node_range}"
            row.hint = "REA refuses unsupported runtimes; move to an admitted line"
    return [row]


def check_ghidra(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    rows: list[Row] = []
    pinned = pins.get("GHIDRA_VERSION", "")
    row = Row("ghidra", "Ghidra", "Engines", "ok", pinned=pinned, admits=admissions.ghidra,
              source="https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/latest")
    try:
        latest = github_latest(fetcher, "NationalSecurityAgency/ghidra")
        row.upstream = latest
        order = compare(pinned, latest)
        if order is not None and order < 0:
            row.status = "outdated"
            row.hint = "bump GHIDRA_VERSION and GHIDRA_ZIP together (GhidraReleasePolicy.ts verifies one build)"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    if admissions.ghidra:
        order = compare(pinned, admissions.ghidra)
        if order is not None and order != 0:
            row.status = "behind-rea"
            row.note = f"REA {admissions.version} admits Ghidra {admissions.ghidra}"
            row.hint = "install exactly the admitted build; a newer Ghidra reports config_drift"
    rows.append(row)

    zip_pin = pins.get("GHIDRA_ZIP", "")
    consistency = Row("ghidra-zip", "Ghidra zip filename", "Engines", "ok", pinned=zip_pin)
    if pinned and pinned not in zip_pin:
        consistency.status = "mismatch"
        consistency.note = f"GHIDRA_ZIP '{zip_pin}' does not name version {pinned}"
        consistency.hint = "bump both together"
    rows.append(consistency)
    return rows


def check_hopper(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    """Hopper: REA admits whatever the publisher-signed vendor feed currently
    offers for Ubuntu/Mint, verified by the launcher digest carried in that
    signed row. Our pin must be exactly that release - and the build itself
    re-checks the feed, so a moved feed is caught before an image ships."""
    rows: list[Row] = []
    feed = admissions.hopper_feed
    feed_name = feed.get("filename", "").rsplit("/", 1)[-1]
    match = re.search(r"Hopper-([\w.]+)-Linux", feed_name)
    feed_version = match.group(1) if match else feed.get("version", "")
    feed_sha1 = feed.get("file_hash", "")
    feed_bytes = feed.get("file_length", "")
    feed_launcher = feed.get("main_exe_hash", "")

    pinned_version = pins.get("HOPPER_DEMO_VERSION", "")
    pinned_sha1 = pins.get("HOPPER_DEB_SHA1", "")
    pinned_bytes = pins.get("HOPPER_DEB_BYTES", "")

    pinned_label = " ".join(part for part in (pinned_version, f"{pinned_sha1[:12]}…" if pinned_sha1 else "") if part)
    admits_label = " ".join(part for part in (feed_version, f"{feed_sha1[:12]}…" if feed_sha1 else "") if part)
    row = Row("hopper", f"Hopper{(' ' + feed_version) if feed_version else ''}", "Engines", "ok",
              pinned=pinned_label or None,
              admits=admits_label or None,
              source=HOPPER_FEED_URL)
    if not feed:
        unknowable(row, RuntimeError(admissions.errors.get("hopper", "no vendor feed release row")))
    else:
        moved: list[str] = []
        if pinned_version and feed_version and pinned_version != feed_version:
            moved.append(f"the vendor feed now offers Hopper {feed_version} ({feed_name})")
        if pinned_sha1 and feed_sha1 and pinned_sha1 != feed_sha1:
            moved.append(f"the vendor feed's sha1 is {feed_sha1}")
        if pinned_bytes and feed_bytes and pinned_bytes != feed_bytes:
            moved.append(f"the vendor feed's package is {feed_bytes} bytes")
        if moved:
            row.status = "behind-rea"
            row.note = "; ".join(moved)
            row.hint = ("re-pin HOPPER_DEMO_VERSION, HOPPER_DEB_SHA1, HOPPER_DEB_BYTES and "
                        "HOPPER_LAUNCHER_SHA256 to the feed's current Ubuntu/Mint release")
        else:
            row.note = f"matches the vendor feed's current signed demo ({feed_bytes} bytes)"
    rows.append(row)

    launcher_pin = pins.get("HOPPER_LAUNCHER_SHA256", "")
    launchers = Row("hopper-launcher", "Hopper admitted launcher digest", "Engines", "info",
                    pinned=(launcher_pin[:12] + "…") if launcher_pin else None,
                    admits=(feed_launcher[:12] + "…") if feed_launcher else None,
                    source=HOPPER_FEED_URL)
    if not feed:
        unknowable(launchers, RuntimeError(admissions.errors.get("hopper", "no vendor feed release row")))
    elif launcher_pin and feed_launcher and launcher_pin != feed_launcher:
        launchers.status = "behind-rea"
        launchers.note = "the pinned launcher digest is not the one the feed authenticates"
        launchers.hint = "bump HOPPER_LAUNCHER_SHA256 to the feed's main_exe_hash and rebuild"
    else:
        launchers.note = ("REA admits this launcher through the feed's signature; a licensed build "
                          "is admitted by its own publisher evidence instead")
    rows.append(launchers)
    return rows


def check_java(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    row = Row("java", "openjdk (Ghidra's JDK)", "Engines", "info", pinned="openjdk-21",
              admits=(f"major {admissions.ghidra_java_major}" if admissions.ghidra_java_major else None),
              source="Launchpad noble/amd64")
    try:
        row.upstream = launchpad_noble(fetcher, "openjdk-21-jdk-headless")
        if admissions.ghidra_java_major and "21" not in row.pinned:
            row.status = "behind-rea"
            row.hint = "Ghidra's bound JDK major changed"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    return [row]


def tool_row(
    key: str,
    label: str,
    pinned: str,
    admitted: dict[str, str] | None,
    upstream_url: str,
    upstream: str | None,
    fetcher_error: Exception | None,
    *,
    floor_semantics: bool = False,
    pinned_present: bool = True,
) -> Row:
    """Shared shape for the REA-admitted helper tools."""
    row = Row(key, label, "REA-admitted tools", "ok",
              pinned=pinned if pinned_present else None,
              upstream=upstream,
              admits=(admitted or {}).get("required"),
              source=upstream_url)
    if admitted and admitted.get("verified") and admitted["verified"] != admitted["required"]:
        row.note = f"REA {admitted['required']} (verified with {admitted['verified']})"
    if fetcher_error is not None:
        unknowable(row, fetcher_error)

    if not pinned_present:
        row.status = "missing"
        row.upstream = upstream
        row.note = (row.note + "; " if row.note else "") + "not installed in the image"
        row.hint = "REA advertises this capability but the tool is absent - it will report provider_missing"
        return row

    if admitted:
        target = admitted.get("verified") or admitted.get("required", "")
        order = compare(pinned, target)
        if order is None:
            if not pinned.startswith(tuple(str(ch) for ch in "0123456789")):
                return row
        elif order < 0:
            row.status = "behind-rea"
            row.note = (row.note + "; " if row.note else "") + (
                f"pinned {pinned} is older than what REA admits ({target})"
            )
            row.hint = "REA checks tool version banners; bump the pin to the admitted version"
            return row
        elif order > 0 and not floor_semantics:
            row.status = "ahead"
            row.note = (row.note + "; " if row.note else "") + (
                f"pinned {pinned} is NEWER than REA's verified {target}"
            )
            row.hint = "unsupported newer banner - verify with the harness before trusting it"

    order = compare(pinned, row.upstream)
    if order is not None and order < 0 and row.status == "ok":
        if key in HELD:
            # newer upstream, but something we ship forbids it - say so, and never
            # dress it up as an available update
            row.status = "info"
            row.note = ((row.note + "; ") if row.note else "") + f"held on {pinned}: {HELD[key]}"
            return row
        if floor_semantics and admitted:
            # REA states a minimum, not a target: anything at or above the floor
            # is admitted, so a newer upstream is optional rather than required.
            row.status = "info"
            row.note = ((row.note + "; ") if row.note else "") + (
                f"REA's floor is {admitted.get('required')}; {row.upstream} is optional"
            )
        elif admitted and compare(pinned, admitted.get("verified", "")) == 0:
            row.status = "info"
            row.note = (row.note + "; " if row.note else "") + "upstream newer, but not admitted by REA"
        else:
            row.status = "outdated"
            row.hint = row.hint or "newer upstream release available"
    return row


def check_tools(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    rows: list[Row] = []
    pypi = {
        "unblob": ("UNBLOB_VERSION", "unblob"),
        "mitmproxy": ("MITMPROXY_VERSION", "mitmproxy"),
        "pwntools": ("PWTOOLS_VERSION", "pwntools"),
        "pyelftools": ("PYELFTOOLS_VERSION", "pyelftools"),
        "unicorn": ("UNICORN_VERSION", "unicorn"),
        "uv": ("UV_VERSION", "uv"),
    }
    github = {
        "binwalk": ("BINWALK_VERSION", "ReFirmLabs/binwalk", False),
        "wabt": ("WABT_VERSION", "WebAssembly/wabt", False),
        "apktool": ("APKTOOL_VERSION", "iBotPeaches/Apktool", True),
        "pwndbg": ("PWNDBG_TAG", "pwndbg/pwndbg", False),
    }
    npm = {
        "frida": ("FRIDA_VERSION", "frida"),
        "supergateway": ("SUPERGATEWAY_VERSION", "supergateway"),
        "jadx-headless-mcp": ("JADX_MCP_VERSION", "jadx-headless-mcp"),
    }

    for key, (pin, package) in pypi.items():
        pinned = pins.get(pin, "")
        url = f"https://pypi.org/pypi/{package}/json"
        upstream, error = None, None
        try:
            upstream = pypi_latest(fetcher, package)
        except Exception as exc:  # noqa: BLE001
            error = exc
        rows.append(tool_row(key, f"{package} (PyPI)", pinned, admissions.tool(key), url, upstream, error))

    for key, (pin, repo, floor) in github.items():
        pinned = pins.get(pin, "")
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        upstream, error = None, None
        try:
            upstream = github_latest(fetcher, repo)
        except Exception as exc:  # noqa: BLE001
            error = exc
        rows.append(tool_row(key, f"{repo} (GitHub)", pinned, admissions.tool(key), url, upstream, error,
                             floor_semantics=floor))

    for key, (pin, package) in npm.items():
        pinned = pins.get(pin, "")
        url = f"https://registry.npmjs.org/{package}/latest"
        upstream, error = None, None
        try:
            upstream = str(npm_latest(fetcher, package)["version"])
        except Exception as exc:  # noqa: BLE001
            error = exc
        rows.append(tool_row(key, f"{package} (npm)", pinned, admissions.tool(key), url, upstream, error))

    # ilspycmd: NuGet, and REA imposes no version admission
    pinned = pins.get("ILSPYCMD_VERSION", "")
    url = "https://api.nuget.org/v3-flatcontainer/ilspycmd/index.json"
    upstream, error = None, None
    try:
        data = fetcher.json(url)
        stable = [v for v in data["versions"] if "-" not in v]  # type: ignore[index]
        upstream = sorted(stable, key=lambda v: vparse(v) or (0,))[-1]
    except Exception as exc:  # noqa: BLE001
        error = exc
    row = tool_row("ilspycmd", "ilspycmd (NuGet)", pinned, admissions.tool("ilspycmd"), url, upstream, error)
    if not admissions.tool("ilspycmd"):
        if row.status == "outdated":
            row.status = "info"
            row.note = ((row.note + "; ") if row.note else "") + "REA only requires a runnable ilspycmd"
        row.admits = None
    rows.append(row)

    # Wakaru: the JavaScript recovery engine REA advertises. Installed since
    # 6.5.0-era tooling; the upstream is the GitHub release asset the image
    # fetches (npm mirrors the identical version).
    wakaru_pin = pins.get("WAKARU_VERSION", "")
    url = "https://api.github.com/repos/pionxzh/wakaru/releases/latest"
    upstream, error = None, None
    try:
        upstream = github_latest(fetcher, "pionxzh/wakaru")
    except Exception as exc:  # noqa: BLE001
        error = exc
    rows.append(tool_row("wakaru", "wakaru (GitHub release)", wakaru_pin,
                         admissions.tool("wakaru"), url, upstream, error,
                         pinned_present=bool(wakaru_pin)))
    return rows


def check_wakaru_digest(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    """Our Wakaru pin must be the asset REA audited, byte for byte.

    REA fingerprints the executed binary and docs/javascript-recovery.md records
    the SHA-256 of the build it verified, so a different asset would be running
    bytes REA never audited even though the version number matches.
    """
    pinned = pins.get("WAKARU_LINUX_X64_SHA256", "")
    url = REA_RAW.format(repo=REA_REPO, version=admissions.version,
                         path="docs/javascript-recovery.md")
    row = Row("wakaru-digest", "wakaru binary digest", "REA-admitted tools", "ok",
              pinned=(pinned[:12] + "…") if pinned else None, source=url)
    if not pinned:
        row.status = "missing"
        row.note = "no WAKARU_LINUX_X64_SHA256 pin, so the fetched asset is unverified"
        row.hint = "pin the digest REA documents for the verified release"
        return [row]
    try:
        doc = fetcher.text(url)
    except Exception as exc:  # noqa: BLE001
        return [unknowable(row, exc)]
    match = re.search(r"SHA-256\s*`([0-9a-f]{64})`", doc)
    if not match:
        return [unknowable(row, RuntimeError("no SHA-256 in REA's javascript-recovery doc"))]
    documented = match.group(1)
    row.admits = documented[:12] + "…"
    release = re.search(r"wakaru/releases/download/v([\d.]+)/", doc)
    if documented == pinned:
        row.note = ("matches the digest REA documents for Wakaru "
                    f"{release.group(1) if release else ''}".strip())
    else:
        row.status = "behind-rea"
        row.note = f"REA documents {documented} for Wakaru {release.group(1) if release else '?'}"
        row.hint = "install the release asset REA audited, or REA runs unaudited bytes"
    return [row]


def check_misc(fetcher: Fetcher, pins: dict[str, str], admissions: ReaAdmissions) -> list[Row]:
    rows: list[Row] = []

    row = Row("ubuntu", "ubuntu:24.04 base", "Base & CI", "info", pinned="24.04",
              source="https://hub.docker.com/v2/repositories/library/ubuntu/tags/24.04")
    try:
        data = fetcher.json("https://hub.docker.com/v2/repositories/library/ubuntu/tags/24.04")
        row.upstream = str(data.get("last_updated", ""))[:10]  # type: ignore[union-attr]
        digest = str(data.get("digest", ""))  # type: ignore[union-attr]
        row.note = f"current digest {digest[:19]}…"
        row.hint = "no pin to bump: a rebuild picks up the current image"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)

    for key, label, binary, url in [
        ("tshark", "tshark/capinfos (apt, REA wants 4.x)", "tshark", "https://api.github.com/repos/wireshark/wireshark/releases/latest"),
        ("sigrok", "sigrok-cli (apt, REA wants 0.7.2)", "sigrok-cli", "https://api.github.com/repos/sigrokproject/sigrok-cli/releases/latest"),
    ]:
        row = Row(key, label, "REA-admitted tools", "info",
                  admits=(admissions.tool(key.split("-")[0]) or {}).get("required"),
                  source="Launchpad noble/amd64")
        try:
            row.pinned = launchpad_noble(fetcher, binary)
            row.note = "installed from apt at build time (no version pin)"
            row.hint = "a rebuild picks up Ubuntu security updates"
        except Exception as exc:  # noqa: BLE001
            unknowable(row, exc)
        rows.append(row)

    row = Row("dotnet", "dotnet-sdk-8.0 (apt)", "Base & CI", "info", pinned="8.0.x",
              source="https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/8.0/releases.json")
    try:
        data = fetcher.json("https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/8.0/releases.json")
        row.upstream = str(data["latest-release"])  # type: ignore[index]
        row.note = "apt-provided; rebuild to pick up patches"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)

    row = Row("chrome", "Google Chrome (unpinned deb)", "Base & CI", "info",
              pinned="google-chrome-stable_current",
              source="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json")
    try:
        data = fetcher.json("https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json")
        row.upstream = str(data["channels"]["Stable"]["version"])  # type: ignore[index]
        row.note = "always the current stable at build time"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)

    row = Row("playwright", "playwright (npm)", "Base & CI", "info",
              source="https://registry.npmjs.org/playwright/latest")
    try:
        row.upstream = str(npm_latest(fetcher, "playwright")["version"])
        row.note = "installed unpinned; browsers land in /opt/ms-playwright"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)

    row = Row("ida-pro-mcp", "mrexodia/ida-pro-mcp (BYO IDA path)", "Engines", "info",
              source="https://api.github.com/repos/mrexodia/ida-pro-mcp/releases/latest")
    try:
        row.upstream = github_latest(fetcher, "mrexodia/ida-pro-mcp")
        row.note = "only used when a user brings their own IDA"
    except Exception as exc:  # noqa: BLE001
        unknowable(row, exc)
    rows.append(row)
    return rows


def check_actions(fetcher: Fetcher) -> list[Row]:
    """Compare pinned action majors with the newest release major."""
    rows: list[Row] = []
    seen: dict[str, str] = {}
    if not WORKFLOW_DIR.exists():
        return rows
    for workflow in sorted(WORKFLOW_DIR.glob("*.yml")):
        for match in re.finditer(r"uses:\s*([\w.\-]+/[\w.\-]+)@(\S+)", workflow.read_text()):
            seen.setdefault(match.group(1), match.group(2))
    for action, pin in sorted(seen.items()):
        row = Row(f"action:{action}", action, "Base & CI", "ok", pinned=pin,
                  source=f"https://api.github.com/repos/{action}/releases/latest")
        try:
            latest = github_latest(fetcher, action)
            row.upstream = latest
            if major(latest) and major(pin) and major(latest) > major(pin):  # type: ignore[operator]
                row.status = "outdated"
                row.hint = "bump the action major (a stale major is what triggers the Node runtime deprecation warning)"
            elif major(latest) and major(pin) and major(latest) == major(pin):
                row.status = "ok"
        except Exception as exc:  # noqa: BLE001
            unknowable(row, exc)
        rows.append(row)
    return rows


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check whether rea-agent-docker's pins are still current.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument("--markdown", action="store_true", help="emit a markdown table (CI step summary)")
    parser.add_argument("--only", default="", help="comma-separated keys/groups to include (keys: run --json to list)")
    parser.add_argument("--skip", default="", help="comma-separated keys/groups to skip")
    parser.add_argument("--jobs", type=int, default=8, help="concurrent lookups (default 8)")
    parser.add_argument("--timeout", type=float, default=12.0, help="per-request timeout in seconds")
    parser.add_argument("--no-fail", action="store_true", help="always exit 0")
    parser.add_argument("--quiet", action="store_true", help="only print actionable rows")
    args = parser.parse_args()

    docker_pins, env_pins = read_pins()
    pins = {**docker_pins, **{k: v for k, v in env_pins.items() if k not in docker_pins}}

    fetcher = Fetcher(args.timeout, args.jobs)
    rea_version = pins.get("REA_VERSION", "")
    admissions = scrape_rea(fetcher, rea_version) if rea_version else ReaAdmissions(version="")

    checks = [
        lambda: check_rea(fetcher, pins, admissions),
        lambda: check_node(fetcher, pins, admissions),
        lambda: check_ghidra(fetcher, pins, admissions),
        lambda: check_hopper(fetcher, pins, admissions),
        lambda: check_java(fetcher, pins, admissions),
        lambda: check_tools(fetcher, pins, admissions),
        lambda: check_wakaru_digest(fetcher, pins, admissions),
        lambda: check_misc(fetcher, pins, admissions),
        lambda: check_actions(fetcher),
    ]
    rows: list[Row] = []
    with ThreadPoolExecutor(max_workers=min(args.jobs, len(checks) * 2)) as pool:
        for result in pool.map(lambda fn: fn(), checks):
            rows.extend(result)

    if args.only:
        needles = [n.strip().lower() for n in args.only.split(",") if n.strip()]
        rows = [r for r in rows if any(n in r.key.lower() or n in r.group.lower() for n in needles)]
    if args.skip:
        needles = [n.strip().lower() for n in args.skip.split(",") if n.strip()]
        rows = [r for r in rows if not any(n in r.key.lower() or n in r.group.lower() for n in needles)]

    actionable = [r for r in rows if r.status in ACTIONABLE]
    pending = [r for r in rows if r.status in PENDING]
    unknowns = [r for r in rows if r.status == "unknown"]
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if args.json:
        print(json.dumps(
            {
                "generated_at": stamp,
                "rea_version": rea_version,
                "rea_admissions": {
                    "node_range": admissions.node_range,
                    "ghidra": admissions.ghidra,
                    "ghidra_java_major": admissions.ghidra_java_major,
                    "hopper_feed": admissions.hopper_feed,
                    "tools": admissions.tools,
                    "errors": admissions.errors,
                },
                "summary": {
                    "rows": len(rows),
                    "actionable": len(actionable),
                    "pending": len(pending),
                    "unknown": len(unknowns),
                },
                "rows": [r.as_dict() for r in rows],
            },
            indent=2,
        ))
        return 1 if actionable and not args.no_fail else 0

    if args.markdown:
        print(f"### rea-agent-docker update check ({stamp})")
        print()
        print(f"Pins read from `Dockerfile`; REA admission tables read from "
              f"`morluto/rea@rea-agents-{rea_version}`. "
              f"**{len(actionable)} actionable**, {len(pending)} awaiting the next REA release, "
              f"{len(unknowns)} unverifiable, {len(rows)} rows.")
        print()
        if actionable:
            print("**Actionable — the image disagrees with what REA admits:**")
            print()
            print("| status | component | pinned | upstream | REA admits |")
            print("| --- | --- | --- | --- | --- |")
            for row in actionable:
                print(f"| **{STATUS_LABEL[row.status]}** | {row.label} | {row.pinned or '-'} | "
                      f"{row.upstream or '-'} | {row.admits or '-'} |")
            print()
        else:
            print("Nothing actionable: every pin matches what REA currently expects.")
            print()
        if pending:
            print("Newer upstream, reported but not applied — by policy these wait for the "
                  "next `rea-agents` release:")
            print()
            print("| component | pinned | upstream |")
            print("| --- | --- | --- |")
            for row in pending:
                print(f"| {row.label} | {row.pinned or '-'} | {row.upstream or '-'} |")
        return 1 if actionable and not args.no_fail else 0

    print(f"rea-agent-docker update check — {stamp}")
    print(f"pins: Dockerfile ARGs; REA admissions: morluto/rea@rea-agents-{rea_version}")
    if admissions.errors:
        for name, error in admissions.errors.items():
            print(f"  ! could not read REA {name} table: {error}")
    print()

    # an engine that REA does not admit is the failure mode worth shouting about
    for row in rows:
        if row.status == "behind-rea":
            print(f"  !! {row.label}: {row.note}")
            if row.hint:
                print(f"     -> {row.hint}")
    if any(row.status == "behind-rea" for row in rows):
        print()

    groups: dict[str, list[Row]] = {}
    for row in rows:
        if args.quiet and row.status not in ACTIONABLE:
            continue
        groups.setdefault(row.group, []).append(row)

    width = max((len(r.label) for r in rows), default=20) + 2
    for group, group_rows in groups.items():
        print(f"{group}")
        for row in group_rows:
            label = STATUS_LABEL[row.status]
            pin = row.pinned or "-"
            bits = [f"pin {pin}"]
            if row.upstream and row.upstream != row.pinned:
                bits.append(f"upstream {row.upstream}")
            if row.admits and row.admits != row.pinned:
                bits.append(f"REA {row.admits}")
            line = f"  [{label:^10}] {row.label:<{width}} " + "  ".join(bits)
            print(line)
            if row.note:
                print(f"             {'':<{width}} {row.note}")
            if row.status in ACTIONABLE and row.hint:
                print(f"             {'':<{width}} -> {row.hint}")
            elif row.status in PENDING and row.note:
                print(f"             {'':<{width}} = newer upstream only - per policy this waits "
                      "for the next REA release")
        print()

    print(f"{len(rows)} rows: {len(actionable)} actionable, {len(pending)} awaiting the next "
          f"REA release, {len(unknowns)} unverifiable, "
          f"{len(rows) - len(actionable) - len(pending) - len(unknowns)} fine")
    if actionable:
        print("See docs/UPDATES.md for what to check and how to apply each bump.")
    elif pending:
        print("Nothing wrong: the pins match what REA admits. The newer upstream releases above "
              "wait for the next rea-agents release (docs/UPDATES.md).")
    return 1 if actionable and not args.no_fail else 0


if __name__ == "__main__":
    sys.exit(main())
