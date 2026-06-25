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
    "vehicle_program": "vehicle_programs",
    "vehicle_programs": "vehicle_programs",
    "vehicles": "vehicle_programs",
    "topics": "canonical_topics",
    "canonical_topics": "canonical_topics",
}


@dataclass
class FPDSClient:
    api_base_url: str
    api_key: str | None = None

    def __post_init__(self) -> None:
        self.api_base_url = self.api_base_url.rstrip("/")

    @property
    def has_api_key(self) -> bool:
        return bool(self.api_key)

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = _clean_params(params or {})
        url = f"{self.api_base_url}{path}"
        if query:
            url = f"{url}?{urlencode(query, doseq=True)}"
        headers = dict(JSON_HEADERS)
        if self.api_key:
            headers["X-API-Key"] = self.api_key
        request = Request(url, headers=headers)
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


def _domain_summary(catalog: dict[str, Any]) -> str:
    """Compact domain → dataset count + one-line purpose for the query tool description."""
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
        "vehicle": "GWAC, Schedule, IDIQ vehicle usage",
        "recompete": "Expiring contracts and recompete pipeline",
        "seasonality": "Fiscal-month and quarter spending patterns",
        "topics": "Machine-derived procurement sub-markets (topic intelligence)",
        "contacts": "Contracting officer profiles and activity",
        "entrants": "New vendor market entry and survival",
    }
    for domain, ids in sorted(domains.items()):
        desc = domain_descriptions.get(domain, "")
        lines.append(f"{domain} ({len(ids)} datasets): {desc}")
    return "; ".join(lines)


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
        try:
            catalog = self.catalog()
            domain_summary = _domain_summary(catalog)
            dataset_listing = _dataset_summary(catalog)
            query_description = (
                "Query bounded rows from a documented FPDS dataset. Use fpds_list_datasets or fpds_describe_dataset first to discover dataset IDs and allowed filters. Documented datasets only, allowlisted filters, bounded rows, no SQL.\n\nDomains: "
                + domain_summary
                + "\n\n"
                + dataset_listing
            )
        except Exception:
            query_description = (
                "Query bounded rows from a documented FPDS dataset. "
                "Use fpds_list_datasets or fpds_describe_dataset first to discover "
                "dataset IDs and allowed filters. Documented datasets only, "
                "allowlisted filters, bounded rows, no SQL."
            )
        return [
            _tool(
                "fpds_list_datasets",
                "List documented FPDS analytics datasets with descriptions, filters, fields, examples, and caveats. Use domain filter to narrow results. Call this first to discover dataset IDs before querying.",
                {"domain": {"type": "string", "description": "Optional domain filter: pricing, concentration, competition, naics, geography, customer, market, incumbent, set_aside, psc, vehicle, recompete, seasonality, topics, contacts, entrants."}},
            ),
            _tool(
                "fpds_describe_dataset",
                "Describe one FPDS dataset, including allowed filters, sortable fields, examples, caveats, and field descriptions. Call this before querying an unfamiliar dataset.",
                {"dataset_id": {"type": "string", "description": "Dataset ID from fpds_list_datasets."}},
                ["dataset_id"],
            ),
            _tool(
                "fpds_query_dataset",
                query_description,
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
                "Resolve plain-English names to FPDS codes using dimension search. Searches departments, agencies, contracting offices, NAICS, PSC codes, vehicle programs, and canonical procurement topics unless types are supplied.",
                {
                    "q": {"type": "string", "description": "Name or description fragment to search for."},
                    "types": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional types: departments, agencies, offices, naics, psc, vehicle_programs, topics.",
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
            _tool(
                "fpds_topic_search",
                "Search procurement topics by keyword. Finds machine-derived sub-market topics matching a text query across 9,313 merged topics and 4,969 govwide canonical topics. Topics are a semantic dimension parallel to NAICS — they decompose broad classification codes into what agencies actually buy. Use fpds_resolve(types=['topics']) for quick canonical topic lookups, or this tool for comprehensive cross-corpus search with department scoping. Use when a user asks about specific procurement domains like 'cybersecurity', 'cloud migration', 'medical devices', etc.",
                {
                    "q": {"type": "string", "description": "Topic search query — a procurement domain, technology, or capability (e.g. 'cybersecurity', 'cloud', 'medical devices')."},
                    "department_code": {"type": "string", "description": "Optional USASpending department code to scope results to one agency."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max results (default 10)."},
                    "include_canonical": {"type": "boolean", "description": "Also search govwide canonical topics (default true)."},
                },
                ["q"],
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
        if name == "fpds_topic_search":
            return _json_text(self.topic_search(arguments))
        raise ValueError(f"Unknown tool: {name}")

    def resolve(self, arguments: dict[str, Any]) -> dict[str, Any]:
        q = arguments["q"]
        raw_types = arguments.get("types") or ["departments", "agencies", "offices", "naics", "psc", "vehicle_programs", "topics"]
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

    def topic_search(self, arguments: dict[str, Any]) -> dict[str, Any]:
        """Search topic labels across merged catalog and govwide canonical topics.

        Uses server-side ILIKE search via the q parameter on datasets that
        have searchable_columns configured. This searches the full corpus
        regardless of API key status (public tier gets up to 25 matching
        results, API key tier gets up to 1000).
        """
        q = arguments["q"]
        limit = min(int(arguments.get("limit") or 10), 100)
        include_canonical = arguments.get("include_canonical", True)
        department_code = arguments.get("department_code")

        results: dict[str, Any] = {"query": q, "sections": []}

        # Search merged topics in the catalog (server-side ILIKE)
        catalog_params: dict[str, Any] = {
            "corpus_type": "merged",
            "sort": "-assignment_count",
            "q": q,
            "limit": limit,
            "fields": "model_id,topic_id,department_code,label,description,naics_alignment,assignment_count,awards_count,sam_count",
        }
        if department_code:
            catalog_params["department_code"] = department_code
        try:
            response = self.client.get("/v1/datasets/topics.catalog/rows", catalog_params)
            data = response.get("data", [])
            results["sections"].append({
                "source": "topics.catalog (merged topics)",
                "matched": len(data),
                "data": data,
            })
        except Exception as exc:
            results["sections"].append({"source": "topics.catalog", "error": str(exc)})

        # Search govwide canonical topics (server-side ILIKE)
        if include_canonical:
            try:
                response = self.client.get("/v1/datasets/topics.govwide_canonical/rows", {
                    "sort": "-department_count",
                    "q": q,
                    "limit": limit,
                })
                data = response.get("data", [])
                results["sections"].append({
                    "source": "topics.govwide_canonical (cross-department)",
                    "matched": len(data),
                    "data": data,
                })
            except Exception as exc:
                results["sections"].append({"source": "topics.govwide_canonical", "error": str(exc)})

        return results


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
    parser.add_argument(
        "--api-key",
        default=os.environ.get("FPDS_API_KEY"),
        help="Optional API key for higher rate limits and larger result sets.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.api_base_url:
        sys.stderr.write("Set --api-base-url or FPDS_API_BASE_URL.\n")
        return 2
    serve(FPDSServer(FPDSClient(args.api_base_url, api_key=args.api_key)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
