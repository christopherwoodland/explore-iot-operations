[CmdletBinding()]
param(
    [string] $TaskName = 'Microsoft Band IoT Gateway',
    [int] $RestartDelayMinutes = 1
)

$ErrorActionPreference = 'Stop'

$sampleRoot = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $sampleRoot 'scripts\Invoke-BandGateway.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`" -Continuous"

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument $arguments `
    -WorkingDirectory $sampleRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RestartCount 10 `
    -RestartInterval (New-TimeSpan -Minutes $RestartDelayMinutes)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description 'Runs the Microsoft Band Bluetooth to Azure IoT Operations gateway.' `
    -Force | Out-Null

Write-Host "Scheduled task registered: $TaskName"
Write-Host 'Start it with: Start-ScheduledTask -TaskName "' + $TaskName + '"'
