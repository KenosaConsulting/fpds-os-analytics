"""API error helpers."""

from __future__ import annotations

from typing import Any

from fastapi import HTTPException


class APIError(HTTPException):
    """HTTP error with a stable machine-readable code."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        error_type: str = "invalid_request",
        param: str | None = None,
        extra: dict[str, Any] | None = None,
    ) -> None:
        detail = {
            "type": error_type,
            "code": code,
            "message": message,
            "param": param,
        }
        if extra:
            detail.update(extra)
        super().__init__(
            status_code=status_code,
            detail=detail,
        )
