"""Normalized telemetry models for the Band gateway."""

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from typing import Any


@dataclass(frozen=True)
class BandTelemetry:
    """A normalized reading independent of the legacy Band SDK."""

    device_id: str
    timestamp: datetime
    values: dict[str, Any]

    def to_json(self) -> str:
        payload = {
            "deviceId": self.device_id,
            "timestamp": self.timestamp.astimezone(timezone.utc).isoformat(),
            **self.values,
        }
        return json.dumps(payload, separators=(",", ":"), sort_keys=True)
