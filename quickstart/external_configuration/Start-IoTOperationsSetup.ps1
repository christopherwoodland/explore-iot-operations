#Requires -Version 7.0
<#
.SYNOPSIS
    Set up a single Windows AKS Edge Essentials machine and Azure IoT Operations.
.DESCRIPTION
    Run in an elevated PowerShell 7 terminal. Prompts for missing settings, saves
    aio_config.json, and runs each stage in a separate, synchronous process.
    Existing AKS Edge deployments and Azure resources are reused. After a required
    Windows restart, rerun the same command. No automatic restart is performed.
.PARAMETER NonInteractive
    Use parameters and saved settings only; fail rather than prompt.
.PARAMETER CheckOnly
    Validate saved configuration and prerequisites without changing Azure or Windows.
.EXAMPLE
    .\Start-IoTOperationsSetup.ps1
.EXAMPLE
    .\Start-IoTOperationsSetup.ps1 -SubscriptionId <guid> -ResourceGroup iot `
        -ClusterName my-edge -Location eastus -AcceptEula -NonInteractive
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are consumed by functions in script scope.')]
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot) 'config\aio_config.json'),
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ResourceGroup,
    [string]$Location,
    [string]$ClusterName,
    [string]$KeyVaultName,
    [string]$StorageAccountName,
    [string]$ContainerRegistry,
    [string]$InstallerSource,
    [ValidateRange(4, 64)][int]$CpuCount = 4,
    [ValidateRange(10240, 1048576)][int]$MemoryInMB = 10240,
    [ValidateRange(40, 2048)][int]$DataSizeInGB = 40,
    [ValidateSet('none', 'edgemqttsim', 'demohistorian')][string]$ModuleName,
    [switch]$AcceptEula,
    [switch]$AcceptOptionalTelemetry,
    [switch]$NonInteractive,
    [switch]$CheckOnly,
    [ValidateRange(1, 240)][int]$StepTimeoutMinutes = 90,
    [ValidateRange(1, 60)][int]$ReadinessTimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'

function Invoke-SetupCommand {
    param([string]$Command, [string[]]$Arguments, [switch]$Capture)
    $PSNativeCommandUseErrorActionPreference = $false
    if ($Capture) {
        $result = & $Command @Arguments
    } else {
        & $Command @Arguments | Out-Host
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed (exit $LASTEXITCODE)."
    }
    if ($Capture) { return $result }
}

function Wait-SetupCondition {
    param(
        [string]$Description,
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 900,
        [int]$IntervalSeconds = 10
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (& $Condition) {
            Write-Host "[READY] $Description" -ForegroundColor Green
            return
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Write-Host "[WAIT] $Description ($([int]$watch.Elapsed.TotalSeconds)s elapsed)"
        Start-Sleep -Seconds ([Math]::Min($IntervalSeconds, [Math]::Max(1,
            [int]($TimeoutSeconds - $watch.Elapsed.TotalSeconds))))
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw "Timed out waiting for $Description after $TimeoutSeconds seconds."
}

function Read-SetupSetting {
    param([string]$Label, [string]$Value, [string]$DefaultValue, [switch]$Required)
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value.Trim() }
    if ($NonInteractive -or $CheckOnly) {
        if ($Required -and [string]::IsNullOrWhiteSpace($DefaultValue)) {
            throw "$Label is required. Supply a parameter or save it in $ConfigPath."
        }
        return $DefaultValue
    }
    do {
        $answer = Read-Host "$Label$(if ($DefaultValue) { " [$DefaultValue]" })"
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $DefaultValue }
    } while ($Required -and [string]::IsNullOrWhiteSpace($answer))
    return "$answer".Trim()
}

function Test-SetupRoleAssignments {
    param([object[]]$Assignments, [object[]]$RequiredRoles)
    $ready = $true
    foreach ($required in $RequiredRoles) {
        $match = $Assignments | Where-Object {
            $_.principalId -eq $required.PrincipalId -and $_.roleDefinitionName -eq $required.Role
        }
        if (-not $match) {
            Write-Host "Waiting for role '$($required.Role)' for $($required.PrincipalId)."
            $ready = $false
        }
    }
    return $ready
}

function Invoke-SetupScript {
    param(
        [string]$Name,
        [string]$Executable,
        [string]$Path,
        [string[]]$Arguments,
        [string]$LogDirectory,
        [int]$TimeoutSeconds = 5400
    )
    Write-Host "`n[START] $Name" -ForegroundColor Cyan
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = Split-Path $Path
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $Path) + $Arguments)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    try {
        while (-not $process.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                $process.Kill($true)
                $process.WaitForExit()
                break
            }
            if ([int]$watch.Elapsed.TotalSeconds % 30 -eq 0) {
                Write-Host "[RUNNING] $Name ($([int]$watch.Elapsed.TotalSeconds)s elapsed)"
            }
        }
        $outputText = $outputTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        $log = Join-Path $LogDirectory "$Name.log"
        [IO.File]::WriteAllText($log, "$outputText`n$errorText")
        Write-Host $outputText
        if ($errorText) { Write-Host $errorText -ForegroundColor Yellow }
        if ($timedOut) { throw "$Name timed out after $TimeoutSeconds seconds. See $log." }
        if ($process.ExitCode -eq 3010) {
            throw "$Name requires a Windows restart. Restart, then rerun this command. See $log."
        }
        if ($process.ExitCode -ne 0) {
            throw "$Name failed (exit $($process.ExitCode)). See $log. Fix the error, then rerun."
        }
        Write-Host "[DONE] $Name" -ForegroundColor Green
    } finally {
        if (-not $process.HasExited) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $process.Dispose()
    }
}

function Invoke-IoTOperationsSetup {
    if (-not $IsWindows -or -not [Environment]::Is64BitProcess) {
        throw 'This setup requires 64-bit PowerShell 7 on Windows.'
    }
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $CheckOnly -and -not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Open PowerShell 7 with Run as administrator, then rerun this command.'
    }
    foreach ($command in @('az', 'kubectl', 'pwsh')) {
        Get-Command $command -ErrorAction Stop | Out-Null
    }
    $configFile = [IO.Path]::GetFullPath($ConfigPath)
    $config = if (Test-Path -LiteralPath $configFile) {
        Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -AsHashtable
    } else { @{} }
    if (-not $config.azure) { $config.azure = @{} }
    if (-not $config.aks_edge) { $config.aks_edge = @{} }
    $azure = $config.azure
    $edge = $config.aks_edge
    $azure.subscription_id = Read-SetupSetting 'Subscription ID' $SubscriptionId $azure.subscription_id -Required
    $azure.tenant_id = Read-SetupSetting 'Tenant ID (blank uses current login)' $TenantId $azure.tenant_id
    $azure.resource_group = Read-SetupSetting 'Resource group' $ResourceGroup $azure.resource_group -Required
    $azure.cluster_name = Read-SetupSetting 'Cluster name' $ClusterName $azure.cluster_name -Required
    $azure.location = Read-SetupSetting 'Azure region' $Location $(if ($azure.location) { $azure.location } else { 'eastus' }) -Required
    if ($azure.subscription_id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Subscription ID must be a GUID.'
    }
    if ($azure.tenant_id -and $azure.tenant_id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
        throw 'Tenant ID must be a GUID.'
    }
    if ($azure.cluster_name -notmatch '^[a-z][a-z0-9-]{0,29}$') {
        throw 'Use a lowercase cluster name starting with a letter, up to 30 letters, digits or hyphens.'
    }
    $suffix = $azure.subscription_id.Replace('-', '').Substring(0, 6)
    $stem = $azure.cluster_name.Replace('-', '')
    $azure.key_vault_name = Read-SetupSetting 'Key Vault name (globally unique)' $KeyVaultName $(
        if ($azure.key_vault_name) { $azure.key_vault_name } else { "kv-$($stem.Substring(0, [Math]::Min(12, $stem.Length)))-$suffix" })
    $azure.storage_account_name = Read-SetupSetting 'Storage account name (globally unique)' $StorageAccountName $(
        if ($azure.storage_account_name) { $azure.storage_account_name } else { "$($stem.Substring(0, [Math]::Min(11, $stem.Length)))store$suffix" })
    $registry = Read-SetupSetting 'Container registry short name or azurecr.io hostname' $ContainerRegistry $(
        if ($azure.container_registry) { $azure.container_registry } else { "$($stem.Substring(0, [Math]::Min(20, $stem.Length)))acr$suffix" })
    $registry = $registry -replace '\.azurecr\.io$', ''
    if ($registry -notmatch '^[a-zA-Z0-9]{5,50}$') { throw 'Invalid Azure Container Registry name.' }
    if ($azure.storage_account_name -notmatch '^[a-z0-9]{3,24}$') { throw 'Invalid storage account name.' }
    if ($azure.key_vault_name -notmatch '^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$' -or
        $azure.key_vault_name.Contains('--')) { throw 'Invalid Key Vault name.' }
    $azure.container_registry = "$registry.azurecr.io"
    $edge.installer_source = Read-SetupSetting 'AKS Edge K3s MSI HTTPS URL or local path' $InstallerSource $(
        if ($edge.installer_source) { $edge.installer_source } else { 'https://aka.ms/aks-edge/k3s-msi' })
    $installerUri = $null
    if ([Uri]::TryCreate($edge.installer_source, [UriKind]::Absolute, [ref]$installerUri) -and
        -not $installerUri.IsFile) {
        if ($installerUri.Scheme -ne 'https') { throw 'Remote installers must use HTTPS.' }
    } else {
        $edge.installer_source = [IO.Path]::GetFullPath($edge.installer_source)
    }
    $sizing = @(
        @{ Parameter = 'CpuCount'; Key = 'cpu_count'; Label = 'Linux VM CPUs'; Minimum = 4; Maximum = 64 }
        @{ Parameter = 'MemoryInMB'; Key = 'memory_in_mb'; Label = 'Linux VM memory (MB)'; Minimum = 10240; Maximum = 1048576 }
        @{ Parameter = 'DataSizeInGB'; Key = 'data_size_in_gb'; Label = 'Linux VM data disk (GB)'; Minimum = 40; Maximum = 2048 }
    )
    foreach ($size in $sizing) {
        $parameterValue = Get-Variable -Name $size.Parameter -ValueOnly
        $value = if ($script:PSBoundParameters.ContainsKey($size.Parameter)) { "$parameterValue" } else { '' }
        $defaultValue = if ($edge.ContainsKey($size.Key)) { "$($edge[$size.Key])" } else { "$parameterValue" }
        $answer = Read-SetupSetting $size.Label $value $defaultValue -Required
        $number = 0
        if (-not [int]::TryParse($answer, [ref]$number) -or $number -lt $size.Minimum -or $number -gt $size.Maximum) {
            throw "$($size.Label) must be between $($size.Minimum) and $($size.Maximum)."
        }
        $edge[$size.Key] = $number
    }
    if ($AcceptEula) { $edge.accept_eula = $true }
    if ($AcceptOptionalTelemetry) { $edge.accept_optional_telemetry = $true }
    if (-not $edge.ContainsKey('accept_optional_telemetry')) {
        $telemetry = Read-SetupSetting 'Accept optional AKS Edge telemetry? (yes/no)' '' 'no'
        if ($telemetry -notin @('yes', 'no')) { throw 'Answer yes or no for optional telemetry.' }
        $edge.accept_optional_telemetry = $telemetry -eq 'yes'
    }
    $selectedModule = Read-SetupSetting 'Optional demo module: none, edgemqttsim, demohistorian' $ModuleName $(
        if ($edge.module_name) { $edge.module_name } else { 'edgemqttsim' })
    if ($selectedModule -notin @('none', 'edgemqttsim', 'demohistorian')) { throw 'Invalid module name.' }
    $edge.module_name = $selectedModule
    if ($CheckOnly) {
        Write-Host "Configuration valid: $($azure.resource_group) / $($azure.cluster_name), $($azure.location)."
        Write-Host 'No Azure resources, roles, Windows features or files were changed.'
        return
    }
    if (-not $edge.accept_eula) {
        $consent = Read-SetupSetting 'Accept AKS Edge license terms? https://learn.microsoft.com/azure/aks/hybrid/aks-edge-software-license-terms (yes/no)' '' 'no'
        if ($consent -ne 'yes') { throw 'License acceptance is required. Use -AcceptEula after reviewing the terms.' }
        $edge.accept_eula = $true
    }
    $summary = "$($azure.subscription_id), $($azure.resource_group), $($azure.cluster_name), $($azure.location)"
    Write-Host "Target: $summary`nDemo sizing; module: $selectedModule" -ForegroundColor Cyan
    Write-Host 'This installs Windows features/software and creates billable Azure resources and role assignments.'
    if (-not $NonInteractive -and (Read-Host 'Continue? (yes/no)') -ne 'yes') { throw 'Setup cancelled.' }
    $configDirectory = Split-Path $configFile
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configFile -Encoding utf8
    $runDirectory = Join-Path $configDirectory "setup-runs\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $env:AZURE_CORE_NO_COLOR = 'true'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $account = & az account show --output json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        $login = @('login')
        if ($azure.tenant_id) { $login += @('--tenant', $azure.tenant_id) }
        Invoke-SetupCommand az $login
    } elseif ($azure.tenant_id -and ($account | ConvertFrom-Json).tenantId -ne $azure.tenant_id) {
        Invoke-SetupCommand az @('login', '--tenant', $azure.tenant_id)
    }
    Invoke-SetupCommand az @('account', 'set', '--subscription', $azure.subscription_id)
    $account = Invoke-SetupCommand az @('account', 'show', '-o', 'json', '--only-show-errors') -Capture | ConvertFrom-Json
    $azure.tenant_id = $account.tenantId
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configFile -Encoding utf8
    $extensions = @(Invoke-SetupCommand az @('extension', 'list', '-o', 'json', '--only-show-errors') -Capture | ConvertFrom-Json)
    foreach ($extension in @('connectedk8s', 'azure-iot-ops', 'k8s-extension')) {
        if ($extension -notin $extensions.name) {
            Invoke-SetupCommand az @('extension', 'add', '--name', $extension, '--only-show-errors')
        }
    }
    $env:AZURE_SUBSCRIPTION_ID = $azure.subscription_id
    $env:AZURE_RESOURCE_GROUP = $azure.resource_group
    $env:AZURE_LOCATION = $azure.location
    $env:AKSEDGE_CLUSTER_NAME = $azure.cluster_name
    $env:AZURE_CONTAINER_REGISTRY = $azure.container_registry
    $scriptOptions = @{
        LogDirectory = $runDirectory
        TimeoutSeconds = $StepTimeoutMinutes * 60
    }
    Invoke-SetupScript @scriptOptions -Name '01-aks-edge' `
        -Executable "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Path (Join-Path $PSScriptRoot 'Initialize-AksEdgeForIoTOperations.ps1') `
        -Arguments @('-ConfigPath', $configFile, '-ReadinessTimeoutMinutes', "$ReadinessTimeoutMinutes")
    $oldKubeconfig = $env:KUBECONFIG
    try {
        $env:KUBECONFIG = Join-Path $configDirectory 'aksedge\config'
        $arcArguments = @('connectedk8s', 'show', '-g', $azure.resource_group,
            '-n', $azure.cluster_name, '--subscription', $azure.subscription_id, '-o', 'json', '--only-show-errors')
        Wait-SetupCondition 'Azure Arc Connected and agents Succeeded' -TimeoutSeconds ($ReadinessTimeoutMinutes * 60) -Condition {
            $arc = Invoke-SetupCommand az $arcArguments -Capture | ConvertFrom-Json
            if ($arc.arcAgentProfile.agentState -eq 'Failed') { throw ($arc.arcAgentProfile | ConvertTo-Json -Depth 10) }
            Write-Host "Arc status: '$($arc.connectivityStatus)'; agents: '$($arc.arcAgentProfile.agentState)'."
            $arc.connectivityStatus -eq 'Connected' -and $arc.arcAgentProfile.agentState -eq 'Succeeded'
        }
        $pwsh = (Get-Command pwsh).Source
        Invoke-SetupScript @scriptOptions -Name '02-permissions' -Executable $pwsh `
            -Path (Join-Path $PSScriptRoot 'grant_entra_id_roles.ps1') -Arguments @('-ConfigFile', $configFile)
        Invoke-SetupScript @scriptOptions -Name '03-infrastructure' -Executable $pwsh `
            -Path (Join-Path $PSScriptRoot 'External-Configurator.ps1') -Arguments @('-ConfigFile', $configFile, '-SkipIoTOps')
        Invoke-SetupScript @scriptOptions -Name '04-resource-permissions' -Executable $pwsh `
            -Path (Join-Path $PSScriptRoot 'grant_entra_id_roles.ps1') -Arguments @('-ConfigFile', $configFile)
        Invoke-SetupScript @scriptOptions -Name '05-iot-operations' -Executable $pwsh `
            -Path (Join-Path $PSScriptRoot 'External-Configurator.ps1') -Arguments @('-ConfigFile', $configFile, '-DemoMode')
        Invoke-SetupScript @scriptOptions -Name '06-final-permissions' -Executable $pwsh `
            -Path (Join-Path $PSScriptRoot 'grant_entra_id_roles.ps1') -Arguments @('-ConfigFile', $configFile)
        $arcPrincipal = Invoke-SetupCommand az @('connectedk8s', 'show', '-n', $azure.cluster_name,
            '-g', $azure.resource_group, '--query', 'identity.principalId', '-o', 'tsv', '--only-show-errors') -Capture
        $syncPrincipal = Invoke-SetupCommand az @('identity', 'show', '-n', "$($azure.cluster_name)-secretsync-mi",
            '-g', $azure.resource_group, '--query', 'principalId', '-o', 'tsv', '--only-show-errors') -Capture
        if (-not $arcPrincipal -or -not $syncPrincipal) { throw 'Cannot verify required managed identities.' }
        $groupScope = "/subscriptions/$($azure.subscription_id)/resourceGroups/$($azure.resource_group)"
        $roleChecks = @(
            @{
                Scope = "$groupScope/providers/Microsoft.KeyVault/vaults/$($azure.key_vault_name)"
                Roles = @(
                    @{ PrincipalId = $arcPrincipal; Role = 'Key Vault Secrets User' }
                    @{ PrincipalId = $syncPrincipal; Role = 'Key Vault Secrets User' }
                )
            }
            @{
                Scope = "$groupScope/providers/Microsoft.ContainerRegistry/registries/$registry"
                Roles = @(@{ PrincipalId = $arcPrincipal; Role = 'AcrPull' })
            }
        )
        foreach ($roleCheck in $roleChecks) {
            Wait-SetupCondition "required RBAC on $($roleCheck.Scope)" -TimeoutSeconds ($ReadinessTimeoutMinutes * 60) -Condition {
                $assignments = @(Invoke-SetupCommand az @('role', 'assignment', 'list', '--scope', $roleCheck.Scope,
                    '--include-inherited', '-o', 'json', '--only-show-errors') -Capture | ConvertFrom-Json)
                Test-SetupRoleAssignments $assignments $roleCheck.Roles
            }
        }
        Wait-SetupCondition 'IoT Operations provisioning' -TimeoutSeconds ($ReadinessTimeoutMinutes * 60) -Condition {
            $instance = Invoke-SetupCommand az @('iot', 'ops', 'show', '-n', "$($azure.cluster_name)-aio",
                '-g', $azure.resource_group, '-o', 'json', '--only-show-errors') -Capture | ConvertFrom-Json
            if ($instance.properties.provisioningState -in @('Failed', 'Canceled')) { throw 'IoT Operations provisioning failed.' }
            $instance.properties.provisioningState -eq 'Succeeded'
        }
        Invoke-SetupCommand kubectl @('wait', 'pods', '--all', '-n', 'azure-iot-operations',
            '--field-selector=status.phase!=Succeeded', '--for=condition=Ready', "--timeout=$($ReadinessTimeoutMinutes)m")
        if ($selectedModule -ne 'none') {
            $objectId = Invoke-SetupCommand az @('ad', 'signed-in-user', 'show', '--query', 'id', '-o', 'tsv', '--only-show-errors') -Capture
            $binding = Invoke-SetupCommand kubectl @('create', 'clusterrolebinding', "admin-$objectId",
                '--clusterrole=cluster-admin', "--user=$objectId", '--dry-run=client', '-o', 'yaml') -Capture
            $binding | & kubectl apply -f -
            if ($LASTEXITCODE -ne 0) { throw 'Failed to bootstrap Kubernetes access for the Arc proxy.' }
            $directConfig = $env:KUBECONFIG
            $proxyConfig = Join-Path $runDirectory 'proxy-config'
            Copy-Item -LiteralPath $directConfig -Destination $proxyConfig
            try {
                $env:KUBECONFIG = $proxyConfig
                Invoke-SetupScript @scriptOptions -Name "07-$selectedModule" -Executable $pwsh `
                    -Path (Join-Path $PSScriptRoot 'Deploy-EdgeModules.ps1') `
                    -Arguments @('-ConfigPath', $configFile, '-ModuleName', $selectedModule)
            } finally {
                $env:KUBECONFIG = $directConfig
                Remove-Item -LiteralPath $proxyConfig -ErrorAction Stop
            }
            Invoke-SetupCommand kubectl @('rollout', 'status', "deployment/$selectedModule", '-n', 'default',
                "--timeout=$($ReadinessTimeoutMinutes)m")
        }
        Write-Host "`nSetup completed. Logs: $runDirectory" -ForegroundColor Green
        Write-Host "https://portal.azure.com/#@/resource/subscriptions/$($azure.subscription_id)/resourceGroups/$($azure.resource_group)"
    } finally {
        $env:KUBECONFIG = $oldKubeconfig
    }
}

try {
    Invoke-IoTOperationsSetup
} catch {
    Write-Error "Setup stopped: $_"
    exit 1
}
