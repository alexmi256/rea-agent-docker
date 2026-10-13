#!/usr/bin/env bash
# =============================================================================
# Build rea-agent and (optionally) verify it.
#
# Handles the Docker-outside-of-Docker path translation: when this script runs
# inside a container that talks to a host Docker daemon (Hermes in Docker with
# the host socket bind-mounted), the build context / volume sources are
# resolved by the *host* daemon, so paths must be translated.
#
#   HOST_PATH_MAP  colon-separated list of <container-path>=<host-path>
#                  (default: the Hermes bind-mount pair)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_PATH_MAP="${HOST_PATH_MAP:-/opt/data=/flashcache/hermes}"
IMAGE="${REA_IMAGE:-rea-agent:6.4.0-linux-amd64}"
DOCKER="${DOCKER:-docker}"
BUILD_ARGS=()

usage() { sed -n '2,12p' "$0"; exit 0; }

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
        --image) IMAGE="$2"; shift 2 ;;
        --arg) BUILD_ARGS+=("--build-arg" "$2"); shift 2 ;;
        --no-cache) BUILD_ARGS+=("--no-cache"); shift ;;
        --verify) VERIFY=1; shift ;;
        --verify-quick) VERIFY=1; QUICK=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

CONTEXT="$(host_path "$PROJECT_DIR")"
echo "project : $PROJECT_DIR"
echo "context : $CONTEXT   (as seen by the Docker daemon)"
echo "image   : $IMAGE"

"$DOCKER" build \
    --platform linux/amd64 \
    --tag "$IMAGE" \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    "$CONTEXT"

echo "built $IMAGE"
"$DOCKER" image inspect "$IMAGE" --format 'size: {{.Size}} id: {{.Id}}'

if [ "${VERIFY:-0}" = "1" ]; then
    WORK="$(host_path "$PROJECT_DIR/work")"
    CONFIG="$(host_path "$PROJECT_DIR/config")"
    mkdir -p "$PROJECT_DIR/work" "$PROJECT_DIR/config"
    echo "--- verification harness ---"
    "$DOCKER" run --rm -i --shm-size=1g \
        --user "${REA_UID:-$(id -u)}:${REA_GID:-$(id -g)}" \
        -v "$WORK:/work" -v "$CONFIG:/etc/rea:ro" \
        "$IMAGE" /opt/rea/verify/verify-all.sh ${QUICK:+--quick}
fi
