# Offline validation after downloading the pinned public Microsoft CRD artifact.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'out'
$crds = Join-Path $out 'crds'
$tools = Join-Path $out 'schema-tools'
$layer = Join-Path $out 'crds.tgz'
Push-Location $root
try {
    New-Item -ItemType Directory -Force $crds, $tools | Out-Null
    $digest = 'e0fae3291c3e7d758aa1edd5ab6e0cde0be9c504491d7875bb6c41589e3ce48f'
    $blob = "https://mcr.microsoft.com/v2/application-lb/images/alb-controller-crds/blobs/sha256:$digest"
    Invoke-WebRequest $blob -OutFile $layer
    if ((Get-FileHash $layer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $digest) {
        throw 'Microsoft CRD layer digest mismatch.'
    }
    & tar -xzf $layer -C $crds
    if ($LASTEXITCODE -ne 0) { throw 'CRD extraction failed.' }
    & npm install --prefix $tools --no-audit --no-fund yaml@2.8.2 ajv@8.17.1
    if ($LASTEXITCODE -ne 0) { throw 'Schema validator dependency installation failed.' }
    & node (Join-Path $PSScriptRoot 'validate-manifests.cjs') (Join-Path $crds 'alb-controller-crds')
    if ($LASTEXITCODE -ne 0) { throw 'Custom-resource schema validation failed.' }
    & go install github.com/yannh/kubeconform/cmd/kubeconform@v0.7.0
    if ($LASTEXITCODE -ne 0) { throw 'Core schema validator installation failed.' }
    $binary = if ($IsWindows) { 'kubeconform.exe' } else { 'kubeconform' }
    & (Join-Path (Join-Path (go env GOPATH) 'bin') $binary) -strict -summary `
        -skip ApplicationLoadBalancer,Gateway,HTTPRoute,BackendLoadBalancingPolicy k8s
    if ($LASTEXITCODE -ne 0) { throw 'Core Kubernetes schema validation failed.' }
} finally { Pop-Location }
