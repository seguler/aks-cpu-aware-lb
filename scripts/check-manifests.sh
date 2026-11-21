#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
for tool in curl sha256sum tar npm node go; do
    command -v "$tool" >/dev/null || { echo "Missing required Linux validator tool: $tool" >&2; exit 2; }
done
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/crds" "$work/schema-tools"
digest=e0fae3291c3e7d758aa1edd5ab6e0cde0be9c504491d7875bb6c41589e3ce48f
curl --fail --silent --show-error --location \
    "https://mcr.microsoft.com/v2/application-lb/images/alb-controller-crds/blobs/sha256:$digest" -o "$work/crds.tgz"
printf '%s  %s\n' "$digest" "$work/crds.tgz" | sha256sum --check --status
tar -xzf "$work/crds.tgz" -C "$work/crds"
npm install --prefix "$work/schema-tools" --no-audit --no-fund yaml@2.8.2 ajv@8.17.1
SCHEMA_TOOLS="$work/schema-tools/package.json" node scripts/validate-manifests.cjs "$work/crds/alb-controller-crds"
go install github.com/yannh/kubeconform/cmd/kubeconform@v0.7.0
"$(go env GOPATH)/bin/kubeconform" -strict -summary \
    -skip ApplicationLoadBalancer,Gateway,HTTPRoute,BackendLoadBalancingPolicy k8s
