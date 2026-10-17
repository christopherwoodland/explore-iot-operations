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
reports a status such as `fresh`, `stale`, `awaiting_reading`, `not_supported`, `unavailable`, or
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
│       ├── outbox.py
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

This reads one multi-sensor snapshot through the external sidecar and prints
normalized JSON without connecting to MQTT.

### Selecting the physical device

List the paired candidates using the separately built sidecar:

```powershell
& .\sidecar\BandSdkSidecar\bin\Release\net8.0-windows10.0.19041.0\BandSdkSidecar.exe --list-devices
```

Copy the exact `selector` into `BAND_DEVICE_SELECTOR` in your local `.env`.
`BAND_DEVICE_ID` is the logical telemetry identity; it does not select hardware.
`BAND_DEVICE_NAME` is an optional exact-name filter, but Windows may expose
multiple Bands under the generic name `Cargo Service 3`. The adapter refuses
ambiguous selection instead of connecting to the first candidate. With one
paired candidate, selectors may be left unset for backwards-compatible setup.
Device selectors are host-specific: configure them again after moving hosts.

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

One sidecar maintains the Bluetooth connection and subscriptions across
snapshots. Sensor events update the latest values continuously; snapshots are
emitted at `-IntervalSeconds` (not a raw high-frequency motion stream).
On a sidecar failure or a motion-stream silence longer than 20 seconds, the
gateway starts a new connection with exponential backoff capped at 30 seconds.
Each new connection starts with empty sensor state. Add
`-MaxConsecutiveFailures 5` for a bounded failure policy. By default collection
and delivery retry indefinitely. Use `-MaxMessages 10` for a finite smoke test.

Collection and MQTT delivery run independently. Every accepted snapshot is
committed to an SQLite WAL outbox **before** network delivery. Broker outages
do not stop sensor collection. FIFO replay preserves the original timestamps,
freshness metadata, and `messageId`; it never re-labels historical data as live.
Records are deleted only after a QoS 1 PUBACK and a successful local archive
write. A crash in that interval can cause duplicates: deduplicate by
`messageId` downstream. This is at-least-once, not exactly-once delivery.

The default outbox is `data/outbox.sqlite3`, limited to 100,000 pending snapshots.
Change `BAND_OUTBOX_PATH` and `BAND_OUTBOX_MAX_RECORDS` if needed. A full outbox or
storage failure stops collection explicitly instead of dropping old records.
The acknowledged-message JSONL archive is not size-limited; apply your site's
retention policy. Both stores can contain personal sensor data; restrict access
and protect the host disk. Do not put personal names into MQTT topics.

The gateway writes rotating logs to `logs/band-gateway.log` and appends each
successfully published reading to `data/telemetry.jsonl`. Both paths are
ignored by Git and can be changed with `BAND_LOG_PATH` and
`BAND_TELEMETRY_ARCHIVE_PATH`. The archive is a simple local time-series
destination for development and can be ingested later into Azure Data Explorer,
a lakehouse, or another historical store.

At collection, each payload is rejected if its timestamp is older than
`BAND_STALE_AFTER_SECONDS` (30 seconds by default). Each sensor also has its own
age and threshold: motion 5 seconds; heart rate/RR 15 seconds; temperature,
contact, GSR, ambient light and barometer 60 seconds; cumulative counters,
UV and altimeter 120 seconds. These are conservative sample policies, not
manufacturer guarantees. A stale sensor has `value: null`, never its old value.
The gateway also rechecks sensor age before persisting a snapshot.

`observedAt` preserves the SDK timestamp, which can depend on the Band's clock.
`receivedAt` records host receipt time. `ageMs` uses monotonic host time and
`timestampBasis: gateway_receipt` explicitly identifies the freshness basis.
This detects missing events, not whether a functioning sensor is accurate.
Heart-rate `quality` must be checked before treating a BPM value as acquired.

For automatic restart at Windows logon, register a Scheduled Task from an
elevated PowerShell prompt:

```powershell
.\scripts\Register-BandGatewayTask.ps1
Start-ScheduledTask -TaskName 'Microsoft Band IoT Gateway'
```

The task starts the continuous launcher, which supervises and restarts its
localhost MQTT tunnel while collection continues into the outbox. Tunnel
errors are written to `logs/tunnel-error.log`. The local Arc proxy is a separate
prerequisite in Arc-proxy environments; the launcher does not authenticate to
Azure or manage that proxy. This cloud-backed development tunnel is **not**
an offline LAN broker endpoint. An offline-first deployment must provision a
locally reachable, TLS-protected broker listener with local authentication.
The task runs in the Windows user environment and does not install a Windows
service. Remove it with:

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

The combined dataset is named `telemetry`. Re-running the registration script
replaces the legacy `accelerometer` dataset with `telemetry`, preserves unrelated
datasets and keeps both MQTT topic paths unchanged. This is a payload schema
upgrade: consumers expecting the old flat fields must migrate to schema 2.

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
  "schemaVersion": 2,
  "deviceId": "microsoft-band-v1-01",
  "messageId": "f5edbba7-71bf-4a67-b04b-ec3fb80f96ba",
  "timestamp": "2026-10-17T17:00:00+00:00",
  "sensors": {
    "accelerometer": {
      "status": "fresh",
      "value": {"x": 0.03, "y": 0.98, "z": 0.12},
      "unit": "g",
      "observedAt": "2026-10-17T17:00:00+00:00",
      "receivedAt": "2026-10-17T17:00:00+00:00",
      "timestampBasis": "gateway_receipt",
      "ageMs": 12,
      "staleAfterMs": 5000
    },
    "heartRate": {"status": "consent_required", "value": null}
  },
  "unsupported": {
    "spo2": "not_available_on_microsoft_band_v1",
    "respiratoryRate": "not_measured; requires validated derivation",
    "sleepState": "not_available_from_live_sensor_api"
  }
}
```

The sidecar emits UTF-8 JSON lines (`device` metadata followed by `telemetry`
records); SDK diagnostics are not telemetry. `schemaVersion: 2` requires a
timezone-aware payload timestamp and a `sensors` object. The gateway adds
`deviceId` and `messageId` before queuing. Distance is normalized from SDK
centimeters to meters and RR intervals from seconds to milliseconds. Derived
RMSSD uses up to 256 recent intervals, resets after an RR gap, and is not a
clinical measurement.

## Connector and local-first management boundary

The current integration uses the built-in MQTT Akri connector, not a custom
connector deployed into Kubernetes. The versioned JSON-lines adapter boundary
keeps Windows Bluetooth ownership separate from broker ingestion. A future
custom Akri connector can reuse this contract without embedding Windows-only
Bluetooth code in a Linux pod. Discovery, configuration reconciliation, and
management actions still need explicit implementation; a custom connector
does not deploy or administer the Windows gateway by itself.

The planned local management application is a separate deliverable: local
inventory, device groups, person assignments with consent/access controls,
health and historical telemetry, plus eventual Azure synchronization. During
outages a locally enrolled device must show `pending Azure registration`,
not pretend that Azure Device Registry has been updated. Do not edit
cloud-managed Kubernetes resources as an offline Device Registry workaround.
The cloud-hosted operations portal is not an offline local console.

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

After enabling it, wear the Band and inspect `sensors.heartRate.value.bpm`,
`sensors.heartRate.value.quality`, and `sensors.rrInterval` in archived and MQTT
payloads. A future
analytics stage could derive activity epochs or respiratory estimates from
accelerometer and heart-rate data, but those should be labeled as derived
values and validated separately.

## Physical pipeline validation (2026-10-17)

The release sidecar built with zero warnings/errors and all 17 Python tests
passed. A physical Band run verified:

- One sidecar PID persisted across successive sensor snapshots.
- The source and unified asset topics each delivered 31 messages with 31
  unique unified message IDs, using only the `telemetry` dataset.
- Heart-rate quality transitioned through `Acquiring` and `Locked`.
- Accelerometer, gyroscope, skin temperature, steps, calories, distance,
  contact and heart-rate freshness envelopes were valid.
- UV produced readings in an earlier run but remained `awaiting_reading` in
  the final run. Unsupported sensors remained explicitly marked.
- Terminating the adapter process caused the gateway to establish a new
  connection and resume physical collection.
- Interrupting only the gateway's MQTT tunnel allowed four snapshots to
  accumulate in the durable outbox. After terminating/restarting the gateway
  and restoring the tunnel, all four IDs reached the unified topic with their
  original payloads and timestamps. The outbox drained completely.

The monitoring subscriber must finish resubscribing before replay starts;
a nonpersistent monitoring session can otherwise miss messages during its own
disconnection even though the publisher receives PUBACKs.

This was a short integration test, not a long-duration soak or a real
Bluetooth-radio/out-of-range test. Actual radio loss, restart of the broker
itself, stale-sensor hardware faults and Scheduled Task startup still need
separate physical testing. Sensor staleness and retry behavior also have
automated coverage. Test telemetry and logs remain in ignored local storage.

## References

- [Azure IoT Operations developer guide](https://learn.microsoft.com/azure/iot-operations/develop-edge-apps/overview-iot-operations-development)
- [Azure IoT Operations custom Akri connectors](https://learn.microsoft.com/azure/iot-operations/develop-edge-apps/overview-akri-connectors)
- [Device and asset lifecycle connectivity requirements](https://learn.microsoft.com/azure/iot-operations/troubleshoot/troubleshoot#troubleshoot-device-and-asset-lifecycle-operations)
- [Microsoft Band SDK package](https://www.nuget.org/packages/Microsoft.Band/)
- [MicrosoftBandDev Band SDK](https://github.com/MicrosoftBandDev/band-sdk)
