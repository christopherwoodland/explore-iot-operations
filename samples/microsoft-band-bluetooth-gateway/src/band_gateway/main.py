"""Host-side gateway entry point."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import logging
import math
from logging.handlers import RotatingFileHandler
from pathlib import Path
import time
from threading import Event, Thread
from queue import Queue

import paho.mqtt.client as mqtt

from .config import GatewayConfig
from .models import BandTelemetry
from .sidecar_adapter import SidecarBandAdapter
from .outbox import Outbox

LOGGER = logging.getLogger("band_gateway")


def create_mqtt_client(
    config: GatewayConfig,
    client_id: str | None = None,
) -> mqtt.Client:
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=client_id or config.mqtt_client_id,
        protocol=mqtt.MQTTv5,
    )
    if config.mqtt_username:
        client.username_pw_set(config.mqtt_username, config.mqtt_password)
    if config.mqtt_tls:
        if config.mqtt_ca_cert:
            client.tls_set(ca_certs=config.mqtt_ca_cert)
        else:
            client.tls_set()
        if config.mqtt_tls_insecure:
            LOGGER.warning(
                "TLS hostname verification is disabled. "
                "Use this only with the localhost development tunnel."
            )
            client.tls_insecure_set(True)
    return client


def validate_reading(config: GatewayConfig, reading: BandTelemetry) -> None:
    if reading.timestamp.tzinfo is None:
        raise RuntimeError("Band payload timestamp must include a timezone.")
    age_seconds = (
        datetime.now(timezone.utc) - reading.timestamp.astimezone(timezone.utc)
    ).total_seconds()
    if age_seconds > config.stale_after_seconds:
        raise RuntimeError(
            f"Band reading is stale by {age_seconds:.1f} seconds "
            f"(limit {config.stale_after_seconds:.1f})."
        )
    if age_seconds < -5:
        raise RuntimeError(
            f"Band reading timestamp is {abs(age_seconds):.1f} seconds in the future."
        )
    if reading.values.get("schemaVersion") != 2:
        raise RuntimeError("Expected telemetry schemaVersion 2.")
    sensors = reading.values.get("sensors")
    if not isinstance(sensors, dict) or not sensors:
        raise RuntimeError("Expected nonempty sensors object.")
    for name, sensor in sensors.items():
        if not isinstance(sensor, dict):
            raise RuntimeError(f"Invalid sensor envelope: {name}")
        if sensor.get("status") == "fresh":
            age = sensor.get("ageMs")
            limit = sensor.get("staleAfterMs")
            if not isinstance(age, (float, int)) or not isinstance(limit, (float, int)):
                raise RuntimeError(f"Missing sensor freshness metadata: {name}")
            if not math.isfinite(age) or not math.isfinite(limit) or age < 0 or limit <= 0:
                raise RuntimeError(f"Invalid sensor freshness metadata: {name}")
            if age + max(age_seconds, 0) * 1000 > limit:
                sensor["status"] = "stale"
                sensor["value"] = None
        elif sensor.get("value") is not None:
            raise RuntimeError(f"Non-fresh sensor contains a value: {name}")


def deliver_pending(config: GatewayConfig, outbox: Outbox, client: mqtt.Client) -> bool:
    record = outbox.peek()
    if record is None:
        return False
    sequence, topic, payload = record
    result = client.publish(topic, payload=payload, qos=1)
    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        raise RuntimeError(f"MQTT publish failed with result code {result.rc}")
    result.wait_for_publish(timeout=config.mqtt_publish_timeout_seconds)
    if not result.is_published():
        raise TimeoutError("MQTT PUBACK timeout; message remains in the outbox.")
    archive_path = Path(config.telemetry_archive_path)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    with archive_path.open("a", encoding="utf-8") as archive:
        archive.write(payload + "\n")
    outbox.acknowledge(sequence)
    LOGGER.info("Broker acknowledged queued telemetry %s", sequence)
    return True


def configure_logging(log_path: str) -> None:
    path = Path(log_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter(
        "%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    file_handler = RotatingFileHandler(
        path,
        maxBytes=5 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)
    console_handler = logging.StreamHandler()
    console_handler.setFormatter(formatter)
    logging.basicConfig(
        level=logging.INFO,
        handlers=[file_handler, console_handler],
    )


def publisher(
    config: GatewayConfig, stop: Event, errors: Queue[Exception],
    max_consecutive_failures: int,
) -> None:
    try:
        _publish_loop(config, stop, max_consecutive_failures)
    except Exception as error:
        LOGGER.exception("Publisher stopped; queued data is retained")
        errors.put(error)
        stop.set()


def _publish_loop(
    config: GatewayConfig, stop: Event, max_consecutive_failures: int,
) -> None:
    outbox = Outbox(config.outbox_path, config.outbox_max_records)
    client = create_mqtt_client(config)

    def on_connect(connected_client, userdata, flags, reason_code, properties):
        if reason_code.is_failure:
            LOGGER.error("Broker rejected connection: %s", reason_code)
        else:
            LOGGER.info("MQTT connected; draining durable outbox")

    client.on_connect = on_connect
    client.enable_logger(LOGGER)
    client.reconnect_delay_set(min_delay=1, max_delay=30)
    client.max_queued_messages_set(1)
    client.connect_async(config.mqtt_host, config.mqtt_port)
    client.loop_start()
    failures = 0
    try:
        while not stop.is_set():
            try:
                if not client.is_connected():
                    raise ConnectionError("MQTT unavailable; collection continues into the outbox")
                if not deliver_pending(config, outbox, client):
                    stop.wait(0.2)
                failures = 0
            except (OSError, RuntimeError, TimeoutError) as error:
                failures += 1
                LOGGER.error("Delivery attempt %s failed: %s", failures, error)
                if max_consecutive_failures and failures >= max_consecutive_failures:
                    raise RuntimeError("MQTT consecutive failure limit reached.") from error
                stop.wait(min(30, 2 ** min(failures, 5)))
    finally:
        client.disconnect()
        client.loop_stop()
        outbox.close()


def collect(
    config: GatewayConfig, adapter: SidecarBandAdapter, outbox: Outbox,
    interval: float, continuous: bool, max_messages: int, failure_limit: int,
    stop: Event,
) -> None:
    failures = 0
    count = 0
    while not stop.is_set():
        stream = adapter.stream(interval, continuous)
        try:
            while not stop.is_set():
                try:
                    reading = next(stream)
                    validate_reading(config, reading)
                except (OSError, RuntimeError) as error:
                    failures += 1
                    LOGGER.error("Band connection failed (%s): %s", failures, error)
                    if not continuous or (failure_limit and failures >= failure_limit):
                        raise
                    stop.wait(min(30, 2 ** min(failures, 5)))
                    break
                # Storage failures are fatal: never silently drop a collected reading.
                message_id = outbox.enqueue(f"{config.topic_prefix}/telemetry", reading)
                LOGGER.info("Queued telemetry %s", message_id)
                failures = 0
                count += 1
                if not continuous or (max_messages and count >= max_messages):
                    return
        finally:
            stream.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--max-messages", type=int, default=0,
        help="Stop continuous collection after N snapshots; zero means unlimited.",
    )
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="Read one Band sample and print it without connecting to MQTT.",
    )
    parser.add_argument(
        "--continuous",
        action="store_true",
        help="Keep reading and publishing telemetry until interrupted.",
    )
    parser.add_argument(
        "--interval-seconds",
        type=float,
        default=5.0,
        help="Delay between continuous telemetry cycles (default: 5).",
    )
    parser.add_argument(
        "--max-consecutive-failures",
        type=int,
        default=0,
        help="Stop after this many failures; zero means retry indefinitely.",
    )
    args = parser.parse_args()
    if not math.isfinite(args.interval_seconds) or args.interval_seconds <= 0:
        parser.error("--interval-seconds must be greater than zero")
    if args.max_consecutive_failures < 0:
        parser.error("--max-consecutive-failures cannot be negative")
    if args.max_messages < 0:
        parser.error("--max-messages cannot be negative")

    config = GatewayConfig.from_environment()
    configure_logging(config.log_path)
    adapter = SidecarBandAdapter(
        device_id=config.device_id,
        sidecar_path=config.band_sidecar_path,
    )
    if args.read_only:
        print(adapter.read().to_json())
        return

    outbox = Outbox(config.outbox_path, config.outbox_max_records)
    stop = Event()
    errors: Queue[Exception] = Queue()
    worker = Thread(
        target=publisher,
        args=(config, stop, errors, args.max_consecutive_failures),
        daemon=True,
    )
    worker.start()
    try:
        collect(
            config, adapter, outbox, args.interval_seconds,
            args.continuous, args.max_messages, args.max_consecutive_failures, stop,
        )
        if not errors.empty():
            raise RuntimeError("Publisher failed.") from errors.get()
        deadline = time.monotonic() + config.mqtt_publish_timeout_seconds * 2
        while outbox.peek() is not None and time.monotonic() < deadline and not stop.wait(0.2):
            pass
        if outbox.peek() is not None:
            raise RuntimeError("Delivery incomplete; messages retained in durable outbox.")
    except KeyboardInterrupt:
        LOGGER.info("Stopping Band gateway")
    finally:
        stop.set()
        worker.join(timeout=config.mqtt_publish_timeout_seconds + 5)
        outbox.close()


if __name__ == "__main__":
    main()
