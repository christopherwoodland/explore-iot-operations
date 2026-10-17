[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sampleRoot = Split-Path -Parent $PSScriptRoot
$sdkRoot = Join-Path $sampleRoot '.external\band-sdk'
$sidecarProject = Join-Path $sampleRoot 'sidecar\BandSdkSidecar\BandSdkSidecar.csproj'
$repository = 'https://github.com/MicrosoftBandDev/band-sdk.git'
$commit = '05401e5a8048139d16f765d7a6b7bc7a5f0f13b1'

if (-not (Test-Path $sdkRoot)) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $sdkRoot) -Force | Out-Null
    git clone --no-checkout --filter=blob:none $repository $sdkRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to clone the external MicrosoftBandDev SDK.'
    }
}

$origin = git -C $sdkRoot remote get-url origin
if ($LASTEXITCODE -ne 0 -or $origin -ne $repository) {
    throw "The existing external SDK directory has an unexpected Git origin: $sdkRoot"
}

git -C $sdkRoot fetch origin $commit --depth 1
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to fetch the pinned MicrosoftBandDev SDK commit.'
}

git -C $sdkRoot checkout --detach $commit
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to check out the pinned MicrosoftBandDev SDK commit.'
}

dotnet build $sidecarProject `
    --configuration Release `
    "-p:BandSdkRoot=$sdkRoot"
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to build the Microsoft Band SDK sidecar.'
}
Write-Host 'Band SDK sidecar installed successfully.'
Write-Host 'Band SDK sidecar installed successfully.'
