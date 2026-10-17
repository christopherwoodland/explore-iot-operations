"""Adapter for the separately built Microsoft Band SDK sidecar."""

from __future__ import annotations

from datetime import datetime
import json
from pathlib import Path
import subprocess

from .models import BandTelemetry


class SidecarBandAdapter:
    """Read normalized telemetry from the external Band SDK process."""

    def __init__(
        self,
        device_id: str,
        sidecar_path: str,
        timeout_seconds: int = 30,
    ) -> None:
        self._device_id = device_id
        self._sidecar_path = Path(sidecar_path).expanduser().resolve()
        self._timeout_seconds = timeout_seconds

    def read(self) -> BandTelemetry:
        if not self._sidecar_path.is_file():
            raise FileNotFoundError(
                f"Band sidecar was not found at {self._sidecar_path}. "
                "Run scripts\\Install-BandSdkSidecar.ps1 first."
            )

        try:
            process = subprocess.run(
                [str(self._sidecar_path), "--samples", "1"],
                check=False,
                capture_output=True,
                text=True,
                timeout=self._timeout_seconds,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(
                f"Band sidecar timed out after {self._timeout_seconds} seconds."
            ) from error
        if process.returncode != 0:
            details = process.stderr.strip() or process.stdout.strip()
            raise RuntimeError(
                f"Band sidecar exited with code {process.returncode}: {details}"
            )

        for line in process.stdout.splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            if payload.get("type") != "telemetry":
                continue

            timestamp = datetime.fromisoformat(payload["timestamp"])
            values = payload.get("values", {
                key: value
                for key, value in payload.items()
                if key not in {"type", "timestamp"}
            })
            return BandTelemetry(
                device_id=self._device_id,
                timestamp=timestamp,
                values=values,
            )

        raise RuntimeError(
            "Band sidecar completed without returning a telemetry reading."
        )
