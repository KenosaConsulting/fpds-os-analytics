"""Remote MCP endpoint — exposes the FPDS Analytics MCP server over HTTP.

This implements the MCP "streamable HTTP" transport: clients POST JSON-RPC
messages to /v1/mcp and receive JSON-RPC responses. For SSE streaming,
clients can accept text/event-stream.

The MCP server logic is reused from mcp.fpds_mcp_server — the same tool
definitions and call handlers serve both stdio and HTTP transports.
"""

from __future__ import annotations

import json
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from mcp.fpds_mcp_server import FPDSServer


router = APIRouter(prefix="/v1/mcp", tags=["mcp"])


def _build_server(request: Request) -> FPDSServer:
    """Build an FPDSServer using the internal client (no HTTP round-trips).
    
    When running inside the API process, InternalFPDSClient routes requests
    through the ASGI app directly — no network I/O, no self-referencing calls.
    """
    api_key = request.headers.get("X-Api-Key")
    if not api_key:
        auth_header = request.headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            api_key = auth_header[7:]
    
    from app.mcp_internal_client import InternalFPDSClient
    client = InternalFPDSClient(api_key=api_key or None)
    return FPDSServer(client)


@router.get("")
@router.get("/")
def mcp_info() -> dict[str, Any]:
    """MCP endpoint discovery — returns server capabilities."""
    return {
        "name": "fpds-analytics-mcp",
        "version": "0.1.0",
        "protocolVersion": "2024-11-05",
        "capabilities": {
            "tools": {},
        },
        "instructions": (
            "FPDS Analytics MCP server. Use 'tools/list' to discover available "
            "tools for querying federal procurement data. API key optional for "
            "bounded queries; required for higher rate limits and larger results."
        ),
    }


@router.post("", response_model=None)
@router.post("/", response_model=None)
async def mcp_handle(
    request: Request,
) -> JSONResponse | StreamingResponse:
    """Handle a JSON-RPC 2.0 request over HTTP.

    Supports both single requests and batch requests per the JSON-RPC spec.
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
        # Notification — no response
        return JSONResponse(status_code=202, content=None)
    if "text/event-stream" in accept:
        return _sse_stream([result])
    return JSONResponse(content=result)


def _handle_message(server: FPDSServer, message: dict[str, Any]) -> dict[str, Any] | None:
    """Route a JSON-RPC message to the MCP server handler."""
    method = message.get("method", "")
    msg_id = message.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {
                    "name": "fpds-analytics-mcp",
                    "version": "0.1.0",
                },
            },
        }

    if method == "notifications/initialized":
        return None  # Notification — no response

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
