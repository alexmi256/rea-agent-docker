#!/usr/bin/env bash
# =============================================================================
# rea-agent entrypoint
#
# Prepares the container for REA, then hands off to the container command:
#
#   * loads optional runtime overrides (/etc/rea/rea.env, ~/.rea/rea.env)
#   * installs an IDA licence/registration if one was mounted
#   * publishes remote IDA/JEB MCP servers onto loopback (REA only accepts
#     127.0.0.1 / [::1] endpoints for those adapters)
#   * prints a provider summary when REA_ENTRYPOINT_DOCTOR=1
#
# Everything REA needs to *find* a tool is already set as image-wide ENV, so
# `docker exec -i <container> rea mcp` behaves identically to the entrypoint.
# =============================================================================
set -euo pipefail

log() { printf '[rea-agent] %s\n' "$*" >&2; }

# --- 1. optional runtime overrides -------------------------------------------
for f in /etc/rea/rea.env "${HOME:-/home/rea}/.rea/rea.env"; do
    if [ -r "$f" ]; then
        # shellcheck disable=SC1090
        set -a; . "$f"; set +a
        log "loaded overrides from $f"
    fi
done

# --- 2. writable runtime dirs (bind mounts may arrive host-owned) ------------
# A named volume over /home/<user> is initialised with the *build-time* uid; if
# the container is later started as a different uid (compose `user:`), HOME is
# not writable and REA's cache/state writes would fail. Fall back loudly.
if ! mkdir -p "${HOME:-/home/rea}/.rea" 2>/dev/null; then
    fallback="${REA_HOME_FALLBACK:-${TMPDIR:-/tmp/rea}/home}"
    mkdir -p "$fallback"
    log "warning: \$HOME=${HOME:-unset} is not writable; using $fallback instead."
    log "warning: fix by rebuilding with REA_UID/REA_GID matching your user, or run:"
    log "warning:   docker compose exec -u 0 rea-agent chown -R \$(id -u):\$(id -g) /home/rea"
    export HOME="$fallback"
fi
mkdir -p "${TMPDIR:-/tmp/rea}" /var/log/rea 2>/dev/null || true

# --- 3. IDA licence relocation ------------------------------------------------
# IDA reads `ida.hexlic` from IDADIR or $HOME/.idapro. Both stay outside the
# image so no licence ever lands in a layer.
install_licences() {
    local src="$1"
    mkdir -p "${HOME:-/home/rea}/.idapro"
    cp -f "$src"/*.hexlic "${HOME:-/home/rea}/.idapro/" 2>/dev/null && \
        log "installed IDA licence(s) from $src" || true
}
[ -n "${IDA_LICENSE_PATH:-}" ] && [ -d "${IDA_LICENSE_PATH}" ] && install_licences "$IDA_LICENSE_PATH"
for d in /etc/rea/ida /opt/ida-license; do
    [ -d "$d" ] && install_licences "$d"
done
[ -n "${IDADIR:-}" ] && [ -d "${IDADIR}" ] && log "IDADIR=${IDADIR}"

# --- 4. loopback forwards for remote MCP engines ------------------------------
# REA's IDA and JEB adapters accept only loopback URLs. Point REA at
# 127.0.0.1:<port> and set REA_IDA_MCP_FORWARD / REA_JEB_MCP_FORWARD to the
# real host:port (sidecar container, another machine, IDA running in a VM).
start_forward() {
    local name="$1" port="$2" target="$3"
    [ -z "$target" ] && return 0
    if ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then
        log "port ${port} already listening; skipping ${name} forward"
        return 0
    fi
    log "forwarding 127.0.0.1:${port} -> ${target} (${name} MCP)"
    socat -d "TCP-LISTEN:${port},bind=127.0.0.1,reuseaddr,fork" "TCP:${target}" \
        >>"/var/log/rea/${name}-forward.log" 2>&1 &
}
start_forward ida "${REA_IDA_MCP_LOCAL_PORT:-8745}" "${REA_IDA_MCP_FORWARD:-}"
start_forward jeb "${REA_JEB_MCP_LOCAL_PORT:-8425}" "${REA_JEB_MCP_FORWARD:-}"

if [ -n "${REA_IDA_MCP_CONFIG:-}" ]; then
    if [ -r "${REA_IDA_MCP_CONFIG}" ]; then
        log "IDA MCP registration: ${REA_IDA_MCP_CONFIG}"
    else
        log "warning: REA_IDA_MCP_CONFIG=${REA_IDA_MCP_CONFIG} is not readable"
    fi
fi
[ -n "${REA_JEB_MCP_URL:-}" ] && log "JEB MCP endpoint: ${REA_JEB_MCP_URL}"

# --- 5. startup summary -------------------------------------------------------
if [ "${REA_ENTRYPOINT_DOCTOR:-0}" = "1" ] && command -v rea >/dev/null 2>&1; then
    log "provider summary:"
    rea providers --json 2>&1 | head -40 >&2 || log "reas providers check failed"
fi

log "ready: rea $(rea --version 2>/dev/null || echo '?') | node $(node --version 2>/dev/null || echo '?') | user $(id -un)"
exec "$@"
