"""Environment-based gateway configuration."""

from dataclasses import dataclass
import os

from dotenv import load_dotenv


def _bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes"}


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"{name} must be set")
    return value


@dataclass(frozen=True)
class GatewayConfig:
    device_id: str
    band_sidecar_path: str
    mqtt_host: str
    mqtt_port: int
    mqtt_tls: bool
    mqtt_tls_insecure: bool
    mqtt_username: str | None
    mqtt_password: str | None
    mqtt_ca_cert: str | None
    mqtt_client_id: str
    topic_prefix: str
    log_path: str
    telemetry_archive_path: str
    stale_after_seconds: float

    @classmethod
    def from_environment(cls) -> "GatewayConfig":
        load_dotenv()
        return cls(
            device_id=_required("BAND_DEVICE_ID"),
            band_sidecar_path=_required("BAND_SIDECAR_PATH"),
            mqtt_host=_required("MQTT_HOST"),
            mqtt_port=int(os.getenv("MQTT_PORT", "18883")),
            mqtt_tls=_bool("MQTT_TLS", True),
            mqtt_tls_insecure=_bool("MQTT_TLS_INSECURE", False),
            mqtt_username=os.getenv("MQTT_USERNAME") or None,
            mqtt_password=os.getenv("MQTT_PASSWORD") or None,
            mqtt_ca_cert=os.getenv("MQTT_CA_CERT") or None,
            mqtt_client_id=_required("MQTT_CLIENT_ID"),
            topic_prefix=_required("MQTT_TOPIC_PREFIX").rstrip("/"),
            log_path=os.getenv("BAND_LOG_PATH", "logs/band-gateway.log"),
            telemetry_archive_path=os.getenv(
                "BAND_TELEMETRY_ARCHIVE_PATH",
                "data/telemetry.jsonl",
            ),
            stale_after_seconds=float(
                os.getenv("BAND_STALE_AFTER_SECONDS", "30")
            ),
        )
