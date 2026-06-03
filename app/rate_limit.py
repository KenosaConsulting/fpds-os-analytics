"""Simple API rate limiting.

Redis makes the limiter shared across workers/instances. Without Redis, the
limiter falls back to per-process memory, which is useful for local testing but
not sufficient as the only public-launch control.
"""

from __future__ import annotations

import hashlib
import os
import time
from dataclasses import dataclass
from threading import Lock
from typing import Callable
from uuid import uuid4

from fastapi import Request
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse, Response


@dataclass(frozen=True)
class RateLimit:
    requests: int
    window_seconds: int


class MemoryRateLimitStore:
    def __init__(self) -> None:
        self._lock = Lock()
        self._counters: dict[str, tuple[int, int]] = {}

    def increment(self, key: str, window_seconds: int) -> tuple[int, int]:
        now = int(time.time())
        window_start = now - (now % window_seconds)
        expires_at = window_start + window_seconds
        with self._lock:
            count, existing_expires_at = self._counters.get(key, (0, expires_at))
            if existing_expires_at != expires_at:
                count = 0
            count += 1
            self._counters[key] = (count, expires_at)
        return count, max(expires_at - now, 1)


class RedisRateLimitStore:
    def __init__(self, redis_url: str) -> None:
        import redis

        self._client = redis.Redis.from_url(redis_url, decode_responses=True)

    def increment(self, key: str, window_seconds: int) -> tuple[int, int]:
        count = int(self._client.incr(key))
        if count == 1:
            self._client.expire(key, window_seconds)
        ttl = self._client.ttl(key)
        return count, ttl if ttl > 0 else window_seconds


def _enabled() -> bool:
    return os.environ.get("FPDS_ANALYTICS_RATE_LIMIT_ENABLED", "1") != "0"


def _limit_from_env(prefix: str, default_requests: int, default_window: int) -> RateLimit:
    requests = int(os.environ.get(f"{prefix}_REQUESTS", str(default_requests)))
    window = int(os.environ.get(f"{prefix}_WINDOW_SECONDS", str(default_window)))
    return RateLimit(requests=requests, window_seconds=window)


def _client_ip(request: Request) -> str:
    forwarded_for = request.headers.get("x-forwarded-for")
    if forwarded_for:
        return forwarded_for.split(",", 1)[0].strip()
    if request.client:
        return request.client.host
    return "unknown"


def _hashed_token(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:24]


def _rate_key(request: Request) -> tuple[str, RateLimit]:
    api_key = request.headers.get("x-api-key")
    is_data_request = request.url.path.endswith("/rows") or request.url.path.startswith("/v1/exports")
    if api_key:
        limit = _limit_from_env("FPDS_ANALYTICS_API_KEY_RATE_LIMIT", 120, 60)
        return f"api-key:{_hashed_token(api_key)}", limit
    if is_data_request:
        limit = _limit_from_env("FPDS_ANALYTICS_UNAUTH_DATA_RATE_LIMIT", 30, 60)
        return f"unauth-data:{_hashed_token(_client_ip(request))}", limit
    limit = _limit_from_env("FPDS_ANALYTICS_PUBLIC_RATE_LIMIT", 300, 60)
    return f"public:{_hashed_token(_client_ip(request))}", limit


def _store() -> MemoryRateLimitStore | RedisRateLimitStore:
    redis_url = os.environ.get("FPDS_ANALYTICS_REDIS_URL")
    if redis_url:
        return RedisRateLimitStore(redis_url)
    return MemoryRateLimitStore()


class RateLimitMiddleware(BaseHTTPMiddleware):
    def __init__(self, app) -> None:  # type: ignore[no-untyped-def]
        super().__init__(app)
        self._store = _store()

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        if not _enabled():
            return await call_next(request)

        key, limit = _rate_key(request)
        count, retry_after = self._store.increment(key, limit.window_seconds)
        if count <= limit.requests:
            response = await call_next(request)
            response.headers["X-RateLimit-Limit"] = str(limit.requests)
            response.headers["X-RateLimit-Remaining"] = str(max(limit.requests - count, 0))
            response.headers["X-RateLimit-Reset"] = str(retry_after)
            return response

        request_id = request.headers.get("X-Request-Id") or f"req_{uuid4().hex[:24]}"
        return JSONResponse(
            status_code=429,
            headers={
                "Retry-After": str(retry_after),
                "X-RateLimit-Limit": str(limit.requests),
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": str(retry_after),
            },
            content={
                "error": {
                    "type": "rate_limit",
                    "code": "rate_limit_exceeded",
                    "message": "Rate limit exceeded. Retry after the indicated number of seconds.",
                    "param": None,
                    "request_id": request_id,
                }
            },
        )
