#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Windows PowerShell stage used by Start-IoTOperationsSetup.ps1.
.DESCRIPTION
    Uses the supported AksEdge cmdlets, not the downloaded quick-start script.
    Downloads MSI URLs as URLs, reuses existing deployments, and exits with 3010
    if Windows needs restarting. Never removes an existing deployment.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are consumed by functions in script scope.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [ValidateRange(1, 60)][int]$ReadinessTimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'

function Invoke-EdgeCommand {
    param([string]$Command, [string[]]$Arguments)
    $output = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command $($Arguments -join ' ') failed (exit $LASTEXITCODE)." }
    return $output
}

function Wait-EdgeApi {
    $ErrorActionPreference = 'Continue'
    $deadline = (Get-Date).AddMinutes($ReadinessTimeoutMinutes)
    do {
        $ready = & kubectl get --raw=/readyz --request-timeout=10s 2>&1
        if ($LASTEXITCODE -eq 0 -and "$ready".Trim() -eq 'ok') { return }
        Write-Host "Waiting for Kubernetes API: $ready"
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    throw "Kubernetes API did not become ready within $ReadinessTimeoutMinutes minutes."
}

function Initialize-AksEdge {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    $azure = $config.azure
    $edge = $config.aks_edge
    if (-not $edge.accept_eula) { throw 'AKS Edge license acceptance is required.' }
    if ([int]$edge.cpu_count -lt 4 -or [int]$edge.memory_in_mb -lt 10240 -or [int]$edge.data_size_in_gb -lt 40) {
        throw 'Demo minimums: 4 CPUs, 10240 MB memory and 40 GB data disk.'
    }
    $workDirectory = Join-Path (Split-Path $ConfigPath) 'aksedge'
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $restartRequired = $false
    foreach ($featureName in @('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Hypervisor')) {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
        if ($feature.State -in @('EnablePending', 'DisablePending')) { $restartRequired = $true; continue }
        if ($feature.State -ne 'Enabled') {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart
            if ($result.RestartNeeded) { $restartRequired = $true }
        }
    }
    $ssh = Get-WindowsCapability -Online -Name 'OpenSSH.Client*'
    if ($ssh.State -ne 'Installed') {
        $result = Add-WindowsCapability -Online -Name $ssh.Name
        if ($result.RestartNeeded) { $restartRequired = $true }
    }
    if ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        $restartRequired = $true
    }
    if ($restartRequired) {
        Write-Host 'Windows features installed. Restart Windows, then rerun Start-IoTOperationsSetup.ps1.'
        exit 3010
    }
    if (-not (Get-Module -ListAvailable AksEdge)) {
        $source = [string]$edge.installer_source
        $uri = $null
        if ([Uri]::TryCreate($source, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https') {
            $installer = Join-Path $workDirectory 'AksEdge.msi'
            Invoke-WebRequest -Uri $uri -OutFile $installer -UseBasicParsing
        } else {
            $installer = (Resolve-Path -LiteralPath $source -ErrorAction Stop).Path
        }
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation,') {
            throw "The AKS Edge installer does not have a valid Microsoft signature: $installer"
        }
        $installProcess = Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart" -PassThru
        $installProcess.WaitForExit()
        if ($installProcess.ExitCode -eq 3010) {
            Write-Host 'AKS Edge installed. Restart Windows, then rerun setup.'
            exit 3010
        }
        if ($installProcess.ExitCode -ne 0) { throw "AKS Edge MSI installation failed (exit $($installProcess.ExitCode))." }
    }
    Import-Module AksEdge -Force
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Install-AksEdgeHostFeatures -Confirm:$false)) { throw 'AKS Edge host prerequisites failed.' }
    if (-not (Test-AksEdgeDeployment)) {
        $deployment = @{
            SchemaVersion = '1.16'
            Version = '1.0'
            DeploymentType = 'SingleMachineCluster'
            AioDeploy = $true
            Init = @{ ServiceIPRangeSize = 10 }
            Arc = @{
                ClusterName = $azure.cluster_name
                Location = $null
                ResourceGroupName = $null
                SubscriptionId = $null
                TenantId = $null
                ClientId = $null
                ClientSecret = $null
            }
            Network = @{
                NetworkPlugin = 'flannel'
                InternetDisabled = $false
                Proxy = @{ Http = $null; Https = $null; No = $null }
            }
            User = @{ AcceptEula = $true; AcceptOptionalTelemetry = [bool]$edge.accept_optional_telemetry }
            Machines = @(@{ LinuxNode = @{
                CpuCount = [int]$edge.cpu_count
                MemoryInMB = [int]$edge.memory_in_mb
                DataSizeInGB = [int]$edge.data_size_in_gb
                LogSizeInGB = 4
            } })
        }
        $result = New-AksEdgeDeployment -JsonConfigString ($deployment | ConvertTo-Json -Depth 10)
        if ($result -ne 'OK') { throw "AKS Edge deployment failed: $result" }
    } else {
        Write-Host 'Reusing existing AKS Edge deployment.'
    }
    $info = Get-AksEdgeDeploymentInfo
    if ($info.LinuxNodeConfig.PowerState -ne 'Running') {
        throw 'The existing AKS Edge Linux node is not running. Start it before resuming setup.'
    }
    if ($info.Arc.ClusterName -and $info.Arc.ClusterName -ne $azure.cluster_name) {
        throw "This machine is already connected as $($info.Arc.ClusterName), not $($azure.cluster_name)."
    }
    Get-AksEdgeKubeConfig -KubeConfigPath $workDirectory -Confirm:$false | Out-Host
    $env:KUBECONFIG = Join-Path $workDirectory 'config'
    if (-not (Test-Path -LiteralPath $env:KUBECONFIG)) { throw 'AKS Edge did not export a kubeconfig.' }
    Wait-EdgeApi
    Invoke-EdgeCommand kubectl @('wait', 'nodes', '--all', '--for=condition=Ready', "--timeout=$($ReadinessTimeoutMinutes)m") | Out-Host
    Invoke-EdgeCommand az @('account', 'set', '--subscription', $azure.subscription_id) | Out-Host
    Invoke-EdgeCommand az @('group', 'create', '-n', $azure.resource_group, '-l', $azure.location, '--output', 'none') | Out-Host
    foreach ($provider in @('Microsoft.ExtendedLocation', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration')) {
        Invoke-EdgeCommand az @('provider', 'register', '-n', $provider, '--wait', '--output', 'none') | Out-Host
    }
    $clusters = @(Invoke-EdgeCommand az @('connectedk8s', 'list', '-g', $azure.resource_group,
        '-o', 'json', '--only-show-errors') | ConvertFrom-Json)
    $cluster = $clusters | Where-Object { $_.name -eq $azure.cluster_name }
    if ($cluster -and -not $info.Arc.ClusterName) {
        throw "An Arc resource named $($azure.cluster_name) already exists, but this local deployment is not associated with it. Verify ownership before reconnecting."
    }
    if (-not $cluster) {
        Invoke-EdgeCommand az @('connectedk8s', 'connect', '-n', $azure.cluster_name, '-g', $azure.resource_group,
            '-l', $azure.location, '--distribution', 'aks_edge_k3s', '--disable-auto-upgrade',
            '--enable-oidc-issuer', '--enable-workload-identity', '--output', 'none') | Out-Host
    } elseif (-not $cluster.oidcIssuerProfile.enabled -or -not $cluster.securityProfile.workloadIdentity.enabled) {
        Invoke-EdgeCommand az @('connectedk8s', 'update', '-n', $azure.cluster_name, '-g', $azure.resource_group,
            '--enable-oidc-issuer', '--enable-workload-identity', '--output', 'none') | Out-Host
    } else {
        Write-Host 'Reusing existing Arc connection; not reconnecting a healthy cluster.'
    }
    $cluster = Invoke-EdgeCommand az @('connectedk8s', 'show', '-n', $azure.cluster_name,
        '-g', $azure.resource_group, '-o', 'json', '--only-show-errors') | ConvertFrom-Json
    $issuer = $cluster.oidcIssuerProfile.issuerUrl
    if ($issuer -notmatch '^https://[a-zA-Z0-9./_-]+/$') { throw 'Azure did not return a valid OIDC issuer URL.' }
    $currentOidc = Invoke-EdgeCommand kubectl @('get', '--raw=/.well-known/openid-configuration', '--request-timeout=15s') | ConvertFrom-Json
    if ($currentOidc.issuer -ne $issuer) {
        $nodeCommand = "sudo grep -q 'service-account-issuer' /var/.eflow/config/k3s/k3s-config.yml && " +
            "sudo sed -i 's|service-account-issuer.*|service-account-issuer=$issuer|' /var/.eflow/config/k3s/k3s-config.yml && " +
            'sudo systemctl restart k3s.service'
        Invoke-AksEdgeNodeCommand -NodeType Linux -Command $nodeCommand | Out-Host
        Wait-EdgeApi
        $oidc = Invoke-EdgeCommand kubectl @('get', '--raw=/.well-known/openid-configuration', '--request-timeout=15s') | ConvertFrom-Json
        if ($oidc.issuer -ne $issuer) { throw 'Kubernetes is not using the Azure Arc OIDC issuer.' }
        Invoke-EdgeCommand kubectl @('rollout', 'restart', 'deployment', '-n', 'azure-arc') | Out-Host
    }
    $customLocationOid = Invoke-EdgeCommand az @('ad', 'sp', 'show',
        '--id', 'bc313c14-388c-4e7d-a58e-70017303ee3b', '--query', 'id', '-o', 'tsv', '--only-show-errors')
    if ($customLocationOid -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Custom Locations service principal lookup failed.' }
    Invoke-EdgeCommand az @('connectedk8s', 'enable-features', '-n', $azure.cluster_name,
        '-g', $azure.resource_group, '--custom-locations-oid', "$customLocationOid",
        '--features', 'cluster-connect', 'custom-locations', '--output', 'none') | Out-Host
    $storageClasses = @(Invoke-EdgeCommand kubectl @('get', 'storageclass', '-o', 'json') | ConvertFrom-Json)
    if ('local-path' -notin $storageClasses.items.metadata.name) {
        $manifest = Join-Path $workDirectory 'local-path-storage.yaml'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Azure/AKS-Edge/main/samples/storage/local-path-provisioner/local-path-storage.yaml' `
            -OutFile $manifest -UseBasicParsing
        Invoke-EdgeCommand kubectl @('apply', '-f', $manifest) | Out-Host
    }
    Invoke-EdgeCommand kubectl @('rollout', 'status', 'deployment/local-path-provisioner', '-n', 'kube-system',
        "--timeout=$($ReadinessTimeoutMinutes)m") | Out-Host
    if (-not (Get-NetFirewallRule -DisplayName 'AIO MQTT Broker' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName 'AIO MQTT Broker' -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 1883 | Out-Null
    }
    $info = Get-AksEdgeDeploymentInfo
    $connectAddress = $info.LinuxNodeConfig.ServiceIPRange.Split('-')[0]
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($connectAddress, [ref]$ip)) { throw 'Invalid broker service IP range.' }
    Invoke-EdgeCommand netsh @('interface', 'portproxy', 'add', 'v4tov4', 'listenport=1883',
        'listenaddress=0.0.0.0', 'connectport=1883', "connectaddress=$connectAddress") | Out-Host
    foreach ($port in @(9110, 10124, 8420, 2379, 50051)) {
        $rule = "-A INPUT -p tcp -m tcp --dport $port -j ACCEPT"
        $nodeCommand = "set -e; if ! sudo iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null; then " +
            "sudo iptables -A INPUT -p tcp --dport $port -j ACCEPT; fi; " +
            "if ! sudo grep -q -- '$rule' /etc/systemd/scripts/ip4save; then " +
            "sudo sed -i '/-A OUTPUT -j ACCEPT/i$rule' /etc/systemd/scripts/ip4save; fi; " +
            "sudo grep -q -- '$rule' /etc/systemd/scripts/ip4save"
        Invoke-AksEdgeNodeCommand -NodeType Linux -Command $nodeCommand | Out-Host
    }
    Invoke-EdgeCommand kubectl @('wait', 'pods', '--all', '-n', 'azure-arc', '--for=condition=Ready',
        "--timeout=$($ReadinessTimeoutMinutes)m") | Out-Host
    Get-AksEdgeDeploymentInfo | Format-List | Out-Host
}

try {
    Initialize-AksEdge
} catch {
    Write-Error "AKS Edge setup stopped: $_"
    exit 1
}
