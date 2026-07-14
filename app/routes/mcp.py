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
import time
import uuid
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from mcp.fpds_mcp_server import FPDSServer

logger = logging.getLogger("fpds.mcp")

# Latest MCP protocol version we support.
LATEST_PROTOCOL_VERSION = "2025-03-26"

# In-memory session registry (TTL: 1 hour, max 1000 entries).
_SESSIONS_MAX = 1000
_SESSIONS_TTL = 3600
_sessions: dict[str, dict[str, Any]] = {}


def _cleanup_sessions() -> None:
    """Remove expired sessions; evict oldest if still over max."""
    now = time.time()
    expired = [k for k, v in _sessions.items() if now - v.get("created_at", 0) > _SESSIONS_TTL]
    for k in expired:
        _sessions.pop(k, None)
    if len(_sessions) > _SESSIONS_MAX:
        oldest = sorted(_sessions.items(), key=lambda kv: kv[1].get("created_at", 0))
        for k, _ in oldest[:len(_sessions) - _SESSIONS_MAX]:
            _sessions.pop(k, None)

# ── Lazy authentication ─────────────────────────────────────────────────
# Tools that work without authentication (public tier).
# Any tool NOT in this set requires auth and triggers 401 + OAuth flow.
_PUBLIC_TOOLS: set[str] = {
    "fpds_list_datasets",
    "fpds_describe_dataset",
    "fpds_list_dimensions",
    "fpds_lookup_dimension",
    "fpds_resolve",
    "fpds_topic_search",
    "fpds_onboarding",
    "keyword_search",
    "keyword_analytics",
    "keyword_vs_topic",
    "keyword_compare",
    "keyword_vendor_profile",
}

# Datasets that require an API key (public_access=api_key in catalog).
# None = not yet loaded. Empty set = catalog failed to load (fail-closed).
_API_KEY_DATASETS: set[str] | None = None


def _get_api_key_datasets() -> set[str]:
    """Lazily load the set of datasets that require an API key.
    
    Returns an empty set on catalog load failure, which causes 
    _calls_protected_tool to treat all datasets as requiring auth (fail-closed).
    """
    global _API_KEY_DATASETS
    if _API_KEY_DATASETS is None:
        try:
            from app.catalog import load_catalog
            cat = load_catalog()
            _API_KEY_DATASETS = {
                ds_id for ds_id, ds in cat.datasets.items()
                if ds.get("public_access") == "api_key"
            }
        except Exception:
            logger.exception("Could not load catalog for API-key dataset check — failing closed")
            _API_KEY_DATASETS = set()
    return _API_KEY_DATASETS


def _is_gated_dataset(dataset_id: str) -> bool:
    """Check if a dataset requires auth. Fails closed on catalog error."""
    gated = _get_api_key_datasets()
    if not gated:
        return True
    return dataset_id in gated


def _calls_protected_tool(body: dict[str, Any] | list) -> bool:
    """Check if a JSON-RPC request calls a tool that requires authentication.
    
    This implements Claude's lazy authentication pattern:
    - Public tools (list, describe, resolve, etc.) work without auth
    - Protected tools (query_dataset on gated data, customer_profile) require auth
    
    Returns True if the request targets a protected tool without auth.
    """
    messages = body if isinstance(body, list) else [body]
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if msg.get("method") != "tools/call":
            continue
        tool_name = (msg.get("params") or {}).get("name", "")
        if tool_name in _PUBLIC_TOOLS:
            continue  # Public tool — no auth needed
        # fpds_query_dataset is conditionally protected:
        # public_bounded datasets work without auth, api_key datasets don't
        if tool_name == "fpds_query_dataset":
            dataset_id = (msg.get("params") or {}).get("arguments", {}).get("dataset_id", "")
            if dataset_id and _is_gated_dataset(dataset_id):
                return True  # Gated dataset — auth required
            continue  # public_bounded dataset — no auth needed
        # All other tools (fpds_customer_profile, etc.) require auth
        return True
    return False

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
    The scope parameter tells Claude which scopes to request.
    
    Per Claude docs: the 401 status is required — Claude does not honor
    WWW-Authenticate on a 200 response. Only a transport-level 401 causes
    Claude to pause the call, run the OAuth flow, and retry.
    """
    base = _base_url(request)
    return JSONResponse(
        status_code=401,
        content={
            "error": "invalid_token",
            "error_description": "Authentication required for this tool. Connect your API key via OAuth.",
        },
        headers={
            "WWW-Authenticate": (
                f'Bearer error="invalid_token", '
                f'error_description="Authentication required for this tool", '
                f'resource_metadata="{base}/.well-known/oauth-protected-resource", '
                f'scope="fpds:read"'
            ),
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
            "prompts": {},
            "resources": {},
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

    # Check if this is an initialize request — always allowed without auth
    method = body.get("method", "") if isinstance(body, dict) else ""
    is_initialize = method == "initialize"

    # Resolve auth state
    api_key = _resolve_api_key(request)
    has_auth = bool(api_key)
    auth_header = request.headers.get("Authorization", "")
    has_bearer = auth_header.startswith("Bearer ")

    # ── Lazy authentication (Claude connector pattern) ────────────────
    # If client sent an invalid OAuth Bearer token, return 401 immediately.
    # If client has no auth AND is calling a protected tool, return 401
    # with WWW-Authenticate — this triggers Claude's OAuth flow.
    # Public tools (initialize, ping, tools/list, public tool calls) pass through.
    if has_bearer and not has_auth and not is_initialize:
        return _unauthorized_response(request)
    if not has_auth and not is_initialize and _calls_protected_tool(body):
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
        _cleanup_sessions()
        session_id = str(uuid.uuid4())
        _sessions[session_id] = {
            "created_at": time.time(),
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
                "capabilities": {"tools": {}, "prompts": {}, "resources": {}},
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

    if method == "prompts/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"prompts": server.prompts()},
        }

    if method == "prompts/get":
        params = message.get("params", {})
        prompt_name = params.get("name", "")
        prompt_args = params.get("arguments", {})
        try:
            result = server.get_prompt(prompt_name, prompt_args)
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
                    "message": f"Prompts error: {exc}",
                },
            }

    if method == "resources/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"resources": server.resources()},
        }

    if method == "resources/read":
        params = message.get("params", {})
        uri = params.get("uri", "")
        try:
            result = server.read_resource(uri)
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
                    "message": f"Resources error: {exc}",
                },
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
