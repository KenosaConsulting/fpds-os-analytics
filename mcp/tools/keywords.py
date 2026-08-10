"""Keyword tools: search, analytics, vs_topic, compare, vendor_profile."""

from __future__ import annotations

from typing import Any

from . import ToolDef

DEFAULT_LIMIT = 25


def _handle_keyword_search(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    params = {
        k: v for k, v in arguments.items()
        if v is not None and k not in ("limit",)
    }
    params["limit"] = arguments.get("limit", DEFAULT_LIMIT)
    return server.client.get("/v1/keywords/search", params)


def _handle_keyword_analytics(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return server.client.get("/v1/keywords/analytics", arguments)


def _handle_keyword_vs_topic(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return server.client.get("/v1/keywords/vs-topic", arguments)


def _handle_keyword_compare(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return server.client.get("/v1/keywords/compare", arguments)


def _handle_keyword_vendor_profile(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    uei = arguments.get("uei")
    if not uei:
        raise ValueError("Missing required argument: uei")
    params = {k: v for k, v in arguments.items() if v is not None and k not in ("uei", "limit")}
    params["limit"] = arguments.get("limit", 50)
    return server.client.get(f"/v1/keywords/vendor/{uei}", params)


TOOLS: dict[str, ToolDef] = {
    "keyword_search": ToolDef(
        schema={
            "name": "keyword_search",
            "description": "Search procurement keywords by text substring.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "q": {"type": "string", "description": "Search query."},
                    "keyword_type": {"type": "array", "items": {"type": "string"}},
                    "category": {"type": "array", "items": {"type": "string"}},
                    "department_code": {"type": "string"},
                    "min_link_count": {"type": "integer", "description": "Popularity filter (default 2)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "required": ["q"],
                "additionalProperties": False,
            },
        },
        handler=_handle_keyword_search,
        tier="public",
    ),
    "keyword_analytics": ToolDef(
        schema={
            "name": "keyword_analytics",
            "description": "Get procurement analytics for a specific keyword.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "keyword_id": {"type": "integer"},
                    "keyword_text": {"type": "string"},
                    "department_code": {"type": "string"},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                    "group_by": {"type": "string", "description": "agency, vendor, fy, naics, set_aside."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_keyword_analytics,
        tier="public",
    ),
    "keyword_vs_topic": ToolDef(
        schema={
            "name": "keyword_vs_topic",
            "description": "Bridge keywords to BERTopic topics and vice versa.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "keyword_id": {"type": "integer"},
                    "keyword_text": {"type": "string"},
                    "topic_id": {"type": "integer"},
                    "department_code": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_keyword_vs_topic,
        tier="public",
    ),
    "keyword_compare": ToolDef(
        schema={
            "name": "keyword_compare",
            "description": "Compare multiple keywords side-by-side on procurement metrics.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "keywords": {"type": "array", "items": {"type": "string"}},
                    "keyword_ids": {"type": "array", "items": {"type": "integer"}},
                    "department_code": {"type": "string"},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_keyword_compare,
        tier="public",
    ),
    "keyword_vendor_profile": ToolDef(
        schema={
            "name": "keyword_vendor_profile",
            "description": "Get keyword profile for a vendor by UEI.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "uei": {"type": "string", "description": "Vendor UEI."},
                    "department_code": {"type": "string"},
                    "category": {"type": "array", "items": {"type": "string"}},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200},
                },
                "required": ["uei"],
                "additionalProperties": False,
            },
        },
        handler=_handle_keyword_vendor_profile,
        tier="public",
    ),
}
