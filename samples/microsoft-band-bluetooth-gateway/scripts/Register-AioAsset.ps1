[CmdletBinding()]
param(
    [string] $ResourceGroup = 'iot',
    [string] $Instance = 'nhds-aio'
)

$ErrorActionPreference = 'Stop'

$template = 'mqtt-connector'
$device = 'legacy-band-gateway'
$endpoint = 'band-mqtt'
$asset = 'legacy-band-v1-01'
$sourceTopic = 'wearables/microsoft-band-v1-01/telemetry'
$destinationTopic = 'azure-iot-operations/data/wearables/microsoft-band-v1-01/telemetry'

$subscriptionId = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0 -or -not $subscriptionId) {
    throw 'Failed to determine the current Azure subscription.'
}
$templateUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.IoTOperations/instances/$Instance/akriConnectorTemplates/$($template)?api-version=2026-07-01"
az rest `
    --method get `
    --url $templateUrl `
    --only-show-errors `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az iot ops connector template create `
        --resource-group $ResourceGroup `
        --instance $Instance `
        --name $template `
        --connector-metadata-ref 'mcr.microsoft.com/azureiotoperations/akri-connectors/mqtt-metadata:3.0.0' `
        --replicas 1 `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the MQTT connector template.'
    }
}

az iot ops ns device show `
    --resource-group $ResourceGroup `
    --instance $Instance `
    --name $device `
    --only-show-errors `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az iot ops ns device create `
        --resource-group $ResourceGroup `
        --instance $Instance `
        --name $device `
        --manufacturer Microsoft `
        --model 'Microsoft Band v1 Bluetooth gateway' `
        --os Windows `
        --attr transport=bluetooth protocol=mqtt `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the Band gateway device.'
    }
}

$deviceResource = az iot ops ns device show `
    --resource-group $ResourceGroup `
    --instance $Instance `
    --name $device `
    --only-show-errors `
    --output json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to read the Band gateway device.'
}

if (
    -not $deviceResource.properties.endpoints.inbound -or
    -not $deviceResource.properties.endpoints.inbound.PSObject.Properties[$endpoint]
) {
    az iot ops ns device endpoint inbound add mqtt `
        --resource-group $ResourceGroup `
        --instance $Instance `
        --device $device `
        --name $endpoint `
        --endpoint-address 'aio-broker:18883' `
        --topic-filter 'wearables/+/telemetry' `
        --topic-mapping-prefix 'azure-iot-operations/data' `
        --asset-level 1 `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the Band MQTT inbound endpoint.'
    }
}

$additionalConfiguration = @{
    useBuiltInMqttBroker = $true
    assetDiscoveryConfiguration = @{
        topicFilter = 'wearables/+/telemetry'
        topicMappingPrefix = 'azure-iot-operations/data'
    }
} | ConvertTo-Json -Depth 5 -Compress

$patchBody = @{
    properties = @{
        endpoints = @{
            inbound = @{
                $endpoint = @{
                    endpointType = 'Microsoft.Mqtt'
                    version = '5'
                    address = 'aio-broker:18883'
                    authentication = @{
                        method = 'Anonymous'
                    }
                    additionalConfiguration = $additionalConfiguration
                }
            }
        }
    }
} | ConvertTo-Json -Depth 10

$patchPath = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText(
        $patchPath,
        $patchBody,
        [Text.UTF8Encoding]::new($false)
    )
    az rest `
        --method patch `
        --url "https://management.azure.com$($deviceResource.id)?api-version=2026-04-01" `
        --headers 'Content-Type=application/json' `
        --body "@$patchPath" `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to apply the MQTT connector version 5 endpoint schema.'
    }
}
finally {
    Remove-Item -Path $patchPath -Force
}

az iot ops ns asset show `
    --resource-group $ResourceGroup `
    --instance $Instance `
    --name $asset `
    --only-show-errors `
    --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az iot ops ns asset mqtt create `
        --resource-group $ResourceGroup `
        --instance $Instance `
        --name $asset `
        --device $device `
        --endpoint $endpoint `
        --display-name 'Microsoft Band v1' `
        --description 'Legacy Microsoft Band v1 connected through a Windows Bluetooth-to-MQTT gateway.' `
        --manufacturer Microsoft `
        --model 'Microsoft Band v1' `
        --hardware-revision 9 `
        --software-revision 10.3.3304.0 `
        --external-asset-id microsoft-band-v1-01 `
        --dataset-dest topic=$destinationTopic retain=Never qos=Qos1 ttl=3600 `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the Microsoft Band asset.'
    }
}

$assetResource = az iot ops ns asset show `
    --resource-group $ResourceGroup `
    --instance $Instance `
    --name $asset `
    --only-show-errors `
    --output json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to read the Microsoft Band asset.'
}

$otherDatasets = @(
    $assetResource.properties.datasets |
        Where-Object { $_.name -notin @('accelerometer', 'telemetry') }
)
$datasetPatchBody = @{
    properties = @{
        datasets = $otherDatasets + @(
            @{
                name = 'telemetry'
                dataSource = $sourceTopic
                dataPoints = @()
                destinations = @(
                    @{
                        target = 'Mqtt'
                        configuration = @{
                            topic = $destinationTopic
                            retain = 'Never'
                            qos = 'Qos1'
                            ttl = 3600
                        }
                    }
                )
            }
        )
    }
} | ConvertTo-Json -Depth 10

$datasetPatchPath = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText(
        $datasetPatchPath,
        $datasetPatchBody,
        [Text.UTF8Encoding]::new($false)
    )
    az rest `
        --method patch `
        --url "https://management.azure.com$($assetResource.id)?api-version=2026-04-01" `
        --headers 'Content-Type=application/json' `
        --body "@$datasetPatchPath" `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to configure the Band telemetry dataset.'
    }
}
finally {
    Remove-Item -Path $datasetPatchPath -Force
}

Write-Host 'Microsoft Band device, MQTT endpoint, asset, and dataset registered.'
Write-Host "Unified telemetry topic: $destinationTopic"
