"""Discovery tools: list_datasets, describe_dataset, list_dimensions, fpds_health."""

from __future__ import annotations

from typing import Any

from . import ToolDef

DEFAULT_LIMIT = 25

_JSON_HEADERS = {"Accept": "application/json"}


def _clean_params(params: dict[str, Any]) -> dict[str, Any]:
    clean: dict[str, Any] = {}
    for key, value in params.items():
        if value in (None, "", [], {}):
            continue
        if isinstance(value, list):
            clean[key] = ",".join(str(item) for item in value)
        elif isinstance(value, dict):
            for nested_key, nested_value in value.items():
                if nested_value not in (None, ""):
                    clean[nested_key] = nested_value
        else:
            clean[key] = value
    return clean


def _domain_summary(catalog: dict[str, Any]) -> str:
    domains: dict[str, list[str]] = {}
    for dataset in catalog.get("data", []):
        domain = dataset.get("domain", "other")
        dataset_id = dataset.get("id", "")
        domains.setdefault(domain, []).append(dataset_id)
    lines = []
    domain_descriptions = {
        "pricing": "Contract pricing structures and risk",
        "concentration": "Vendor concentration and incumbent strength",
        "competition": "Competed vs sole-source, bundling, offer patterns",
        "naics": "Industry demand by NAICS sector",
        "geography": "Where federal work is performed",
        "customer": "Agency and office buying profiles",
        "market": "Market sizing by agency x NAICS x office",
        "incumbent": "Who wins and how entrenched they are",
        "set_aside": "Small business and socioeconomic programs",
        "psc": "Product/service code analytics",
        "acquisition": "GWAC, Schedule, IDIQ vehicle usage",
        "pipeline": "Expiring contracts and recompete pipeline",
        "seasonality": "Fiscal-month and quarter spending patterns",
        "topics": "Machine-derived procurement sub-markets",
        "contacts": "Contracting officer profiles and activity",
        "entrants": "New vendor market entry and survival",
        "funding": "Who funds vs who executes across agencies",
        "opportunity": "Cross-agency vendor opportunity analysis",
    }
    for domain, ids in sorted(domains.items()):
        desc = domain_descriptions.get(domain, "")
        lines.append(f"{domain} ({len(ids)} datasets): {desc}")
    return "; ".join(lines)


def _handle_health(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return {"status": "ok", "service": "fpds-os-analytics", "version": "0.2.0"}


def _handle_list_datasets(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    params: dict[str, Any] = {}
    if arguments.get("domain"):
        params["domain"] = arguments["domain"]
    if arguments.get("q"):
        params["q"] = arguments["q"]
    if arguments.get("filter_name"):
        params["filter_name"] = arguments["filter_name"]
    if arguments.get("field_name"):
        params["field_name"] = arguments["field_name"]
    return server.client.get("/v1/catalog", params)


def _handle_describe_dataset(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dataset_id = arguments.get("dataset_id")
    if not dataset_id:
        raise ValueError("Missing required argument: dataset_id")
    return server.client.get(f"/v1/datasets/{dataset_id}")


def _handle_list_dimensions(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return server.client.get("/v1/dimensions")


TOOLS: dict[str, ToolDef] = {
    "fpds_health": ToolDef(
        schema={
            "name": "fpds_health",
            "description": "Check API health and connectivity.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        handler=_handle_health,
        tier="public",
    ),
    "fpds_list_datasets": ToolDef(
        schema={
            "name": "fpds_list_datasets",
            "description": "List 90 documented FPDS analytics datasets across 17 intelligence domains.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "domain": {"type": "string", "description": "Optional domain filter."},
                    "filter_name": {"type": "string", "description": "Show datasets supporting a specific filter."},
                    "field_name": {"type": "string", "description": "Show datasets including a specific field."},
                    "q": {"type": "string", "description": "Optional substring search on titles/descriptions."},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_list_datasets,
        tier="public",
    ),
    "fpds_describe_dataset": ToolDef(
        schema={
            "name": "fpds_describe_dataset",
            "description": "Inspect one FPDS dataset before querying it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "dataset_id": {"type": "string", "description": "Dataset ID from fpds_list_datasets."},
                },
                "required": ["dataset_id"],
                "additionalProperties": False,
            },
        },
        handler=_handle_describe_dataset,
        tier="public",
    ),
    "fpds_list_dimensions": ToolDef(
        schema={
            "name": "fpds_list_dimensions",
            "description": "List 17 FPDS code-lookup dimensions.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        handler=_handle_list_dimensions,
        tier="public",
    ),
}
