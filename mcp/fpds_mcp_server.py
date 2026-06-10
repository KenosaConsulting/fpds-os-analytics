"""Standalone stdio MCP server for the FPDS Analytics API."""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode
from urllib.request import Request, urlopen


JSON_HEADERS = {"Accept": "application/json"}
DEFAULT_LIMIT = 25
TYPE_TO_DIMENSION = {
    "departments": "departments",
    "department": "departments",
    "agencies": "agencies",
    "agency": "agencies",
    "offices": "contracting_offices",
    "office": "contracting_offices",
    "contracting_offices": "contracting_offices",
    "naics": "naics",
    "psc": "psc_codes",
    "psc_codes": "psc_codes",
}


@dataclass
class FPDSClient:
    api_base_url: str

    def __post_init__(self) -> None:
        self.api_base_url = self.api_base_url.rstrip("/")

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = _clean_params(params or {})
        url = f"{self.api_base_url}{path}"
        if query:
            url = f"{url}?{urlencode(query, doseq=True)}"
        request = Request(url, headers=JSON_HEADERS)
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))


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


def _dataset_summary(catalog: dict[str, Any]) -> str:
    lines = []
    for dataset in catalog.get("data", []):
        dataset_id = dataset.get("id")
        description = dataset.get("description") or dataset.get("title") or ""
        if dataset_id:
            lines.append(f"{dataset_id}: {description}")
    return "\n".join(lines)


def _json_text(payload: Any) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(payload, indent=2, sort_keys=True),
            }
        ]
    }


def _tool(name: str, description: str, properties: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required or [],
            "additionalProperties": False,
        },
    }


class FPDSServer:
    def __init__(self, client: FPDSClient) -> None:
        self.client = client
        self._catalog_cache: dict[str, Any] | None = None

    def catalog(self) -> dict[str, Any]:
        if self._catalog_cache is None:
            self._catalog_cache = self.client.get("/v1/catalog")
        return self._catalog_cache

    def tools(self) -> list[dict[str, Any]]:
        dataset_descriptions = _dataset_summary(self.catalog())
        return [
            _tool(
                "fpds_list_datasets",
                "List documented FPDS analytics datasets with descriptions, filters, fields, examples, and caveats.",
                {"domain": {"type": "string", "description": "Optional dataset domain filter."}},
            ),
            _tool(
                "fpds_describe_dataset",
                "Describe one FPDS dataset, including allowed filters, sortable fields, examples, caveats, and field descriptions.",
                {"dataset_id": {"type": "string", "description": "Dataset ID from fpds_list_datasets."}},
                ["dataset_id"],
            ),
            _tool(
                "fpds_query_dataset",
                "Query bounded rows from a documented FPDS dataset. Same REST guardrails apply: documented datasets only, allowlisted filters, bounded rows, no SQL.\n\nAvailable datasets:\n"
                + dataset_descriptions,
                {
                    "dataset_id": {"type": "string", "description": "Dataset ID from fpds_list_datasets."},
                    "filters": {"type": "object", "description": "Allowed dataset filters as key/value pairs."},
                    "fields": {"type": "array", "items": {"type": "string"}, "description": "Optional public fields to return."},
                    "sort": {"type": "string", "description": "Optional allowlisted sort; prefix with '-' for descending."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Bounded row limit."},
                    "cursor": {"type": "string", "description": "Pagination cursor from a prior response."},
                },
                ["dataset_id"],
            ),
            _tool(
                "fpds_list_dimensions",
                "List FPDS code lookup dimensions available through the REST API.",
                {},
            ),
            _tool(
                "fpds_lookup_dimension",
                "Lookup FPDS dimension rows by allowed filters or q substring search where supported. Same bounded REST guardrails apply.",
                {
                    "dimension_id": {"type": "string", "description": "Dimension ID from fpds_list_dimensions."},
                    "q": {"type": "string", "description": "Optional substring search."},
                    "filters": {"type": "object", "description": "Allowed dimension filters as key/value pairs."},
                    "sort": {"type": "string", "description": "Optional sort field."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "cursor": {"type": "string"},
                },
                ["dimension_id"],
            ),
            _tool(
                "fpds_resolve",
                "Resolve plain-English names to FPDS codes using the FPDS-009 dimension search. Searches departments, agencies, contracting offices, NAICS, and PSC codes unless types are supplied.",
                {
                    "q": {"type": "string", "description": "Name or description fragment to search for."},
                    "types": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional types: departments, agencies, offices, naics, psc.",
                    },
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                ["q"],
            ),
            _tool(
                "fpds_customer_profile",
                "Return Customer 360 sections from GET /v1/profiles/customer, including spend trend, top NAICS, competition posture, pricing posture, set-aside mix, incumbents, vehicles, recompete signals, and narrative hints.",
                {
                    "contracting_dept_id": {"type": "string", "description": "Contracting department code."},
                    "contracting_agency_id": {"type": "string", "description": "Contracting agency code."},
                },
            ),
        ]

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "fpds_list_datasets":
            return _json_text(self.client.get("/v1/catalog", {"domain": arguments.get("domain")}))
        if name == "fpds_describe_dataset":
            return _json_text(self.client.get(f"/v1/datasets/{arguments['dataset_id']}"))
        if name == "fpds_query_dataset":
            params = {
                **(arguments.get("filters") or {}),
                "fields": arguments.get("fields"),
                "sort": arguments.get("sort"),
                "limit": arguments.get("limit", DEFAULT_LIMIT),
                "cursor": arguments.get("cursor"),
            }
            return _json_text(self.client.get(f"/v1/datasets/{arguments['dataset_id']}/rows", params))
        if name == "fpds_list_dimensions":
            return _json_text(self.client.get("/v1/dimensions"))
        if name == "fpds_lookup_dimension":
            params = {
                **(arguments.get("filters") or {}),
                "q": arguments.get("q"),
                "sort": arguments.get("sort"),
                "limit": arguments.get("limit", DEFAULT_LIMIT),
                "cursor": arguments.get("cursor"),
            }
            return _json_text(self.client.get(f"/v1/dimensions/{arguments['dimension_id']}", params))
        if name == "fpds_resolve":
            return _json_text(self.resolve(arguments))
        if name == "fpds_customer_profile":
            return _json_text(self.client.get("/v1/profiles/customer", arguments))
        raise ValueError(f"Unknown tool: {name}")

    def resolve(self, arguments: dict[str, Any]) -> dict[str, Any]:
        q = arguments["q"]
        raw_types = arguments.get("types") or ["departments", "agencies", "offices", "naics", "psc"]
        limit = min(int(arguments.get("limit") or 10), 100)
        results = []
        for raw_type in raw_types:
            dimension_id = TYPE_TO_DIMENSION.get(str(raw_type))
            if not dimension_id:
                continue
            response = self.client.get(f"/v1/dimensions/{dimension_id}", {"q": q, "limit": limit})
            results.append(
                {
                    "type": raw_type,
                    "dimension_id": dimension_id,
                    "data": response.get("data", []),
                    "meta": response.get("meta", {}),
                }
            )
        return {"query": q, "results": results}


def _success(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def _error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def handle_message(server: FPDSServer, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}
    try:
        if method == "initialize":
            return _success(
                request_id,
                {
                    "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                    "serverInfo": {"name": "fpds-os-analytics", "version": "0.1.0"},
                    "capabilities": {"tools": {}},
                },
            )
        if method == "notifications/initialized":
            return None
        if method == "ping":
            return _success(request_id, {})
        if method == "tools/list":
            return _success(request_id, {"tools": server.tools()})
        if method == "tools/call":
            return _success(request_id, server.call_tool(params["name"], params.get("arguments") or {}))
        return _error(request_id, -32601, f"Method not found: {method}")
    except Exception as exc:
        return _error(request_id, -32000, str(exc))


def serve(server: FPDSServer) -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        response = handle_message(server, json.loads(line))
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the FPDS Analytics MCP stdio server.")
    parser.add_argument(
        "--api-base-url",
        default=os.environ.get("FPDS_API_BASE_URL"),
        help="Base URL for the FPDS Analytics API, for example https://analytics-api.example.com",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.api_base_url:
        sys.stderr.write("Set --api-base-url or FPDS_API_BASE_URL.\n")
        return 2
    serve(FPDSServer(FPDSClient(args.api_base_url)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
