from datetime import datetime, timezone
import json

from band_gateway.models import BandTelemetry


def test_telemetry_serializes_normalized_payload() -> None:
    telemetry = BandTelemetry(
        device_id="band-01",
        timestamp=datetime(2026, 10, 17, 17, 0, tzinfo=timezone.utc),
        values={"heartRateBpm": 72},
    )

    assert json.loads(telemetry.to_json()) == {
        "deviceId": "band-01",
        "timestamp": "2026-10-17T17:00:00+00:00",
        "heartRateBpm": 72,
    }
