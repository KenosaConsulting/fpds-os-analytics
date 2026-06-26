"""Remote MCP endpoint — exposes the FPDS Analytics MCP server over HTTP.

This implements the MCP "streamable HTTP" transport (2025-03-26 spec):
clients POST JSON-RPC messages to /v1/mcp and receive JSON-RPC responses.
For SSE streaming, clients can accept text/event-stream.

Supports two authentication modes:
  1. X-Api-Key header (static key, works with Claude Desktop config)
  2. OAuth 2.0 Bearer token (works with Claude.ai custom connectors)

When no credentials are provided, the MCP endpoint returns 401 with
WWW-Authenticate header pointing to OAuth metadata — this triggers
Claude's built-in OAuth flow for the custom connector UI.
"""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from mcp.fpds_mcp_server import FPDSServer

logger = logging.getLogger("fpds.mcp")

# Latest MCP protocol version we support.
LATEST_PROTOCOL_VERSION = "2025-03-26"

# In-memory session registry.
_sessions: dict[str, dict[str, Any]] = {}

router = APIRouter(prefix="/v1/mcp", tags=["mcp"])


def _resolve_api_key(request: Request) -> str | None:
    """Resolve the effective API key from the request.
    
    Checks in order:
      1. X-Api-Key header (direct API key)
      2. Authorization: Bearer <token> — if token starts with fpds_at_,
         resolve it via OAuth store; otherwise treat as raw API key
    """
    # 1. X-Api-Key header
    api_key = request.headers.get("X-Api-Key")
    if api_key:
        return api_key

    # 2. Authorization: Bearer header
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        # If it's an OAuth access token, resolve to API key
        if token.startswith("fpds_at_"):
            from app.oauth import resolve_access_token
            resolved = resolve_access_token(token)
            if resolved:
                return resolved
            logger.warning("OAuth token invalid or expired: %s...", token[:20])
            return None
        # Otherwise treat as a raw API key (backward compat)
        return token

    return None


def _build_server(request: Request) -> FPDSServer:
    """Build an FPDSServer using the internal client (no HTTP round-trips)."""
    api_key = _resolve_api_key(request)
    from app.mcp_internal_client import InternalFPDSClient
    client = InternalFPDSClient(api_key=api_key)
    return FPDSServer(client)


def _negotiated_protocol_version(client_version: str | None) -> str:
    """Return the highest protocol version both client and server support."""
    if not client_version:
        return LATEST_PROTOCOL_VERSION
    if client_version <= LATEST_PROTOCOL_VERSION:
        return client_version
    return LATEST_PROTOCOL_VERSION


def _base_url(request: Request) -> str:
    """Determine the canonical base URL for this deployment."""
    host = request.headers.get("X-Forwarded-Host") or request.headers.get("Host", "")
    proto = request.headers.get("X-Forwarded-Proto", "https")
    if host:
        return f"{proto}://{host}"
    return "https://analytics-api.kenosaconsulting.com"


def _unauthorized_response(request: Request) -> JSONResponse:
    """Return a 401 with WWW-Authenticate header per MCP authorization spec.
    
    Claude's connector framework uses this to discover the OAuth flow.
    The resource_metadata parameter points to our protected resource metadata.
    """
    base = _base_url(request)
    return JSONResponse(
        status_code=401,
        content={
            "jsonrpc": "2.0",
            "error": {
                "code": -32001,
                "message": "Authentication required. Connect your API key via OAuth or pass X-Api-Key header.",
            },
            "id": None,
        },
        headers={
            "WWW-Authenticate": f'Bearer resource_metadata="{base}/.well-known/oauth-protected-resource"',
        },
    )


@router.get("")
@router.get("/")
def mcp_info() -> dict[str, Any]:
    """MCP endpoint discovery — returns server capabilities."""
    return {
        "name": "fpds-analytics-mcp",
        "version": "0.2.0",
        "protocolVersion": LATEST_PROTOCOL_VERSION,
        "capabilities": {
            "tools": {},
        },
        "instructions": (
            "FPDS Analytics MCP server. Use 'tools/list' to discover available "
            "tools for querying federal procurement data. API key optional for "
            "bounded queries; required for higher rate limits and larger results. "
            "Authenticate via OAuth (automatic in Claude.ai) or X-Api-Key header."
        ),
    }


@router.post("", response_model=None)
@router.post("/", response_model=None)
async def mcp_handle(
    request: Request,
) -> JSONResponse | StreamingResponse:
    """Handle a JSON-RPC 2.0 request over streamable HTTP.

    For 'initialize' requests, no auth is required — the client needs to
    discover capabilities before authenticating. For all other requests,
    auth is optional (public tier) but if Bearer token is present and
    invalid, we return 401 to trigger the OAuth flow.
    """
    try:
        body = await request.json()
    except Exception:
        return JSONResponse(
            status_code=400,
            content={
                "jsonrpc": "2.0",
                "error": {"code": -32700, "message": "Parse error"},
                "id": None,
            },
        )

    # Check if this is an initialize request — allow without auth
    method = body.get("method", "") if isinstance(body, dict) else ""
    is_initialize = method == "initialize"

    # Resolve auth
    has_auth = bool(_resolve_api_key(request))
    auth_header = request.headers.get("Authorization", "")
    has_bearer = auth_header.startswith("Bearer ")
    has_api_key = bool(request.headers.get("X-Api-Key"))

    # If client sent a Bearer token but it's invalid, return 401
    # to trigger OAuth flow (Claude uses this to discover auth endpoints)
    if has_bearer and not has_auth and not is_initialize:
        return _unauthorized_response(request)

    server = _build_server(request)
    accept = request.headers.get("Accept", "")

    # Handle batch requests
    if isinstance(body, list):
        results = []
        for msg in body:
            result = _handle_message(server, msg)
            if result is not None:
                results.append(result)
        if not results:
            return JSONResponse(content=[])
        if "text/event-stream" in accept:
            return _sse_stream(results)
        return JSONResponse(content=results)

    # Single request
    result = _handle_message(server, body)
    if result is None:
        return JSONResponse(status_code=202, content=None)

    # If this is an initialize response, attach session ID header
    if is_initialize:
        session_id = str(uuid.uuid4())
        _sessions[session_id] = {
            "created_at": json.dumps(None),
            "protocol_version": LATEST_PROTOCOL_VERSION,
        }
        resp = JSONResponse(content=result)
        resp.headers["Mcp-Session-Id"] = session_id
        return resp

    if "text/event-stream" in accept:
        return _sse_stream([result])
    return JSONResponse(content=result)


def _handle_message(server: FPDSServer, message: dict[str, Any]) -> dict[str, Any] | None:
    """Route a JSON-RPC message to the MCP server handler."""
    method = message.get("method", "")
    msg_id = message.get("id")

    if method == "initialize":
        params = message.get("params", {})
        client_version = params.get("protocolVersion")
        negotiated = _negotiated_protocol_version(client_version)
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": negotiated,
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": "fpds-analytics-mcp",
                    "version": "0.2.0",
                },
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"tools": server.tools()},
        }

    if method == "tools/call":
        params = message.get("params", {})
        tool_name = params.get("name", "")
        arguments = params.get("arguments", {})
        try:
            result = server.call_tool(tool_name, arguments)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": result,
            }
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "error": {
                    "code": -32603,
                    "message": f"Tool execution error: {exc}",
                },
            }

    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {
            "code": -32601,
            "message": f"Method not found: {method}",
        },
    }


def _sse_stream(results: list[dict[str, Any]]) -> StreamingResponse:
    """Stream results as Server-Sent Events."""
    async def generate():
        for result in results:
            yield f"data: {json.dumps(result, separators=(',', ':'))}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )
