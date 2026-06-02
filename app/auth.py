"""API key authentication for data endpoints."""

from __future__ import annotations

import hashlib
import hmac
import os

from fastapi import Header

from .errors import APIError


def _configured_keys() -> list[str]:
    raw = os.environ.get("FPDS_ANALYTICS_API_KEYS", "")
    return [item.strip() for item in raw.split(",") if item.strip()]


def _auth_required() -> bool:
    return os.environ.get("FPDS_ANALYTICS_REQUIRE_AUTH", "1") != "0"


def require_api_key(x_api_key: str | None = Header(default=None, alias="X-Api-Key")) -> str:
    """Require an API key unless auth is explicitly disabled for local dev."""
    if not _auth_required():
        return "local-dev"

    keys = _configured_keys()
    if not keys:
        raise APIError(503, "api_key_store_unconfigured", "API key validation is not configured.", error_type="service_unavailable")
    if not x_api_key:
        raise APIError(401, "missing_api_key", "Missing X-Api-Key header.", param="X-Api-Key")

    for key in keys:
        if hmac.compare_digest(x_api_key, key):
            return api_key_id(x_api_key)
    raise APIError(403, "invalid_api_key", "The supplied API key is not valid.", param="X-Api-Key")


def api_key_id(api_key: str) -> str:
    """Stable non-secret key identifier for logs."""
    digest = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    return f"key_{digest[:12]}"
