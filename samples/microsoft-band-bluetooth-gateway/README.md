# Microsoft Band v1 Bluetooth Gateway

This sample is the starting point for connecting a legacy Microsoft Band v1 to
Azure IoT Operations.

The Band is a Bluetooth peripheral. It does not run an Azure IoT Operations
module. The gateway runs on the Windows host that owns the Bluetooth adapter,
reads Band telemetry, and publishes normalized JSON to the IoT Operations MQTT
broker.

```text
Microsoft Band v1 --Bluetooth--> Windows gateway --MQTT/TLS--> IoT Operations
```

## Current status

This proof of concept has successfully opened the Band v1 RFCOMM services and
read live sensor telemetry on Windows. The Python gateway communicates
with a separately built community-SDK sidecar so GPL source and binaries remain
outside this MIT repository.

The gateway has also authenticated to the IoT Operations broker and delivered
physical Band telemetry over MQTT/TLS.

The sidecar attempts every live sensor exposed by the recovered SDK:
accelerometer, gyroscope, heart rate, RR intervals, skin temperature, steps,
calories, distance, contact/worn state, UV exposure, galvanic skin response,
ambient light, barometer, and altimeter. Sensors report their own support and
may be unavailable on a particular Band model or firmware.

Heart rate and RR intervals require explicit consent. Set
`BAND_ALLOW_HEART_RATE=true` only after obtaining the user's permission. The
Band v1 has no SpO2 sensor and does not expose sleep state or respiratory rate
as live sensor readings. HRV is calculated as RMSSD from collected RR
intervals; it is not a native Band measurement.

The default configuration leaves heart-rate and RR-interval subscriptions
disabled. Other sensors are still attempted independently, and every sensor
reports a status such as `started`, `not_supported`, `unavailable`, or
`consent_required`.

## Probe the Band connection

The Windows-native probe looks for the foreground RFCOMM service used by the
Microsoft Band SDK. It does not read or modify Band data.

```powershell
cd samples\microsoft-band-bluetooth-gateway
dotnet run --project .\native\BandProbe\BandProbe.csproj
```

If discovery succeeds, test opening the encrypted RFCOMM channel:

```powershell
dotnet run --project .\native\BandProbe\BandProbe.csproj -- --connect
```

Opening the channel proves that Windows can reach the Band protocol endpoint.
The sidecar in the next section adds the Band command protocol and sensor read.

## Install the external Band SDK sidecar

The community MicrosoftBandDev SDK is GPL-3.0 licensed, while this repository is
MIT licensed. The installer clones a pinned SDK commit into the ignored
`.external` directory and builds it into a separate process. No GPL SDK source
or binary is committed to this repository. The resulting sidecar binary is
subject to the GPL-3.0 license.

```powershell
cd samples\microsoft-band-bluetooth-gateway
.\scripts\Install-BandSdkSidecar.ps1
```

The compatibility project uses only the SDK protocol core and Windows transport.
It does not restore the abandoned MAUI project or its legacy image dependencies.

## Folder layout

```text
samples/microsoft-band-bluetooth-gateway/
├── .env.example
├── README.md
├── requirements.txt
├── native/
│   └── BandProbe/
│       ├── BandProbe.csproj
│       └── Program.cs
├── scripts/
│   ├── Configure-AioMqttAccess.ps1
│   ├── Install-BandSdkSidecar.ps1
│   ├── Invoke-BandGateway.ps1
│   ├── Register-BandGatewayTask.ps1
│   └── Register-AioAsset.ps1
├── sidecar/
│   └── BandSdkSidecar/
│       ├── BandSdkSidecar.csproj
│       ├── DesktopApplicationPlatformProvider.cs
│       └── Program.cs
├── src/
│   └── band_gateway/
│       ├── __init__.py
│       ├── config.py
│       ├── main.py
│       ├── monitor.py
│       ├── models.py
│       └── sidecar_adapter.py
└── tests/
    ├── test_models.py
    └── test_sidecar_adapter.py
```

## Setup

Use a supported Python version on the Windows host with the Bluetooth adapter:

```powershell
cd samples\microsoft-band-bluetooth-gateway
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
pip install -r requirements.txt
Copy-Item .env.example .env
```

Edit `.env` with the MQTT broker address and credentials. Do not commit `.env`.

## Test one local sensor reading

```powershell
$env:PYTHONPATH = "src"
python -m band_gateway.main --read-only
```

This reads one accelerometer sample through the external sidecar and prints
normalized JSON without connecting to MQTT.

## Publish one reading

```powershell
$env:PYTHONPATH = "src"
python -m band_gateway.main
```

## Connect to Azure IoT Operations MQTT

The default IoT Operations broker listener is a Kubernetes `ClusterIP` and
accepts Kubernetes service-account tokens. A Windows host process can't use
that listener directly. For this development environment:

1. The existing username/password authentication server validates the gateway
   credentials over mutual TLS.
2. The default broker authentication policy keeps `ServiceAccountToken` first
   for internal workloads and adds `Custom` authentication second.
3. `kubectl port-forward` exposes the broker only on `127.0.0.1`.
4. The gateway validates the broker certificate against the exported IoT
   Operations CA. Hostname validation is disabled only because the certificate
   names the Kubernetes service rather than `localhost`.

Configure this development-only access:

```powershell
.\scripts\Configure-AioMqttAccess.ps1 -ForDevelopmentOnly
```

The script generates a random password, stores its PBKDF2 hash in a Kubernetes
secret, deploys the auth server, updates the broker authentication policy,
exports the broker CA to the ignored `certs` directory, and writes the
credentials to the ignored `.env` file.

Publish one Band reading through a temporary localhost tunnel:

```powershell
.\scripts\Invoke-BandGateway.ps1
```

Run the data pipeline continuously. Stop it with `Ctrl+C`:

```powershell
.\scripts\Invoke-BandGateway.ps1 -Continuous -IntervalSeconds 5
```

Each cycle starts the sidecar, reads the full available sensor payload, and
publishes it with QoS 1. If Bluetooth or the sidecar fails, the gateway logs
the failure and retries. A new sidecar process on the next cycle also
re-establishes the Band connection. Add
`-MaxConsecutiveFailures 5` when a bounded failure policy is preferred.

The gateway writes rotating logs to `logs/band-gateway.log` and appends each
successfully published reading to `data/telemetry.jsonl`. Both paths are
ignored by Git and can be changed with `BAND_LOG_PATH` and
`BAND_TELEMETRY_ARCHIVE_PATH`. The archive is a simple local time-series
destination for development and can be ingested later into Azure Data Explorer,
a lakehouse, or another historical store.

Each reading is rejected if its timestamp is older than
`BAND_STALE_AFTER_SECONDS` (30 seconds by default), preventing stale Bluetooth
data from being published as current telemetry.

For automatic restart at Windows logon, register a Scheduled Task from an
elevated PowerShell prompt:

```powershell
.\scripts\Register-BandGatewayTask.ps1
Start-ScheduledTask -TaskName 'Microsoft Band IoT Gateway'
```

The task starts the existing continuous launcher, which owns the localhost
MQTT tunnel and retries failed MQTT and Band sidecar cycles. Remove it with:

```powershell
Unregister-ScheduledTask -TaskName 'Microsoft Band IoT Gateway' -Confirm:$false
```

Register the Windows gateway connection and physical Band in Azure Device
Registry:

```powershell
.\scripts\Register-AioAsset.ps1
```

The script installs the Microsoft MQTT connector template if the instance
doesn't already have one.

The Azure resource names are `legacy-band-gateway` and `legacy-band-v1-01`
because Device Registry rejects trademarked terms in resource names.

The MQTT connector subscribes to
`wearables/microsoft-band-v1-01/telemetry` and republishes the Band dataset to
`azure-iot-operations/data/wearables/microsoft-band-v1-01/telemetry`.

For production, create a separate `NodePort` or `LoadBalancer` listener with a
certificate valid for its external hostname and use managed secret delivery.
Do not use `MQTT_TLS_INSECURE=true` outside this localhost tunnel.

## MQTT contract

The default topics are:

```text
wearables/microsoft-band-v1-01/telemetry
wearables/microsoft-band-v1-01/status
```

Telemetry is published as JSON, for example:

```json
{
  "deviceId": "microsoft-band-v1-01",
  "timestamp": "2026-10-17T17:00:00+00:00",
  "heartRateBpm": 72,
  "heartRateVariability": {
    "rmssdMs": 42.1,
    "sampleCount": 12
  },
  "skinTemperatureCelsius": 31.2,
  "steps": {
    "total": 488770,
    "today": 3421
  },
  "accelerometer": {
    "x": 0.03,
    "y": 0.98,
    "z": 0.12
  },
  "sensorStatus": {
    "accelerometer": "started",
    "heartRate": "started",
    "rrInterval": "not_supported"
  },
  "unsupported": {
    "spo2": "not_available_on_microsoft_band_v1",
    "respiratoryRate": "not_measured; requires validated derivation",
    "sleepState": "not_available_from_live_sensor_api"
  }
}
```

Register the MQTT asset manually in Azure IoT Operations after telemetry is
visible. MQTT assets are not automatically discovered by the IoT Operations
Discovery experience.

## Data limitations and next steps

The Band v1 hardware observed in this sample provides accelerometer,
gyroscope, skin temperature, pedometer, calories, distance, contact state, and
UV readings. Heart rate is available when explicit consent is enabled and the
Band is worn. RR interval, GSR, ambient light, barometer, and altimeter are
reported by the SDK but are not supported by this Band's firmware.

SpO2 is not present in the Band v1 sensor set. Sleep state is historical
summary data rather than a live sensor stream, and respiratory rate is not
provided by the SDK. A future analytics stage could derive activity epochs or
respiratory estimates from accelerometer and heart-rate data, but those should
be labeled as derived values and validated separately.

The current sample now covers continuous retries, stale-reading rejection,
durable local logs, a development time-series archive, and Windows Scheduled
Task startup. Heart-rate and RR-interval collection remains disabled unless
explicit consent is configured:

```text
BAND_ALLOW_HEART_RATE=true
```

After enabling it, wear the Band and inspect the archived payload and MQTT
topic for `heartRateBpm`, `heartRateQuality`, and `rrIntervalMs`. A future
analytics stage could derive activity epochs or respiratory estimates from
accelerometer and heart-rate data, but those should be labeled as derived
values and validated separately.

## References

- [Azure IoT Operations developer guide](https://learn.microsoft.com/azure/iot-operations/develop-edge-apps/overview-iot-operations-development)
- [Azure IoT Operations custom Akri connectors](https://learn.microsoft.com/azure/iot-operations/develop-edge-apps/overview-akri-connectors)
- [Microsoft Band SDK package](https://www.nuget.org/packages/Microsoft.Band/)
- [MicrosoftBandDev Band SDK](https://github.com/MicrosoftBandDev/band-sdk)
