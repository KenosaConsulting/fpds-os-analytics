"""API key authentication for data endpoints.

Supports two validation backends:
  1. Supabase api_admin schema (primary) — keys provisioned via create_api_key()
  2. Environment variable keys (fallback) — FPDS_ANALYTICS_API_KEYS / _KEY_HASHES

The Supabase backend is used when ANALYTICS_DATABASE_URL or DB_HOST is configured.
Env-var keys are checked as a fallback if the Supabase lookup returns no match,
ensuring backward compatibility during migration.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import os
from dataclasses import dataclass, field

from fastapi import Header

from .errors import APIError

logger = logging.getLogger("fpds.auth")

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class APIAccess:
    key_id: str
    is_authenticated: bool
    tier: str = "public"
    max_rows_per_request: int = field(default_factory=lambda: public_row_limit())
    rate_limited: bool = False


# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

def _configured_keys() -> list[str]:
    raw = os.environ.get("FPDS_ANALYTICS_API_KEYS", "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def _configured_key_hashes() -> list[str]:
    raw = os.environ.get("FPDS_ANALYTICS_API_KEY_HASHES", "")
    return [item.strip().lower() for item in raw.split(",") if item.strip()]


def _auth_required() -> bool:
    return os.environ.get("FPDS_ANALYTICS_REQUIRE_AUTH", "1") != "0"


def public_rows_enabled() -> bool:
    return os.environ.get("FPDS_ANALYTICS_PUBLIC_ROWS_ENABLED", "1") != "0"


def public_row_limit() -> int:
    return int(os.environ.get("FPDS_ANALYTICS_PUBLIC_ROW_LIMIT", "100"))


def _is_placeholder(value: str) -> bool:
    return "replace_me" in value.lower() or value.lower().startswith("example_")


# ---------------------------------------------------------------------------
# Supabase backend
# ---------------------------------------------------------------------------

def _supabase_validate(api_key: str, endpoint: str | None = None, ip: str | None = None) -> APIAccess | None:
    """Validate a key against api_admin.validate_api_key(). Returns None if
    Supabase is not configured or the key doesn't match any Supabase-managed key."""
    try:
        from .db import db_cursor
    except Exception:
        return None

    try:
        with db_cursor(read_only=False) as cur:
            cur.execute(
                "SELECT api_key_id, tier, max_rows_per_request, rate_limited, key_prefix "
                "FROM api_admin.validate_api_key(%s, %s, %s)",
                (api_key, endpoint, ip),
            )
            row = cur.fetchone()
    except Exception as exc:
        logger.warning("Supabase key validation failed: %s", exc)
        return None

    if not row:
        return None

    if row["rate_limited"]:
        raise APIError(
            429,
            "rate_limit_exceeded",
            "API rate limit exceeded. Please wait and retry.",
            error_type="rate_limit",
            extra={"tier": row["tier"], "api_key_id": row["key_prefix"]},
        )

    return APIAccess(
        key_id=row["key_prefix"],
        is_authenticated=True,
        tier=row["tier"],
        max_rows_per_request=row["max_rows_per_request"],
    )


# ---------------------------------------------------------------------------
# Env-var fallback backend
# ---------------------------------------------------------------------------

_ENV_KEY_TIER = "internal"
_ENV_KEY_MAX_ROWS = 10000

def _envvar_validate(api_key: str) -> APIAccess | None:
    """Validate against FPDS_ANALYTICS_API_KEYS and _KEY_HASHES env vars.
    Returns None if no match. This is the legacy path kept for backward compat."""
    keys = _configured_keys()
    key_hashes = _configured_key_hashes()

    if not keys and not key_hashes:
        return None

    # Skip placeholder keys
    if any(_is_placeholder(key) for key in keys):
        return None

    # Direct comparison
    for key in keys:
        if hmac.compare_digest(api_key, key):
            return APIAccess(
                key_id=api_key_id(api_key),
                is_authenticated=True,
                tier=_ENV_KEY_TIER,
                max_rows_per_request=_ENV_KEY_MAX_ROWS,
            )

    # Hash comparison
    candidate_hash = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    for key_hash in key_hashes:
        if hmac.compare_digest(candidate_hash, key_hash):
            return APIAccess(
                key_id=f"key_{key_hash[:12]}",
                is_authenticated=True,
                tier=_ENV_KEY_TIER,
                max_rows_per_request=_ENV_KEY_MAX_ROWS,
            )

    return None


# ---------------------------------------------------------------------------
# Public API — FastAPI dependencies
# ---------------------------------------------------------------------------

def optional_api_access(x_api_key: str | None = Header(default=None, alias="X-Api-Key")) -> APIAccess:
    """Allow public access without a key, but validate keys when supplied.

    Resolution order when a key is present:
      1. Supabase api_admin (primary)
      2. Env-var keys (fallback)
      3. Reject as invalid
    """
    if not x_api_key:
        if public_rows_enabled():
            return APIAccess(key_id="public", is_authenticated=False)
        # Public rows disabled — require a key
        raise APIError(401, "missing_api_key", "API key required. Pass X-Api-Key header.", param="X-Api-Key")

    # Try Supabase first
    access = _supabase_validate(x_api_key)
    if access is not None:
        return access

    # Try env-var fallback
    access = _envvar_validate(x_api_key)
    if access is not None:
        return access

    raise APIError(403, "invalid_api_key", "The supplied API key is not valid.", param="X-Api-Key")


def require_api_key(x_api_key: str | None = Header(default=None, alias="X-Api-Key")) -> str:
    """Require an API key for endpoints that don't allow public access."""
    if not _auth_required():
        return "local-dev"

    if not x_api_key:
        raise APIError(401, "missing_api_key", "Missing X-Api-Key header.", param="X-Api-Key")

    access = optional_api_access(x_api_key)
    if not access.is_authenticated:
        raise APIError(401, "missing_api_key", "Missing X-Api-Key header.", param="X-Api-Key")
    return access.key_id


def api_key_id(api_key: str) -> str:
    """Stable non-secret key identifier for logs."""
    digest = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    return f"key_{digest[:12]}"
