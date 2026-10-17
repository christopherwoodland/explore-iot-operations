from dataclasses import replace
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from threading import Event
from unittest.mock import Mock

import pytest

from band_gateway.config import GatewayConfig
from band_gateway.main import collect, deliver_pending, validate_reading
from band_gateway.models import BandTelemetry
from band_gateway.outbox import Outbox


def make_config(tmp_path: Path) -> GatewayConfig:
    return GatewayConfig(
        device_id="band-01", band_sidecar_path="BandSdkSidecar.exe",
        mqtt_host="localhost", mqtt_port=18883, mqtt_tls=False,
        mqtt_tls_insecure=False, mqtt_username=None, mqtt_password=None,
        mqtt_ca_cert=None, mqtt_client_id="band-client", topic_prefix="wearables/band-01",
        log_path=str(tmp_path / "gateway.log"),
        telemetry_archive_path=str(tmp_path / "archive.jsonl"),
        stale_after_seconds=30, outbox_path=str(tmp_path / "outbox.sqlite3"),
    )


def reading(age_ms: float = 0, limit_ms: float = 5000) -> BandTelemetry:
    return BandTelemetry(
        "band-01", datetime.now(timezone.utc),
        {"schemaVersion": 2, "sensors": {"accelerometer": {
            "status": "fresh", "value": {"x": 1},
            "ageMs": age_ms, "staleAfterMs": limit_ms,
        }}},
    )


@pytest.mark.parametrize("age,limit", [(6000, 5000), (10000, 1000)])
def test_stale_sensor_values_are_removed(tmp_path, age, limit):
    value = reading(age, limit)
    validate_reading(make_config(tmp_path), value)
    assert value.values["sensors"]["accelerometer"]["status"] == "stale"
    assert value.values["sensors"]["accelerometer"]["value"] is None


def test_stale_payload_rejected(tmp_path):
    value = replace(reading(), timestamp=datetime.now(timezone.utc) - timedelta(seconds=31))
    with pytest.raises(RuntimeError, match="stale"):
        validate_reading(make_config(tmp_path), value)


@pytest.mark.parametrize("age,limit", [(-1, 1000), (float("nan"), 1000), (0, 0)])
def test_invalid_sensor_age_rejected(tmp_path, age, limit):
    with pytest.raises(RuntimeError, match="freshness"):
        validate_reading(make_config(tmp_path), reading(age, limit))


def test_outbox_survives_restart_and_replays_original_identity(tmp_path):
    config = make_config(tmp_path)
    box = Outbox(config.outbox_path)
    message_id = box.enqueue("test/telemetry", reading())
    box.close()
    box = Outbox(config.outbox_path)
    client = Mock()
    client.publish.return_value.rc = 0
    client.publish.return_value.is_published.return_value = True
    try:
        assert deliver_pending(config, box, client)
        assert box.peek() is None
        archived = json.loads(Path(config.telemetry_archive_path).read_text())
        assert archived["messageId"] == message_id
        assert archived["timestamp"]
    finally:
        box.close()


def test_timeout_preserves_message_and_id_for_retry(tmp_path):
    config = make_config(tmp_path)
    box = Outbox(config.outbox_path)
    box.enqueue("test/telemetry", reading())
    original = box.peek()
    client = Mock()
    client.publish.return_value.rc = 0
    client.publish.return_value.is_published.return_value = False
    try:
        with pytest.raises(TimeoutError):
            deliver_pending(config, box, client)
        assert box.peek() == original
        client.publish.return_value.is_published.return_value = True
        assert deliver_pending(config, box, client)
        assert box.peek() is None
        assert client.publish.call_args_list[0] == client.publish.call_args_list[1]
    finally:
        box.close()


def test_fifo_and_capacity_no_silent_drops(tmp_path):
    box = Outbox(str(tmp_path / "box.db"), max_records=2)
    try:
        first = box.enqueue("t", reading())
        box.enqueue("t", reading())
        with pytest.raises(RuntimeError, match="full"):
            box.enqueue("t", reading())
        assert json.loads(box.peek()[2])["messageId"] == first
    finally:
        box.close()


def test_collect_uses_one_persistent_stream_and_spools_offline(tmp_path):
    config = make_config(tmp_path)
    box = Outbox(config.outbox_path)
    adapter = Mock()
    adapter.stream.return_value = iter_readings = (reading() for _ in range(3))
    try:
        collect(config, adapter, box, 1, True, 3, 2, Event())
        adapter.stream.assert_called_once_with(1, True)
        assert box.connection.execute("SELECT count(*) FROM messages").fetchone()[0] == 3
    finally:
        iter_readings.close()
        box.close()


def test_bluetooth_restart_discards_old_session_and_retries(tmp_path, monkeypatch):
    config = make_config(tmp_path)
    box = Outbox(config.outbox_path)
    adapter = Mock()

    def broken():
        raise RuntimeError("Bluetooth disconnected")
        yield

    adapter.stream.side_effect = [broken(), (reading() for _ in range(1))]
    stop = Event()
    monkeypatch.setattr(stop, "wait", lambda delay: False)
    try:
        collect(config, adapter, box, 1, True, 1, 2, stop)
        assert adapter.stream.call_count == 2
        assert box.peek() is not None
    finally:
        box.close()
