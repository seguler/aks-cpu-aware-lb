[CmdletBinding()]
param(
    [string]$Kubeconfig = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out\demo.kubeconfig'),
    [ValidateRange(1,5)][int]$Repetitions = 3,
    [ValidateRange(10,300)][int]$Seconds = 90,
    [ValidateRange(1,128)][int]$Concurrency = 32
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function kc {
    $input | & kubectl --kubeconfig $Kubeconfig @args
    if ($LASTEXITCODE -ne 0) { throw 'kubectl failed; benchmark stopped.' }
}
function Wait-Policy {
    for ($i=0; $i -lt 60; $i++) {
        $p = (kc get backendloadbalancingpolicy demo -n cpu-aware -o json) | ConvertFrom-Json -Depth 50
        $conditions = @($p.status.targets | ForEach-Object { $_.conditions })
        $ready = @($conditions | Where-Object { $_.status -eq 'True' -and $_.observedGeneration -eq $p.metadata.generation })
        if ('Accepted' -in $ready.type -and 'ResolvedRefs' -in $ready.type) { return }
        Start-Sleep 2
    }
    throw 'Policy did not become Accepted at its current generation.'
}
$gw = (kc get gateway demo -n cpu-aware -o json) | ConvertFrom-Json -Depth 50
if (-not $gw.status.addresses[0].value) { throw 'Gateway has no address.' }
$url = 'http://' + $gw.status.addresses[0].value + '/work'
$secret = (kc get secret demo-auth -n cpu-aware -o json) | ConvertFrom-Json
$oldToken = $env:DEMO_TOKEN
$env:DEMO_TOKEN = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.token))
$secret = $null
$results = Join-Path $root 'results'
New-Item -ItemType Directory -Force $results | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root 'out') | Out-Null
Push-Location $root
try {
    & go build -o (Join-Path $root 'out\bench.exe') ./cmd/bench
    if ($LASTEXITCODE -ne 0) { throw 'Benchmark build failed.' }
    for ($trial=1; $trial -le $Repetitions; $trial++) {
        # Alternate order to reduce systematic time/order bias.
        $modes = if ($trial % 2 -eq 1) { @('round-robin','load-aware') } else { @('load-aware','round-robin') }
        foreach ($mode in $modes) {
            $policy = Get-Content (Join-Path $root 'k8s\policy.yaml') -Raw
            if ($mode -eq 'round-robin') {
                $policy = $policy.Replace('strategy: load-aware', 'strategy: round-robin')
                $policy = $policy.Substring(0, $policy.IndexOf('    loadAware:'))
            }
            $policy | kc apply -f -
            Wait-Policy
            $file = Join-Path $results "$mode-$trial.json"
            & (Join-Path $root 'out\bench.exe') -url $url -mode $mode -duration "${Seconds}s" -warmup 60s -concurrency $Concurrency |
                Set-Content -Encoding utf8 $file
            if ($LASTEXITCODE -ne 0) { throw 'Benchmark failed; partial results are not evidence of successful routing.' }
            $summary = Get-Content $file -Raw | ConvertFrom-Json
            if ($summary.errors -gt 0) { Write-Warning 'Requests failed in this phase; inspect the error counts before making a routing/performance claim.' }
            Get-Content $file
        }
    }
} finally {
    try { kc apply -f (Join-Path $root 'k8s\policy.yaml') } finally {
        $env:DEMO_TOKEN = $oldToken
        Pop-Location
    }
}
