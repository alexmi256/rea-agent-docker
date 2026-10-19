# syntax=docker/dockerfile:1.7
# =============================================================================
#  rea-agent : Reverse Engineer Anything (REA) + its full analysis toolchain
#
#  Linux/amd64 only (deliberate scope - see README "Architecture & scope").
#  Base: Ubuntu 24.04 LTS ("noble") - the distribution REA's own automated
#  Hopper installer and Ghidra/JDK bindings are verified against.
#
#  Every tool REA can drive is installed *unless* the vendor forbids
#  redistribution (IDA Pro, JEB, licensed Hopper). Those are supported as
#  bring-your-own artefacts via `vendor/` at build time or volume mounts at
#  runtime; see docs/BYO-LICENSES.md.
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1 - binwalk 3.1.x (Rust rewrite). No prebuilt Linux release asset
# exists upstream, so build it in a throwaway Rust stage and copy the binary.
# -----------------------------------------------------------------------------
FROM rust:1.99-bookworm AS binwalk-builder
ARG BINWALK_VERSION=3.1.0
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    set -eux; \
    cargo install --locked --version "${BINWALK_VERSION}" binwalk --root /out; \
    /out/bin/binwalk --version; \
    strip /out/bin/binwalk


# -----------------------------------------------------------------------------
# Stage 2 - runtime image
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS rea-agent

ARG DEBIAN_FRONTEND=noninteractive

# --- pinned upstream versions ------------------------------------------------
ARG REA_VERSION=6.7.0
ARG NODE_VERSION=24.22.0
# REA declares frida as an optional dependency (JS instrumentation). npm 11
# blocks package install scripts by default, so frida's native binding is
# installed explicitly with --allow-scripts and linked into REA's tree.
ARG FRIDA_VERSION=17.24.1
ARG GHIDRA_VERSION=12.1.4
ARG GHIDRA_ZIP=ghidra_12.1.4_PUBLIC_20260921.zip
ARG GHIDRA_SHA256=
ARG GHIDRA_BASE_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download
# Hopper: REA 6.6.0 replaced the fixed launcher-digest allowlist with the
# publisher-signed vendor release feed (src/application/HopperReleaseFeed.ts +
# LinuxHopperPublisher.ts). REA now admits a Linux build only when it can verify
# the launcher against that feed's *current* release, so the pin below IS "the
# current public Linux demo" and the build fails loudly the moment the feed
# moves. Leave HOPPER_DEB_URL empty to read the filename and every digest from
# the feed (then compared against these pins); set it, and clear
# HOPPER_DEB_SHA1, to install your own mirrored/modified package instead. A
# licensed .deb dropped in vendor/ supersedes all of it (see vendor/README.md).
ARG HOPPER_RELEASES_URL=https://www.hopperapp.com/include/files-api.php?request=releases&public=true
ARG HOPPER_PUBLIC_KEY_URL=https://www.hopperapp.com/hopper-public-key.asc
ARG HOPPER_DEB_URL=
ARG HOPPER_DEMO_VERSION=6.6.0
ARG HOPPER_DEB_SHA1=575efccfd1ab3565399d04ef420b81483b631864
ARG HOPPER_DEB_BYTES=35748722
ARG HOPPER_LAUNCHER_SHA256=b2271008fb82bf14cfae5c3644cdde2b11fc6804bd7c99d67032ec1b1942d53c
ARG WABT_VERSION=1.0.42
ARG JADX_MCP_VERSION=0.7.1
ARG APKTOOL_VERSION=2.12.1
ARG UNBLOB_VERSION=26.6.4
ARG UNBLOB_PYTHON_VERSION=3.12
ARG MITMPROXY_VERSION=12.2.3
ARG PWNDBG_TAG=2026.09.15
ARG PWNDBG_COMMIT=55596aa676a2756efb8d67034f31675170eabe48
ARG PWTOOLS_VERSION=4.15.0
ARG PYELFTOOLS_VERSION=0.33
# Held at 2.1.2 by pwntools 4.15.0, which declares `unicorn !=2.1.3, !=2.1.4,
# >=2.0.1`: pip's resolver refuses 2.1.4 outright (ResolutionImpossible), so the
# newer unicorn is not installable next to the pwntools build REA admits. Unicorn
# is not REA-admitted either, so pwntools' own constraint is the binding one.
ARG UNICORN_VERSION=2.1.2
ARG ILSPYCMD_VERSION=8.2.0.7535
# Wakaru - REA's caller-supplied JavaScript source-recovery engine. Accepted range
# ^1.13.0, verified against 1.14.0 (src/javascript/recovery/WakaruRelease.ts), and
# REA fingerprints the executed binary, so the digest below is REA's own audited
# build of the official release asset - not a value we invented. The npm package
# would give the same bytes via @wakaru/cli-linux-x64, but REA wants the platform
# binary, never the Node shim in node_modules/.bin.
ARG WAKARU_VERSION=1.14.0
ARG WAKARU_LINUX_X64_SHA256=664fa06782a61eda7ed15885134b52525fd565dd77607e642062ceb6cd927c38
ARG CHROME_DEB_URL=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

# --- engine selection --------------------------------------------------------
# Which native analysis engine(s) this image ships:
#   all    -> Ghidra + Hopper (current default, largest)
#   ghidra -> Ghidra only
#   hopper -> Hopper only
#   ida    -> no bundled engine: bring your own IDA install + licence and an
#             IDA MCP registration (see docs/ida-variants.md)
# The rest of REA's toolchain (firmware, captures, managed code, browsers,
# Android, debuggers, cross toolchains) is identical in all four images.
ARG REA_ENGINE=all

# --- optional components -----------------------------------------------------
ARG INSTALL_CHROME=1
ARG INSTALL_PLAYWRIGHT=1
ARG INSTALL_PWNDBG=1
ARG INSTALL_WINE=1
ARG INSTALL_CROSS_TOOLCHAINS=1
ARG INSTALL_IDA=auto

# --- runtime identity --------------------------------------------------------
ARG REA_UID=1000
ARG REA_GID=1000
ARG REA_USER=rea

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    LANGUAGE=en_US:en \
    TZ=UTC \
    DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# =============================================================================
# 1. Base system packages
# =============================================================================
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      git git-lfs patch \
      unzip zip p7zip-full 7zip cabextract \
      xz-utils bzip2 gzip zstd lz4 lzop lzip \
      tar cpio file less jq tree rsync which locales tzdata \
      build-essential pkg-config bison flex make autoconf automake libtool \
      gcc g++ gdb gdb-multiarch libc6-dbg strace ltrace \
      binutils elfutils file nasm yasm upx-ucl \
      python3 python3-venv python3-pip python3-dev python3-magic \
      libmagic1t64 \
      util-linux procps psmisc netcat-openbsd socat iproute2 tcpdump \
      libncurses6 libncursesw6 libreadline8t64 \
      libgl1 libegl1 libglx-mesa0 libgl1-mesa-dri libgbm1 \
      libnss3 libx11-6 libxext6 libxrender1 libxtst6 libxi6 libxdamage1 \
      libxkbcommon0 libxkbcommon-x11-0 \
      libxcb-cursor0 libxcb-xinerama0 libxcb-icccm4 libxcb-image0 \
      libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xkb1 \
      libqt6svg6 \
      libcups2t64 libdrm2 libpango-1.0-0 libcairo2 libasound2t64 \
      fontconfig fonts-liberation2 fonts-dejavu-core \
      xvfb xauth x11-utils \
      openjdk-21-jdk-headless \
      yara qemu-user-static binfmt-support \
      openssl libssl-dev zlib1g-dev liblzma-dev \
    ; \
    rm -rf /var/lib/apt/lists/*

# =============================================================================
# 2. Node.js (REA requires 22.19+ / 24.11+ / 26+; Ubuntu ships an old Node)
# =============================================================================
ENV NODE_VERSION=${NODE_VERSION}
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    cd /var/cache/rea-dl; \
    file="node-v${NODE_VERSION}-linux-x64.tar.xz"; \
    [ -f "$file" ] || curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${file}"; \
    shasums="SHASUMS256-${NODE_VERSION}.txt"; \
    [ -f "$shasums" ] || curl -fsSLo "$shasums" "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${file}\$" "$shasums" | sha256sum -c -; \
    tar -xJf "$file" -C /usr/local --strip-components=1 --no-same-owner; \
    node --version; npm --version

# =============================================================================
# 3. REA itself (global npm install -> `rea` on PATH)
# =============================================================================
ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    REA_PACKAGE_VERSION=${REA_VERSION}
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    set -eux; \
    npm install --global --no-fund --no-audit "rea-agents@${REA_VERSION}"; \
    rea --version; \
    npm install --global --no-fund --no-audit --allow-scripts=frida "frida@${FRIDA_VERSION}"; \
    ln -sfn "$(npm root -g)/frida" "$(npm root -g)/rea-agents/node_modules/frida"; \
    cd "$(npm root -g)/rea-agents"; \
    node -e 'const f=require("frida"); console.log("frida binding:", require.resolve("frida")); f.getLocalDevice().then(d=>console.log("frida local device:", d.name)).catch(e=>{console.error("frida error:", e.message);process.exit(1);})'

# =============================================================================
# 4. Ghidra 12.1.x + JDK 21  (the multi-architecture engine)
#    Ships decompilers/languages for x86, x86-64, ARM/Thumb, AArch64, MIPS,
#    PowerPC, RISC-V, SuperH, 6502, Z80, 16-bit DOS, ... -> this is what makes
#    Hopper/IDA's narrower architecture coverage a non-issue.
#    Included in REA_ENGINE=all and REA_ENGINE=ghidra.
# =============================================================================
# JAVA_HOME is engine-independent: jadx, apktool and ilspycmd all need a JDK.
# The Ghidra install itself lives in the engine section at the end of the file.
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# =============================================================================
# 5. Hopper Disassembler (Linux x64) - engine section at the end of the file
# =============================================================================
COPY vendor/ /opt/rea-vendor/

# =============================================================================
# 6. Optional in-image IDA (Pro / Home / Free) - engine section at the end
#    OFF BY DEFAULT: Hex-Rays does not permit redistribution of IDA, and a
#    redistribution image (blacktop/docker-idapro) was taken down by DMCA in
#    Jan 2026. Drop your own installer in vendor/ida/*.run to bake it in, or
#    bind-mount an existing installation at runtime (recommended).
# =============================================================================

# =============================================================================
# 7. WABT 1.0.42 (exact release REA admits) and JADX headless MCP 0.7.1
# =============================================================================
ENV REA_WABT_BIN_DIRECTORY=/opt/wabt/bin \
    REA_JADX_MCP_JAR=/opt/jadx/jadx-headless-mcp-${JADX_MCP_VERSION}-all.jar
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    cd /var/cache/rea-dl; \
    wabt="wabt-${WABT_VERSION}-linux-x64.tar.gz"; \
    [ -f "$wabt" ] || curl -fsSLO "https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/${wabt}"; \
    [ -f "$wabt.sha256" ] || curl -fsSLO "https://github.com/WebAssembly/wabt/releases/download/${WABT_VERSION}/${wabt}.sha256"; \
    sha256sum -c "$wabt.sha256"; \
    mkdir -p /opt/wabt; \
    tar -xzf "$wabt" -C /opt/wabt --strip-components=1; \
    /opt/wabt/bin/wasm2wat --version; \
    mkdir -p /opt/jadx; \
    jar="jadx-headless-mcp-${JADX_MCP_VERSION}-all.jar"; \
    [ -f "$jar" ] || curl -fsSLo "$jar" \
      "https://github.com/1013503897/jadx-headless-mcp/releases/download/v${JADX_MCP_VERSION}/${jar}"; \
    install -m 0644 "$jar" "/opt/jadx/${jar}"; \
    ls -l "/opt/jadx/${jar}"

# =============================================================================
# 7b. Wakaru 1.14.0 (REA's JavaScript source-recovery engine)
# =============================================================================
# REA advertises `recover_javascript_sources` but installs nothing for it: it
# refuses the capability unless REA_WAKARU_COMMAND is an ABSOLUTE path to a
# platform binary (accepted range ^1.13.0, parser verified with 1.14.0) and
# util-linux prlimit is present. Hence the official release asset rather than the
# npm package - npm yields identical bytes at @wakaru/cli-linux-x64, but its
# node_modules/.bin entry is a Node shim, and REA resolves and fingerprints the
# executable itself. The digest below is REA's own audited value for this asset,
# so the build fails if the bytes ever differ; the banner is asserted in the
# exact form REA parses (`wakaru <semver>`).
ENV REA_WAKARU_COMMAND=/opt/wakaru/wakaru
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    cd /var/cache/rea-dl; \
    asset="wakaru-linux-x64.tar.gz"; \
    tarball="wakaru-${WAKARU_VERSION}-linux-x64.tar.gz"; \
    [ -f "$tarball" ] || curl -fsSLo "$tarball" \
      "https://github.com/pionxzh/wakaru/releases/download/v${WAKARU_VERSION}/${asset}"; \
    mkdir -p /opt/wakaru; \
    tar -xzf "$tarball" -C /opt/wakaru wakaru; \
    chmod 0755 /opt/wakaru/wakaru; \
    echo "${WAKARU_LINUX_X64_SHA256}  /opt/wakaru/wakaru" | sha256sum -c -; \
    "$REA_WAKARU_COMMAND" --version; \
    test -f /usr/bin/prlimit && test -x /usr/bin/prlimit

# =============================================================================
# 8. Apktool 2.x (REA verified against 2.7.0; 3.x changes output layout)
# =============================================================================
ENV REA_APKTOOL_COMMAND=/usr/local/bin/apktool
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    cd /var/cache/rea-dl; \
    jar="apktool_${APKTOOL_VERSION}.jar"; \
    [ -f "$jar" ] || curl -fsSLO \
      "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/${jar}"; \
    install -m 0644 "$jar" "/opt/apktool_${APKTOOL_VERSION}.jar"; \
    printf '#!/bin/sh\nexec java -jar /opt/apktool_%s.jar "$@"\n' "${APKTOOL_VERSION}" \
      > /usr/local/bin/apktool; \
    chmod 0755 /usr/local/bin/apktool; \
    apktool --version

# =============================================================================
# 9. .NET SDK 8 + ilspycmd (REA's optional managed-code engine)
# =============================================================================
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_ROOT=/usr/lib/dotnet \
    DOTNET_ROLL_FORWARD=Major \
    REA_ILSPY_CMD_PATH=/opt/dotnet-tools/ilspycmd
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends dotnet-sdk-8.0; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    dotnet --version

# =============================================================================
# 10. Python analysis environments (each one repo-pinned to what REA admits)
#     - pwntools    : inspect_binary_layout / recorded crash decoding
#     - pwndbg      : optional GDB mapping context for core files
#     - unblob      : firmware extraction
#     - mitmproxy   : native .mitm capture decoding
# =============================================================================
ENV REA_PWNTOOLS_PYTHON=/opt/venvs/pwntools/bin/python \
    REA_PWNDBG_GDB=/usr/bin/gdb \
    REA_PWNDBG_GDBINIT=/opt/pwndbg/gdbinit.py \
    REA_PWNDBG_VENV_PATH=/opt/pwndbg/.venv \
    REA_UNBLOB_COMMAND=/opt/venvs/unblob/bin/unblob \
    REA_MITMDUMP_COMMAND=/opt/venvs/mitmproxy/bin/mitmdump \
    PATH=/opt/venvs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    set -eux; \
    python3 -m venv /opt/venvs/pwntools; \
    /opt/venvs/pwntools/bin/pip install --upgrade pip; \
    /opt/venvs/pwntools/bin/pip install \
      "pwntools==${PWTOOLS_VERSION}" "pyelftools==${PYELFTOOLS_VERSION}" "unicorn==${UNICORN_VERSION}"; \
    /opt/venvs/pwntools/bin/python -c "import pwn; print('pwntools', pwn.version)"

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    set -eux; \
    python3 -m venv /opt/venvs/unblob; \
    /opt/venvs/unblob/bin/pip install --upgrade pip; \
    /opt/venvs/unblob/bin/pip install "unblob==${UNBLOB_VERSION}"; \
    /opt/venvs/unblob/bin/unblob --version

RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    set -eux; \
    python3 -m venv /opt/venvs/mitmproxy; \
    /opt/venvs/mitmproxy/bin/pip install --upgrade pip; \
    /opt/venvs/mitmproxy/bin/pip install "mitmproxy==${MITMPROXY_VERSION}"; \
    /opt/venvs/mitmproxy/bin/mitmdump --version

# =============================================================================
# 11. Firmware + signal + packet + binary tooling
# =============================================================================
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
      e2fsprogs dosfstools mtools device-tree-compiler \
      squashfs-tools cpio sleuthkit \
      tshark tcpdump \
      sigrok-cli libsigrokdecode4 \
      adb \
    ; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    tshark --version | head -1; \
    capinfos --version 2>/dev/null | head -1 || true; \
    sigrok-cli --version; \
    adb version | head -1

COPY --from=binwalk-builder /out/bin/binwalk /usr/local/bin/binwalk
ENV REA_BINWALK_COMMAND=/usr/local/bin/binwalk \
    REA_TSHARK_COMMAND=/usr/bin/tshark \
    REA_CAPINFOS_COMMAND=/usr/bin/capinfos \
    REA_SIGROK_COMMAND=/usr/bin/sigrok-cli \
    REA_ADB_PATH=/usr/bin/adb
RUN set -eux; binwalk --version; tshark --version | head -1; which capinfos

# =============================================================================
# 12. Browser (websites / Electron renderers) + Playwright Chromium
# =============================================================================
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    REA_BROWSER_NO_SANDBOX=1
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    if [ "${INSTALL_CHROME}" = "1" ]; then \
      cd /var/cache/rea-dl; \
      [ -f google-chrome.deb ] || curl -fsSLo google-chrome.deb "${CHROME_DEB_URL}"; \
      apt-get update -qq; \
      apt-get install -y --no-install-recommends ./google-chrome.deb; \
      apt-get clean; rm -rf /var/lib/apt/lists/*; \
      google-chrome --version; \
    fi; \
    if [ "${INSTALL_PLAYWRIGHT}" = "1" ]; then \
      pw_root="$(npm root -g)"; \
      pwc=""; \
      for c in "$pw_root/rea-agents/node_modules/playwright-core/cli.js" \
               "$pw_root/playwright-core/cli.js"; do \
        if [ -f "$c" ]; then pwc="$c"; break; fi; \
      done; \
      test -n "$pwc"; \
      echo "installing Playwright Chromium via $pwc"; \
      node "$pwc" install --with-deps chromium; \
      ls -1 /opt/ms-playwright; \
    fi

# =============================================================================
# 13. Optional: pwndbg (REA's --debugger-context for recorded Linux crashes)
# =============================================================================
RUN --mount=type=cache,target=/root/.cache/uv,sharing=locked \
    --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    set -eux; \
    if [ "${INSTALL_PWNDBG}" = "1" ]; then \
      git clone --quiet --branch "${PWNDBG_TAG}" --depth 1 \
        https://github.com/pwndbg/pwndbg.git /opt/pwndbg; \
      cd /opt/pwndbg; \
      test "$(git rev-parse HEAD)" = "${PWNDBG_COMMIT}"; \
      PWNDBG_NO_AUTOUPDATE=1 PWNDBG_VENV_PATH=/opt/pwndbg/.venv ./setup.sh; \
      test -f /opt/pwndbg/gdbinit.py; \
      test -x /opt/pwndbg/.venv/bin/python; \
      gdb --batch -q --nx -ex 'python import pwndbg; print("pwndbg", pwndbg.version.commit)' 2>&1 | tail -3 || true; \
    fi

# =============================================================================
# 14. Optional: wine (run x86/x86-64 PE targets) and cross toolchains
#     (build aarch64/arm/mips/riscv64/powerpc/Windows fixtures for analysis)
# =============================================================================
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    set -eux; \
    apt-get update -qq; \
    if [ "${INSTALL_WINE}" = "1" ]; then \
      apt-get install -y --no-install-recommends wine wine64 || true; \
    fi; \
    if [ "${INSTALL_CROSS_TOOLCHAINS}" = "1" ]; then \
      apt-get install -y --no-install-recommends \
        gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf \
        gcc-mips-linux-gnu gcc-mipsel-linux-gnu \
        gcc-riscv64-linux-gnu gcc-powerpc-linux-gnu \
        libc6-dev-arm64-cross libc6-dev-armhf-cross \
        libc6-dev-mips-cross libc6-dev-mipsel-cross \
        libc6-dev-riscv64-cross libc6-dev-powerpc-cross \
        mingw-w64 || true; \
    fi; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    ls /usr/bin/*-gcc 2>/dev/null | head -20 || true

# =============================================================================
# 15. MCP plumbing: uv (needed by the official Hex-Rays IDA MCP / PyPI MCP
#     servers) and supergateway (stdio <-> Streamable HTTP bridge so the
#     container's MCP surface can be published on a port).
# =============================================================================
ARG UV_VERSION=0.13.1
ARG SUPERGATEWAY_VERSION=4.2.0
ENV UV_INSTALL_DIR=/usr/local/bin \
    UV_NO_MODIFY_PATH=1 \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_TOOL_DIR=/opt/uv-tools \
    UV_CACHE_DIR=/tmp/uv-cache
RUN set -eux; \
    curl -fsSL "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh; \
    uv --version; \
    npm install --global --no-fund --no-audit "supergateway@${SUPERGATEWAY_VERSION}"; \
    supergateway --help >/dev/null 2>&1 || node -e "require('supergateway')" 2>/dev/null || true; \
    command -v supergateway

# =============================================================================
# 16. Non-root runtime user, auxiliary services and verification harness
# =============================================================================
# Ubuntu 24.04 ships uid/gid 1000 as a stock `ubuntu` user, so the runtime
# identity is created tolerantly: reuse an existing group id, and rename a stock
# user that already owns the requested uid (this is what makes the default
# REA_UID/REA_GID work, not just the host-matched ones).
RUN set -eux; \
    if ! getent group "${REA_GID}" >/dev/null; then \
      groupadd --gid "${REA_GID}" "${REA_USER}"; \
    fi; \
    if getent passwd "${REA_UID}" >/dev/null; then \
      stock="$(getent passwd "${REA_UID}" | cut -d: -f1)"; \
      echo "uid ${REA_UID} is taken by the stock user '${stock}'; renaming it to '${REA_USER}'"; \
      usermod --login "${REA_USER}" --home "/home/${REA_USER}" --move-home \
        --shell /bin/bash --gid "${REA_GID}" "${stock}"; \
    else \
      useradd --uid "${REA_UID}" --gid "${REA_GID}" --create-home \
        --home-dir "/home/${REA_USER}" --shell /bin/bash "${REA_USER}"; \
    fi; \
    id "${REA_USER}"; \
    mkdir -p /work /evidence /etc/rea /home/${REA_USER}/.idapro \
             /home/${REA_USER}/.local/share/hopper /home/${REA_USER}/.rea \
             /home/${REA_USER}/.dotnet /var/log/rea; \
    chown -R "${REA_UID}:${REA_GID}" /home/${REA_USER} /work /evidence /var/log/rea; \
    chmod 0755 /opt/wabt /opt/jadx 2>/dev/null || true

# ilspycmd as a global tool in a fixed, home-independent location (so a
# named/bind volume over /home/rea does not hide it)
RUN set -eux; \
    mkdir -p /opt/dotnet-tools; \
    dotnet tool install --tool-path /opt/dotnet-tools ilspycmd --version ${ILSPYCMD_VERSION}; \
    test -x /opt/dotnet-tools/ilspycmd; \
    /opt/dotnet-tools/ilspycmd --version 2>&1 | head -3 || true

# =============================================================================
# 17. ENGINE LAYERS - kept at the end on purpose.
#     Everything above is identical in all four engine images (REA_ENGINE=all,
#     ghidra, hopper, ida), so those layers come from the cache for the second
#     and later engine variant instead of being rebuilt. Only the layers below
#     differ between rea-agent, rea-agent-ghidra, rea-agent-hopper and
#     rea-agent-ida. `make build-all` builds them one after the other for this
#     reason.
# =============================================================================
ENV REA_ENGINE=${REA_ENGINE}

# --- 17a. Ghidra 12.1.x (REA_ENGINE=all|ghidra) -----------------------------
# Multi-architecture engine: x86, x86-64, ARM/Thumb, AArch64, MIPS, PowerPC,
# RISC-V, SuperH, 6502, Z80, 16-bit DOS, ... JDK 21 is installed above and is
# present in every image (jadx, apktool and ilspycmd need it too).
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    case "${REA_ENGINE}" in all|ghidra) : ;; *) echo "skipping Ghidra (REA_ENGINE=${REA_ENGINE})"; exit 0 ;; esac; \
    cd /var/cache/rea-dl; \
    [ -f "${GHIDRA_ZIP}" ] || curl -fsSLo "${GHIDRA_ZIP}" \
      "${GHIDRA_BASE_URL}/Ghidra_${GHIDRA_VERSION}_build/${GHIDRA_ZIP}"; \
    if [ -n "${GHIDRA_SHA256}" ]; then echo "${GHIDRA_SHA256}  ${GHIDRA_ZIP}" | sha256sum -c -; fi; \
    sha256sum "${GHIDRA_ZIP}" | tee /tmp/ghidra-zip.sha256; \
    mkdir -p /opt/ghidra-extract; \
    unzip -q "${GHIDRA_ZIP}" -d /opt/ghidra-extract; \
    mv "/opt/ghidra-extract/ghidra_${GHIDRA_VERSION}_PUBLIC" /opt/ghidra; \
    rmdir /opt/ghidra-extract; \
    test -x /opt/ghidra/support/analyzeHeadless; \
    test -x "/opt/ghidra/Ghidra/Features/Decompiler/os/linux_x86_64/decompile"; \
    chmod -R a+rX /opt/ghidra; \
    java -version 2>&1 | head -1; \
    javac -version

# --- 17b. Hopper Disassembler (REA_ENGINE=all|hopper) ----------------------
# Official public demo .deb -> /opt/hopper. A licensed .deb dropped in
# vendor/ supersedes it (see vendor/README.md). Hopper's headless Linux path
# is driven by REA on a private Xvfb display, demo mode included.
#
# REA 6.6.0+ admits a Linux Hopper build by verifying its launcher against the
# publisher-signed vendor release feed, so the build:
#   1. reads the feed, and fails if its current Ubuntu/Mint release is not
#      exactly the pinned one (that is the update trigger, not a surprise at
#      runtime);
#   2. verifies the downloaded package against the feed's byte length + SHA-1
#      and the installed launcher against the feed's main_exe_hash;
#   3. retains that signed evidence (release row + vendor public key + the
#      package bytes) under REA's own cache path, so REA can admit the launcher
#      without network access.
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    case "${REA_ENGINE}" in all|hopper) : ;; *) echo "skipping Hopper (REA_ENGINE=${REA_ENGINE})"; exit 0 ;; esac; \
    cd /var/cache/rea-dl; \
    evidence="/home/${REA_USER}/.cache/rea/hopper-releases"; \
    vendor_deb="$(ls /opt/rea-vendor/*.deb 2>/dev/null | head -n1 || true)"; \
    from_feed=0; \
    if [ -n "$vendor_deb" ]; then \
      echo "Using vendor-supplied Hopper package: $vendor_deb"; \
      cp "$vendor_deb" /tmp/hopper.deb; \
    else \
      url="${HOPPER_DEB_URL}"; \
      if [ -n "${HOPPER_DEB_SHA1}" ]; then \
        from_feed=1; \
        feed=/tmp/hopper-release-feed.json; \
        curl -fsSL -H "accept: application/json" -H "user-agent: rea-installer" \
          -o "$feed" "${HOPPER_RELEASES_URL}"; \
        jq -e '."Ubuntu / Mint"' "$feed" > /dev/null; \
        feed_version="$(jq -r '."Ubuntu / Mint".version' "$feed")"; \
        debname="$(jq -r '."Ubuntu / Mint".filename | split("/") | last' "$feed")"; \
        feed_sha1="$(jq -r '."Ubuntu / Mint".file_hash' "$feed")"; \
        feed_bytes="$(jq -r '."Ubuntu / Mint".file_length' "$feed")"; \
        feed_main="$(jq -r '."Ubuntu / Mint".main_exe_hash' "$feed")"; \
        echo "vendor feed offers Linux Hopper ${feed_version} (${debname}, ${feed_bytes} bytes)"; \
        test "$debname" = "Hopper-${HOPPER_DEMO_VERSION}-Linux-demo.deb" \
          || { echo "Hopper feed moved: ${debname} is no longer Hopper-${HOPPER_DEMO_VERSION}-Linux-demo.deb - bump HOPPER_DEMO_VERSION and its digests (docs/UPDATES.md section B)"; exit 1; }; \
        test "$feed_sha1" = "${HOPPER_DEB_SHA1}" \
          || { echo "Hopper feed moved: sha1 ${feed_sha1} != pin ${HOPPER_DEB_SHA1}"; exit 1; }; \
        test "$feed_bytes" = "${HOPPER_DEB_BYTES}" \
          || { echo "Hopper feed moved: ${feed_bytes} != pin ${HOPPER_DEB_BYTES} bytes"; exit 1; }; \
        test "$feed_main" = "${HOPPER_LAUNCHER_SHA256}" \
          || { echo "Hopper feed moved: launcher ${feed_main} != pin ${HOPPER_LAUNCHER_SHA256}"; exit 1; }; \
        [ -n "$url" ] || url="https://www.hopperapp.com:443/downloader/public/${debname}"; \
      fi; \
      [ -n "$url" ] || { echo "no Hopper package to install: set HOPPER_DEB_URL or HOPPER_DEB_SHA1"; exit 1; }; \
      echo "Downloading ${url}"; \
      debname="${debname:-$(basename "$url")}"; \
      [ -f "$debname" ] || curl -fsSL -A "Mozilla/5.0 (X11; Linux x86_64)" \
        -H "Referer: https://www.hopperapp.com/download" -o "$debname" "$url"; \
      if [ -n "${HOPPER_DEB_BYTES}" ]; then \
        test "$(stat -c %s "$debname")" = "${HOPPER_DEB_BYTES}"; \
      fi; \
      if [ -n "${HOPPER_DEB_SHA1}" ]; then \
        echo "${HOPPER_DEB_SHA1}  ${debname}" | sha1sum -c -; \
      fi; \
      cp "$debname" /tmp/hopper.deb; \
    fi; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends /tmp/hopper.deb; \
    rm -f /tmp/hopper.deb; \
    apt-get install -y --no-install-recommends xvfb python3 x11-utils libxtst6; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    test -x /opt/hopper/bin/Hopper; \
    ldd /opt/hopper/bin/Hopper | grep -c "not found" || true; \
    chmod -R a+rX /opt/hopper; \
    launcher="$(sha256sum /opt/hopper/bin/Hopper | cut -d' ' -f1)"; \
    echo "Hopper launcher sha256: ${launcher}"; \
    if [ "$from_feed" = "1" ]; then \
      test "$launcher" = "${HOPPER_LAUNCHER_SHA256}" \
        || { echo "installed Hopper launcher ${launcher} is not the admitted demo ${HOPPER_LAUNCHER_SHA256}"; exit 1; }; \
      mkdir -p "${evidence}/${launcher}"; \
      install -m 0644 "$debname" "${evidence}/${launcher}/archive"; \
      jq -c '{format:"rea-signed-hopper-release-v1", family:"deb", release:."Ubuntu / Mint"}' \
        "$feed" > "${evidence}/${launcher}/release.json"; \
      curl -fsSL -H "user-agent: rea-installer" \
        -o "${evidence}/${launcher}/public-key.asc" "${HOPPER_PUBLIC_KEY_URL}"; \
      chmod 0644 "${evidence}/${launcher}/release.json" "${evidence}/${launcher}/public-key.asc"; \
      chown -R "${REA_UID}:${REA_GID}" "/home/${REA_USER}/.cache"; \
      mkdir -p /usr/local/share/rea; \
      printf '%s\n' "${launcher}" > /usr/local/share/rea/hopper-launcher.sha256; \
      echo "retained publisher-signed Hopper evidence: ${evidence}/${launcher}"; \
    fi

# --- 17c. Optional in-image IDA (REA_ENGINE=all|ida) ------------------------
# OFF BY DEFAULT: Hex-Rays does not permit redistribution of IDA, and a
# redistribution image (blacktop/docker-idapro) was taken down by DMCA in
# Jan 2026. Drop your own installer in vendor/ida/*.run to bake it in, or
# bind-mount an existing installation at runtime (recommended).
# IDA Pro / IDA Home / IDA Free are the same program at different licence
# tiers - see docs/ida-variants.md for which ones can drive REA headlessly.
RUN set -eux; \
    mkdir -p /opt/ida; \
    case "${REA_ENGINE}" in all|ida) : ;; *) echo "skipping IDA (REA_ENGINE=${REA_ENGINE})"; exit 0 ;; esac; \
    run="$(ls /opt/rea-vendor/ida/*.run 2>/dev/null | head -n1 || true)"; \
    if [ "${INSTALL_IDA}" = "0" ] || [ -z "$run" ]; then \
      echo "IDA not baked into the image (bring-your-own via volume mount, or vendor/ida/*.run)"; \
    else \
      echo "Installing vendor-supplied IDA: $run"; \
      chmod +x "$run"; \
      "$run" --mode unattended --prefix=/opt/ida --unattendedmodeui none; \
      test -x /opt/ida/ida64 || test -x /opt/ida/ida; \
      for lic in /opt/rea-vendor/ida/*.hexlic; do \
        [ -e "$lic" ] || continue; \
        mkdir -p /home/rea/.idapro; \
        cp "$lic" /home/rea/.idapro/; \
      done; \
      chown -R "${REA_UID}:${REA_GID}" /home/rea/.idapro; \
      true; \
    fi

# --- 17d. Engine configuration ---------------------------------------------
# /usr/local/share/rea/engine      : plain marker the healthcheck, entrypoint
#                                    and verification harness read
#                                    (all|ghidra|hopper|ida)
# /usr/local/share/rea/engine.env  : the engine paths THIS image needs, and a
#                                    standing REA_ANALYSIS_PROVIDER for the
#                                    single-engine images
# /usr/local/bin/rea               : wrapper that sources engine.env for every
#                                    `rea` invocation, so `docker exec -i <ctr>
#                                    rea mcp` finds the engine without any
#                                    compose env. An image that has no Ghidra
#                                    does not advertise GHIDRA_INSTALL_DIR at
#                                    all - REA never sees a stale path.
#
# NOTE the path: these live under /usr/local/share, NOT /etc/rea, because
# compose mounts the user's ./config over /etc/rea (overrides + secrets) and a
# mount there would shadow the marker.
RUN set -eux; \
    mkdir -p /usr/local/share/rea /etc/rea; \
    echo "${REA_ENGINE}" > /usr/local/share/rea/engine; \
    touch /usr/local/share/rea/engine.env; \
    case "${REA_ENGINE}" in \
      all|ghidra) printf '%s\n' \
        "export GHIDRA_INSTALL_DIR=/opt/ghidra" \
        "export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64" >> /usr/local/share/rea/engine.env ;; \
    esac; \
    case "${REA_ENGINE}" in \
      ghidra) printf '%s\n' "export REA_ANALYSIS_PROVIDER=ghidra" >> /usr/local/share/rea/engine.env ;; \
    esac; \
    case "${REA_ENGINE}" in \
      all|hopper) printf '%s\n' \
        "export HOPPER_LAUNCHER_PATH=/opt/hopper/bin/Hopper" \
        "export HOPPER_STATE_DIR=/home/rea/.local/share/hopper" >> /usr/local/share/rea/engine.env ;; \
    esac; \
    case "${REA_ENGINE}" in \
      hopper) printf '%s\n' "export REA_ANALYSIS_PROVIDER=hopper" >> /usr/local/share/rea/engine.env ;; \
    esac; \
    case "${REA_ENGINE}" in \
      all|ida) printf '%s\n' "export IDADIR=/opt/ida" >> /usr/local/share/rea/engine.env ;; \
    esac; \
    cat /usr/local/share/rea/engine.env; \
    mv /usr/local/bin/rea /usr/local/bin/rea-npm-shim; \
    printf '%s\n' \
      '#!/bin/sh' \
      '# Inject this image'"'"'s engine configuration (see engine.env beside this' \
      '# script, generated by the rea-agent image build - do not edit in a' \
      '# container; rebuild the image instead).' \
      'rea_engine_env=/usr/local/share/rea/engine.env' \
      'if [ -r "$rea_engine_env" ]; then' \
      '    set -a' \
      '    . "$rea_engine_env"' \
      '    set +a' \
      'fi' \
      'exec /usr/local/bin/rea-npm-shim "$@"' \
      > /usr/local/bin/rea; \
    chmod 0755 /usr/local/bin/rea; \
    rea --version; \
    echo "engine profile: $(cat /usr/local/share/rea/engine)"; \
    rea providers --json 2>/dev/null | head -20 || true

# --- operational env ---------------------------------------------------------
# TERM keeps PTY-oriented tooling (pwntools, mitmdump, chrome) quiet; REA uses
# its own PTY for process capture.
ENV TERM=xterm \
    REA_MCP_INPUT_SCHEMA_PROFILE=compact \
    TMPDIR=/tmp/rea \
    NODE_OPTIONS=--max-old-space-size=8192

COPY docker/entrypoint.sh /usr/local/bin/rea-agent-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/rea-agent-healthcheck
COPY docker/rea.env.example /usr/local/share/rea/rea.env.example
COPY docker/verify /opt/rea/verify
COPY scripts/setup-ida-mcp.sh /opt/rea/scripts/setup-ida-mcp.sh
COPY assets /opt/rea/assets
RUN chmod 0755 /usr/local/bin/rea-agent-entrypoint \
              /usr/local/bin/rea-agent-healthcheck \
              /opt/rea/scripts/setup-ida-mcp.sh \
              /opt/rea/verify/*.sh

USER ${REA_USER}
WORKDIR /work
ENV HOME=/home/${REA_USER}
# The scratch dir must be usable by *any* uid: compose/`docker run` may start the
# container as a different user than the image's, and the entrypoint's
# writable-HOME fallback lives here. 1777 (like /tmp) is the conventional mode -
# users can only remove their own files - and it is what lets a foreign uid still
# reach "ready" instead of dying on mkdir.
RUN mkdir -p "${TMPDIR}" && chmod 1777 "${TMPDIR}"

EXPOSE 8811
HEALTHCHECK --interval=60s --timeout=90s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/rea-agent-healthcheck"]

# =============================================================================
# OCI metadata - deliberately the LAST instructions.
# Labels are image metadata, so placing them here means adding one never
# invalidates the cached Ghidra/Hopper/IDA layers above.
#
# org.opencontainers.image.source is not decoration: it is what links a package
# published to ghcr.io back to this repository, and it is what lets the package
# inherit the repository's access (public image for a public repo). Without it a
# pushed image stays private and unrelated to the repo in the GitHub UI.
# =============================================================================
ARG OCI_SOURCE=https://github.com/alexmi256/rea-agent-docker
LABEL org.opencontainers.image.source="${OCI_SOURCE}" \
      org.opencontainers.image.title="rea-agent-${REA_ENGINE}" \
      org.opencontainers.image.description="REA (Reverse Engineer Anything) with the '${REA_ENGINE}' engine profile plus a full reverse-engineering toolchain (Ghidra/Hopper/IDA-ready, firmware, captures, browsers, managed code, Android, debuggers), MCP-ready." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${REA_VERSION}-linux-amd64" \
      org.opencontainers.image.base.name="docker.io/library/ubuntu:24.04" \
      com.rea.engine="${REA_ENGINE}"

ENTRYPOINT ["/usr/local/bin/rea-agent-entrypoint"]
CMD ["sleep", "infinity"]
