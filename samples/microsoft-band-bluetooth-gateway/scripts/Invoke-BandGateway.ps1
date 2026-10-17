[CmdletBinding()]
param(
    [string] $Namespace = 'azure-iot-operations',
    [int] $LocalPort = 18883,
    [switch] $ReadOnly,
    [switch] $Continuous,
    [ValidateRange(0.1, 3600)]
    [double] $IntervalSeconds = 5,
    [ValidateRange(0, 1000000)]
    [int] $MaxConsecutiveFailures = 0,
    [ValidateRange(0, 1000000)]
    [int] $MaxMessages = 0
)

$ErrorActionPreference = 'Stop'
$sampleRoot = Split-Path -Parent $PSScriptRoot
$previousPythonPath = $env:PYTHONPATH
$previousPort = $env:MQTT_PORT
$portForward = $null
$gateway = $null
Push-Location $sampleRoot
try {
    $env:PYTHONPATH = Join-Path $sampleRoot 'src'
    if ($ReadOnly) {
        python -m band_gateway.main --read-only
        if ($LASTEXITCODE -ne 0) {
            throw "Band local read exited with code $LASTEXITCODE."
        }
        return
    }
    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 `
        -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        throw "Local port $LocalPort is already in use."
    }
    $env:MQTT_PORT = "$LocalPort"
    $logs = Join-Path $sampleRoot 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $arguments = @('-u', '-m', 'band_gateway.main')
    if ($Continuous) {
        $arguments += @(
            '--continuous', '--interval-seconds', "$IntervalSeconds",
            '--max-consecutive-failures', "$MaxConsecutiveFailures",
            '--max-messages', "$MaxMessages"
        )
    }
    $gateway = Start-Process -FilePath (Get-Command python -ErrorAction Stop).Source `
        -ArgumentList $arguments -PassThru -NoNewWindow
    $retryAt = [DateTime]::MinValue
    while (-not $gateway.HasExited) {
        if (($null -eq $portForward -or $portForward.HasExited) -and
            [DateTime]::UtcNow -ge $retryAt) {
            if ($null -ne $portForward) {
                Write-Warning "MQTT tunnel exited ($($portForward.ExitCode)); see logs\tunnel-error.log. Retrying."
                $portForward.Dispose()
            }
            $portForward = Start-Process -FilePath 'kubectl' -ArgumentList @(
                'port-forward', '--namespace', $Namespace, 'service/aio-broker',
                "${LocalPort}:18883", '--address', '127.0.0.1'
            ) -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $logs 'tunnel-output.log') `
                -RedirectStandardError (Join-Path $logs 'tunnel-error.log')
            $retryAt = [DateTime]::UtcNow.AddSeconds(5)
        }
        Start-Sleep -Milliseconds 500
        $gateway.Refresh()
    }
    if ($gateway.ExitCode -ne 0) {
        throw "Band gateway exited with code $($gateway.ExitCode). See logs\band-gateway.log."
    }
}
finally {
    foreach ($process in @($gateway, $portForward)) {
        if ($null -ne $process) {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id
            }
            $process.Dispose()
        }
    }
    $env:PYTHONPATH = $previousPythonPath
    $env:MQTT_PORT = $previousPort
    Pop-Location
}
