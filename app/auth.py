"""API key authentication for data endpoints."""

from __future__ import annotations

import hashlib
import hmac
import os
from dataclasses import dataclass

from fastapi import Header

from .errors import APIError


@dataclass(frozen=True)
class APIAccess:
    key_id: str
    is_authenticated: bool


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
    return int(os.environ.get("FPDS_ANALYTICS_PUBLIC_ROW_LIMIT", "25"))


def _is_placeholder(value: str) -> bool:
    return "replace_me" in value.lower() or value.lower().startswith("example_")


def optional_api_access(x_api_key: str | None = Header(default=None, alias="X-Api-Key")) -> APIAccess:
    """Allow public access without a key, but validate keys when supplied."""
    if not x_api_key:
        if public_rows_enabled():
            return APIAccess(key_id="public", is_authenticated=False)
        return APIAccess(key_id=require_api_key(x_api_key), is_authenticated=True)
    return APIAccess(key_id=require_api_key(x_api_key), is_authenticated=True)


def require_api_key(x_api_key: str | None = Header(default=None, alias="X-Api-Key")) -> str:
    """Require an API key for paid/higher-volume or non-public endpoints."""
    if not _auth_required():
        return "local-dev"

    keys = _configured_keys()
    key_hashes = _configured_key_hashes()
    if any(_is_placeholder(key) for key in keys):
        raise APIError(503, "api_key_store_unconfigured", "API key validation is not configured.", error_type="service_unavailable")
    if not keys and not key_hashes:
        raise APIError(503, "api_key_store_unconfigured", "API key validation is not configured.", error_type="service_unavailable")
    if not x_api_key:
        raise APIError(401, "missing_api_key", "Missing X-Api-Key header.", param="X-Api-Key")

    for key in keys:
        if hmac.compare_digest(x_api_key, key):
            return api_key_id(x_api_key)
    candidate_hash = hashlib.sha256(x_api_key.encode("utf-8")).hexdigest()
    for key_hash in key_hashes:
        if hmac.compare_digest(candidate_hash, key_hash):
            return f"key_{key_hash[:12]}"
    raise APIError(403, "invalid_api_key", "The supplied API key is not valid.", param="X-Api-Key")


def api_key_id(api_key: str) -> str:
    """Stable non-secret key identifier for logs."""
    digest = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    return f"key_{digest[:12]}"
