#!/usr/bin/env bash
# =============================================================================
# Run the in-image verification harness against a throwaway container.
#
#   scripts/verify.sh                 # everything (Ghidra multi-arch, Hopper, MCP)
#   scripts/verify.sh --quick         # tool presence, static analysis, MCP handshake
#   scripts/verify.sh --only tools,mcp
#   scripts/verify.sh --compose       # exec the harness in the compose service
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PATH_MAP="${HOST_PATH_MAP:-/opt/data=/flashcache/hermes}"
IMAGE="${REA_IMAGE:-rea-agent:6.4.0-linux-amd64}"
DOCKER="${DOCKER:-docker}"
COMPOSE=0
ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMAGE="$2"; shift 2 ;;
        --compose) COMPOSE=1; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

if [ "$COMPOSE" = "1" ]; then
    exec docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T rea-agent \
        /opt/rea/verify/verify-all.sh ${ARGS[@]+"${ARGS[@]}"}
fi

host_path() {
    local path="$1" pair cp hp
    while IFS= read -r pair; do
        [ -z "$pair" ] && continue
        cp="${pair%%=*}"; hp="${pair#*=}"
        case "$path" in
            "$cp"|"$cp"/*)
                if grep -qs " $cp " /proc/self/mountinfo; then
                    printf '%s%s' "$hp" "${path#"$cp"}"; return 0
                fi ;;
        esac
    done <<<"$(printf '%s' "$HOST_PATH_MAP" | tr ':' '\n')"
    printf '%s' "$path"
}

mkdir -p "$PROJECT_DIR/work" "$PROJECT_DIR/config"
WORK="$(host_path "$PROJECT_DIR/work")"
CONFIG="$(host_path "$PROJECT_DIR/config")"

# NOTE: .env is intentionally NOT passed with --env-file. It contains
# interpolated settings only; forwarding its (sometimes empty) REA_* entries
# would make REA fail config validation ("Too small: expected string to have
# >=1 characters"). Optional REA_* overrides belong in config/rea.env.

# Run as the host user that owns ./work, so reports and /work stay readable.
# REA_UID/REA_GID come from .env when present; the image user is uid 1000.
RUN_USER="${REA_UID:-$(id -u)}:${REA_GID:-$(id -g)}"
echo "running harness in $IMAGE as $RUN_USER"
exec "$DOCKER" run --rm -i --shm-size=1g \
    --user "$RUN_USER" \
    -v "$WORK:/work" \
    -v "$CONFIG:/etc/rea:ro" \
    "$IMAGE" /opt/rea/verify/verify-all.sh ${ARGS[@]+"${ARGS[@]}"}
