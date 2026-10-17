[CmdletBinding()]
param(
    [string] $Namespace = 'azure-iot-operations',
    [int] $LocalPort = 18883,
    [switch] $ReadOnly,
    [switch] $Continuous,
    [double] $IntervalSeconds = 5,
    [int] $MaxConsecutiveFailures = 0
)

$ErrorActionPreference = 'Stop'

$sampleRoot = Split-Path -Parent $PSScriptRoot
$existingListener = Get-NetTCPConnection `
    -LocalAddress 127.0.0.1 `
    -LocalPort $LocalPort `
    -State Listen `
    -ErrorAction SilentlyContinue
if ($existingListener) {
    throw "Local port $LocalPort is already in use."
}

$portForward = Start-Process `
    -FilePath 'kubectl' `
    -ArgumentList @(
        'port-forward',
        '--namespace', $Namespace,
        'service/aio-broker',
        "${LocalPort}:18883",
        '--address', '127.0.0.1'
    ) `
    -PassThru `
    -WindowStyle Hidden

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        if ($portForward.HasExited) {
            throw "kubectl port-forward exited with code $($portForward.ExitCode)."
        }
        $listener = Get-NetTCPConnection `
            -LocalAddress 127.0.0.1 `
            -LocalPort $LocalPort `
            -State Listen `
            -ErrorAction SilentlyContinue
    } while (-not $listener -and [DateTime]::UtcNow -lt $deadline)

    if (-not $listener) {
        throw "Timed out waiting for the MQTT tunnel on port $LocalPort."
    }

    Push-Location $sampleRoot
    try {
        $env:PYTHONPATH = Join-Path $sampleRoot 'src'
        if ($ReadOnly) {
            python -m band_gateway.main --read-only
        }
        elseif ($Continuous) {
            python -m band_gateway.main `
                --continuous `
                --interval-seconds $IntervalSeconds `
                --max-consecutive-failures $MaxConsecutiveFailures
        }
        else {
            python -m band_gateway.main
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Band gateway exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if (-not $portForward.HasExited) {
        Stop-Process -Id $portForward.Id
    }
}
