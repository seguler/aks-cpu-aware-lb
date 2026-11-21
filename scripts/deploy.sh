#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out"
KUBECONFIG="$OUT/demo.kubeconfig"
preflight_only=false
confirm_costs=false
for argument in "$@"; do
    case "$argument" in
        --preflight-only) preflight_only=true ;;
        --confirm-costs) confirm_costs=true ;;
        *) echo "Usage: deploy.sh --preflight-only | --confirm-costs" >&2; exit 2 ;;
    esac
done
if ! "$preflight_only" && ! "$confirm_costs"; then
    echo "Creates NEW billable resources. Review costs and use --confirm-costs, or --preflight-only." >&2
    exit 2
fi
: "${SUBSCRIPTION:?Set SUBSCRIPTION locally; never commit it}"
: "${RESOURCE_GROUP:?Set a NEW dedicated RESOURCE_GROUP}"
: "${REGISTRY:?Set a globally unique REGISTRY name}"
: "${KUBERNETES_VERSION:?Set an exact currently supported AKS patch >=1.32}"
LOCATION="${LOCATION:-westus2}"
SMALL_SKU="${SMALL_SKU:-Standard_D2s_v5}"
LARGE_SKU="${LARGE_SKU:-Standard_D4s_v5}"
SYSTEM_SKU="${SYSTEM_SKU:-Standard_D4s_v5}"
[[ "$RESOURCE_GROUP" =~ ^[a-zA-Z0-9-]+$ && "$REGISTRY" =~ ^[a-z0-9]{5,40}$ ]] || {
    echo "Invalid resource-group or registry name." >&2; exit 2;
}
[[ "$SMALL_SKU" != "$LARGE_SKU" ]] || { echo "Choose different backend VM SKUs." >&2; exit 2; }
if ! [[ "$KUBERNETES_VERSION" =~ ^1\.([0-9]{1,3})\.[0-9]+$ ]]; then
    echo "Use a supported AKS patch >=1.32." >&2; exit 2
fi
if (( 10#${BASH_REMATCH[1]} < 32 )); then
    echo "Use a supported AKS patch >=1.32." >&2; exit 2
fi
for tool in az jq kubectl kubelogin; do
    command -v "$tool" >/dev/null || { echo "Missing required Linux tool: $tool" >&2; exit 2; }
done
azc() { az "$@" --subscription "$SUBSCRIPTION" --only-show-errors; }
kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }
created=false
phase=preflight
on_exit() {
    local status=$?
    unset DEMO_TOKEN
    if (( status != 0 )); then
        echo "Failed during $phase. Azure RBAC conditions, deny assignments, policy or propagation may reject deployment." >&2
        if "$created"; then
            echo "Inspect the NEW demo, then run scripts/cleanup.sh --confirm-delete with the same environment." >&2
        fi
    fi
    exit "$status"
}
trap on_exit EXIT
group_exists="$(azc group exists --name "$RESOURCE_GROUP" -o tsv)"
[[ "$group_exists" == false ]] || {
    echo "Refusing to reuse an existing resource group." >&2; exit 1;
}
subscription_id="$(azc account show --query id -o tsv)"
permissions="$(azc rest --method get --url \
    "https://management.azure.com/subscriptions/$subscription_id/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json)"
jq -e '.value | type == "array"' <<<"$permissions" >/dev/null
action=microsoft.authorization/roleassignments/write
can_assign=false
while IFS= read -r entry; do
    allowed=false
    excluded=false
    while IFS= read -r pattern; do
        # Unquoted RHS intentionally matches Azure action wildcards.
        # shellcheck disable=SC2053
        if [[ "$action" == ${pattern,,} ]]; then allowed=true; fi
    done < <(jq -r '.actions[]?' <<<"$entry")
    while IFS= read -r pattern; do
        # shellcheck disable=SC2053
        if [[ "$action" == ${pattern,,} ]]; then excluded=true; fi
    done < <(jq -r '.notActions[]?' <<<"$entry")
    if "$allowed" && ! "$excluded"; then can_assign=true; fi
done < <(jq -c '.value[]' <<<"$permissions")
if ! "$can_assign"; then
    echo "Preflight: no advertised roleAssignments/write at the subscription parent. Contributor alone cannot attach ACR or grant cluster RBAC. Activate appropriately scoped RBAC/User Access Administrator (or equivalent). No resources created." >&2
    exit 1
fi
echo "Role-assignment permission is advertised; this does NOT prove conditional/deny/policy or future assignment success."
for provider in Microsoft.ContainerService Microsoft.Network Microsoft.NetworkFunction \
    Microsoft.ServiceNetworking Microsoft.Compute Microsoft.ContainerRegistry; do
    state="$(azc provider show --namespace "$provider" --query registrationState -o tsv)"
    [[ "$state" == Registered ]] || {
        echo "Required provider not Registered: $provider. Obtain scoped approval before registering it." >&2; exit 1;
    }
done
for feature in ManagedGatewayAPIPreview ApplicationLoadBalancerPreview; do
    state="$(azc feature show --namespace Microsoft.ContainerService --name "$feature" --query properties.state -o tsv)"
    [[ "$state" == Registered ]] || {
        echo "Required managed-add-on preview not Registered: $feature. Obtain scoped approval first." >&2; exit 1;
    }
done
tenant="$(azc account show --query tenantId -o tsv)"
active_tenant="$(az account show --query tenantId -o tsv --only-show-errors)"
[[ "$active_tenant" == "$tenant" ]] || { echo "Sign in to the chosen subscription's tenant first." >&2; exit 1; }
# Graph identity reads have no --subscription option; tenant context was checked.
principal="$(az ad signed-in-user show --query id -o tsv --only-show-errors)"
[[ -n "$principal" ]] || { echo "Cannot identify the signed-in user for cluster RBAC." >&2; exit 1; }
if "$preflight_only"; then
    echo "Read-only prerequisites passed. No resources created; quota/SKU availability and Azure policy still need verification."
    exit 0
fi

mkdir -p "$OUT"
phase="resource group and ACR build"
azc group create --name "$RESOURCE_GROUP" --location "$LOCATION" --tags sample=aks-cpu-aware-lb -o none
created=true
azc acr create --resource-group "$RESOURCE_GROUP" --name "$REGISTRY" --sku Basic -o none
azc acr build --registry "$REGISTRY" --image cpu-backend:v1 "$ROOT" -o none
phase="AKS creation and ACR role assignment"
azc aks create --resource-group "$RESOURCE_GROUP" --name cpu-demo --location "$LOCATION" \
    --kubernetes-version "$KUBERNETES_VERSION" --tier free --nodepool-name system \
    --node-count 2 --node-vm-size "$SYSTEM_SKU" --node-osdisk-size 64 \
    --network-plugin azure --enable-oidc-issuer --enable-workload-identity \
    --enable-gateway-api --enable-application-load-balancer --attach-acr "$REGISTRY" \
    --enable-aad --enable-azure-rbac --disable-local-accounts --generate-ssh-keys -o none
cluster_id="$(azc aks show -g "$RESOURCE_GROUP" -n cpu-demo --query id -o tsv)"
phase="new cluster administrator role assignment"
azc role assignment create --assignee-object-id "$principal" --assignee-principal-type User \
    --role "Azure Kubernetes Service RBAC Cluster Admin" --scope "$cluster_id" -o none
phase="heterogeneous user pools"
for pool in small large; do
    sku="$SMALL_SKU"
    [[ "$pool" == large ]] && sku="$LARGE_SKU"
    azc aks nodepool add -g "$RESOURCE_GROUP" --cluster-name cpu-demo --name "$pool" \
        --node-vm-size "$sku" --node-count 1 --node-osdisk-size 64 --mode User \
        --labels cpu-aware-demo=true --node-taints cpu-aware-demo=true:NoSchedule -o none
done
azc aks get-credentials -g "$RESOURCE_GROUP" -n cpu-demo --file "$KUBECONFIG" -o none
kubelogin convert-kubeconfig --login azurecli --kubeconfig "$KUBECONFIG"
wait_resource() {
    local resource="$1"
    for ((i=0; i<100; i++)); do
        if kc get "$resource" -o name >/dev/null 2>&1; then return; fi
        sleep 3
    done
    echo "Managed add-on/RBAC never made $resource accessible; inspect kube-system and events." >&2
    return 1
}
phase="managed controller and Kubernetes resources"
wait_resource crd/backendloadbalancingpolicy.alb.networking.azure.io
kc wait --for=condition=Established crd/backendloadbalancingpolicy.alb.networking.azure.io --timeout=180s
crd="$(kc get crd backendloadbalancingpolicy.alb.networking.azure.io -o json)"
jq -e '[.spec.versions[] | select(.name == "v1") |
        .schema.openAPIV3Schema.properties.spec.properties.loadBalancing.properties.strategy.enum[]] |
        index("load-aware") != null' <<<"$crd" >/dev/null || {
        echo "Installed ALB CRD lacks load-aware; controller >=1.10.21 required." >&2; exit 1;
    }
wait_resource gatewayclass/azure-alb-external
kc wait --for=condition=Accepted gatewayclass/azure-alb-external --timeout=180s
kc create namespace cpu-aware
DEMO_TOKEN="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
export DEMO_TOKEN
jq -n '{apiVersion:"v1",kind:"Secret",metadata:{name:"demo-auth",namespace:"cpu-aware"},
    type:"Opaque",stringData:{token:env.DEMO_TOKEN}}' | kc apply -f -
unset DEMO_TOKEN
image="$(azc acr show --name "$REGISTRY" --query loginServer -o tsv)/cpu-backend:v1"
backend="$(< "$ROOT/k8s/backend.yaml")"
backend="${backend/SAMPLE_IMAGE/$image}"
printf '%s\n' "$backend" | kc apply --dry-run=server --validate=strict -f -
printf '%s\n' "$backend" | kc apply -f -
kc rollout status daemonset/backend -n cpu-aware --timeout=300s
mc="$(azc aks show -g "$RESOURCE_GROUP" -n cpu-demo --query nodeResourceGroup -o tsv)"
subnet="$(azc network vnet list -g "$mc" -o json |
    jq -er '[.[].subnets[] | select(.name == "aks-appgateway")] |
        if length == 1 then .[0].id else error("Expected one managed aks-appgateway subnet") end')"
gateway="$(< "$ROOT/k8s/gateway.yaml")"
gateway="${gateway/ALB_SUBNET_ID/$subnet}"
printf '%s\n' "$gateway" | kc apply --dry-run=server --validate=strict -f -
printf '%s\n' "$gateway" | kc apply -f -
kc apply --dry-run=server --validate=strict -f "$ROOT/k8s/policy.yaml"
kc apply -f "$ROOT/k8s/policy.yaml"
kc wait --for=condition=Deployment applicationloadbalancer/demo -n cpu-aware --timeout=600s
kc wait --for=condition=Programmed gateway/demo -n cpu-aware --timeout=300s
kc get gateway,httproute,backendloadbalancingpolicy -n cpu-aware
echo "Deployment ready. Verify current-generation route/policy conditions before benchmarking."
