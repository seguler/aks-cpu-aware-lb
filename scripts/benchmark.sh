#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$ROOT/out/demo.kubeconfig}"
REPETITIONS="${REPETITIONS:-3}"
SECONDS_PER_PHASE="${SECONDS_PER_PHASE:-90}"
CONCURRENCY="${CONCURRENCY:-32}"
for tool in kubectl jq go; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 2; }
done
if ! [[ "$REPETITIONS" =~ ^[1-5]$ && "$SECONDS_PER_PHASE" =~ ^[0-9]{1,3}$ && "$CONCURRENCY" =~ ^[0-9]{1,3}$ ]]; then
    echo "Use repetitions 1..5, phase seconds 10..300, concurrency 1..128." >&2; exit 2
fi
SECONDS_PER_PHASE=$((10#$SECONDS_PER_PHASE))
CONCURRENCY=$((10#$CONCURRENCY))
if (( SECONDS_PER_PHASE < 10 || SECONDS_PER_PHASE > 300 || CONCURRENCY < 1 || CONCURRENCY > 128 )); then
    echo "Use repetitions 1..5, phase seconds 10..300, concurrency 1..128." >&2; exit 2
fi
kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
url="$(kc get gateway demo -n cpu-aware -o json | jq -er '.status.addresses[0].value')"
url="http://$url/work"
DEMO_TOKEN="$(kc get secret demo-auth -n cpu-aware -o json | jq -er '.data.token | @base64d')"
export DEMO_TOKEN
restore_policy() {
    local status=$?
    trap - EXIT
    unset DEMO_TOKEN
    if ! kc apply -f "$ROOT/k8s/policy.yaml"; then
        echo "Failed to restore load-aware policy; restore it manually." >&2
        status=1
    fi
    exit "$status"
}
trap restore_policy EXIT
mkdir -p "$ROOT/out" "$ROOT/results"
(cd "$ROOT" && go build -o out/bench ./cmd/bench)
wait_policy() {
    for ((attempt=0; attempt<60; attempt++)); do
        if kc get backendloadbalancingpolicy demo -n cpu-aware -o json | jq -e '
            .metadata.generation as $g |
            [.status.targets[]?.conditions[]? |
                select(.status == "True" and .observedGeneration == $g) | .type] |
            index("Accepted") != null and index("ResolvedRefs") != null' >/dev/null; then return; fi
        sleep 2
    done
    echo "Policy did not become Accepted/ResolvedRefs at the current generation." >&2
    return 1
}
for ((trial=1; trial<=REPETITIONS; trial++)); do
    modes=(round-robin load-aware)
    (( trial % 2 == 0 )) && modes=(load-aware round-robin)
    for mode in "${modes[@]}"; do
        if [[ "$mode" == round-robin ]]; then
            sed -e 's/strategy: load-aware/strategy: round-robin/' -e '/^    loadAware:/,$d' "$ROOT/k8s/policy.yaml" | kc apply -f -
        else
            kc apply -f "$ROOT/k8s/policy.yaml"
        fi
        wait_policy
        file="$ROOT/results/$mode-$trial.json"
        "$ROOT/out/bench" -url "$url" -mode "$mode" -duration "${SECONDS_PER_PHASE}s" \
            -warmup 60s -concurrency "$CONCURRENCY" >"$file"
        if jq -e '.errors > 0' "$file" >/dev/null; then
            echo "Requests failed in this phase; inspect counts before claiming routing/performance improvement." >&2
        fi
        cat "$file"
    done
done
