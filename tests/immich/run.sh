#!/usr/bin/env bash
# Regression suite for Immich v2/v3 dual-version support.
#
#   ./run.sh                      # default matrix: v2.5.6, v3.0.3, v3.1.0
#   ./run.sh v3.2.0               # just one version
#   ./run.sh v2.5.6 v3.2.0        # any set
#
# Each version gets a throwaway stack, a real API key, and both harnesses compiled
# against the CURRENT Core sources. Requires docker, python3, swiftc.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(cd ../.. && pwd)"
CORE="$ROOT/ImmiBridge/ImmiBridge/Core"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

VERSIONS=("$@")
[ ${#VERSIONS[@]} -eq 0 ] && VERSIONS=(v2.5.6 v3.0.3 v3.1.0)

FAILED=0
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "Compiling harnesses against $CORE"
CORE_SRCS=("$CORE"/*.swift)

swiftc -O -o "$WORK/client_harness" client_harness/main.swift "${CORE_SRCS[@]}" 2>"$WORK/build1.log" || {
    echo "client harness failed to build:"; grep error "$WORK/build1.log" | head; exit 1; }

# The pipeline harness needs ImmichUploadPipeline's file scope, so glue the real source
# and the shim into one file rather than checking in a copy that would go stale.
mkdir -p "$WORK/core"
cp "$CORE"/*.swift "$WORK/core/"
cat pipeline_harness/shim.swift >> "$WORK/core/PhotoBackupCore.swift"
swiftc -O -o "$WORK/pipeline_harness" pipeline_harness/main.swift "$WORK/core"/*.swift 2>"$WORK/build2.log" || {
    echo "pipeline harness failed to build:"; grep error "$WORK/build2.log" | head; exit 1; }
echo "  both harnesses built"

i=0
for TAG in "${VERSIONS[@]}"; do
    PORT=$((2400 + i * 10))
    PROXY=$((PORT + 1))
    SLUG="immich-test-$(echo "$TAG" | tr -d 'v.')"
    i=$((i + 1))

    say "=== $TAG (api :$PORT, proxy :$PROXY) ==="
    IMMICH_TAG="$TAG" IMMICH_PORT="$PORT" docker compose -f compose.yml -p "$SLUG" up -d >/dev/null 2>&1

    printf '  waiting for server'
    UP=0
    for _ in $(seq 1 90); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/server/ping" 2>/dev/null)" = "200" ]; then
            UP=1; break
        fi
        printf '.'; sleep 4
    done
    echo
    if [ "$UP" != "1" ]; then
        echo "  SERVER NEVER CAME UP — skipping $TAG"; FAILED=1
        IMMICH_TAG="$TAG" IMMICH_PORT="$PORT" docker compose -f compose.yml -p "$SLUG" down -v >/dev/null 2>&1
        continue
    fi

    MAJOR=$(curl -s "http://localhost:$PORT/api/server/version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["major"])')
    KEY=$(python3 getkey.py "http://localhost:$PORT")
    echo "  major=$MAJOR"

    # Recording proxy: Immich does not request-log by default, so sitting in the path is
    # the only trustworthy way to prove which endpoints the client actually hits.
    LOG="$WORK/wire-$TAG.log"
    python3 proxy.py "$PROXY" "http://localhost:$PORT" "$LOG" >/dev/null 2>&1 &
    PROXY_PID=$!
    sleep 2

    "$WORK/client_harness" "http://localhost:$PROXY" "$KEY" "$MAJOR" || FAILED=1
    "$WORK/pipeline_harness" "http://localhost:$PORT" "$KEY" "$MAJOR" || FAILED=1

    kill $PROXY_PID 2>/dev/null

    # The whole point of the change: v3 must never touch the endpoints it removed, and
    # v2 must still use them. Anything else means the version gate regressed.
    # grep -c exits 1 when the count is zero but still prints "0", so `|| echo 0` would
    # append a second line and break the integer comparison below.
    EXIST=$(grep -c 'POST /api/assets/exist' "$LOG" 2>/dev/null || true); EXIST=${EXIST:-0}
    SEARCH=$(grep -c 'POST /api/search/metadata' "$LOG" 2>/dev/null || true); SEARCH=${SEARCH:-0}
    echo
    echo "  wire: /assets/exist=$EXIST  /search/metadata=$SEARCH"
    if [ "$MAJOR" -ge 3 ]; then
        if [ "$EXIST" -eq 0 ] && [ "$SEARCH" -eq 0 ]; then
            echo "  [PASS] v3 issued zero calls to the removed endpoints"
        else
            echo "  [FAIL] v3 called a removed endpoint — the version gate leaked"; FAILED=1
        fi
    else
        if [ "$EXIST" -gt 0 ] && [ "$SEARCH" -gt 0 ]; then
            echo "  [PASS] v2 still uses its endpoints (routing preserved)"
        else
            echo "  [FAIL] v2 stopped using its own endpoints — gate is over-eager"; FAILED=1
        fi
    fi

    IMMICH_TAG="$TAG" IMMICH_PORT="$PORT" docker compose -f compose.yml -p "$SLUG" down -v >/dev/null 2>&1
done

say "$([ $FAILED -eq 0 ] && echo 'ALL VERSIONS PASSED' || echo 'FAILURES — see above')"
exit $FAILED
