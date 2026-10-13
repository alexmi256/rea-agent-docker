#!/usr/bin/env bash
# =============================================================================
# Build every engine image: all, ghidra, hopper, ida.
#
#   scripts/build-all.sh                 # build all four
#   scripts/build-all.sh --verify-quick  # ...and smoke-verify each one
#   scripts/build-all.sh --engines ghidra,hopper
#
# Ghidra/Hopper/IDA/Docker layers are shared through the build cache, so the
# later images are mostly cache hits: only the engine-specific layer differs.
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINES="all ghidra hopper ida"
PASSTHROUGH=()

while [ $# -gt 0 ]; do
    case "$1" in
        --engines) ENGINES="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

failed=()
for engine in $ENGINES; do
    echo
    echo "=== building engine: $engine ==="
    if "$PROJECT_DIR/scripts/build.sh" --engine "$engine" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; then
        :
    else
        failed+=("$engine")
    fi
done

echo
echo "=== image sizes ==="
for engine in $ENGINES; do
    case "$engine" in
        all)    img="rea-agent:6.4.0-linux-amd64" ;;
        *)      img="rea-agent-${engine}:6.4.0-linux-amd64" ;;
    esac
    size="$("${DOCKER:-docker}" image inspect "$img" --format '{{.Size}}' 2>/dev/null || echo missing)"
    if [ "$size" != "missing" ]; then
        size="$(awk -v b="$size" 'BEGIN{printf "%.2f GB", b/1024/1024/1024}')"
    fi
    printf '  %-34s %s\n' "$img" "$size"
done

if [ "${#failed[@]}" -gt 0 ]; then
    echo
    echo "FAILED: ${failed[*]}" >&2
    exit 1
fi
echo
echo "all engine images built"
