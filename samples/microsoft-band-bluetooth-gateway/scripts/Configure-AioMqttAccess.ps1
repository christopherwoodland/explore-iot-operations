[CmdletBinding()]
param(
    [string] $ResourceGroup = 'iot',
    [string] $Instance = 'nhds-aio',
    [string] $Namespace = 'azure-iot-operations',
    [switch] $ForDevelopmentOnly
)

$ErrorActionPreference = 'Stop'

if (-not $ForDevelopmentOnly) {
    throw 'Pass -ForDevelopmentOnly to acknowledge that this sample stores credentials in a Kubernetes secret.'
}

$sampleRoot = Split-Path -Parent $PSScriptRoot
$authManifest = Join-Path $sampleRoot '..\auth-server-user-pass-mqtt\deploy\custom-user-pass-auth-server.yaml'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "band-gateway-$([guid]::NewGuid())"
$username = 'microsoft-band-gateway'

function ConvertTo-PasslibBase64 {
    param([byte[]] $Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=')
}

function New-RandomBytes {
    param([int] $Length)

    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return $bytes
}

New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    $passwordBytes = New-RandomBytes -Length 24
    $password = [Convert]::ToBase64String($passwordBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $salt = New-RandomBytes -Length 16
    $deriveBytes = [Security.Cryptography.Rfc2898DeriveBytes]::new(
        $password,
        $salt,
        100000,
        [Security.Cryptography.HashAlgorithmName]::SHA512
    )
    try {
        $hash = $deriveBytes.GetBytes(64)
    }
    finally {
        $deriveBytes.Dispose()
    }

    $passwordHash = '$pbkdf2-sha512$i=100000,l=64${0}${1}' -f (
        ConvertTo-PasslibBase64 -Bytes $salt
    ), (
        ConvertTo-PasslibBase64 -Bytes $hash
    )

    $credentialsPath = Join-Path $temporaryDirectory 'passwords.toml'
    @"
[$username]
password = "$passwordHash"

[$username.attributes]
device = "microsoft-band-v1-01"
site = "aks-edge-development"
"@ | Set-Content -Path $credentialsPath -Encoding utf8

    kubectl create secret generic auth-server-user-pass-mqtt-server-credentials `
        --namespace $Namespace `
        "--from-file=passwords.toml=$credentialsPath" `
        --dry-run=client `
        -o yaml |
        kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the MQTT credential secret.'
    }

    kubectl delete pod auth-server-user-pass-mqtt `
        --namespace $Namespace `
        --ignore-not-found
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to replace the MQTT authentication pod.'
    }

    kubectl apply -f $authManifest
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to deploy the MQTT username/password authentication server.'
    }

    kubectl wait `
        --namespace $Namespace `
        --for=condition=Ready `
        certificate/auth-server-user-pass-mqtt-server-cert `
        certificate/auth-server-user-pass-mqtt-client-cert `
        --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        throw 'Timed out waiting for authentication certificates.'
    }

    kubectl wait `
        --namespace $Namespace `
        --for=condition=Ready `
        pod/auth-server-user-pass-mqtt `
        --timeout=180s
    if ($LASTEXITCODE -ne 0) {
        throw 'Timed out waiting for the authentication server.'
    }

    $authConfigPath = Join-Path $temporaryDirectory 'broker-authentication.json'
    @{
        authenticationMethods = @(
            @{
                method = 'ServiceAccountToken'
                serviceAccountTokenSettings = @{
                    audiences = @('aio-internal')
                }
            },
            @{
                method = 'Custom'
                customSettings = @{
                    endpoint = 'https://auth-server-user-pass-mqtt'
                    caCertConfigMap = 'azure-iot-operations-aio-ca-trust-bundle'
                    auth = @{
                        x509 = @{
                            secretRef = 'auth-server-user-pass-mqtt-client-cert'
                        }
                    }
                }
            }
        )
    } |
        ConvertTo-Json -Depth 8 |
        Set-Content -Path $authConfigPath -Encoding utf8

    az iot ops broker authn apply `
        --resource-group $ResourceGroup `
        --instance $Instance `
        --name default `
        --config-file $authConfigPath `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to update the IoT Operations broker authentication policy.'
    }

    $certificateDirectory = Join-Path $sampleRoot 'certs'
    New-Item -ItemType Directory -Path $certificateDirectory -Force | Out-Null
    $certificatePath = Join-Path $certificateDirectory 'aio-ca.crt'
    $configMapJson = kubectl get configmap azure-iot-operations-aio-ca-trust-bundle `
        --namespace $Namespace `
        -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to export the IoT Operations broker CA certificate.'
    }
    $certificate = ($configMapJson | ConvertFrom-Json).data.'ca.crt'
    if (-not $certificate) {
        throw 'The IoT Operations CA trust bundle is empty.'
    }
    [IO.File]::WriteAllText(
        $certificatePath,
        $certificate,
        [Text.UTF8Encoding]::new($false)
    )

    $environmentPath = Join-Path $sampleRoot '.env'
    @"
BAND_DEVICE_ID=microsoft-band-v1-01
BAND_SIDECAR_PATH=sidecar/BandSdkSidecar/bin/Release/net8.0-windows10.0.19041.0/BandSdkSidecar.exe
MQTT_HOST=localhost
MQTT_PORT=18883
MQTT_TLS=true
MQTT_TLS_INSECURE=true
MQTT_USERNAME=$username
MQTT_PASSWORD=$password
MQTT_CA_CERT=certs/aio-ca.crt
MQTT_CLIENT_ID=microsoft-band-v1-gateway
MQTT_TOPIC_PREFIX=wearables/microsoft-band-v1-01
"@ | Set-Content -Path $environmentPath -Encoding utf8

    Write-Host 'IoT Operations MQTT access configured for the Band gateway.'
    Write-Host "Credentials were written to the ignored file: $environmentPath"
}
finally {
    if (Test-Path $temporaryDirectory) {
        Remove-Item -Path $temporaryDirectory -Recurse -Force
    }
}
