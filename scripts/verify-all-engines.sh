#!/usr/bin/env bash
# =============================================================================
# Verify every built engine image with the same harness, then report the
# per-engine result. The harness is engine-aware (it reads /etc/rea/engine), so
# each image is checked for what it actually carries and skips the rest.
#
#   scripts/verify-all-engines.sh                 # full harness on all four
#   scripts/verify-all-engines.sh --quick         # fast profile on all four
#   scripts/verify-all-engines.sh --engines ghidra,hopper
#
# Reads .env for REA_UID/REA_GID and image tags; honours --tag <suffix>.
# =============================================================================
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINES="all ghidra hopper ida"
QUICK=0
PASSTHROUGH=()

while [ $# -gt 0 ]; do
    case "$1" in
        --engines) ENGINES="$(printf '%s' "$2" | tr ',' ' ')"; shift 2 ;;
        --quick) QUICK=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) PASSTHROUGH+=("$1"); shift ;;
    esac
done

if [ -f "$PROJECT_DIR/.env" ]; then
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env"
fi
TAG_SUFFIX="${REA_TAG:-6.4.0-linux-amd64}"

image_for() {
    case "$1" in
        all) printf 'rea-agent:%s' "$TAG_SUFFIX" ;;
        *)   printf 'rea-agent-%s:%s' "$1" "$TAG_SUFFIX" ;;
    esac
}

declare -a RESULTS=()
failed=0

for engine in $ENGINES; do
    img="$(image_for "$engine")"
    echo
    echo "=============================================================="
    echo "=== verifying engine: $engine  ($img)"
    echo "=============================================================="
    if ! "${DOCKER:-docker}" image inspect "$img" >/dev/null 2>&1; then
        echo "image not built: $img" >&2
        RESULTS+=("$engine|not built|-|-|-")
        failed=$((failed + 1))
        continue
    fi
    if "$PROJECT_DIR/scripts/verify.sh" --image "$img" ${QUICK:+--quick} ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; then
        rc=0
    else
        rc=$?
        failed=$((failed + 1))
    fi
    latest="$(ls -td "$PROJECT_DIR/work/verify-reports"/*/ 2>/dev/null | head -1 || true)"
    p="$(sed -n 's/^passed: *//p' "${latest}summary.txt" 2>/dev/null | head -1)"
    f="$(sed -n 's/^failed: *//p' "${latest}summary.txt" 2>/dev/null | head -1)"
    s="$(sed -n 's/^skipped: *//p' "${latest}summary.txt" 2>/dev/null | head -1)"
    RESULTS+=("$engine|passed=${p:-?} failed=${f:-?} skipped=${s:-?}|exit=$rc|$(basename "${latest:-none}")")
done

echo
echo "=============================================================="
echo "=== per-engine results"
echo "=============================================================="
printf '%-8s %-38s %-9s %s\n' "ENGINE" "COUNTS" "EXIT" "RUN"
for row in "${RESULTS[@]}"; do
    IFS='|' read -r engine counts rc run <<<"$row"
    printf '%-8s %-38s %-9s %s\n' "$engine" "$counts" "$rc" "$run"
done

echo
if [ "$failed" -gt 0 ]; then
    echo "$failed engine image(s) did not pass; reports are under work/verify-reports/" >&2
    exit 1
fi
echo "all verified engine images passed"
