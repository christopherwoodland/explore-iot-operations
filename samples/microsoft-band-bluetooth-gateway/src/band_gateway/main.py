"""Host-side gateway entry point."""

from __future__ import annotations

import argparse
import logging
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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--read-only",
        action="store_true",
        help="Read one Band sample and print it without connecting to MQTT.",
    )
    args = parser.parse_args()

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
    client.connect(config.mqtt_host, config.mqtt_port)
    client.loop_start()
    try:
        publish_once(config, adapter, client)
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
