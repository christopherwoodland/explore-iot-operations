from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from unittest.mock import Mock

import pytest

from band_gateway.config import GatewayConfig
from band_gateway.main import publish_once
from band_gateway.models import BandTelemetry


def make_config(tmp_path: Path, stale_after_seconds: float = 30) -> GatewayConfig:
    return GatewayConfig(
        device_id="band-01",
        band_sidecar_path="BandSdkSidecar.exe",
        mqtt_host="localhost",
        mqtt_port=18883,
        mqtt_tls=False,
        mqtt_tls_insecure=False,
        mqtt_username=None,
        mqtt_password=None,
        mqtt_ca_cert=None,
        mqtt_client_id="band-client",
        topic_prefix="wearables/band-01",
        log_path=str(tmp_path / "logs" / "gateway.log"),
        telemetry_archive_path=str(tmp_path / "data" / "telemetry.jsonl"),
        stale_after_seconds=stale_after_seconds,
    )


def test_publish_once_archives_published_reading(tmp_path: Path) -> None:
    config = make_config(tmp_path)
    adapter = Mock()
    adapter.read.return_value = BandTelemetry(
        device_id="band-01",
        timestamp=datetime.now(timezone.utc),
        values={"accelerometer": {"x": 1}},
    )
    client = Mock()
    client.publish.return_value.rc = 0

    publish_once(config, adapter, client)

    archive = Path(config.telemetry_archive_path)
    assert json.loads(archive.read_text(encoding="utf-8"))["deviceId"] == "band-01"
    client.publish.assert_called_once()


def test_publish_once_rejects_stale_reading(tmp_path: Path) -> None:
    config = make_config(tmp_path, stale_after_seconds=5)
    adapter = Mock()
    adapter.read.return_value = BandTelemetry(
        device_id="band-01",
        timestamp=datetime.now(timezone.utc) - timedelta(seconds=6),
        values={},
    )

    with pytest.raises(RuntimeError, match="reading is stale"):
        publish_once(config, adapter, Mock())
