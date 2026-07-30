"""Transactional email delivery for API key signup and notifications.

Uses standard SMTP — works with Gmail, SendGrid, Mailgun, Resend, Postmark,
or any SMTP relay. Configure via environment variables:

    FPDS_SMTP_HOST=smtp.example.com
    FPDS_SMTP_PORT=587
    FPDS_SMTP_USER=user
    FPDS_SMTP_PASS=pass
    FPDS_SMTP_FROM=no-reply@kenosaconsulting.com
    FPDS_SMTP_USE_TLS=1

If SMTP is not configured, sending is silently skipped (dev-friendly).
"""

from __future__ import annotations

import logging
import os
import smtplib
import threading
from email.mime.text import MIMEText

logger = logging.getLogger("fpds.email")


def _smtp_config() -> dict[str, str | int | bool] | None:
    host = os.environ.get("FPDS_SMTP_HOST", "").strip()
    if not host:
        return None
    return {
        "host": host,
        "port": int(os.environ.get("FPDS_SMTP_PORT", "587")),
        "user": os.environ.get("FPDS_SMTP_USER", "").strip(),
        "password": os.environ.get("FPDS_SMTP_PASS", ""),
        "from_addr": os.environ.get("FPDS_SMTP_FROM", "no-reply@kenosaconsulting.com").strip(),
        "use_tls": os.environ.get("FPDS_SMTP_USE_TLS", "1") != "0",
    }


def send_api_key_email(to_email: str, api_key: str, tier: str, expires_at: str | None) -> None:
    """Send the API key to the user's email. Runs in a background thread."""
    config = _smtp_config()
    if not config:
        logger.debug("SMTP not configured — skipping email to %s", to_email)
        return

    expiry_str = f"Expires: {expires_at.split('T')[0]}" if expires_at else "No expiration"
    body = f"""Your FPDS Analytics API Key

Tier: {tier}
{expiry_str}

Your API key:

    {api_key}

Use it with the X-Api-Key header:

    curl -H "X-Api-Key: {api_key}" \\
      https://analytics-api.kenosaconsulting.com/v1/datasets/pricing.trend_fy/rows?limit=10

Browse datasets: https://analytics-api.kenosaconsulting.com/v1/catalog
Manage keys:    https://analytics-api.kenosaconsulting.com/v1/signup

- Kenosa Consulting / FPDS Analytics
"""

    msg = MIMEText(body)
    msg["Subject"] = "Your FPDS Analytics API Key"
    msg["From"] = config["from_addr"]
    msg["To"] = to_email

    def _send():
        try:
            if config["use_tls"]:
                with smtplib.SMTP(config["host"], int(config["port"]), timeout=15) as s:
                    s.starttls()
                    if config["user"]:
                        s.login(config["user"], config["password"])
                    s.send_message(msg)
            else:
                with smtplib.SMTP(config["host"], int(config["port"]), timeout=15) as s:
                    if config["user"]:
                        s.login(config["user"], config["password"])
                    s.send_message(msg)
            logger.info("API key email sent to %s", to_email)
        except Exception:
            logger.exception("Failed to send API key email to %s", to_email)

    threading.Thread(target=_send, daemon=True).start()
