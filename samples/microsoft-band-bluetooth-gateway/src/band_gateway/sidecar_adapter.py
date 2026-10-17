"""Versioned JSON-lines boundary to the external Windows Bluetooth adapter."""

from __future__ import annotations

from datetime import datetime
import json
import logging
from pathlib import Path
from queue import Empty, Full, Queue
import subprocess
from threading import Event, Thread
from typing import Iterator

from .models import BandTelemetry

LOGGER = logging.getLogger("band_gateway")


class SidecarBandAdapter:
    def __init__(
        self, device_id: str, sidecar_path: str, timeout_seconds: float = 45,
    ) -> None:
        self._device_id = device_id
        self._sidecar_path = Path(sidecar_path).expanduser().resolve()
        self._timeout_seconds = timeout_seconds

    def _command(self) -> list[str]:
        if not self._sidecar_path.is_file():
            raise FileNotFoundError(
                f"Band sidecar was not found at {self._sidecar_path}. "
                "Run scripts\\Install-BandSdkSidecar.ps1 first."
            )
        return [str(self._sidecar_path)]

    def _parse(self, line: str) -> BandTelemetry | None:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            LOGGER.debug("SDK diagnostic: %s", line.rstrip())
            return None
        if not isinstance(payload, dict) or payload.get("type") != "telemetry":
            return None
        if payload.get("schemaVersion") != 2:
            raise RuntimeError("Unsupported sidecar schema; rebuild the sidecar.")
        try:
            timestamp = datetime.fromisoformat(payload["timestamp"])
            if timestamp.tzinfo is None or not isinstance(payload["sensors"], dict):
                raise ValueError("Expected timezone-aware timestamp and sensor object")
        except (KeyError, TypeError, ValueError) as error:
            raise RuntimeError(f"Invalid sidecar telemetry: {error}") from error
        return BandTelemetry(
            device_id=self._device_id, timestamp=timestamp,
            values={k: v for k, v in payload.items() if k not in {"type", "timestamp"}},
        )

    def read(self) -> BandTelemetry:
        stream = self.stream(5, continuous=False)
        try:
            return next(stream)
        finally:
            stream.close()

    def stream(
        self, interval_seconds: float, continuous: bool = True,
    ) -> Iterator[BandTelemetry]:
        command = self._command() + ["--interval-seconds", str(interval_seconds)]
        command += ["--continuous"] if continuous else ["--samples", "1"]
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
        )
        lines: Queue[str | None] = Queue(maxsize=16)
        stopping = Event()

        def pump() -> None:
            assert process.stdout is not None
            try:
                for line in process.stdout:
                    while not stopping.is_set():
                        try:
                            lines.put(line, timeout=0.2)
                            break
                        except Full:
                            continue
                    if stopping.is_set():
                        return
            finally:
                if not stopping.is_set():
                    # The consumer drains the queue even when the process exits.
                    while not stopping.is_set():
                        try:
                            lines.put(None, timeout=0.2)
                            break
                        except Full:
                            continue

        def diagnostics() -> None:
            assert process.stderr is not None
            for line in process.stderr:
                LOGGER.warning("Band sidecar: %s", line.rstrip())

        readers = [Thread(target=pump, daemon=True), Thread(target=diagnostics, daemon=True)]
        for reader in readers:
            reader.start()
        try:
            while True:
                try:
                    line = lines.get(timeout=max(self._timeout_seconds, interval_seconds + 10))
                except Empty as error:
                    raise RuntimeError("Timed out waiting for Band telemetry.") from error
                if line is None:
                    code = process.wait(timeout=5)
                    raise RuntimeError(f"Band sidecar stream ended with code {code}.")
                reading = self._parse(line)
                if reading is not None:
                    yield reading
                    if not continuous:
                        return
        finally:
            stopping.set()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            for reader in readers:
                reader.join(timeout=2)
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()
