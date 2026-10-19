#!/usr/bin/env bash
# =============================================================================
# Print the image name for an engine profile - the single source of truth used
# by scripts/build.sh, scripts/verify.sh, scripts/verify-all-engines.sh and the
# Makefile, so the image you build, the image you verify and the image compose
# pulls are always the same name.
#
#   scripts/image-name.sh all|ghidra|hopper|ida
#
# Precedence:
#   1. the per-engine variable from the environment or .env
#      REA_IMAGE / REA_GHIDRA_IMAGE / REA_HOPPER_IMAGE / REA_IDA_IMAGE
#      (.env.example points these at ghcr.io/<owner>/<image>:<tag>, so building
#      and pulling agree by default)
#   2. a plain local name: rea-agent[-<engine>]:<tag>
#
# REA_TAG overrides the tag suffix (default 6.7.0-linux-amd64).
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$DIR/.." && pwd)"

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a; . "$PROJECT_DIR/.env"; set +a
fi

engine="${1:-all}"
tag="${REA_TAG:-6.7.0-linux-amd64}"

case "$engine" in
    all)    configured="${REA_IMAGE:-}";        default="rea-agent:$tag" ;;
    ghidra) configured="${REA_GHIDRA_IMAGE:-}"; default="rea-agent-ghidra:$tag" ;;
    hopper) configured="${REA_HOPPER_IMAGE:-}"; default="rea-agent-hopper:$tag" ;;
    ida)    configured="${REA_IDA_IMAGE:-}";    default="rea-agent-ida:$tag" ;;
    *)
        echo "image-name.sh: unknown engine '$engine' (use all|ghidra|hopper|ida)" >&2
        exit 2
        ;;
esac

printf '%s\n' "${configured:-$default}"
