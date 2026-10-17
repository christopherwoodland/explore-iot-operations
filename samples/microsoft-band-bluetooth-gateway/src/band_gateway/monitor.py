"""Subscribe to one Band MQTT message for connectivity verification."""

from __future__ import annotations

import argparse
from threading import Event

import paho.mqtt.client as mqtt

from .config import GatewayConfig
from .main import create_mqtt_client


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--topic")
    args = parser.parse_args()

    config = GatewayConfig.from_environment()
    client = create_mqtt_client(
        config,
        client_id=f"{config.mqtt_client_id}-monitor",
    )
    received = Event()
    connection_error: list[str] = []

    def on_connect(
        connected_client: mqtt.Client,
        userdata: object,
        flags: mqtt.ConnectFlags,
        reason_code: mqtt.ReasonCode,
        properties: mqtt.Properties | None,
    ) -> None:
        if reason_code.is_failure:
            connection_error.append(str(reason_code))
            received.set()
            return
        connected_client.subscribe(
            args.topic or f"{config.topic_prefix}/telemetry",
            qos=1,
        )

    def on_message(
        connected_client: mqtt.Client,
        userdata: object,
        message: mqtt.MQTTMessage,
    ) -> None:
        print(message.payload.decode("utf-8"))
        received.set()

    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(config.mqtt_host, config.mqtt_port)
    client.loop_start()
    try:
        if not received.wait(args.timeout):
            raise TimeoutError("Timed out waiting for Band MQTT telemetry.")
        if connection_error:
            raise RuntimeError(
                f"MQTT connection failed: {connection_error[0]}"
            )
    finally:
        client.loop_stop()
        client.disconnect()


if __name__ == "__main__":
    main()
