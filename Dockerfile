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
ARG REA_VERSION=6.4.0
ARG NODE_VERSION=24.21.0
ARG GHIDRA_VERSION=12.1.4
ARG GHIDRA_ZIP=ghidra_12.1.4_PUBLIC_20260921.zip
ARG GHIDRA_SHA256=
ARG GHIDRA_BASE_URL=https://github.com/NationalSecurityAgency/ghidra/releases/download
ARG HOPPER_DEB_URL=https://www.hopperapp.com/downloader/public/Hopper-6.5.0-Linux-demo.deb
ARG HOPPER_DEB_SHA1=f3aa66e3ebb3dc8a716538a96c3ef03d5c8ff789
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
ARG UNICORN_VERSION=2.1.2
ARG ILSPYCMD_VERSION=8.2.0.7535
ARG CHROME_DEB_URL=https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

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
    [ -f SHASUMS256.txt ] || curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"; \
    grep " ${file}\$" SHASUMS256.txt | sha256sum -c -; \
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
    rea --version

# =============================================================================
# 4. Ghidra 12.1.x + JDK 21  (the multi-architecture engine)
#    Ships decompilers/languages for x86, x86-64, ARM/Thumb, AArch64, MIPS,
#    PowerPC, RISC-V, SuperH, 6502, Z80, 16-bit DOS, ... -> this is what makes
#    Hopper/IDA's narrower architecture coverage a non-issue.
# =============================================================================
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64 \
    GHIDRA_INSTALL_DIR=/opt/ghidra
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
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
    java -version 2>&1 | head -1; \
    javac -version

# =============================================================================
# 5. Hopper Disassembler (Linux x64)
#    Official public demo .deb -> /opt/hopper. A licensed .deb dropped in
#    vendor/ supersedes it (see vendor/README.md). Hopper's headless Linux
#    path is driven by REA on a private Xvfb display, demo mode included.
# =============================================================================
ENV HOPPER_LAUNCHER_PATH=/opt/hopper/bin/Hopper \
    HOPPER_STATE_DIR=/home/rea/.local/share/hopper
COPY vendor/ /opt/rea-vendor/
RUN --mount=type=cache,target=/var/cache/rea-dl,sharing=locked \
    set -eux; \
    cd /var/cache/rea-dl; \
    deb="$(ls /opt/rea-vendor/*.deb 2>/dev/null | head -n1 || true)"; \
    if [ -n "$deb" ]; then \
      echo "Using vendor-supplied Hopper package: $deb"; \
      cp "$deb" /tmp/hopper.deb; \
    else \
      echo "Using official Hopper demo package: ${HOPPER_DEB_URL}"; \
      [ -f hopper.deb ] || curl -fsSL -A "Mozilla/5.0 (X11; Linux x86_64)" \
        -H "Referer: https://www.hopperapp.com/download" -o hopper.deb "${HOPPER_DEB_URL}"; \
      echo "${HOPPER_DEB_SHA1}  hopper.deb" | sha1sum -c -; \
      cp hopper.deb /tmp/hopper.deb; \
    fi; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends /tmp/hopper.deb; \
    rm -f /tmp/hopper.deb; \
    apt-get install -y --no-install-recommends xvfb python3 x11-utils libxtst6; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    test -x "${HOPPER_LAUNCHER_PATH}"; \
    ldd "${HOPPER_LAUNCHER_PATH}" | grep -c "not found" || true; \
    "${HOPPER_LAUNCHER_PATH}" --help 2>&1 | head -5 || echo "Hopper present (GUI binary)"

# =============================================================================
# 6. Optional in-image IDA Pro / IDA Home / IDA Free
#    OFF BY DEFAULT: Hex-Rays does not permit redistribution of IDA, and a
#    redistribution image (blacktop/docker-idapro) was taken down by DMCA in
#    Jan 2026. Drop your own installer in vendor/ida/*.run to bake it in, or
#    bind-mount an existing installation at runtime (recommended).
# =============================================================================
ENV IDADIR=/opt/ida
RUN set -eux; \
    run="$(ls /opt/rea-vendor/ida/*.run 2>/dev/null | head -n1 || true)"; \
    if [ "${INSTALL_IDA}" = "0" ] || [ -z "$run" ]; then \
      echo "IDA not baked into the image (bring-your-own via volume mount, or vendor/ida/*.run)"; \
      mkdir -p /opt/ida; \
    else \
      echo "Installing vendor-supplied IDA: $run"; \
      chmod +x "$run"; \
      "$run" --mode unattended --prefix=/opt/ida --unattendedmodeui none; \
      test -x /opt/ida/ida64 || test -x /opt/ida/ida; \
      for lic in /opt/rea-vendor/ida/*.hexlic; do [ -e "$lic" ] && mkdir -p /home/rea/.idapro && cp "$lic" /home/rea/.idapro/; done; \
      true; \
    fi

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
    /opt/venvs/pwntools/bin/python -c "import pwn; from pwn import version; print('pwntools', version.version)"

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
      pwc="/usr/lib/node_modules/rea-agents/node_modules/playwright-core/cli.js"; \
      test -f "$pwc"; \
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
        mingw-w64 || true; \
    fi; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    ls /usr/bin/*-gcc 2>/dev/null | head -20 || true

# =============================================================================
# 15. MCP plumbing: uv (needed by the official Hex-Rays IDA MCP / PyPI MCP
#     servers) and supergateway (stdio <-> Streamable HTTP bridge so the
#     container's MCP surface can be published on a port).
# =============================================================================
ARG UV_VERSION=0.13.0
ARG SUPERGATEWAY_VERSION=4.1.0
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
RUN set -eux; \
    groupadd --gid "${REA_GID}" "${REA_USER}"; \
    useradd --uid "${REA_UID}" --gid "${REA_GID}" --create-home \
      --home-dir "/home/${REA_USER}" --shell /bin/bash "${REA_USER}"; \
    mkdir -p /work /evidence /etc/rea /home/${REA_USER}/.idapro \
             /home/${REA_USER}/.local/share/hopper /home/${REA_USER}/.rea \
             /home/${REA_USER}/.dotnet /var/log/rea; \
    chown -R "${REA_UID}:${REA_GID}" /home/${REA_USER} /work /evidence /var/log/rea; \
    chmod 0755 /opt/ghidra /opt/hopper /opt/wabt /opt/jadx 2>/dev/null || true

# ilspycmd as a global tool in a fixed, home-independent location (so a
# named/bind volume over /home/rea does not hide it)
RUN set -eux; \
    mkdir -p /opt/dotnet-tools; \
    dotnet tool install --tool-path /opt/dotnet-tools ilspycmd --version ${ILSPYCMD_VERSION}; \
    test -x /opt/dotnet-tools/ilspycmd; \
    /opt/dotnet-tools/ilspycmd --version 2>&1 | head -3 || true

# --- operational env ---------------------------------------------------------
ENV REA_MCP_INPUT_SCHEMA_PROFILE=compact \
    TMPDIR=/tmp/rea \
    NODE_OPTIONS=--max-old-space-size=8192

COPY docker/entrypoint.sh /usr/local/bin/rea-agent-entrypoint
COPY docker/healthcheck.sh /usr/local/bin/rea-agent-healthcheck
COPY docker/rea.env.example /etc/rea/rea.env.example
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
RUN mkdir -p "${TMPDIR}"

EXPOSE 8811
HEALTHCHECK --interval=60s --timeout=90s --start-period=120s --retries=3 \
    CMD ["/usr/local/bin/rea-agent-healthcheck"]

ENTRYPOINT ["/usr/local/bin/rea-agent-entrypoint"]
CMD ["sleep", "infinity"]
