"""Host-side gateway entry point."""

from __future__ import annotations

import argparse
import logging
import time
from typing import Protocol

import paho.mqtt.client as mqtt

from .config import GatewayConfig
from .models import BandTelemetry
from .sidecar_adapter import SidecarBandAdapter

LOGGER = logging.getLogger("band_gateway")


class BandAdapter(Protocol):
    """Bluetooth adapter boundary for a Microsoft Band implementation."""

    def read(self) -> BandTelemetry:
        """Return one reading, or raise an explicit connection error."""


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


def publish_once(
    config: GatewayConfig, adapter: BandAdapter, client: mqtt.Client
) -> None:
    reading = adapter.read()
    result = client.publish(
        f"{config.topic_prefix}/telemetry",
        payload=reading.to_json(),
        qos=1,
    )
    result.wait_for_publish()
    if result.rc != mqtt.MQTT_ERR_SUCCESS:
        raise RuntimeError(f"MQTT publish failed with result code {result.rc}")


def publish_continuously(
    config: GatewayConfig,
    adapter: BandAdapter,
    client: mqtt.Client,
    interval_seconds: float,
    max_consecutive_failures: int,
) -> None:
    consecutive_failures = 0
    while True:
        try:
            if not client.is_connected():
                LOGGER.info("Reconnecting to MQTT broker")
                client.reconnect()
            publish_once(config, adapter, client)
            consecutive_failures = 0
            LOGGER.info("Published Band telemetry")
        except (OSError, RuntimeError, TimeoutError) as error:
            consecutive_failures += 1
            LOGGER.error(
                "Telemetry cycle failed (%s/%s): %s",
                consecutive_failures,
                max_consecutive_failures or "unlimited",
                error,
            )
            if (
                max_consecutive_failures > 0
                and consecutive_failures >= max_consecutive_failures
            ):
                raise RuntimeError(
                    "Stopping after the configured consecutive failure limit."
                ) from error
        time.sleep(interval_seconds)


def connect_with_retry(
        config: GatewayConfig,
        client: mqtt.Client,
        max_consecutive_failures: int,
) -> None:
        consecutive_failures = 0
        while True:
            try:
                client.connect(config.mqtt_host, config.mqtt_port)
                return
            except (OSError, RuntimeError) as error:
                consecutive_failures += 1
                LOGGER.error(
                    "MQTT connection failed (%s/%s): %s",
                    consecutive_failures,
                    max_consecutive_failures or "unlimited",
                    error,
                )
                if (
                    max_consecutive_failures > 0
                    and consecutive_failures >= max_consecutive_failures
                ):
                    raise RuntimeError(
                        "Stopping after the configured MQTT connection failure limit."
                    ) from error
                time.sleep(5)


def main() -> None:
    parser = argparse.ArgumentParser()
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
    if args.interval_seconds <= 0:
        parser.error("--interval-seconds must be greater than zero")
    if args.max_consecutive_failures < 0:
        parser.error("--max-consecutive-failures cannot be negative")

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    config = GatewayConfig.from_environment()
    adapter = SidecarBandAdapter(
        device_id=config.device_id,
        sidecar_path=config.band_sidecar_path,
    )
    if args.read_only:
        print(adapter.read().to_json())
        return

    client = create_mqtt_client(config)
    LOGGER.info("Connecting to MQTT broker %s:%s", config.mqtt_host, config.mqtt_port)
    if args.continuous:
        connect_with_retry(client=client, config=config, max_consecutive_failures=args.max_consecutive_failures)
    else:
        client.connect(config.mqtt_host, config.mqtt_port)
    client.loop_start()
    try:
        if args.continuous:
            publish_continuously(
                config,
                adapter,
                client,
                args.interval_seconds,
                args.max_consecutive_failures,
            )
        else:
            publish_once(config, adapter, client)
    except KeyboardInterrupt:
        LOGGER.info("Stopping Band gateway")
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
