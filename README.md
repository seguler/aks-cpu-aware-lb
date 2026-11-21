# CPU-aware L7 routing in AKS

**Route to pods on different VM SKUs using actual host-node CPU**, rather than
round robin or static SKU weights. This runnable sample uses the **AKS managed
Application Gateway for Containers add-on**, Gateway API, and native **ORCA
load-aware routing**. No custom weight controller or monitoring stack.

**How it works:** AKS metrics-server measures node CPU -> each backend reports
`node CPU / node capacity` and its measured completed requests/second in an ORCA
response header -> the native gateway derives endpoint weights -> traffic can
redistribute across VM SKUs. [Architecture](docs/architecture.md).

One DaemonSet pod per demo node, two differently sized user pools, **one Service**.
L7 routing targets **pod IPs on those VMs**, not VMSS instances. CPU utilization
alone does not encode clock speed: request rate relative to utilization provides
an effective capacity signal. This is adaptive weighted routing, **not an exact
instantaneous least-CPU scheduler**, and no particular traffic split is guaranteed.

## Before you start

- A disposable Azure environment and permission to create AKS, ACR, networking
  and role assignments (Contributor plus Role Based Access Control Administrator
  at the deployment scope, or equivalent). Provider/preview registration needs
  subscription permissions. Cluster-admin installs the sample's read-only RBAC.
- PowerShell **7+**, current Azure CLI with `aks-preview` and `alb` extensions,
  `kubectl`; **Go 1.26+** for the benchmark. Docker is unnecessary: ACR builds
  the backend. Sign in with `az login`; never commit credentials.
- Supported region, available non-burstable Linux VM SKUs, quota for 14 vCPUs
  (allow upgrade headroom). Defaults: **East US**, two D4s_v5 system nodes,
  D2s_v5 + D4s_v5 user nodes. Change SKUs to examine the customer's hardware.
- A **currently supported stable AKS version >=1.32** in that region.
  Run `az aks get-versions --location eastus -o table` and choose the exact patch.
  Do not choose an unsupported version merely because it meets the minimum.
- Managed ALB/Gateway API add-ons are **preview**. Requires **ALB Controller
  >=1.10.21**, the release introducing load-aware routing. Managed versions are
  pinned by AKS version: published mapping is AKS <=1.35 -> 1.10.x;
  >=1.36 -> 1.11.x. Deployment checks the installed CRD for `load-aware` and
  performs strict server-side dry runs.

**Costs:** four VMs + disks, AKS outbound networking, ACR Basic, and Application
Gateway for Containers (resource, association, frontend and capacity).
No existing clusters are changed. A small two-hour East US demo is estimated at
**$3–5** with build/network allowance, not a guaranteed cap; check current
[pricing](https://learn.microsoft.com/azure/application-gateway/for-containers/understanding-pricing).
Resources bill until deleted. Use a dedicated group, set a timer, and clean up
even when deployment or benchmarking fails.

## Deploy (PowerShell 7)

Clone this repository and enter it. Choose your subscription locally; never commit
its ID/name, generated manifests, tokens or kubeconfig.

```powershell
$sub = '<your authorized subscription>'
$rg = 'cpu-lb-demo-' + (Get-Date -Format 'MMddHHmmss')
$acr = 'cpulbdemo' + (Get-Random -Minimum 100000 -Maximum 999999)
$version = '<exact supported AKS patch from get-versions>'
az account set --subscription $sub
az extension add --name aks-preview --upgrade
az extension add --name alb --upgrade
foreach ($provider in @('Microsoft.ContainerService','Microsoft.Network','Microsoft.NetworkFunction','Microsoft.ServiceNetworking','Microsoft.Compute','Microsoft.ContainerRegistry')) {
    az provider register --namespace $provider --wait
}
foreach ($feature in @('ManagedGatewayAPIPreview','ApplicationLoadBalancerPreview')) {
    az feature register --namespace Microsoft.ContainerService --name $feature
}
# Wait for BOTH features to reach Registered before continuing.
az feature show --namespace Microsoft.ContainerService --name ManagedGatewayAPIPreview --query properties.state -o tsv
az feature show --namespace Microsoft.ContainerService --name ApplicationLoadBalancerPreview --query properties.state -o tsv
az provider register --namespace Microsoft.ContainerService --wait

.\scripts\deploy.ps1 -Subscription $sub -ResourceGroup $rg -Registry $acr `
    -KubernetesVersion $version -ConfirmCosts
```

Allow 15–30 minutes. The script builds/pushes the container, creates a new cluster
with **Azure CNI and AKS-managed VNet**, enables OIDC/workload identity and managed
Gateway API/ALB add-ons, adds two labeled/tainted user pools, and installs the
backend + gateway + policy. It refuses to reuse an existing group.
Networking is deliberately simple: no BYO VNet, peering, firewall or overlay.
The add-on creates a delegated `aks-appgateway` subnet and its managed
identity/role assignments in the node resource group. Do not customize that
identity or its `kube-system` namespace.
Override `-Location`, `-SystemSku`, `-SmallSku` and `-LargeSku` for your regional
availability/quota; use non-burstable SKUs and keep the two backend SKUs different.
The system pool uses two nodes with at least four vCPUs each, per
[AKS system-pool requirements](https://learn.microsoft.com/azure/aks/use-system-pools).

Prefer no AKS add-on previews? Microsoft's
[Helm-installed ALB Controller](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-helm)
supports the same native load-aware ORCA feature without the two preview opt-ins.
It requires manually installing the controller and configuring its identity,
roles and delegated subnet; the Azure resource providers are still required.
This repo's deployment script intentionally uses the simpler managed-add-on path.

Configuration is three small files: [backend](k8s/backend.yaml),
[gateway and route](k8s/gateway.yaml), [native policy](k8s/policy.yaml).
The script substitutes placeholders **in memory**. The actual released CRD requires
`apiVersion` and nested `targetRefs[].targetRef` (some Learn examples incorrectly
show `version` and flattened target references).

## Verify, then benchmark

```powershell
$env:KUBECONFIG = Join-Path $PWD 'out\demo.kubeconfig'
kubectl get nodes -L node.kubernetes.io/instance-type,cpu-aware-demo
kubectl top nodes
kubectl get pods -n cpu-aware -o wide
kubectl get endpointslices -n cpu-aware -l kubernetes.io/service-name=backend
kubectl get gateway,httproute,backendloadbalancingpolicy -n cpu-aware -o yaml
.\scripts\benchmark.ps1
```

Require Gateway `Programmed=True`, HTTPRoute `Accepted=True`/`ResolvedRefs=True`,
and policy target `Accepted=True`/`ResolvedRefs=True` at the current generation.
Expect two ready backend endpoints, one per user node. `kubectl top nodes` is a
diagnostic; the backend reads NodeMetrics directly.

Benchmarking switches the **same native policy** between round robin and load-aware,
alternates order across three repetitions, discards 60 seconds warmup per phase,
and measures 90 seconds at 32 concurrent closed-loop clients. It restores
load-aware in `finally`. JSON reports per-node/SKU shares, distinct **real** node
CPU samples, throughput, p50/p95 latency, errors and ORCA emission. Anonymous
summaries go under ignored `results/`; no gateway addresses, tokens, resource IDs
or raw node names. Defaults run about 15 minutes.

[Benchmark interpretation, controlled CPU perturbation, and validation status](docs/benchmark.md).
Without sustained traffic or a capacity/load difference, near-equal shares are
valid. Claim redistribution only if measurements actually show it.

## Telemetry and safety

GET-only Kubernetes RBAC reads **nodes and NodeMetrics**. No privileged pod, host
mount or container-local `/proc/stat`. Whole-node usage (cores averaged over the
metrics-server interval) is divided by **node CPU capacity**, not allocatable
or pod requests. SKU comes from `node.kubernetes.io/instance-type`.
CPU includes unrelated workloads and system daemons; it is a sampled kubelet/node
signal, not Azure Monitor's VM metric.

Metrics poll every 10 seconds. Completed request/error rates use an actual elapsed
rolling 30-second interval, excluding probes/unauthorized traffic. During warmup,
with zero/out-of-range/missing CPU, failed API reads, or metrics over 60 seconds
old, the backend **omits ORCA** and exposes the reason in JSON/logs.
The gateway may retain last valid weights until the configured **30-second
expiration**, then uses native equal-weight fallback; recovered metrics need a
**10-second blackout** before reuse. CPU and request-rate windows differ; this
sample does not claim perfect synchronization. The gateway **strips ORCA** from
client responses, so JSON includes timestamp, CPU, rates and `orcaEmitted`.

Only fixed-cost `/work` is routed publicly. It requires a random bearer token
created in a Kubernetes Secret, never printed or passed on the command line.
Concurrency is bounded at 32 per backend; overload returns 503. No public CPU-load
control. **HTTP is demo-only**: bearer authentication is not confidential over
cleartext. Use short disposable tests from a trusted network; add HTTPS, network
restrictions/WAF and proper identity before exposing real workloads.
No backend CPU limit is set to reveal VM capacity; don't copy that setting blindly
into a shared production cluster.

## Troubleshooting and cleanup

`kubectl logs -n cpu-aware -l app=cpu-backend` exposes telemetry failures.
Check ALB controller and metrics-server with `kubectl get pods -n kube-system`.
403 means missing RBAC; stale metrics mean unhealthy metrics-server/node sampling.
Rejected policy/version means use a supported managed add-on, **not** least-request
or static weights. For an unprogrammed gateway inspect conditions, events, subnet
delegation and identity roles. Health probes inherit `/healthz` from pod readiness.

Delete **only your newly created group**; AKS deletes its managed node group too.
Wait and verify both groups are gone. Do not target shared groups.

```powershell
$mc = az aks show --subscription $sub -g $rg -n cpu-demo --query nodeResourceGroup -o tsv
az group delete --subscription $sub --name $rg --yes
az group exists --subscription $sub --name $rg
az group exists --subscription $sub --name $mc
Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
Remove-Item .\out\demo.kubeconfig -ErrorAction SilentlyContinue
```

## Local checks and sources

`go test ./...` and `go vet ./...` cover CPU units/denominator, invalid/stale
telemetry, elapsed rolling rates, errors, auth, token rotation and benchmark
aggregation/anonymization. CI builds the Linux container and runs Gitleaks.
No Azure credentials are needed. [Schema validator](scripts/validate-manifests.cjs)
checks Microsoft released CRDs; cluster dry-run/status checks remain mandatory.
Run `.\scripts\check-manifests.ps1` with Node.js/npm and Go installed for the
repeatable local schema check (downloads a digest-verified CRD layer from the
1.10.40 Microsoft installer image and local validators). It checks field names,
required fields and types, but does not evaluate Kubernetes CEL/controller rules.

- [Native load-aware / ORCA](https://learn.microsoft.com/azure/application-gateway/for-containers/load-balancing-strategies)
- [Add-on prerequisites, identity and subnet](https://learn.microsoft.com/azure/application-gateway/for-containers/quickstart-deploy-application-gateway-for-containers-alb-controller-addon)
- [Release support/version mapping](https://learn.microsoft.com/azure/application-gateway/for-containers/alb-controller-release-notes)
- [Supported regions](https://learn.microsoft.com/azure/application-gateway/for-containers/overview#supported-regions)
- [Kubernetes API specification](https://learn.microsoft.com/azure/application-gateway/for-containers/api-specification-kubernetes)
