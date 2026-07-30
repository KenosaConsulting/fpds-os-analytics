"""API key self-service routes.

POST /v1/keys/request — public signup endpoint.
GET  /v1/signup         — HTML signup form for browser-based signup.

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
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, field_validator

from app.db import db_cursor
from app.errors import APIError

logger = logging.getLogger("fpds.keys")
router = APIRouter(prefix="/v1")

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

SIGNUP_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Get an API Key — FPDS Analytics</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
               background: #0f172a; color: #e2e8f0; display: flex; justify-content: center;
               align-items: center; min-height: 100vh; margin: 0; }
        .card { background: #1e293b; border-radius: 12px; padding: 2rem; max-width: 520px; width: 100%; box-shadow: 0 8px 32px rgba(0,0,0,0.3); }
        h1 { color: #60a5fa; font-size: 1.5rem; margin: 0 0 0.5rem; }
        .subtitle { color: #94a3b8; font-size: 0.9rem; line-height: 1.5; margin-bottom: 1.5rem; }
        label { display: block; color: #cbd5e1; font-size: 0.85rem; margin: 1rem 0 0.25rem; }
        input[type="email"], input[type="text"] { width: 100%; padding: 0.6rem; border: 1px solid #334155;
            border-radius: 6px; background: #0f172a; color: #e2e8f0; font-size: 0.9rem; box-sizing: border-box; }
        input:focus { outline: none; border-color: #60a5fa; }
        button { width: 100%; padding: 0.7rem; background: #3b82f6; color: white; border: none;
            border-radius: 6px; font-size: 1rem; font-weight: 600; cursor: pointer; margin-top: 1.5rem; }
        button:hover { background: #2563eb; }
        button:disabled { background: #475569; cursor: not-allowed; }
        .result { margin-top: 1.5rem; display: none; }
        .result.success .key-box { background: #065f46; border: 1px solid #059669; border-radius: 8px; padding: 1rem; }
        .result.success .api-key { font-family: monospace; font-size: 0.82rem; color: #6ee7b7; word-break: break-all; }
        .result.success .copy-btn { margin-top: 0.5rem; padding: 0.35rem 0.8rem; background: #059669; color: white;
            border: none; border-radius: 4px; font-size: 0.8rem; cursor: pointer; width: auto; }
        .result.success .copy-btn:hover { background: #047857; }
        .result.success .warning { color: #fbbf24; font-size: 0.82rem; margin-top: 0.5rem; font-weight: 600; }
        .result.success .example { background: #0f172a; border-radius: 6px; padding: 0.7rem; margin-top: 0.7rem; }
        .result.success .example code { font-size: 0.78rem; color: #94a3b8; word-break: break-all; }
        .result.success .limits { color: #94a3b8; font-size: 0.8rem; margin-top: 0.7rem; }
        .result.error { background: #7f1d1d; border: 1px solid #dc2626; border-radius: 8px; padding: 1rem; color: #fca5a5; font-size: 0.85rem; }
        .footer { text-align: center; margin-top: 1.5rem; font-size: 0.75rem; color: #64748b; }
        .field-hint { color: #64748b; font-size: 0.75rem; margin-top: 0.15rem; }
    </style>
</head>
<body>
    <div class="card">
        <h1>Get an API Key</h1>
        <p class="subtitle">Free beta-tier access to 88 federal procurement analytics datasets. 250 rows/request, 300 requests/minute, no credit card required.</p>
        <form id="signup-form">
            <label for="email">Email <span style="color:#f87171">*</span></label>
            <input type="email" name="email" id="email" placeholder="you@example.com" required autocomplete="email">
            <div class="field-hint">We'll never spam you. Used for key recovery and limit enforcement.</div>
            <label for="name">Name (optional)</label>
            <input type="text" name="name" id="name" placeholder="Your name">
            <label for="organization">Organization (optional)</label>
            <input type="text" name="organization" id="organization" placeholder="Your company or team">
            <label for="intended_use">What will you use the API for? (optional)</label>
            <input type="text" name="intended_use" id="intended_use" placeholder="e.g. market research, capture planning">
            <button type="submit" id="submit-btn">Request API Key</button>
        </form>
        <div class="result" id="result"></div>
        <div class="footer">
            <p>Your key is SHA-256 hashed and never stored in plaintext.<br>
            See the <a href="https://analytics-api.kenosaconsulting.com/v1/catalog" style="color:#60a5fa">API catalog</a> for available datasets.</p>
        </div>
    </div>
    <script>
        const form = document.getElementById('signup-form');
        const result = document.getElementById('result');
        const btn = document.getElementById('submit-btn');
        form.addEventListener('submit', async (e) => {
            e.preventDefault();
            btn.disabled = true;
            btn.textContent = 'Requesting...';
            result.style.display = 'none';
            try {
                const body = { email: form.email.value.trim() };
                if (form.name.value.trim()) body.name = form.name.value.trim();
                if (form.organization.value.trim()) body.organization = form.organization.value.trim();
                if (form.intended_use.value.trim()) body.intended_use = form.intended_use.value.trim();
                const res = await fetch('/v1/keys/request', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(body)
                });
                const data = await res.json();
                if (res.ok) {
                    const limits = `Tier: ${data.tier} · ${data.limits.max_rows_per_request} rows/req · ${data.limits.rate_limit_per_minute} req/min · Expires: ${data.expires_at ? data.expires_at.split('T')[0] : 'never'}`;
                    const example = `curl -H "X-Api-Key: ${data.api_key}" https://analytics-api.kenosaconsulting.com/v1/datasets/pricing.trend_fy/rows?limit=10`;
                    result.className = 'result success';
                    result.innerHTML = `<div class="key-box">
                        <div class="api-key" id="the-key">${data.api_key}</div>
                        <button class="copy-btn" onclick="navigator.clipboard.writeText(document.getElementById('the-key').textContent);this.textContent='Copied!';setTimeout(()=>this.textContent='Copy',2000)">Copy</button>
                        <div class="warning">&#9888; Save this key now — it will never be shown again.</div>
                        <div class="example"><code>${example}</code></div>
                        <div class="limits">${limits}</div>
                    </div>`;
                } else {
                    const msg = data.detail ? (Array.isArray(data.detail) ? data.detail.map(d=>d.msg).join('; ') : JSON.stringify(data.detail)) : (data.error ? data.error.message : 'Unknown error');
                    result.className = 'result error';
                    result.innerHTML = msg;
                }
            } catch (err) {
                result.className = 'result error';
                result.innerHTML = 'Network error. Please try again.';
            }
            result.style.display = 'block';
            btn.disabled = false;
            btn.textContent = 'Request API Key';
        });
    </script>
</body>
</html>"""


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
# Endpoints
# ---------------------------------------------------------------------------

@router.get("/signup")
def signup_page(request: Request) -> HTMLResponse:
    """Browser-based API key signup form."""
    return HTMLResponse(content=SIGNUP_HTML)


@router.post("/keys/request")
def request_api_key(body: KeyRequest, request: Request) -> dict:
    """Self-service API key signup. Returns a beta-tier key."""

    # Check for duplicate email (max 3 active keys per email)
    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT count(*)::int AS active_count FROM api_admin.api_keys "
                "WHERE user_email = %s AND is_active = TRUE AND (expires_at IS NULL OR expires_at > now())",
                (body.email,),
            )
            row = cur.fetchone()
    except Exception as exc:
        logger.error("DB check failed: %s", exc)
        raise APIError(503, "service_unavailable", "Key provisioning is temporarily unavailable.") from exc

    if row and row["active_count"] >= 3:
        raise APIError(
            409,
            "too_many_keys",
            "This email already has the maximum of 3 active API keys. "
            "Contact support@kenosaconsulting.com if you need additional keys.",
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


class KeyManageRequest(BaseModel):
    email: str
    key_prefix: str | None = None

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        v = v.strip().lower()
        if not EMAIL_RE.match(v):
            raise ValueError("Invalid email address.")
        return v


@router.post("/keys/list")
def list_api_keys(body: KeyManageRequest, request: Request) -> dict:
    """List active API keys for an email address. Never returns plaintext keys."""
    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT key_prefix, tier, max_rows_per_request, rate_limit_per_minute, "
                "created_at, expires_at, last_used_at, notes "
                "FROM api_admin.api_keys "
                "WHERE user_email = %s AND is_active = TRUE "
                "AND (expires_at IS NULL OR expires_at > now()) "
                "ORDER BY created_at DESC",
                (body.email,),
            )
            rows = cur.fetchall()
    except Exception as exc:
        logger.error("Key list failed: %s", exc)
        raise APIError(503, "service_unavailable", "Key lookup is temporarily unavailable.") from exc

    return {
        "email": body.email,
        "active_count": len(rows),
        "keys": [
            {
                "key_prefix": r["key_prefix"],
                "tier": r["tier"],
                "created_at": r["created_at"].isoformat() if r["created_at"] else None,
                "expires_at": r["expires_at"].isoformat() if r["expires_at"] else None,
                "last_used_at": r["last_used_at"].isoformat() if r["last_used_at"] else None,
                "limits": {
                    "max_rows_per_request": r["max_rows_per_request"],
                    "rate_limit_per_minute": r["rate_limit_per_minute"],
                },
            }
            for r in rows
        ],
    }


@router.post("/keys/revoke")
def revoke_api_key(body: KeyManageRequest, request: Request) -> dict:
    """Revoke an API key by email + key_prefix. The email is a verification gate."""
    if not body.key_prefix:
        raise APIError(400, "missing_key_prefix", "Provide the key_prefix of the key to revoke.", param="key_prefix")

    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT id, key_prefix FROM api_admin.api_keys "
                "WHERE user_email = %s AND key_prefix = %s AND is_active = TRUE "
                "AND (expires_at IS NULL OR expires_at > now()) AND revoked_at IS NULL",
                (body.email, body.key_prefix),
            )
            key = cur.fetchone()
            if not key:
                raise APIError(
                    404,
                    "key_not_found",
                    "No active key found matching that email and key prefix.",
                    param="key_prefix",
                )

            cur.execute(
                "UPDATE api_admin.api_keys SET is_active = FALSE, revoked_at = now() "
                "WHERE id = %s AND is_active = TRUE",
                (key["id"],),
            )
    except APIError:
        raise
    except Exception as exc:
        logger.error("Key revoke failed: %s", exc)
        raise APIError(503, "service_unavailable", "Key revocation is temporarily unavailable.") from exc

    return {
        "status": "revoked",
        "key_prefix": body.key_prefix,
        "email": body.email,
    }
