[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares BeforeEach variables with It blocks.')]
param()

$scriptDirectory = Split-Path $PSScriptRoot
$entryPoint = Join-Path $scriptDirectory 'Start-IoTOperationsSetup.ps1'
$initializer = Join-Path $scriptDirectory 'Initialize-AksEdgeForIoTOperations.ps1'
$tokens = $null
$parseErrors = $null
$setupAst = [Management.Automation.Language.Parser]::ParseFile($entryPoint, [ref]$tokens, [ref]$parseErrors)
foreach ($function in $setupAst.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$edgeAst = [Management.Automation.Language.Parser]::ParseFile($initializer, [ref]$null, [ref]$null)
$apiWait = $edgeAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Wait-EdgeApi'
}
. ([scriptblock]::Create($apiWait.Extent.Text))
$installerSelection = $edgeAst.Find({
    param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text.StartsWith('[Uri]::TryCreate')
}, $true)

Describe 'Setup script syntax' {
    It 'parses the coordinator and initializer without errors' {
        foreach ($file in @($entryPoint, $initializer)) {
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors) | Out-Null
            @($errors).Count | Should Be 0
        }
    }
}

Describe 'Readiness waits' {
    It 'returns immediately when ready' {
        { Wait-SetupCondition 'test' { $true } -TimeoutSeconds 1 } | Should Not Throw
    }
    It 'polls until ready instead of assuming a process exit means readiness' {
        $script:attempt = 0
        Mock Start-Sleep {}
        Wait-SetupCondition 'test' { $script:attempt++; $script:attempt -eq 3 } -TimeoutSeconds 2
        $script:attempt | Should Be 3
    }
    It 'fails on timeout' {
        { Wait-SetupCondition 'test' { $false } -TimeoutSeconds 0 } | Should Throw 'Timed out'
    }
    It 'does not hide query errors as success or continue indefinitely' {
        { Wait-SetupCondition 'test' { throw 'query failed' } -TimeoutSeconds 1 } | Should Throw 'query failed'
    }
}

Describe 'AKS Edge installer source handling' {
    It 'downloads HTTPS installers without passing the URL to Resolve-Path' {
        $source = 'https://example.com/AksEdge.msi'
        $uri = $null
        $workDirectory = $TestDrive
        Mock Invoke-WebRequest {}
        Mock Resolve-Path { throw 'Resolve-Path must not receive an HTTPS URL' }
        . ([scriptblock]::Create($installerSelection.Extent.Text))
        $installer | Should Be (Join-Path $TestDrive 'AksEdge.msi')
        Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly
        Assert-MockCalled Resolve-Path -Times 0 -Exactly
    }
    It 'resolves local installer files without downloading them' {
        $source = Join-Path $TestDrive 'local installer.msi'
        'test' | Set-Content -LiteralPath $source
        $uri = $null
        Mock Invoke-WebRequest { throw 'Local installer must not be downloaded' }
        . ([scriptblock]::Create($installerSelection.Extent.Text))
        $installer | Should Be $source
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'AKS Edge API readiness' {
    It 'waits through a transient API failure' {
        $ReadinessTimeoutMinutes = 1
        $script:apiAttempt = 0
        Mock Start-Sleep {}
        Mock kubectl {
            $script:apiAttempt++
            if ($script:apiAttempt -eq 1) {
                $global:LASTEXITCODE = 1
                Write-Error 'API is restarting' -ErrorAction Continue
            } else {
                $global:LASTEXITCODE = 0
                'ok'
            }
        }
        Wait-EdgeApi
        $script:apiAttempt | Should Be 2
    }
}

Describe 'Configuration prompting' {
    BeforeEach {
        $NonInteractive = $true
        $CheckOnly = $false
        $ConfigPath = 'test-config.json'
    }
    It 'prefers an explicit parameter over saved settings' {
        Read-SetupSetting 'cluster' 'explicit' 'saved' | Should Be 'explicit'
    }
    It 'uses saved settings without prompting in noninteractive mode' {
        Read-SetupSetting 'cluster' '' 'saved' | Should Be 'saved'
    }
    It 'fails when required input is missing in noninteractive mode' {
        { Read-SetupSetting 'cluster' '' '' -Required } | Should Throw 'cluster is required'
    }
}

Describe 'Permission verification' {
    It 'requires both the expected principal and the expected role' {
        $required = @(@{ PrincipalId = 'arc'; Role = 'AcrPull' })
        Test-SetupRoleAssignment @(@{ principalId = 'arc'; roleDefinitionName = 'AcrPull' }) $required | Should Be $true
        Test-SetupRoleAssignment @(@{ principalId = 'other'; roleDefinitionName = 'AcrPull' }) $required | Should Be $false
        Test-SetupRoleAssignment @(@{ principalId = 'arc'; roleDefinitionName = 'Reader' }) $required | Should Be $false
    }
    It 'does not consider empty role query results successful' {
        Test-SetupRoleAssignment @() @(@{ PrincipalId = 'arc'; Role = 'AcrPull' }) | Should Be $false
    }
}

Describe 'Sequential child scripts' {
    BeforeEach {
        $stage = Join-Path $TestDrive 'stage with spaces.ps1'
        $logDirectory = Join-Path $TestDrive 'logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $options = @{
            Name = 'test-stage'
            Executable = (Get-Command pwsh).Source
            Path = $stage
            LogDirectory = $logDirectory
            TimeoutSeconds = 15
        }
    }
    It 'waits for completion and preserves argument boundaries' {
        'param([string]$Value) Write-Output $Value; exit 0' | Set-Content -LiteralPath $stage
        Invoke-SetupScript @options -Arguments @('-Value', "space ' quote & ampersand")
        Get-Content (Join-Path $logDirectory 'test-stage.log') -Raw | Should Match "space ' quote & ampersand"
    }
    It 'stops on a failed child process and saves its output' {
        'Write-Output "failure evidence"; exit 17' | Set-Content -LiteralPath $stage
        { Invoke-SetupScript @options } | Should Throw 'exit 17'
        Get-Content (Join-Path $logDirectory 'test-stage.log') -Raw | Should Match 'failure evidence'
    }
    It 'reports reboot requirements without pretending the stage completed' {
        'exit 3010' | Set-Content -LiteralPath $stage
        { Invoke-SetupScript @options } | Should Throw 'requires a Windows restart'
    }
    It 'terminates only the timed-out child and reports the timeout' {
        'Start-Sleep -Seconds 30' | Set-Content -LiteralPath $stage
        $options.TimeoutSeconds = 1
        { Invoke-SetupScript @options } | Should Throw 'timed out'
    }
}

Describe 'Read-only preflight' {
    BeforeEach {
        $testConfig = Join-Path $TestDrive 'aio_config.json'
        @{
            azure = @{
                subscription_id = '11111111-2222-3333-4444-555555555555'
                resource_group = 'test-rg'
                cluster_name = 'test-cluster'
                location = 'eastus'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $testConfig
        $before = Get-Content -LiteralPath $testConfig -Raw
    }
    It 'accepts saved settings without modifying the config or deploying' {
        & pwsh -NoProfile -File $entryPoint -CheckOnly -NonInteractive -ConfigPath $testConfig | Out-Null
        $LASTEXITCODE | Should Be 0
        Get-Content -LiteralPath $testConfig -Raw | Should Be $before
        Test-Path (Join-Path $TestDrive 'setup-runs') | Should Be $false
    }
    It 'rejects invalid saved VM sizing' {
        $config = Get-Content -LiteralPath $testConfig -Raw | ConvertFrom-Json
        $config | Add-Member -NotePropertyName aks_edge -NotePropertyValue @{ memory_in_mb = 1 }
        $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $testConfig
        & pwsh -NoProfile -File $entryPoint -CheckOnly -NonInteractive -ConfigPath $testConfig 2>&1 | Out-Null
        $LASTEXITCODE | Should Be 1
    }
}
