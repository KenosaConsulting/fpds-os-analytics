"""Internal client for the MCP server when running inside the API process.

Uses Starlette's TestClient to route requests through the ASGI app directly,
bypassing all network I/O. This eliminates the self-referencing HTTP round-trip
that caused timeouts on Render.

Used by the remote MCP endpoint (app/routes/mcp.py).
"""

from __future__ import annotations

from typing import Any

from starlette.testclient import TestClient

from mcp.fpds_mcp_server import FPDSClient


_client: TestClient | None = None


def _get_client() -> TestClient:
    global _client
    if _client is None:
        from app.main import app
        _client = TestClient(app, raise_server_exceptions=False)
    return _client


class InternalFPDSClient(FPDSClient):
    """FPDSClient that calls the ASGI app directly — no network I/O."""

    def __init__(self, api_key: str | None = None) -> None:
        self.api_key = api_key

    @property
    def has_api_key(self) -> bool:
        return bool(self.api_key)

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        params = params or {}
        clean = {k: v for k, v in params.items() if v is not None and v != ""}

        headers = {}
        if self.api_key:
            headers["X-Api-Key"] = self.api_key

        client = _get_client()
        response = client.get(path, params=clean, headers=headers)

        if response.status_code >= 400:
            raise RuntimeError(
                f"Internal API call failed: {response.status_code} {response.text[:500]}"
            )

        return response.json()
