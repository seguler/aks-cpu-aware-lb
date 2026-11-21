# Benchmark without pretending CPU is a SKU weight

## Validation status

**Live AKS routing/benchmark validation is not complete.** Two authorized
disposable deployment attempts built/pushed the real container through ACR.
The first was denied by a policy requiring Microsoft Entra authentication.
The second enabled Entra/Azure RBAC but failed the `--attach-acr` role assignment:
`Could not create a role assignment for ACR. Are you an Owner on this subscription?`
The execution identity had Contributor, without advertised
`Microsoft.Authorization/roleAssignments/write`. All newly created resource
groups were deleted and verified; no benchmark measurements were collected.
The deployment script now checks that permission **before** billable creation,
documents its limits, and supports policy-compliant Entra authentication.

Local unit/HTTP-harness tests use synthetic fixtures and are **not evidence of
Azure gateway redistribution**. GitHub CI passed Go race tests, vet, Linux
container build, released-CRD/core manifest validation and a local Gitleaks scan.
Do not call this sample end-to-end proven until live routing and the A/B run
complete with the documented permissions. No account/resource identifiers or
raw Azure diagnostic output are published.

## A/B methodology

`scripts/benchmark.ps1` applies `round-robin` and `load-aware` to the **same Service**.
Do not split traffic between Services or change placement, replicas, request work,
concurrency, CPU limits or VM SKUs between phases. Verify policy acceptance at its
current generation. Keep autoscaling off.

Defaults: three trials with alternating order, 60 seconds warmup then 90 seconds
measurement per mode, 32 concurrent persistent-connection clients. The backend
performs 200,000 dependent SHA-256 iterations per authorized request. Fixed work
exposes CPU throughput differences without a client-supplied CPU knob.

This is a **closed-loop saturation test**, not a fixed-arrival-rate benchmark:
offered RPS follows response times. Compare throughput/latency as well as shares;
higher load-aware throughput can increase absolute CPU even when routing improves.
CPU means deduplicate NodeMetrics by timestamp per endpoint, then average distinct
actual samples in the phase. Nodes receiving no responses cannot contribute CPU
samples; inspect `kubectl top nodes` independently. Latency includes returned HTTP
errors but excludes requests cancelled at the planned phase boundary; successful
RPS uses actual elapsed time. Client/network saturation can mask capacity differences.

## Optional real CPU perturbation (operator-only)

Start one bounded CPU worker on the smaller node **before the full A/B run**, and
keep it through both modes and all trials. Use a second terminal:

```powershell
$env:KUBECONFIG = Join-Path $PWD 'out\demo.kubeconfig'
$node = kubectl get nodes -l agentpool=small -o jsonpath='{.items[0].metadata.name}'
$pod = kubectl get pods -n cpu-aware --field-selector "spec.nodeName=$node" -l app=cpu-backend -o jsonpath='{.items[0].metadata.name}'
# 1 real CPU worker, hard-stops after 20 minutes; never a public HTTP control.
kubectl exec -n cpu-aware $pod -- /backend -burn 1200 -workers 1
```

Run `scripts/benchmark.ps1` in the first terminal (defaults ~15 minutes).
This is **actual computation on the node**, not synthetic telemetry. It competes
with the backend and demonstrates the unrelated-workload caveat. Record worker
count alongside results. Do not compare phases after the worker expires.
Use only disposable nodes: CPU can reach 100%. Burn mode allows at most 1,800
seconds/eight workers and requires Kubernetes `pods/exec`, not the public token.

## What counts as evidence

Require two endpoints, multiple fresh CPU samples on each, `orcaEmittedRequests`
near the successful count after warmup, and zero `unexpectedOrcaHeaders` through
the gateway. That confirms emission/stripping, **not** weight consumption; policy
status plus measured A/B differences support a routing claim. Group request counts
by `sku` with more nodes. Compare all trials, not a cherry-picked phase.

Report shares, CPU means/sample counts, throughput, p50/p95, errors, VM SKUs,
placement, worker count, concurrency, intervals, region and controller/AKS version.
Review sanitized JSON summaries before committing; keep raw diagnostics,
kubeconfigs, addresses and identifiers out of Git. If shares stay equal or CPU
is stale, publish that honestly. Don't invent metrics, use concurrency as RPS or
claim exact percentages. Clock speed, SMT, noisy neighbors, throttling and unrelated
workloads all affect this sampled capacity signal.
