"""API key self-service routes.

POST /v1/keys/request — public signup endpoint.
Accepts email + optional metadata, provisions a beta-tier key,
returns the plaintext key exactly once.

Uses the standard DB connection. api_admin.create_api_key() is
SECURITY DEFINER with PUBLIC EXECUTE, so the readonly role can
call it; the function runs with postgres privileges internally.
"""

from __future__ import annotations

import logging
import re

from fastapi import APIRouter, Request
from pydantic import BaseModel, field_validator

from app.db import db_cursor
from app.errors import APIError

logger = logging.getLogger("fpds.keys")
router = APIRouter(prefix="/v1")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class KeyRequest(BaseModel):
    email: str
    name: str | None = None
    organization: str | None = None
    intended_use: str | None = None

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        v = v.strip().lower()
        if not EMAIL_RE.match(v):
            raise ValueError("Invalid email address.")
        if len(v) > 254:
            raise ValueError("Email too long.")
        return v

    @field_validator("name", "organization", "intended_use")
    @classmethod
    def sanitize_text(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = v.strip()
        if len(v) > 500:
            raise ValueError("Field too long (max 500 chars).")
        return v or None


# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------

@router.post("/keys/request")
def request_api_key(body: KeyRequest, request: Request) -> dict:
    """Self-service API key signup. Returns a beta-tier key."""

    # Check for duplicate email (one active key per email)
    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT id, key_prefix FROM api_admin.api_keys "
                "WHERE user_email = %s AND is_active = TRUE AND (expires_at IS NULL OR expires_at > now())",
                (body.email,),
            )
            existing = cur.fetchone()
    except Exception as exc:
        logger.error("DB check failed: %s", exc)
        raise APIError(503, "service_unavailable", "Key provisioning is temporarily unavailable.") from exc

    if existing:
        raise APIError(
            409,
            "key_already_exists",
            f"An active API key already exists for this email (prefix: {existing['key_prefix']}...). "
            "Contact support@kenosaconsulting.com to rotate or recover your key.",
            param="email",
        )

    # Create the key
    notes_parts = []
    if body.intended_use:
        notes_parts.append(f"Intended use: {body.intended_use}")
    notes_parts.append("Self-service signup")
    notes = " | ".join(notes_parts)

    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT * FROM api_admin.create_api_key("
                "p_tier := 'beta', p_user_email := %s, p_user_name := %s, "
                "p_organization := %s, p_notes := %s, p_expires_in_days := %s"
                ")",
                (body.email, body.name, body.organization, notes, 90),
            )
            row = cur.fetchone()
    except Exception as exc:
        logger.error("Key creation failed: %s", exc)
        raise APIError(503, "service_unavailable", "Key provisioning is temporarily unavailable.") from exc

    return {
        "status": "created",
        "api_key": row["plaintext_key"],
        "key_prefix": row["key_prefix"],
        "tier": row["tier"],
        "expires_at": row["expires_at"].isoformat() if row["expires_at"] else None,
        "limits": {
            "max_rows_per_request": 250,
            "rate_limit_per_minute": 300,
        },
        "usage": {
            "header": "X-Api-Key",
            "example": f'curl -H "X-Api-Key: {row["plaintext_key"]}" https://analytics-api.kenosaconsulting.com/v1/datasets/pricing.trend_fy/rows?limit=10',
        },
        "important": "Save this API key now — it will not be shown again.",
    }
