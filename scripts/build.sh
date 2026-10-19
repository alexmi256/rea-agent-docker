#!/usr/bin/env bash
# =============================================================================
# Build rea-agent and (optionally) verify it.
#
# Handles the Docker-outside-of-Docker path translation: when this script runs
# inside a container that talks to a host Docker daemon (Hermes in Docker with
# the host socket bind-mounted), the build context / volume sources are
# resolved by the *host* daemon, so paths must be translated.
#
#   scripts/build.sh                        # the all-engines image (default)
#   scripts/build.sh --engine ghidra        # Ghidra-only image
#   scripts/build.sh --engine hopper --verify-quick
#   scripts/build.sh --engine ida --no-cache
#
# The image name comes from scripts/image-name.sh, which honours the per-engine
# REA_*_IMAGE variables in .env (GHCR names by default, so a local build tags the
# same name `docker compose pull` would fetch) and falls back to a plain local
# name. `--image` overrides it.
#
# REA_UID / REA_GID are read from the environment or .env and passed to the
# build, so the image's runtime user matches your host user (the harness and the
# compose mounts assume that). Unset, the Dockerfile default 1000 is used, which
# the image handles even though Ubuntu ships a stock uid 1000.
#
#   HOST_PATH_MAP  colon-separated list of <container-path>=<host-path>
#                  (Docker-outside-of-Docker only; see the header comment above)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Container-path -> host-path translation for Docker-outside-of-Docker (see the
# header). Empty by default: on a normal host the paths are already host-visible
# and nothing needs translating. Hermes-in-Docker users set it in .env, e.g.
#   HOST_PATH_MAP=/opt/data=/flashcache/hermes
HOST_PATH_MAP="${HOST_PATH_MAP:-}"
IMAGE=""       # set by --image, else derived from the engine via image-name.sh
DOCKER="${DOCKER:-docker}"
BUILD_ARGS=()
ENGINE="all"
REA_TAG="${REA_TAG:-6.7.0-linux-amd64}"

usage() { sed -n '2,20p' "$0"; exit 0; }

host_path() {
    local path="$1" pair container_prefix host_prefix
    while IFS= read -r pair; do
        [ -z "$pair" ] && continue
        container_prefix="${pair%%=*}"
        host_prefix="${pair#*=}"
        case "$path" in
            "$container_prefix"|"$container_prefix"/*)
                # only translate when the container prefix really is a bind
                # mount here (otherwise the path is already host-visible)
                if mountpoint -q "$container_prefix" 2>/dev/null || grep -qs " $container_prefix " /proc/self/mountinfo; then
                    printf '%s%s' "$host_prefix" "${path#"$container_prefix"}"
                    return 0
                fi
                ;;
        esac
    done <<<"$(printf '%s' "$HOST_PATH_MAP" | tr ':' '\n')"
    printf '%s' "$path"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --arg) BUILD_ARGS+=("--build-arg" "$2"); shift 2 ;;
        --no-cache) BUILD_ARGS+=("--no-cache"); shift ;;
        --verify) VERIFY=1; shift ;;
        --verify-quick) VERIFY=1; QUICK=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

ENV_FILE=""
if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env"
    REA_TAG="${REA_TAG:-6.7.0-linux-amd64}"
fi
# Image name: --image wins, otherwise the shared helper (which reads .env, so a
# GHCR-published name here means `docker build` tags exactly what compose pulls).
[ -n "$IMAGE" ] || IMAGE="$("$PROJECT_DIR/scripts/image-name.sh" "$ENGINE")"

CONTEXT="$(host_path "$PROJECT_DIR")"
echo "project : $PROJECT_DIR"
echo "context : $CONTEXT   (as seen by the Docker daemon)"
echo "engine  : $ENGINE"
echo "image   : $IMAGE"
echo "user    : ${REA_UID:-<image default 1000>}:${REA_GID:-<image default 1000>}"

"$DOCKER" build \
    --platform linux/amd64 \
    --tag "$IMAGE" \
    --build-arg "REA_ENGINE=$ENGINE" \
    ${REA_UID:+--build-arg "REA_UID=$REA_UID"} \
    ${REA_GID:+--build-arg "REA_GID=$REA_GID"} \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    "$CONTEXT"

echo "built $IMAGE"
"$DOCKER" image inspect "$IMAGE" --format 'size: {{.Size}} id: {{.Id}}'

if [ "${VERIFY:-0}" = "1" ]; then
    WORK="$(host_path "$PROJECT_DIR/work")"
    CONFIG="$(host_path "$PROJECT_DIR/config")"
    mkdir -p "$PROJECT_DIR/work" "$PROJECT_DIR/config"
    echo "--- verification harness (image engine: $(docker image inspect "$IMAGE" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^REA_ENGINE=//p')) ---"
    "$DOCKER" run --rm -i --shm-size=1g \
        --user "${REA_UID:-$(id -u)}:${REA_GID:-$(id -g)}" \
        -e "REA_IMAGE_ID=$IMAGE" \
        -v "$WORK:/work" -v "$CONFIG:/etc/rea:ro" \
        "$IMAGE" /opt/rea/verify/verify-all.sh ${QUICK:+--quick}
fi
