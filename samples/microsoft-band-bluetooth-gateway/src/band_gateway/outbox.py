"""Crash-safe FIFO; remove records only after broker acknowledgement."""

from pathlib import Path
import sqlite3
from uuid import uuid4
import json

from .models import BandTelemetry


class Outbox:
    def __init__(self, path: str, max_records: int = 100000) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.connection = sqlite3.connect(path)
        self.connection.execute("PRAGMA journal_mode=WAL")
        self.connection.execute("PRAGMA synchronous=FULL")
        self.connection.execute(
            "CREATE TABLE IF NOT EXISTS messages "
            "(sequence INTEGER PRIMARY KEY, topic TEXT NOT NULL, payload TEXT NOT NULL)"
        )
        self.max_records = max_records

    def enqueue(self, topic: str, reading: BandTelemetry) -> str:
        if self.connection.execute("SELECT count(*) FROM messages").fetchone()[0] >= self.max_records:
            raise RuntimeError("Outbox is full; stopping collection without dropping queued data.")
        payload = json.loads(reading.to_json())
        payload["messageId"] = str(uuid4())
        serialized = json.dumps(payload, separators=(",", ":"), allow_nan=False)
        with self.connection:
            self.connection.execute(
                "INSERT INTO messages(topic, payload) VALUES (?, ?)", (topic, serialized)
            )
        return payload["messageId"]

    def peek(self) -> tuple[int, str, str] | None:
        return self.connection.execute(
            "SELECT sequence, topic, payload FROM messages ORDER BY sequence LIMIT 1"
        ).fetchone()

    def acknowledge(self, sequence: int) -> None:
        with self.connection:
            self.connection.execute("DELETE FROM messages WHERE sequence = ?", (sequence,))

    def close(self) -> None:
        self.connection.close()
