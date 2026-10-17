from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest

from band_gateway.sidecar_adapter import SidecarBandAdapter


def test_sidecar_adapter_normalizes_accelerometer_payload(
    tmp_path: Path,
) -> None:
    sidecar = tmp_path / "BandSdkSidecar.exe"
    sidecar.touch()
    output = (
        '[Info] SDK diagnostic\n'
        '{"type":"device","name":"Cargo Service 3"}\n'
        '{"type":"telemetry","timestamp":"2026-10-17T13:31:01-04:00",'
        '"accelerometer":{"x":-0.98,"y":0.07,"z":0.18}}\n'
    )

    with patch(
        "band_gateway.sidecar_adapter.subprocess.run",
        return_value=subprocess.CompletedProcess([], 0, output, ""),
    ):
        reading = SidecarBandAdapter("band-01", str(sidecar)).read()

    assert reading.device_id == "band-01"
    assert reading.values == {
        "accelerometer": {"x": -0.98, "y": 0.07, "z": 0.18}
    }


def test_sidecar_adapter_surfaces_process_failure(tmp_path: Path) -> None:
    sidecar = tmp_path / "BandSdkSidecar.exe"
    sidecar.touch()

    with patch(
        "band_gateway.sidecar_adapter.subprocess.run",
        return_value=subprocess.CompletedProcess([], 4, "", "sensor timeout"),
    ):
        with pytest.raises(RuntimeError, match="sensor timeout"):
            SidecarBandAdapter("band-01", str(sidecar)).read()
