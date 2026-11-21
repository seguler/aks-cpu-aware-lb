#!/usr/bin/env bash
set -Eeuo pipefail
set +x
[[ "${1:-}" == --confirm-delete && $# == 1 ]] || {
    echo "Deletes only the tagged NEW sample group. Usage: cleanup.sh --confirm-delete" >&2; exit 2;
}
: "${SUBSCRIPTION:?Set the same authorized SUBSCRIPTION used to deploy}"
: "${RESOURCE_GROUP:?Set the exact NEW sample RESOURCE_GROUP}"
[[ "$RESOURCE_GROUP" =~ ^[a-zA-Z0-9-]+$ ]] || { echo "Invalid resource group." >&2; exit 2; }
azc() { az "$@" --subscription "$SUBSCRIPTION" --only-show-errors; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
expected_managed="MC_${RESOURCE_GROUP}_cpu-demo_${LOCATION:-westus2}"
group_exists="$(azc group exists -n "$RESOURCE_GROUP" -o tsv)"
if [[ "$group_exists" == false ]]; then
    managed_exists="$(azc group exists -n "$expected_managed" -o tsv)"
    [[ "$managed_exists" == false ]] || {
        echo "Sample group is absent but an expected managed group remains; verify ownership and complete scoped teardown." >&2; exit 1;
    }
    rm -f -- "$ROOT/out/demo.kubeconfig"
    echo "Sample group already absent."
    exit 0
fi
group="$(azc group show -n "$RESOURCE_GROUP" -o json)"
[[ "$(jq -r '.tags.sample // ""' <<<"$group")" == aks-cpu-aware-lb ]] || {
    echo "Safety tag mismatch; refusing deletion." >&2; exit 1;
}
clusters="$(azc aks list -g "$RESOURCE_GROUP" -o json)"
managed_names="$(jq -r --arg expected "$expected_managed" \
    '([$expected] + [.[].nodeResourceGroup | strings | select(length > 0)]) | unique[]' <<<"$clusters")"
mapfile -t managed_groups <<<"$managed_names"
azc group delete -n "$RESOURCE_GROUP" --yes -o none
group_exists="$(azc group exists -n "$RESOURCE_GROUP" -o tsv)"
[[ "$group_exists" == false ]] || {
    echo "Sample group still exists after deletion." >&2; exit 1;
}
for managed in "${managed_groups[@]}"; do
    managed_exists="$(azc group exists -n "$managed" -o tsv)"
    [[ "$managed_exists" == false ]] || {
        echo "A sample-managed node group still exists; inspect teardown." >&2; exit 1;
    }
done
rm -f -- "$ROOT/out/demo.kubeconfig"
echo "Sample group and its managed node groups are absent. Shared providers/features were NOT unregistered."
