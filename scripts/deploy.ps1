# Requires PowerShell 7, Azure CLI, kubectl and a signed-in Azure account.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Subscription,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string]$ResourceGroup,
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{5,40}$')][string]$Registry,
    [Parameter(Mandatory)][string]$KubernetesVersion,
    [string]$Location = 'eastus',
    [string]$SmallSku = 'Standard_D2s_v5',
    [string]$LargeSku = 'Standard_D4s_v5',
    [string]$SystemSku = 'Standard_D4s_v5',
    [switch]$EnableEntra,
    [switch]$PreflightOnly,
    [switch]$ConfirmCosts
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'out'
function azc {
    & az @args --subscription $Subscription --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI command failed; no subsequent deployment steps executed.' }
}
function kc {
    $input | & kubectl --kubeconfig (Join-Path $out 'demo.kubeconfig') @args
    if ($LASTEXITCODE -ne 0) { throw 'kubectl command failed; inspect the resource status.' }
}
function Wait-Resource([string]$Resource) {
    for ($i=0; $i -lt 100; $i++) {
        & kubectl --kubeconfig (Join-Path $out 'demo.kubeconfig') get $Resource -o name 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep 3
    }
    throw "Managed add-on never published $Resource. Inspect kube-system controller pods and events."
}
if (-not $ConfirmCosts -and -not $PreflightOnly) { throw 'This creates billable NEW resources. Review costs and pass -ConfirmCosts, or use -PreflightOnly for read-only checks.' }
if ($SmallSku -eq $LargeSku) { throw 'Choose two different VM SKUs.' }
if ([version]$KubernetesVersion -lt [version]'1.32.0') { throw 'Use a currently supported AKS version >=1.32.' }
if ((azc group exists --name $ResourceGroup -o tsv).Trim() -ne 'false') {
    throw 'Resource group already exists. This script only creates a new disposable environment.'
}
$subscriptionId = (azc account show --query id -o tsv).Trim()
$scope = "https://management.azure.com/subscriptions/$subscriptionId"
$permissions = (azc rest --method get --url "$scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json) |
    ConvertFrom-Json -Depth 30
$action = 'Microsoft.Authorization/roleAssignments/write'
$canAssign = @($permissions.value | Where-Object {
    $entry = $_
    @($entry.actions | Where-Object { $action -like $_ }).Count -gt 0 -and
    @($entry.notActions | Where-Object { $action -like $_ }).Count -eq 0
}).Count -gt 0
if (-not $canAssign) {
    throw 'Preflight: no advertised roleAssignments/write permission at the parent subscription. Contributor alone cannot attach ACR or grant cluster RBAC. Activate appropriately scoped Role Based Access Control Administrator/User Access Administrator (or equivalent), then retry. No resources were created.'
}
Write-Host 'Role-assignment permission is advertised; Azure Policy, deny assignments, RBAC conditions and propagation can still reject deployment.'
foreach ($feature in @('ManagedGatewayAPIPreview', 'ApplicationLoadBalancerPreview')) {
    if ((azc feature show --namespace Microsoft.ContainerService --name $feature --query properties.state -o tsv).Trim() -ne 'Registered') {
        throw "Register $feature and wait for Registered before deploying; see README."
    }
}
$auth = @()
if ($EnableEntra) {
    if (-not (Get-Command kubelogin -ErrorAction SilentlyContinue)) { throw 'Install kubelogin before enabling Entra authentication.' }
    $tenant = (azc account show --query tenantId -o tsv).Trim()
    $activeTenant = (& az account show --query tenantId -o tsv --only-show-errors).Trim()
    if ($LASTEXITCODE -ne 0 -or $activeTenant -ne $tenant) { throw 'Sign in to the tenant owning the chosen subscription first.' }
    # Graph identity reads have no --subscription option; verify tenant context first.
    $principal = (& az ad signed-in-user show --query id -o tsv --only-show-errors).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $principal) { throw 'Cannot identify the signed-in user for the new cluster RBAC grant.' }
    $auth = @('--enable-aad','--enable-azure-rbac','--disable-local-accounts')
}
if ($PreflightOnly) {
    Write-Host 'Read-only prerequisite checks passed; no resources created. This does not prove policy, quota, SKU availability or future role-assignment success.'
    return
}
New-Item -ItemType Directory -Force $out | Out-Null
azc group create --name $ResourceGroup --location $Location --tags sample=aks-cpu-aware-lb -o none
try {
    azc acr create --resource-group $ResourceGroup --name $Registry --sku Basic -o none
    azc acr build --registry $Registry --image cpu-backend:v1 $root -o none
    azc aks create --resource-group $ResourceGroup --name cpu-demo --location $Location `
        --kubernetes-version $KubernetesVersion --tier free --nodepool-name system `
        --node-count 2 --node-vm-size $SystemSku --node-osdisk-size 64 `
        --network-plugin azure --enable-oidc-issuer --enable-workload-identity `
        --enable-gateway-api --enable-application-load-balancer --attach-acr $Registry `
        --generate-ssh-keys @auth -o none
    if ($EnableEntra) {
        $clusterId = (azc aks show -g $ResourceGroup -n cpu-demo --query id -o tsv).Trim()
        azc role assignment create --assignee-object-id $principal --assignee-principal-type User `
            --role 'Azure Kubernetes Service RBAC Cluster Admin' --scope $clusterId -o none
    }
    foreach ($pool in @(@{Name='small'; SKU=$SmallSku}, @{Name='large'; SKU=$LargeSku})) {
        azc aks nodepool add --resource-group $ResourceGroup --cluster-name cpu-demo `
            --name $pool.Name --node-vm-size $pool.SKU --node-count 1 --node-osdisk-size 64 `
            --mode User --labels cpu-aware-demo=true --node-taints cpu-aware-demo=true:NoSchedule -o none
    }
    azc aks get-credentials --resource-group $ResourceGroup --name cpu-demo `
        --file (Join-Path $out 'demo.kubeconfig') -o none
    if ($EnableEntra) {
        & kubelogin convert-kubeconfig --login azurecli --kubeconfig (Join-Path $out 'demo.kubeconfig')
        if ($LASTEXITCODE -ne 0) { throw 'kubelogin configuration failed.' }
    }
    Wait-Resource 'crd/backendloadbalancingpolicy.alb.networking.azure.io'
    kc wait --for=condition=Established crd/backendloadbalancingpolicy.alb.networking.azure.io --timeout=180s
    $crd = (kc get crd backendloadbalancingpolicy.alb.networking.azure.io -o json) | ConvertFrom-Json -Depth 100
    $v1 = $crd.spec.versions | Where-Object name -EQ 'v1'
    if ('load-aware' -notin $v1.schema.openAPIV3Schema.properties.spec.properties.loadBalancing.properties.strategy.enum) {
        throw 'Installed add-on CRD does not support load-aware. ALB Controller >=1.10.21 is required.'
    }
    Wait-Resource 'gatewayclass/azure-alb-external'
    kc wait --for=condition=Accepted gatewayclass/azure-alb-external --timeout=180s
    kc create namespace cpu-aware
    # Secret travels over stdin, never as a CLI argument, printed output or tracked file.
    $token = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    @{apiVersion='v1'; kind='Secret'; metadata=@{name='demo-auth'; namespace='cpu-aware'};
        type='Opaque'; stringData=@{token=$token}} | ConvertTo-Json -Depth 5 | kc apply -f -
    $token = $null
    $image = (azc acr show --name $Registry --query loginServer -o tsv).Trim() + '/cpu-backend:v1'
    $backend = (Get-Content (Join-Path $root 'k8s\backend.yaml') -Raw).Replace('SAMPLE_IMAGE', $image)
    $backend | kc apply --dry-run=server --validate=strict -f -
    $backend | kc apply -f -
    kc rollout status daemonset/backend -n cpu-aware --timeout=300s
    $mc = (azc aks show -g $ResourceGroup -n cpu-demo --query nodeResourceGroup -o tsv).Trim()
    $vnets = (azc network vnet list -g $mc -o json) | ConvertFrom-Json
    $subnets = @($vnets | ForEach-Object { $_.subnets } | Where-Object name -EQ 'aks-appgateway')
    if ($subnets.Count -ne 1) { throw 'Expected exactly one managed aks-appgateway subnet; inspect add-on provisioning.' }
    $gateway = (Get-Content (Join-Path $root 'k8s\gateway.yaml') -Raw).Replace('ALB_SUBNET_ID', $subnets[0].id)
    $gateway | kc apply --dry-run=server --validate=strict -f -
    $gateway | kc apply -f -
    kc apply --dry-run=server --validate=strict -f (Join-Path $root 'k8s\policy.yaml')
    kc apply -f (Join-Path $root 'k8s\policy.yaml')
    kc wait --for=condition=Deployment applicationloadbalancer/demo -n cpu-aware --timeout=600s
    kc wait --for=condition=Programmed gateway/demo -n cpu-aware --timeout=300s
    kc get gateway,httproute,backendloadbalancingpolicy -n cpu-aware
    Write-Host 'Deployment ready. Inspect all policy/route conditions before benchmarking; see README.'
} catch {
    Write-Warning "Deployment failed. Delete only the NEW group '$ResourceGroup' after inspecting: az group delete --name <new-group> --subscription <chosen-subscription> --yes"
    throw
}
