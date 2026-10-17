import json
import sys
from unittest.mock import patch

import pytest

from band_gateway.sidecar_adapter import SidecarBandAdapter


def payload():
    return json.dumps({
        "type": "telemetry", "schemaVersion": 2,
        "timestamp": "2026-10-17T22:00:00+00:00",
        "sensors": {"accelerometer": {"status": "fresh", "value": {"x": 1}}},
    })


def test_stream_reads_multiple_lines_from_one_process_and_cleans_up():
    output = payload()
    code = f"import time; print({output!r}, flush=True); print({output!r}, flush=True); time.sleep(60)"
    adapter = SidecarBandAdapter("band-01", sys.executable)
    with patch.object(adapter, "_command", return_value=[sys.executable, "-u", "-c", code]):
        stream = adapter.stream(1)
        try:
            assert next(stream).device_id == "band-01"
            assert next(stream).values["schemaVersion"] == 2
        finally:
            stream.close()


def test_sidecar_surfaces_process_failure():
    adapter = SidecarBandAdapter("band-01", sys.executable)
    with patch.object(adapter, "_command", return_value=[sys.executable, "-c", "raise SystemExit(4)"]):
        with pytest.raises(RuntimeError, match="code 4"):
            next(adapter.stream(1))


def test_schema_version_rejected():
    adapter = SidecarBandAdapter("band-01", sys.executable)
    with pytest.raises(RuntimeError, match="schema"):
        adapter._parse('{"type":"telemetry","schemaVersion":1}')


def test_sdk_diagnostic_lines_ignored():
    adapter = SidecarBandAdapter("band-01", sys.executable)
    assert adapter._parse("[Info] SDK message") is None


def test_missing_sidecar_reported(tmp_path):
    with pytest.raises(FileNotFoundError):
        SidecarBandAdapter("band", str(tmp_path / "missing.exe")).read()
