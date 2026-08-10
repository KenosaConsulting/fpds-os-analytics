"""Dataset query tools: query_dataset, analytics_query, lookup_dimension."""

from __future__ import annotations

from typing import Any

from . import ToolDef

DEFAULT_LIMIT = 25


def _handle_query_dataset(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dataset_id = arguments.get("dataset_id")
    if not dataset_id:
        raise ValueError("Missing required argument: dataset_id")
    filters = arguments.get("filters") or {}
    params = {
        **filters,
        "fields": arguments.get("fields"),
        "sort": arguments.get("sort"),
        "limit": arguments.get("limit", DEFAULT_LIMIT),
        "cursor": arguments.get("cursor"),
    }
    return server.client.get(f"/v1/datasets/{dataset_id}/rows", params)


def _handle_analytics_query(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dataset_id = arguments.get("dataset_id")
    if not dataset_id:
        raise ValueError("Missing required argument: dataset_id")
    filters = arguments.get("filters") or {}
    if filters and "recompete_confidence" in filters:
        val = str(filters["recompete_confidence"]).lower()
        if val in ("high", "medium", "low"):
            filters["recompete_confidence"] = val
    params = {
        **filters,
        "fields": arguments.get("fields"),
        "sort": arguments.get("sort"),
        "limit": min(int(arguments.get("limit", DEFAULT_LIMIT)), 1000),
        "cursor": arguments.get("cursor"),
    }
    return server.client.get(f"/v1/datasets/{dataset_id}/rows", params)


def _handle_lookup_dimension(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dimension_id = arguments.get("dimension_id")
    if not dimension_id:
        raise ValueError("Missing required argument: dimension_id")
    filters = arguments.get("filters") or {}
    params = {
        **filters,
        "q": arguments.get("q"),
        "sort": arguments.get("sort"),
        "limit": arguments.get("limit", DEFAULT_LIMIT),
        "cursor": arguments.get("cursor"),
    }
    return server.client.get(f"/v1/dimensions/{dimension_id}", params)


TOOLS: dict[str, ToolDef] = {
    "fpds_query_dataset": ToolDef(
        schema={
            "name": "fpds_query_dataset",
            "description": (
                "Query bounded rows from a documented FPDS dataset. "
                "Use fpds_list_datasets or fpds_describe_dataset first to discover "
                "dataset IDs and allowed filters. Documented datasets only, "
                "allowlisted filters, bounded rows, no SQL. "
                "Always include at least one filter (e.g. contracting_dept_id, "
                "fiscal_year, principal_naics_code) to avoid query timeouts. "
                "Use fpds_resolve to find filter values from names. "
                "Domains: pricing, concentration, competition, naics, geography, "
                "customer, market, incumbent, set_aside, psc, acquisition, pipeline, "
                "seasonality, topics, contacts, entrants, funding, opportunity."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "dataset_id": {"type": "string", "description": "Dataset ID."},
                    "filters": {"type": "object", "description": "Allowed dataset filters."},
                    "fields": {"type": "array", "items": {"type": "string"}},
                    "sort": {"type": "string", "description": "Sort field; prefix '-' for descending."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "cursor": {"type": "string", "description": "Pagination cursor."},
                },
                "required": ["dataset_id"],
                "additionalProperties": False,
            },
        },
        handler=_handle_query_dataset,
        tier="public",
    ),
    "analytics_query": ToolDef(
        schema={
            "name": "analytics_query",
            "description": (
                "Query rows from a documented FPDS analytics dataset. "
                "Datasets cover: pricing, concentration, competition, NAICS, "
                "geography, customer, market, incumbent, set_aside, PSC, "
                "vehicle, recompete, seasonality, topics, contacts, entrants."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "dataset_id": {"type": "string", "description": "Dataset ID."},
                    "filters": {"type": "object", "description": "Key/value filters."},
                    "fields": {"type": "array", "items": {"type": "string"}},
                    "sort": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "cursor": {"type": "string"},
                },
                "required": ["dataset_id"],
                "additionalProperties": False,
            },
        },
        handler=_handle_analytics_query,
        tier="tier3",
    ),
    "fpds_lookup_dimension": ToolDef(
        schema={
            "name": "fpds_lookup_dimension",
            "description": "Look up rows in a single FPDS dimension by filters or substring search.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "dimension_id": {"type": "string", "description": "Dimension ID."},
                    "q": {"type": "string"},
                    "filters": {"type": "object"},
                    "sort": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "cursor": {"type": "string"},
                },
                "required": ["dimension_id"],
                "additionalProperties": False,
            },
        },
        handler=_handle_lookup_dimension,
        tier="public",
    ),
}
