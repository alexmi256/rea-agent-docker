#!/usr/bin/env bash
# =============================================================================
# Run the in-image verification harness against a throwaway container.
#
#   scripts/verify.sh                      # the default (all-engines) image
#   scripts/verify.sh --quick              # tool presence, static analysis, MCP handshake
#   scripts/verify.sh --only tools,mcp
#   scripts/verify.sh --engine hopper      # whatever image that engine resolves to
#   scripts/verify.sh --image ghcr.io/<owner>/rea-agent-hopper:6.8.0-linux-amd64
#   scripts/verify.sh --compose --service rea-ghidra   # exec inside a compose service
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Container-path -> host-path translation for Docker-outside-of-Docker: when this
# script runs inside a container that talks to the host Docker daemon, volume
# sources resolve on the *host*. Empty by default (nothing to translate on a
# normal host); Hermes-in-Docker users set it in .env, e.g.
#   HOST_PATH_MAP=/opt/data=/flashcache/hermes
HOST_PATH_MAP="${HOST_PATH_MAP:-}"
IMAGE=""
DOCKER="${DOCKER:-docker}"
COMPOSE=0
SERVICE="${REA_SERVICE:-rea-agent}"
ENGINE=""
ARGS=()

if [ -f "$PROJECT_DIR/.env" ]; then
    # .env supplies REA_UID/REA_GID, REA_*_IMAGE, HOST_PATH_MAP and friends. It is
    # gitignored, so host-specific values live there and never in the repo.
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env"
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --compose) COMPOSE=1; shift ;;
        --service) SERVICE="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

# Resolve the image: --image wins, then --engine via the shared helper (which
# also honours the REA_*_IMAGE names in .env), then the all-engines default.
if [ -z "$IMAGE" ]; then
    IMAGE="$("$PROJECT_DIR/scripts/image-name.sh" "${ENGINE:-all}")"
fi

if [ "$COMPOSE" = "1" ]; then
    exec docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T "$SERVICE" \
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
# Name the image in the summary: the harness reads REA_IMAGE_ID, and its own
# fallback (/etc/rea/image-id) is hidden here because /etc/rea is bind-mounted.
echo "running harness in $IMAGE as $RUN_USER"
exec "$DOCKER" run --rm -i --shm-size=1g \
    --user "$RUN_USER" \
    -e "REA_IMAGE_ID=$IMAGE" \
    -v "$WORK:/work" \
    -v "$CONFIG:/etc/rea:ro" \
    "$IMAGE" /opt/rea/verify/verify-all.sh ${ARGS[@]+"${ARGS[@]}"}
