# One native L7 gateway, heterogeneous node endpoints

```mermaid
flowchart LR
  client[Authenticated demo client] --> gateway[Application Gateway for Containers]
  controller[AKS managed ALB add-on] -. Gateway API and policy .-> gateway
  gateway --> service[One Service endpoint set]
  service --> small[Backend pod on smaller VM]
  service --> large[Backend pod on larger VM]
  metrics[AKS metrics-server NodeMetrics] -. whole-node CPU .-> small
  metrics -. whole-node CPU .-> large
  small -. ORCA CPU plus measured RPS .-> gateway
  large -. ORCA CPU plus measured RPS .-> gateway
```

The Service identifies eligible pod endpoints; the gateway connects directly to those
endpoints. It does **not** send requests through a kube-proxy round-robin hop, or
route directly to VMSS instances. A DaemonSet places exactly one backend per selected
node so each endpoint's CPU report belongs to its host VM.
