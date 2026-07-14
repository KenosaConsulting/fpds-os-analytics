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
        if not dataset_id:
            continue
        meta_parts = []
        filters = dataset.get("filters") or []
        if filters:
            meta_parts.append("filters: " + ", ".join(filters))
        sortable = dataset.get("sortable") or []
        if sortable:
            meta_parts.append("sort: " + ", ".join(sortable))
        line = f"{dataset_id}: {description}"
        if meta_parts:
            line += " [" + " | ".join(meta_parts) + "]"
        lines.append(line)
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
        "acquisition": "GWAC, Schedule, IDIQ vehicle usage",
        "pipeline": "Expiring contracts and recompete pipeline",
        "seasonality": "Fiscal-month and quarter spending patterns",
        "topics": "Machine-derived procurement sub-markets (topic intelligence)",
        "contacts": "Contracting officer profiles and activity",
        "entrants": "New vendor market entry and survival",
        "funding": "Who funds vs who executes across agencies",
        "opportunity": "Cross-agency vendor opportunity analysis",
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


def _prompt_arg(name: str, description: str, required: bool = False) -> dict[str, Any]:
    return {"name": name, "description": description, "required": required}


class FPDSServer:
    def __init__(self, client: FPDSClient) -> None:
        self.client = client
        self._catalog_cache: dict[str, Any] | None = None
        self._resources_cache: dict[str, dict[str, Any]] | None = None

    def catalog(self) -> dict[str, Any]:
        if self._catalog_cache is None:
            self._catalog_cache = self.client.get("/v1/catalog")
        return self._catalog_cache

    def _load_resources(self) -> dict[str, dict[str, Any]]:
        if self._resources_cache is not None:
            return self._resources_cache
        resources: dict[str, dict[str, Any]] = {}
        docs_dir = os.path.join(os.path.dirname(__file__), "..", "docs")
        resource_defs = [
            ("fpds://docs/methodology", "METHODOLOGY.md", "How every number is computed — data sources, aggregation rules, metric definitions, and refresh cadence."),
            ("fpds://docs/datasets", "DATASETS.md", "Field-by-field reference for all 88 analytics datasets — what each field means, its grain, and its caveats."),
            ("fpds://docs/caveats", "CAVEATS.md", "Data limitations, interpretation caveats, and things the data cannot prove. Include these when explaining results."),
            ("fpds://docs/ai-assistant-guide", "AI_ASSISTANT_GUIDE.md", "How to use the FPDS Analytics API with AI assistants — workflows, common starting points, and good user prompts."),
        ]
        for uri, filename, description in resource_defs:
            filepath = os.path.join(docs_dir, filename)
            try:
                with open(filepath, "r") as f:
                    content = f.read()
            except FileNotFoundError:
                content = f"Resource not found: {filename}"
            resources[uri] = {
                "uri": uri,
                "name": uri.rsplit("/", 1)[-1],
                "description": description,
                "mimeType": "text/markdown",
                "text": content,
            }
        # Add notices resource (generated from app.notices)
        try:
            from app.notices import GLOBAL_DATA_NOTICES, AGENCY_CODE_NOTICES, GEOGRAPHY_NOTICES
            notices_text = (
                "# Critical Data Notices\n\n"
                "Always include these notices when explaining FPDS analytics results.\n\n"
            )
            notices_text += "## Global Data Notices\n\n"
            for n in GLOBAL_DATA_NOTICES:
                notices_text += f"- {n}\n"
            notices_text += "\n## Agency Code Notices\n\n"
            for n in AGENCY_CODE_NOTICES:
                notices_text += f"- {n}\n"
            notices_text += "\n## Geography Notices\n\n"
            for n in GEOGRAPHY_NOTICES:
                notices_text += f"- {n}\n"
            resources["fpds://docs/notices"] = {
                "uri": "fpds://docs/notices",
                "name": "notices",
                "description": "Critical interpretation caveats that must accompany analytics results — data completeness, agency code limitations, and geography caveats.",
                "mimeType": "text/markdown",
                "text": notices_text,
            }
        except ImportError:
            pass
        # Add live catalog resources (generated from API)
        try:
            catalog = self.catalog()
            resources["fpds://catalog/datasets"] = {
                "uri": "fpds://catalog/datasets",
                "name": "datasets",
                "description": "Complete machine-readable catalog of all 88+ analytics datasets — fields, filters, grain, caveats, examples. Load this for session-wide dataset awareness.",
                "mimeType": "application/json",
                "text": json.dumps(catalog, indent=2),
            }
        except Exception as exc:
            resources["fpds://catalog/datasets"] = {
                "uri": "fpds://catalog/datasets",
                "name": "datasets",
                "description": "Complete machine-readable catalog of all 88+ analytics datasets — fields, filters, grain, caveats, examples. Load this for session-wide dataset awareness.",
                "mimeType": "text/plain",
                "text": f"Catalog not available: {exc}",
            }
        try:
            dimensions = self.client.get("/v1/dimensions")
            resources["fpds://catalog/dimensions"] = {
                "uri": "fpds://catalog/dimensions",
                "name": "dimensions",
                "description": "Complete list of 17 code-lookup dimensions with key fields and filters.",
                "mimeType": "application/json",
                "text": json.dumps(dimensions, indent=2),
            }
        except Exception as exc:
            resources["fpds://catalog/dimensions"] = {
                "uri": "fpds://catalog/dimensions",
                "name": "dimensions",
                "description": "Complete list of 17 code-lookup dimensions with key fields and filters.",
                "mimeType": "text/plain",
                "text": f"Dimensions not available: {exc}",
            }
        self._resources_cache = resources
        return resources

    def resources(self) -> list[dict[str, Any]]:
        res = self._load_resources()
        return [{"uri": r["uri"], "name": r["name"], "description": r["description"], "mimeType": r.get("mimeType")} for r in res.values()]

    def read_resource(self, uri: str) -> dict[str, Any]:
        res = self._load_resources()
        if uri not in res:
            raise ValueError(f"Resource not found: {uri}")
        r = res[uri]
        return {
            "contents": [
                {
                    "uri": r["uri"],
                    "mimeType": r.get("mimeType", "text/markdown"),
                    "text": r["text"],
                }
            ]
        }

    def tools(self) -> list[dict[str, Any]]:
        try:
            catalog = self.catalog()
            domain_summary = _domain_summary(catalog)
            dataset_listing = _dataset_summary(catalog)
            query_description = (
                "Query bounded rows from a documented FPDS dataset. Use fpds_list_datasets or fpds_describe_dataset first to discover dataset IDs and allowed filters. Documented datasets only, allowlisted filters, bounded rows, no SQL.\n\nIMPORTANT: Always include at least one filter (e.g. contracting_dept_id, fiscal_year, principal_naics_code) to avoid query timeouts. Unfiltered queries on large datasets may time out. Use fpds_resolve to find filter values from names.\n\nWhen querying vendor-grain datasets and you need obligation totals, consider using keyword_analytics(group_by=\"vendor\") for pre-aggregated vendor rankings by capability keyword — this avoids pulling raw rows and summing client-side.\n\nDomains: "
                + domain_summary
                + "\n\n"
                + dataset_listing
            )
        except Exception:
            query_description = (
                "Query bounded rows from a documented FPDS dataset. "
                "Use fpds_list_datasets or fpds_describe_dataset first to discover "
                "dataset IDs and allowed filters. Documented datasets only, "
                "allowlisted filters, bounded rows, no SQL. "
                "Always include at least one filter to avoid timeouts."
            )
        return [
            _tool(
                "fpds_list_datasets",
                "List 88 documented FPDS analytics datasets across 17 intelligence domains. This is your primary discovery tool — call it first to browse available datasets by domain. Each dataset entry includes its ID, title, domain, description, allowed filters, sortable fields, examples, and caveats. Use the domain filter to narrow results (e.g. domain='competition' for competition-related datasets, domain='topics' for topic intelligence). After finding a dataset, use fpds_describe_dataset to inspect it in detail before querying.",
                {"domain": {"type": "string", "description": "Optional domain filter: pricing, concentration, competition, naics, geography, customer, market, incumbent, set_aside, psc, acquisition, pipeline, seasonality, topics, contacts, entrants, funding."},
                 "q": {"type": "string", "description": "Optional substring search on dataset titles and descriptions to find relevant datasets by concept (e.g. 'vendor concentration', 'expiring contracts')."}},
            ),
            _tool(
                "fpds_describe_dataset",
                "Inspect one FPDS dataset before querying it. Returns allowed filters, sortable fields, example queries with explanations, dataset caveats, field descriptions, and access tier. Call this whenever you're about to query an unfamiliar dataset — it prevents invalid filter errors and helps you choose the right fields and sorts.",
                {"dataset_id": {"type": "string", "description": "Dataset ID from fpds_list_datasets (e.g. 'competition.sole_source_hotspots')."}},
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
                "List 17 FPDS code-lookup dimensions: departments, agencies, contracting offices, NAICS codes, PSC codes, vehicle programs, set-aside codes, competition codes, pricing codes, business size codes, commercial item codes, bundling codes, financing codes, reason-not-competed codes, states, and canonical procurement topics. Dimensions let you translate between plain-English names and FPDS codes. After listing, use fpds_lookup_dimension to search within a dimension or fpds_resolve to search across multiple dimensions simultaneously.",
                {},
            ),
            _tool(
                "fpds_lookup_dimension",
                "Look up rows in a single FPDS dimension by allowed filters or substring search (q parameter). Use this when you need a specific code list (e.g. all NAICS codes in sector 54) or want to browse a dimension's contents. For cross-dimension plain-English search, use fpds_resolve instead.",
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
                "Generate a composite Customer 360 profile for a federal agency in one call. Returns 8 analytical sections: (1) spend trend by fiscal year, (2) top NAICS codes bought, (3) competition posture (competed% vs sole-source%), (4) pricing structure mix (fixed-price vs cost-type vs T&M), (5) set-aside program usage breakdown, (6) top incumbent vendors by share, (7) acquisition vehicle paths (GWAC/Schedule/IDIQ/Open Market), and (8) recompete signals with narrative hints. Use this as a first-pass customer brief — then drill into specific datasets (pricing, competition, pipeline) for detail.",
                {
                    "contracting_dept_id": {"type": "string", "description": "Contracting department code (e.g. 9700 for DoD)."},
                    "contracting_agency_id": {"type": "string", "description": "Contracting agency code (e.g. 1700 for Navy)."},
                },
            ),
            _tool(
                "fpds_vendor_profile",
                "Get a vendor intelligence profile by UEI. Returns vendor summary stats, agency footprint with ranks, NAICS concentration, cross-agency presence, and contracts in the recompete pipeline. Use this when you need a complete picture of a vendor's federal presence.",
                {
                    "uei": {"type": "string", "description": "Vendor UEI (Unique Entity Identifier, 12 characters)."},
                    "contracting_dept_id": {"type": "string", "description": "Optional FPDS department code to scope results."},
                    "contracting_agency_id": {"type": "string", "description": "Optional FPDS agency code to scope results."},
                },
                ["uei"],
            ),
            _tool(
                "fpds_topic_profile",
                "Get a topic intelligence profile for a federal department. Returns top procurement topics by assignment frequency, trend classifications (growing/stable/declining), competitive landscape per topic, NAICS decompositions, and links to strategic documents. Use this for deep sub-market analysis of what an agency actually buys.",
                {
                    "department_code": {"type": "string", "description": "Department code (USASpending 3-digit format, e.g. '097' for DoD, '036' for VA)."},
                    "topic_id": {"type": "integer", "description": "Optional: focus on a specific topic ID for competitive and NAICS detail."},
                    "q": {"type": "string", "description": "Optional: keyword filter to find topics matching a capability domain (e.g. 'cybersecurity', 'cloud')."},
                },
                ["department_code"],
            ),
            _tool(
                "fpds_topic_search",
                "Search procurement topics by keyword. Finds machine-derived sub-market topics matching a text query across 9,313 merged topics and 4,969 govwide canonical topics. Topics are a semantic dimension parallel to NAICS — they decompose broad classification codes into what agencies actually buy. Use fpds_resolve(types=['topics']) for quick canonical topic lookups, or this tool for comprehensive cross-corpus search with department scoping. Use when a user asks about specific procurement domains like 'cybersecurity', 'cloud migration', 'medical devices', etc.\n\nFor capability-level vendor rankings (e.g., 'who wins AI/ML contracts'), use keyword_analytics for pre-aggregated vendor rankings by keyword with obligation data. Topics provide sub-market decomposition; keywords provide capability-level vendor rankings.",
                {
                    "q": {"type": "string", "description": "Topic search query — a procurement domain, technology, or capability (e.g. 'cybersecurity', 'cloud', 'medical devices')."},
                    "department_code": {"type": "string", "description": "Optional USASpending department code to scope results to one agency."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max results (default 10)."},
                    "include_canonical": {"type": "boolean", "description": "Also search govwide canonical topics (default true)."},
                },
                ["q"],
            ),
            _tool(
                "fpds_contract_history",
                "Get the transaction-level modification history for a specific contract PIID. Returns every modification with descriptions, reason codes, obligation amounts, and dates. Use this when you need to understand WHAT HAPPENED on a contract — scope changes, option exercises, funding increments, de-obligations, and more. This is the drill-down layer that the recompete watchlist and vendor dashboards point to.",
                {
                    "piid": {"type": "string", "description": "Contract PIID (e.g. W31P4Q21FB004, N0001920C0009). Required."},
                    "reason_for_modification": {"type": "string", "description": "Filter by modification reason code (B=supplemental agreement within scope, F=exercise an option, C=funding only, A=change order, etc.)."},
                    "contract_action_type": {"type": "string", "description": "Filter by action type code (A=definitive contract, B=purchase order, C=delivery order, D=BPA call)."},
                    "sort": {"type": "string", "description": "Sort field (default: -signed_date for newest first)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Max rows (default 100)."},
                },
                ["piid"],
            ),
            _tool(
                "fpds_onboarding",
                "Getting-started guide and navigation map for FPDS Analytics. Returns a structured reference covering: what FPDS Analytics is, the 17 intelligence domains with what each answers, common workflow patterns (which datasets to use for specific questions), the recommended query sequence (resolve → describe → query), how keyword-level analysis complements topic intelligence, and pointers to available documentation resources. Call this when a user is new to the tool or asks 'what can I do with this?' or 'how do I get started?'. No arguments required.",
                {},
            ),
            # ── Keyword-level tools ─────────────────────────────────────
            _tool(
                "keyword_search",
                "Search procurement keywords by text substring. Searches the keywords table (product_vendor, method_service, system_program categories by default — noise categories are excluded) and returns keyword metadata with link counts and top departments. Use this to discover capabilities, vendor names, or program names mentioned in contract descriptions.",
                {
                    "q": {"type": "string", "description": "Search query — substring match on keyword text."},
                    "keyword_type": {"type": "array", "items": {"type": "string"}, "description": "Filter by keyword type: phrase, term. Default: both."},
                    "category": {"type": "array", "items": {"type": "string"}, "description": "Filter by category: product_vendor, method_service, system_program. Default: all three."},
                    "department_code": {"type": "string", "description": "USASpending department code filter (e.g. '070' for DHS)."},
                    "min_link_count": {"type": "integer", "description": "Minimum total link count (popularity filter, default 2)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max results (default 25)."},
                },
                ["q"],
            ),
            _tool(
                "keyword_analytics",
                "Get procurement analytics for a specific keyword. Returns award count, total obligation dollars, breakdown by agency/vendor/fy/naics/set_aside, and FY spending trend. Uses pre-computed obligation data from keyword_link_metadata. Obligation data is reliable; award counts may be sparse for some departments.",
                {
                    "keyword_id": {"type": "integer", "description": "Keyword ID from keyword_search results."},
                    "keyword_text": {"type": "string", "description": "Exact keyword text (case-insensitive match)."},
                    "department_code": {"type": "string", "description": "USASpending department code filter (e.g. '070' for DHS)."},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                    "group_by": {"type": "string", "description": "Breakdown dimension: agency, vendor, fy, naics, set_aside. Default: agency."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max rows in breakdown (default 25)."},
                },
            ),
            _tool(
                "keyword_vs_topic",
                "Bridge keywords to BERTopic topics and vice versa. Two modes: (1) keyword → topics: provide keyword_id or keyword_text to see which topics the keyword maps to; (2) topic → keywords: provide topic_id to see which keywords are most associated with that topic. Department code scoping recommended — topic IDs are per-department.",
                {
                    "keyword_id": {"type": "integer", "description": "Keyword ID for keyword→topics mode."},
                    "keyword_text": {"type": "string", "description": "Exact keyword text for keyword→topics mode."},
                    "topic_id": {"type": "integer", "description": "Topic ID for topic→keywords mode."},
                    "department_code": {"type": "string", "description": "Department filter (e.g. '097' for Army). Topic IDs are per-department."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max results (default 15)."},
                },
            ),
            _tool(
                "keyword_compare",
                "Compare multiple keywords side-by-side on procurement metrics. Returns award count, total obligation, unique vendors, unique agencies, FY trend, and top 3 agencies for each keyword. Useful for competitive positioning questions like 'Salesforce vs ServiceNow vs Oracle at DHS.'",
                {
                    "keywords": {"type": "array", "items": {"type": "string"}, "description": "List of keyword texts to compare (e.g. ['Salesforce', 'ServiceNow'])."},
                    "keyword_ids": {"type": "array", "items": {"type": "integer"}, "description": "List of keyword IDs to compare."},
                    "department_code": {"type": "string", "description": "USASpending department code filter (e.g. '070' for DHS)."},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                },
            ),
            _tool(
                "keyword_vendor_profile",
                "Get keyword profile for a vendor by UEI. Returns all keywords a vendor appears in across federal awards, with award counts, obligation amounts, agency coverage per keyword, and a summary with department coverage. Useful for questions like 'what capabilities does this vendor compete in?'",
                {
                    "uei": {"type": "string", "description": "Vendor UEI (Unique Entity Identifier, e.g. 'C6FQH2VLCVL9')."},
                    "department_code": {"type": "string", "description": "USASpending department code filter (e.g. '070' for DHS)."},
                    "category": {"type": "array", "items": {"type": "string"}, "description": "Keyword categories: product_vendor, method_service, system_program. Default: all three."},
                    "fy_start": {"type": "integer", "description": "Start fiscal year (default 2018)."},
                    "fy_end": {"type": "integer", "description": "End fiscal year (default 2026)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 200, "description": "Max keywords (default 50)."},
                },
                ["uei"],
            ),
        ]

    def _onboarding_guide(self) -> str:
        return (
            "# FPDS Analytics: Getting Started\n\n"
            "FPDS Analytics is a read-only intelligence layer over 99M federal procurement records. "
            "It converts raw FPDS transactions into 88 pre-computed analytics datasets across 17 domains — "
            "each dataset answers a specific business question about the federal contracting market.\n\n"
            "## What FPDS Analytics is NOT\n\n"
            "- It is NOT raw transaction search. For individual contract lookups, use USASpending.gov or SAM.gov.\n"
            "- It is NOT real-time. Data refreshes periodically; check `data_as_of` in response metadata.\n"
            "- It does NOT contain classified, grant, or subcontract data.\n"
            "- Department code 9700 ≠ all DoD opportunity. DoD work can appear under other codes.\n"
            "- It describes patterns, not guarantees. Use it for market intelligence, not contract action.\n\n"
            "## The 17 Domains — What Each Answers\n\n"
            "| Domain | It Answers | Key Dataset |\n"
            "|---|---|---|\n"
            "| **Pricing** | How do agencies structure contracts? Fixed-price, cost-type, or T&M? | `pricing.risk_scorecard` |\n"
            "| **Concentration** | Is the market open or dominated? Who are the incumbents? | `concentration.vendor_market_leaders` |\n"
            "| **Competition** | Competed or sole-source? How many offers per action? | `competition.sole_source_hotspots` |\n"
            "| **NAICS** | Which industries are growing? Who buys each NAICS? | `naics.growth_leaders` |\n"
            "| **Geography** | Where is work performed? Local vs out-of-state patterns? | `geography.state_trend_fy` |\n"
            "| **Customer** | Who's buying, what are their patterns, how many offices? | `customer.agency_profile_fy` |\n"
            "| **Market** | How big is a specific agency×NAICS market? How hard to enter? | `market.entry_difficulty_score` |\n"
            "| **Incumbent** | Who wins at each agency, how long have they been there? | `incumbent.agency_vendor_leaders` |\n"
            "| **Set-Aside** | Which agencies use 8(a), SDVOSB, WOSB, HUBZone programs? | `set_aside.agency_profile_fy` |\n"
            "| **PSC** | What products/services are bought? How do PSCs map to NAICS? | `psc.naics_crosswalk` |\n"
            "| **Acquisition** | GWAC, Schedule, IDIQ, or open market? Do I need a vehicle? | `acquisition.agency_vehicle_mix_fy` |\n"
            "| **Pipeline** | What contracts are expiring? When? How confident is the signal? | `pipeline.recompete_watchlist` |\n"
            "| **Seasonality** | When during the fiscal year do agencies buy? Q4 spike? | `seasonality.agency_month_fy` |\n"
            "| **Topics** | What does an agency actually buy (sub-NAICS machine discovery)? | `topics.catalog` |\n"
            "| **Contacts** | Which contracting officers buy my NAICS? What are their patterns? | `contacts.naics_buyers` |\n"
            "| **Entrants** | Do new vendors survive at this agency? What's the foothold size? | `entrants.agency_cohort_fy` |\n"
            "| **Funding** | Who funds vs who executes? Cross-agency assisted acquisition? | `funding.mismatch_flows_fy` |\n\n"
            "## Recommended Query Sequence\n\n"
            "1. **Resolve names to codes** — use `fpds_resolve` to find agency, department, NAICS, or PSC codes from plain-English names.\n"
            "2. **Inspect a dataset** — use `fpds_describe_dataset` to see allowed filters, sort fields, examples, and caveats.\n"
            "3. **Query rows** — use `fpds_query_dataset` with at least one filter. Unfiltered queries on large datasets time out.\n"
            "4. **Interpret** — include the response caveats and notices in your explanation. Do not invent data.\n"
            "5. **Drill deeper** — use `fpds_contract_history` for individual contract details.\n\n"
            "## Common Workflow Patterns\n\n"
            "### I sell [capability]. Which agencies should I target?\n"
            "1. `fpds_resolve` → find your NAICS code\n"
            "2. `fpds_query_dataset` on `naics.growth_leaders` with your NAICS → confirm growth\n"
            "3. `fpds_query_dataset` on `market.naics_customer_leaders` → see which agencies buy it\n"
            "4. `fpds_query_dataset` on `market.entry_difficulty_score` → rank agencies by accessibility\n\n"
            "### I want to pursue [agency]. Help me understand them.\n"
            "1. `fpds_resolve` → find the agency code\n"
            "2. Use `fpds_customer_profile` for the 8-section composite\n"
            "3. Drill into `pricing.risk_scorecard`, `competition.sole_source_hotspots`, `acquisition.agency_vehicle_mix_fy`\n"
            "4. Check `pipeline.recompete_watchlist` for upcoming opportunities\n"
            "5. Query `contacts.office_roster` for key personnel\n\n"
            "### I need to find expiring contracts to pursue.\n"
            "1. `fpds_query_dataset` on `pipeline.agency_recompete_summary` → how big is the pipeline?\n"
            "2. `fpds_query_dataset` on `pipeline.recompete_watchlist` → specific contracts\n"
            "3. `fpds_query_dataset` on `contacts.recompete_handlers` → who handled them?\n"
            "4. `fpds_contract_history` for deep modification intelligence on target PIIDs\n\n"
            "### I'm a small business. Which agencies and topics use set-asides?\n"
            "1. `fpds_query_dataset` on `set_aside.agency_profile_fy` → ranked by friendliness\n"
            "2. `fpds_query_dataset` on `set_aside.agency_mix_fy` → specific programs used\n"
            "3. `fpds_query_dataset` on `topics.set_aside_profile` → which topics flow through set-asides\n"
            "4. `fpds_query_dataset` on `entrants.agency_cohort_fy` → can new vendors survive here?\n\n"
            "### What does [agency] actually buy? (beyond NAICS codes)\n"
            "1. `fpds_query_dataset` on `topics.agency_profile` → full topic distribution\n"
            "2. `fpds_query_dataset` on `topics.trends` with trend_classification='growing' → what's expanding?\n"
            "3. `fpds_query_dataset` on `topics.competitive_landscape` → who dominates each topic?\n"
            "4. `fpds_query_dataset` on `topics.document_links` → strategic document backing\n\n"
            "## Available Documentation Resources\n\n"
            "Ask me to read these resources for deeper context:\n"
            "- `fpds://docs/methodology` — How every number is computed\n"
            "- `fpds://docs/datasets` — Field-by-field reference\n"
            "- `fpds://docs/caveats` — Data limitations\n"
            "- `fpds://docs/ai-assistant-guide` — AI assistant usage patterns\n"
            "- `fpds://docs/notices` — Critical interpretation caveats\n\n"
            "## Pre-Built Prompt Workflows\n\n"
            "Eight guided prompts are available. Say 'show me the prompts' to see:\n"
            "- Assess market entry difficulty\n"
            "- Find expiring contracts\n"
            "- Discover what an agency actually buys\n"
            "- Profile a customer agency\n"
            "- Find contracting officers for a NAICS\n"
            "- Find growth NAICS with weak competition\n"
            "- Map vendor competitive landscape\n"
            "- Find set-aside opportunities\n\n"
            "## Keyword-Level Analysis\n\n"
            "Keyword tools provide capability-level procurement intelligence built from\n"
            "extracted phrases and terms found in contract descriptions. Keywords are categorized as\n"
            "product_vendor (e.g. 'Microsoft Azure', 'Salesforce'), method_service (e.g. 'agile\n"
            "development', 'penetration testing'), or system_program (e.g. 'Cerner EHR', 'JPAS').\n\n"
            "### Keywords vs Topics — When to Use Which\n\n"
            "- **Topics** decompose procurement into coherent sub-markets (BERTopic clusters). Use them\n"
            "  to understand what an agency buys at a macro level ('this agency buys cloud migration\n"
            "  services') and how sub-markets relate to each other.\n"
            "- **Keywords** map specific capabilities, vendors, and technologies to awards. Use them for\n"
            "  vendor rankings, capability-level competitive analysis, and precise market sizing.\n\n"
            "### Available Keyword Tools\n\n"
            "- **keyword_search** — Find keywords by text substring across any category.\n"
            "- **keyword_analytics** — Vendor/agency/FY/NAICS/set-aside breakdowns by capability.\n"
            "  Use group_by=\"vendor\" for server-side vendor rankings with obligation data.\n"
            "- **keyword_compare** — Side-by-side comparison of multiple keywords (e.g.\n"
            "  'Salesforce vs ServiceNow vs Oracle at DHS').\n"
            "- **keyword_vs_topic** — Bridge keywords to BERTopic topics and vice versa.\n"
            "  Provide a keyword to see which topics it maps to, or a topic to see associated keywords.\n"
            "- **keyword_vendor_profile** — All keywords associated with a vendor by UEI.\n\n"
        )

    def prompts(self) -> list[dict[str, Any]]:
        return [
            {
                "name": "assess_market_entry_difficulty",
                "description": "Assess how structurally hard it is to enter a specific agency x NAICS market. Uses the Market Entry Difficulty Score — a composite 0-100 metric combining vendor concentration (HHI), sole-source prevalence, vehicle dependence, low offer intensity, and incumbent tenure. Compares entry difficulty across agencies so you can prioritize targets.",
                "arguments": [
                    _prompt_arg("naics_code", "6-digit NAICS code for your capability (e.g. 541512 for IT consulting, 541330 for engineering). Use fpds_resolve to find NAICS codes from plain-English descriptions.", True),
                    _prompt_arg("agency_name", "Optional: agency or department name to scope to (e.g. 'Department of Veterans Affairs', 'Army'). If omitted, compares all agencies.", False),
                ],
            },
            {
                "name": "find_expiring_contracts",
                "description": "Find contracts expiring soon that you can chase for recompete. Pulls from the Recompete Watchlist — pre-computed expiration pipeline with confidence scores (HIGH/MEDIUM/LOW), remaining months, and obligation amounts. Also links each contract to the contracting officers who created and approved it, so you know who to contact.",
                "arguments": [
                    _prompt_arg("agency_name", "Agency or department name to search (e.g. 'Department of Homeland Security', 'Navy').", True),
                    _prompt_arg("naics_code", "Optional: 6-digit NAICS code to filter for your specific capability area.", False),
                    _prompt_arg("expiration_window", "How soon contracts should expire: '0-6 months', '6-12 months', '12-18 months', or '18-24 months'. Default is 0-12 months.", False),
                ],
            },
            {
                "name": "discover_what_agency_actually_buys",
                "description": "Discover what an agency actually buys at sub-NAICS resolution using Topic Intelligence — machine-derived procurement sub-markets from BERTopic analysis of 99M+ contract descriptions. NAICS codes are broad; topic decomposition reveals the real sub-markets (e.g. 'cloud migration services' vs 'cybersecurity operations' within the same 541512 code). Also shows which topics are growing, who dominates each topic, and how topics link to the agency's strategic documents.",
                "arguments": [
                    _prompt_arg("agency_name", "Agency or department name to profile (e.g. 'Department of Veterans Affairs', 'NASA').", True),
                    _prompt_arg("topic_keyword", "Optional: filter topics by keyword (e.g. 'cybersecurity', 'cloud', 'medical devices', 'construction').", False),
                ],
            },
            {
                "name": "profile_customer_agency",
                "description": "Generate a complete customer profile for a federal agency. Pulls from the Customer 360 composite endpoint, covering 8 analytical dimensions in one pass: spend trends, top NAICS, competition posture (competed vs sole-source), pricing structure mix (FFP/cost/T&M), set-aside program usage, incumbent vendors, acquisition vehicle paths (GWAC/IDIQ/Schedule), and upcoming recompete signals. Also surfaces pricing risk and non-competition reason patterns.",
                "arguments": [
                    _prompt_arg("agency_name", "Agency or department name to profile (e.g. 'Department of Energy', 'DHS').", True),
                ],
            },
            {
                "name": "find_contracting_officers_for_naics",
                "description": "Find the specific contracting officers who buy what you sell. Identifies COs by NAICS code, showing their buying volume, set-aside rates, sole-source tendencies, career span, and agency affiliations. Includes behavioral indicators so you can identify COs who favor small business, run competitive procurements, or work heavily in your NAICS. Optionally scope to a specific agency.",
                "arguments": [
                    _prompt_arg("naics_code", "6-digit NAICS code for your capability (e.g. 541512, 541330, 561210).", True),
                    _prompt_arg("agency_name", "Optional: agency or department name to scope to.", False),
                ],
            },
            {
                "name": "find_growth_naics_with_weak_competition",
                "description": "Find NAICS codes where demand is growing AND competition is weak — the sweet spot for market entry. Cross-references NAICS Growth Leaders (pre-computed YoY growth rates across the two most recent complete fiscal years) with Market Entry Difficulty Scores. Identifies markets with expanding demand and structural accessibility for new entrants.",
                "arguments": [
                    _prompt_arg("sector_name", "Optional: NAICS sector to scope to (e.g. 'Professional Services' = sector 54, 'Manufacturing' = 31-33, 'Construction' = 23).", False),
                    _prompt_arg("agency_name", "Optional: agency or department name to scope growth analysis to.", False),
                    _prompt_arg("min_growth_pct", "Minimum YoY growth percentage (default: 10). Higher = stronger growth signal.", False),
                ],
            },
            {
                "name": "map_vendor_competitive_landscape",
                "description": "Map the competitive landscape: who wins where, how entrenched are they, and what's their cross-agency footprint. Analyzes vendor market leaders by agency and NAICS, shows cross-agency rankings (where else does this vendor dominate?), tracks incumbent tenure, and reveals new-entrant survival rates at specific agencies. Use this to understand incumbency depth, identify teaming partners, or size up competitors.",
                "arguments": [
                    _prompt_arg("agency_name", "Agency or department name to analyze (e.g. 'Army', 'HHS', 'GSA').", True),
                    _prompt_arg("naics_code", "Optional: 6-digit NAICS code to scope vendor analysis to a specific industry.", False),
                    _prompt_arg("vendor_filter", "Optional: focus analysis on small business, veteran-owned, minority-owned, or women-owned vendors.", False),
                ],
            },
            {
                "name": "find_agency_set_aside_opportunities",
                "description": "Find agencies that actively use set-aside programs matching your business type — and identify which technical topics within those agencies flow through set-asides. Uses agency set-aside friendliness rankings cross-referenced with topic-level set-aside profiles. Tells you not just which agencies use set-asides, but exactly what kind of work they set aside for 8(a), SDVOSB, WOSB, HUBZone, or small business.",
                "arguments": [
                    _prompt_arg("set_aside_type", "Your business type: '8(a)', 'SDVOSB', 'WOSB', 'HUBZone', or 'small business'.", True),
                    _prompt_arg("naics_code", "Optional: 6-digit NAICS code to scope to your capability area.", False),
                    _prompt_arg("topic_keyword", "Optional: filter the topics analysis by keyword (e.g. 'IT', 'security', 'construction').", False),
                ],
            },
        ]

    def get_prompt(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        prompts = {
            "assess_market_entry_difficulty": self._prompt_assess_market_entry_difficulty,
            "find_expiring_contracts": self._prompt_find_expiring_contracts,
            "discover_what_agency_actually_buys": self._prompt_discover_what_agency_actually_buys,
            "profile_customer_agency": self._prompt_profile_customer_agency,
            "find_contracting_officers_for_naics": self._prompt_find_contracting_officers_for_naics,
            "find_growth_naics_with_weak_competition": self._prompt_find_growth_naics_with_weak_competition,
            "map_vendor_competitive_landscape": self._prompt_map_vendor_competitive_landscape,
            "find_agency_set_aside_opportunities": self._prompt_find_agency_set_aside_opportunities,
        }
        handler = prompts.get(name)
        if not handler:
            raise ValueError(f"Unknown prompt: {name}")
        messages = handler(arguments)
        return {
            "description": messages[0]["content"]["text"].split("\n")[0] if messages else "",
            "messages": messages,
        }

    def _prompt_assess_market_entry_difficulty(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        naics = args.get("naics_code", "")
        agency = args.get("agency_name", "")
        agency_filter = f" at {agency}" if agency else ""
        scope_clause = f"For {agency}, " if agency else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I need to assess how hard it is to enter the market for NAICS {naics}{agency_filter}.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    "1. **Resolve the NAICS code** — use `fpds_resolve` with types=['naics'] to confirm the NAICS code and get its description.\n\n"
                    f"2. **{scope_clause if scope_clause else ''}Get Market Entry Difficulty Scores** — query `market.entry_difficulty_score` "
                    f"with principal_naics_code={naics}"
                    f"{' and contracting_agency_id=<resolved_id>' if agency else ''}"
                    ". Sort by entry_difficulty_score descending. This gives you a 0-100 composite score per agency x NAICS composed of: HHI (vendor concentration), not-competed action share, vehicle dependence, low offer intensity, and incumbent tenure.\n\n"
                    "3. **Drill into the difficulty components** — for the top 3 hardest agencies, explain what's driving their scores. High HHI = concentrated incumbents. High not-competed share = sole-source risk. High vehicle dependence = you need a contract vehicle to play. Low offers = few competitors getting a shot. High incumbent tenure = long-entrenched winners.\n\n"
                    "4. **Check sole-source hotspots** — query `competition.sole_source_hotspots` to see which agencies have the highest sole-source rates overall (not just for this NAICS). Cross-reference with the entry difficulty results.\n\n"
                    "5. **Look at award sizes** — query `pipeline.award_size_distribution` for this NAICS and the target agencies. Are contracts small and reachable or large and consolidated? Include median award size and share under simplified acquisition threshold.\n\n"
                    "6. **Identify the incumbents** — query `incumbent.agency_vendor_leaders` or `incumbent.agency_naics_vendor_leaders` for the target agencies. Who holds the market?\n\n"
                    "7. **Check new-entrant survival** — query `entrants.agency_cohort_fy` for the target agencies. What percentage of first-time vendors survive past year two?\n\n"
                    "Synthesize into: (a) overall entry difficulty assessment, (b) top 3 hardest and easiest agencies to enter, (c) what specifically makes each hard or easy, (d) recommended entry strategy — teaming recommendation if high incumbent tenure, vehicle acquisition advice if high vehicle dependence, sub-market targeting within the NAICS using topic intelligence."
                ),
            },
        }]

    def _prompt_find_expiring_contracts(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        agency = args.get("agency_name", "")
        naics = args.get("naics_code", "")
        window = args.get("expiration_window", "0-12 months")
        naics_clause = f" for NAICS {naics}" if naics else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I want to find expiring contracts I can pursue for recompete at {agency}{naics_clause}. Focus on contracts expiring within {window}.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Resolve the agency** — use `fpds_resolve` with types=['agencies'] to find the contracting_agency_id for '{agency}'.\n\n"
                    f"2. **Get the recompete summary** — query `pipeline.agency_recompete_summary` with contracting_agency_id=<resolved_id>. This shows how many contracts expire in each window (0-6, 6-12, 12-18, 18-24 months) and their total obligated value. Gives you the big-picture pipeline size.\n\n"
                    f"3. **Pull the watchlist** — query `pipeline.recompete_watchlist` with contracting_agency_id=<resolved_id>"
                    f"{' and principal_naics_code=' + naics if naics else ''}"
                    f". Focus on contracts in the '{window}' window. Sort by remaining_months ascending to see nearest expirations first.\n\n"
                    "For each high-value/interesting contract, note:\n"
                    "- PIID (contract ID), vendor name, NAICS, PSC\n"
                    "- Total obligated, base and all options value\n"
                    "- Remaining months, expiration bucket, recompete confidence (HIGH/MEDIUM/LOW)\n"
                    "- Current completion date\n"
                    "- Competition family (was this competed originally?)\n"
                    "- Set-aside status\n\n"
                    "4. **Identify the handlers** — query `contacts.recompete_handlers` with the same agency filter. This links each expiring contract to the contracting officer who created it and the most recent human approver. Note which COs handle the highest-value contracts.\n\n"
                    "5. **For the top 3-5 contracts, get full history** — use `fpds_contract_history` with each PIID to see the modification trail: scope changes, option exercises, funding increments, de-obligations. This tells you the real story of the contract.\n\n"
                    "6. **Check contract durations** — query `pipeline.duration_profile` for the agency and relevant NAICS. Are contracts usually 1-year, 3-year, or 5-year? This helps you anticipate the next contract structure.\n\n"
                    "Synthesize into: (a) pipeline overview (how many contracts, total value, urgency), (b) top 5-10 highest-value targets with recompete confidence, incumbent, CO contact, and key dates, (c) modification history insights for the top targets, (d) recommended capture timeline based on expiration dates and typical procurement lead times."
                ),
            },
        }]

    def _prompt_discover_what_agency_actually_buys(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        agency = args.get("agency_name", "")
        keyword = args.get("topic_keyword", "")
        keyword_clause = f" related to '{keyword}'" if keyword else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I want to understand what {agency} actually buys — beyond broad NAICS codes — using topic intelligence{keyword_clause}.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Resolve the agency** — use `fpds_resolve` with types=['agencies', 'departments'] to find the department_code and contracting_dept_id for '{agency}'.\n\n"
                    f"2. **Browse the topic catalog** — query `topics.catalog` with department_code=<resolved_code> and corpus_type='merged'. "
                    f"{'Add q=' + repr(keyword) + ' to search for specific topics.' if keyword else 'Sort by -assignment_count to see the largest topics first.'} "
                    "This shows every machine-derived procurement topic — semantically coherent clusters of what this agency actually buys, discovered from 99M+ contract descriptions.\n\n"
                    "3. **Get the agency topic profile** — query `topics.agency_profile` with department_code=<resolved_code>. Sort by -assignment_count. This shows the full topic distribution with obligation amounts, topic shares, and office-level grain.\n\n"
                    "4. **For key topics, decompose into NAICS** — query `topics.naics_decomposition` with department_code=<resolved_code> and optionally topic_id=<id>. This shows which NAICS codes map to each topic — sometimes a topic spans 5+ NAICS codes, revealing cross-industry procurement patterns.\n\n"
                    "5. **Check topic trends** — query `topics.trends` with department_code=<resolved_code> and trend_classification='growing'. Are key topics expanding or contracting year-over-year? Growing topics signal expanding budgets.\n\n"
                    "6. **Map the competitive landscape by topic** — query `topics.competitive_landscape` with department_code=<resolved_code> for the most relevant topics. Who dominates each sub-market?\n\n"
                    "7. **Link topics to strategic documents** — query `topics.document_links` with department_code_document=<resolved_code>. Which topics are referenced in agency strategic plans, budget documents, or oversight reports? Topics that appear in strategic documents signal priority areas with budget backing.\n\n"
                    "8. **Check govwide canonical topics** — query `topics.govwide_canonical` to see cross-agency topic patterns. Does this agency's topic profile align with or diverge from government-wide procurement patterns?\n\n"
                    "Synthesize into: (a) top 10-15 topics by spend and growth, (b) which topics are growing vs declining, (c) who dominates each key topic, (d) which topics are backed by strategic documents (priority areas), (e) recommended capability areas to target based on growth + accessibility + strategic alignment."
                ),
            },
        }]

    def _prompt_profile_customer_agency(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        agency = args.get("agency_name", "")
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I want a complete procurement profile for {agency} — how they buy, who dominates, and where the gaps and opportunities are.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Resolve the agency** — use `fpds_resolve` with types=['agencies', 'departments'] to find the contracting_dept_id, contracting_agency_id, and department_code for '{agency}'.\n\n"
                    "2. **Get the Customer 360 profile** — use `fpds_customer_profile` with contracting_dept_id=<resolved_dept_id> and contracting_agency_id=<resolved_agency_id>. This composite endpoint returns 8 analytical sections: spend trend, top NAICS, competition posture (competed% vs sole-source%), pricing structure mix (fixed-price vs cost vs T&M), set-aside program usage, top incumbent vendors, acquisition vehicle breakdown (GWAC/Schedule/IDIQ/Open Market), recompete signals, and narrative hints.\n\n"
                    "3. **Deep-dive on pricing risk** — query `pricing.agency_profile_fy` and `pricing.risk_scorecard` for the agency. Does this agency favor cost-type contracts (higher risk, harder for small business) or fixed-price (more accessible)? What's their T&M exposure?\n\n"
                    "4. **Understand competition dynamics** — query `competition.agency_profile_fy` for the agency. What's their competed vs sole-source split? How many offers per action on average? How much is bundled or consolidated?\n\n"
                    "5. **Examine non-competition reasons** — query `competition.not_competed_reasons_fy` for the agency. Are they sole-sourcing via 'only one source' (statutory), 'follow-on contract' (incumbency lock-in), or 'urgency'? Follow-on contracts signal the strongest incumbency.\n\n"
                    "6. **Analyze vehicle dependence** — query `acquisition.agency_vehicle_mix_fy` for the agency. What share of obligations flow through GWACs, Schedules, IDIQs vs open market? Do you need a vehicle to compete here?\n\n"
                    "7. **Check set-aside usage** — query `set_aside.agency_profile_fy` for the agency. What's their set-aside share? What specific programs do they use (8a, SDVOSB, WOSB, HUBZone)? What's their friendliness rank?\n\n"
                    "8. **Identify incumbents** — query `incumbent.agency_vendor_leaders` for the agency. Sort by vendor_rank. Who are the top 10 vendors? How long have they been there (tenure_years)? What's their 3-year obligation?\n\n"
                    "9. **Assess new-entrant opportunity** — query `entrants.agency_cohort_fy` for the agency. How many new vendors enter each year? What's the 2-year survival rate? What's the median first-year foothold size?\n\n"
                    "10. **Map funding flows** — query `funding.assisted_acquisition_fy` for the agency. Does this agency execute contracts for other agencies (assisted acquisition)? Or does it rely on others (like GSA, DISA) to buy for it? Cross-department flows reveal hidden buying paths.\n\n"
                    "Synthesize into a structured customer brief: (a) agency overview (total spend, YoY trend, composition), (b) buying behavior (pricing, competition, vehicle paths), (c) incumbent landscape (top vendors, tenure, concentration), (d) accessibility scorecard (new-entrant viability, set-aside gateway, vehicle requirements), (e) specific opportunities (growing NAICS + expiring contracts + accessible PSC codes), (f) recommended capture strategy."
                ),
            },
        }]

    def _prompt_find_contracting_officers_for_naics(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        naics = args.get("naics_code", "")
        agency = args.get("agency_name", "")
        agency_clause = f" at {agency}" if agency else " across all agencies"
        resolve_agency_step = (
            f"2. **Resolve the agency** — use `fpds_resolve` with types=['agencies'] to find the contracting_agency_id for '{agency}'.\n\n"
            if agency else ""
        )
        agency_filter = " and contracting_agency_id=<resolved_id>" if agency else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I need to find the contracting officers who buy NAICS {naics}{agency_clause}.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Resolve the NAICS code** — use `fpds_resolve` with types=['naics'] to confirm the NAICS code and get its description.\n\n"
                    f"{resolve_agency_step}"
                    f"3. **Find NAICS buyers** — query `contacts.naics_buyers` with principal_naics_code={naics}"
                    f"{agency_filter}"
                    ". Sort by -obligated_amount to see the largest buyers first. This returns every CO who has awarded contracts in this NAICS, with their buying volume, set-aside percentage, sole-source percentage, and agency affiliation.\n\n"
                    "4. **For the top COs, get full profiles** — use their user_id to query `contacts.detail`. This shows their career span, behavioral indicators (set-aside rates, sole-source rates), primary NAICS, primary office, email, active status, and lifetime procurement volume across all agencies and offices.\n\n"
                    "5. **Check office coverage** — query `contacts.office_coverage` for the relevant agencies/offices. What share of procurement activity is attributed to identified human COs vs system accounts? Low coverage = many awards can't be traced to a person.\n\n"
                    "6. **Look at the CO's full year-over-year trajectory** — use a top CO's user_id to query `contacts.profile_fy`. Are they buying more or less over time? Are they moving between offices?\n\n"
                    "7. **Find their office roster context** — query `contacts.office_roster` for the CO's primary office. Who else works in that office? Understanding the full office team helps with relationship planning.\n\n"
                    "Identify: (a) top 10 COs by obligation volume in your NAICS, (b) which COs favor set-asides (easier entry for small business), (c) which COs have high sole-source rates (harder to break in), (d) which COs are still active (recent_2fy_actions > 0), (e) any COs who handle recompete contracts — cross-reference with `contacts.recompete_handlers`, (f) key offices with the most CO activity for your NAICS."
                ),
            },
        }]

    def _prompt_find_growth_naics_with_weak_competition(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        sector = args.get("sector_name", "")
        agency = args.get("agency_name", "")
        min_growth = args.get("min_growth_pct", "10")
        sector_clause = f" in the {sector} sector" if sector else ""
        agency_clause = f" for {agency}" if agency else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I'm looking for NAICS codes{sector_clause} where demand is growing and competition is structurally weak{agency_clause} — the best targets for market entry. Filter for YoY growth of at least {min_growth}%.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Find growth leaders** — query `naics.growth_leaders`"
                    f"{' with sector_code=<resolved>' if sector else ''}"
                    f". Sort by -obligation_growth_rate. This returns NAICS codes ranked by YoY obligation growth between the two most recent complete fiscal years. Each row shows current year obligations, prior year obligations, absolute change, and growth rate. By default it filters to credible markets ($10M+ prior year baseline).\n\n"
                    "2. **For the top growing NAICS, find the customer agencies** — query `market.naics_customer_leaders` with principal_naics_code=<code> for the top 5-10 growth NAICS. This shows which agencies buy each NAICS, ranked by 3-year obligation, with small business share and competition metrics.\n\n"
                    f"{'3. **Scope growth to the target agency** — if the user specified an agency, query `market.agency_naics_fy` with contracting_agency_id=<resolved> and fiscal_year=<latest>. Sort by net_obligated_amount descending. This shows what the specific agency buys by NAICS.' if agency else ''}\n\n"
                    "4. **Cross-reference with entry difficulty** — for each promising NAICS + agency combination, query `market.entry_difficulty_score` with principal_naics_code=<code> and optionally contracting_agency_id=<id>. Sort by entry_difficulty_score ascending to find the most accessible markets first.\n\n"
                    "5. **Check concentration** — query `concentration.agency_profile` for the target agencies. What's their average HHI, monopoly market percentage, and small business share? High small business share + low HHI = accessible.\n\n"
                    "6. **Check competition posture** — query `competition.agency_profile_fy` for the target agencies. High competed_action_share + high avg_offers_received = competitive but open. Low competed share = hard to break in regardless of growth.\n\n"
                    "7. **Verify with topic intelligence** — query `topics.naics_decomposition` for the most promising NAICS codes at the target agencies. Are there growing sub-topics within the NAICS where competition is lower?\n\n"
                    "Synthesize into a ranked opportunity list: (a) top 10-15 NAICS × agency combinations scored by growth potential + accessibility, (b) entry difficulty score for each, (c) key risk factors (incumbency, vehicle requirements, sole-source prevalence), (d) recommended approach for the top 3 targets."
                ),
            },
        }]

    def _prompt_map_vendor_competitive_landscape(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        agency = args.get("agency_name", "")
        naics = args.get("naics_code", "")
        vendor_filter = args.get("vendor_filter", "")
        naics_clause = f" in NAICS {naics}" if naics else ""
        filter_clause = f" focusing on {vendor_filter} vendors" if vendor_filter else ""
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I want to map the competitive landscape at {agency}{naics_clause}{filter_clause} — who wins, how entrenched are they, and what's their cross-agency footprint.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    f"1. **Resolve the agency** — use `fpds_resolve` with types=['agencies'] to find the contracting_agency_id for '{agency}'.\n\n"
                    f"2. **Get agency vendor leaders** — query `incumbent.agency_vendor_leaders` with contracting_agency_id=<resolved_id>"
                    f"{' and is_small_business=true' if vendor_filter and 'small' in vendor_filter.lower() else ''}"
                    ". Sort by vendor_rank. This shows the top vendors at the agency ranked by 3-year obligation, with tenure in years, active fiscal years, total obligated, and socioeconomic flags (small business, veteran-owned, women-owned, minority-owned).\n\n"
                    f"3. **Get NAICS-grain vendor leaders** — query `incumbent.agency_naics_vendor_leaders` with contracting_agency_id=<resolved_id>"
                    f"{' and principal_naics_code=' + naics if naics else ''}"
                    ". This shows who wins each NAICS market at the agency.\n\n"
                    "4. **For the top 5 vendors, check cross-agency footprint** — query `concentration.vendor_cross_agency_rank` with uei=<vendor_uei> and fiscal_year=<latest>. This shows every agency where this vendor has obligations, their rank at each agency, and their obligation share. Are they a one-agency shop or government-wide?\n\n"
                    "5. **Check global vendor market leaders** — query `concentration.vendor_market_leaders` with uei=<vendor_uei> for the top vendors. This shows their lifetime totals, agencies served, tenure, and small business status.\n\n"
                    "6. **Assess new-entrant viability** — query `entrants.agency_cohort_fy` with contracting_agency_id=<resolved_id> for the last 5 fiscal years. How many new vendors enter each year? What's the 2-year survival rate? Median first-year foothold? This tells you whether new entrants can realistically gain traction.\n\n"
                    "7. **Look at office-level vendor presence** — query `incumbent.office_vendor_leaders` with contracting_agency_id=<resolved_id>"
                    f"{' and principal_naics_code=' + naics if naics else ''}"
                    ". This shows which offices each vendor dominates — some vendors are agency-wide, others are office-specific.\n\n"
                    "Synthesize into: (a) competitive landscape overview (concentration level, number of active vendors, incumbent tenure distribution), (b) top 10 vendors with share, tenure, cross-agency footprint, and socioeconomic flags, (c) vulnerability analysis — which incumbents show signs of weakness (declining share, single-agency dependence, nearing small-business graduation thresholds), (d) new-entrant outlook — is there a real pathway for newcomers or is the market locked up?, (e) teaming partner recommendations — which incumbents would make strong primes for a small business to team with?"
                ),
            },
        }]

    def _prompt_find_agency_set_aside_opportunities(self, args: dict[str, Any]) -> list[dict[str, Any]]:
        set_aside = args.get("set_aside_type", "")
        naics = args.get("naics_code", "")
        keyword = args.get("topic_keyword", "")
        naics_clause = f" for NAICS {naics}" if naics else ""
        keyword_clause = f" in the '{keyword}' domain" if keyword else ""
        topic_keyword_step = (
            f"7. **Filter by topic keyword** — query `topics.set_aside_profile` with department_code=<resolved> and "
            f"set_aside_family='{set_aside}', then scan for topics matching '{keyword}'. "
            "This finds specific sub-markets where your capability intersects with set-aside programs.\n\n"
            if keyword else ""
        )
        return [{
            "role": "user",
            "content": {
                "type": "text",
                "text": (
                    f"I want to find federal agencies that actively use {set_aside} set-asides{naics_clause}{keyword_clause} so I can prioritize my business development.\n\n"
                    "Use the FPDS Analytics MCP tools to:\n\n"
                    "1. **Get overall set-aside trends** — query `set_aside.trend_fy` for the most recent fiscal years. This shows government-wide set-aside usage, the share of actions using set-asides, and modification vs base-award breakdowns.\n\n"
                    f"2. **Find the {set_aside} family trend** — query `set_aside.family_trend_fy` with set_aside_family='{set_aside}'. Sort by -fiscal_year. This shows year-over-year trends for this specific set-aside program government-wide. Is it growing or shrinking?\n\n"
                    f"3. **Rank agencies by {set_aside} friendliness** — query `set_aside.agency_profile_fy` with fiscal_year=<latest_complete>. Sort by friendliness_rank. This ranks every agency by their set-aside usage share. Note agencies with high set-aside share and high total obligation.\n\n"
                    f"4. **Check agency program mix** — query `set_aside.agency_mix_fy` with set_aside_family='{set_aside}' and fiscal_year=<latest_complete> for the top agencies. Sort by -net_obligated_amount. This shows exactly how much each agency spends through this specific program.\n\n"
                    f"5. **Cross-reference with your NAICS** — query `market.agency_naics_fy`"
                    f"{' with principal_naics_code=' + naics if naics else ''}"
                    " with fiscal_year=<latest_complete> for the top agencies. Check their small_biz_obligation_share. High share = this NAICS flows through small business at this agency.\n\n"
                    f"6. **Use topic intelligence for deeper targeting** — query `topics.set_aside_profile` with department_code=<resolved> and set_aside_family='{set_aside}' for the top agencies. Sort by -assignment_count. This reveals which specific technical topics within each agency flow through {set_aside} set-asides. A much more precise targeting signal than NAICS alone.\n\n"
                    f"{topic_keyword_step}"
                    "8. **Check the competition angle** — query `competition.agency_profile_fy` for the top target agencies. Even with set-asides, check competed_action_share and avg_offers_received. Some set-aside contracts still draw multiple bidders.\n\n"
                    f"Synthesize into: (a) overall {set_aside} landscape — total spend, growth trend, top-using agencies, (b) top 10 agencies ranked by {set_aside} spend + obligation volume + growth, (c) which specific NAICS and topics flow through {set_aside} at each agency, (d) competition level within the set-aside lane, (e) recommended priority targets with specific capability-to-program mapping."
                ),
            },
        }]

    def call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if name == "fpds_list_datasets":
            params: dict[str, Any] = {}
            if arguments.get("domain"):
                params["domain"] = arguments["domain"]
            if arguments.get("q"):
                params["q"] = arguments["q"]
            return _json_text(self.client.get("/v1/catalog", params))
        if name == "fpds_describe_dataset":
            return _json_text(self.client.get(f"/v1/datasets/{self._require(arguments, 'dataset_id')}"))
        if name == "fpds_query_dataset":
            params = {
                **(arguments.get("filters") or {}),
                "fields": arguments.get("fields"),
                "sort": arguments.get("sort"),
                "limit": arguments.get("limit", DEFAULT_LIMIT),
                "cursor": arguments.get("cursor"),
            }
            return _json_text(self.client.get(f"/v1/datasets/{self._require(arguments, 'dataset_id')}/rows", params))
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
            return _json_text(self.client.get(f"/v1/dimensions/{self._require(arguments, 'dimension_id')}", params))
        if name == "fpds_resolve":
            return _json_text(self.resolve(arguments))
        if name == "fpds_customer_profile":
            return _json_text(self.client.get("/v1/profiles/customer", arguments))
        if name == "fpds_vendor_profile":
            return _json_text(self.client.get("/v1/profiles/vendor", arguments))
        if name == "fpds_topic_profile":
            return _json_text(self.client.get("/v1/profiles/topic", arguments))
        if name == "fpds_topic_search":
            return _json_text(self.topic_search(arguments))
        if name == "fpds_contract_history":
            piid = self._require(arguments, "piid")
            filters: dict[str, Any] = {"piid": piid}
            if arguments.get("reason_for_modification"):
                filters["reason_for_modification"] = arguments["reason_for_modification"]
            if arguments.get("contract_action_type"):
                filters["contract_action_type"] = arguments["contract_action_type"]
            params = {
                **filters,
                "sort": arguments.get("sort", "-signed_date"),
                "limit": arguments.get("limit", 100),
            }
            return _json_text(self.client.get("/v1/datasets/pipeline.contract_transactions/rows", params))
        if name == "fpds_onboarding":
            return {"content": [{"type": "text", "text": self._onboarding_guide()}]}
        # ── Keyword tools ───────────────────────────────────────────────
        if name == "keyword_search":
            return _json_text(self.client.get("/v1/keywords/search", {
                k: v for k, v in arguments.items()
                if v is not None and k != "limit"
            } | {"limit": arguments.get("limit", DEFAULT_LIMIT)}))
        if name == "keyword_analytics":
            return _json_text(self.client.get("/v1/keywords/analytics", arguments))
        if name == "keyword_vs_topic":
            return _json_text(self.client.get("/v1/keywords/vs-topic", arguments))
        if name == "keyword_compare":
            return _json_text(self.client.get("/v1/keywords/compare", arguments))
        if name == "keyword_vendor_profile":
            uei = self._require(arguments, "uei")
            params = {k: v for k, v in arguments.items() if v is not None and k != "uei" and k != "limit"}
            params["limit"] = arguments.get("limit", 50)
            return _json_text(self.client.get(f"/v1/keywords/vendor/{uei}", params))
        raise ValueError(f"Unknown tool: {name}")

    @staticmethod
    def _require(args: dict[str, Any], key: str) -> Any:
        value = args.get(key)
        if value is None:
            raise ValueError(f"Missing required argument: {key}")
        return value

    def resolve(self, arguments: dict[str, Any]) -> dict[str, Any]:
        q = self._require(arguments, "q")
        raw_types = arguments.get("types") or ["agencies", "departments", "offices", "naics", "psc", "vehicle_programs", "topics"]
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
        q = self._require(arguments, "q")
        limit = min(int(arguments.get("limit") or DEFAULT_LIMIT), 100)
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


def handle_message(server: FPDSServer, message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    msg_id = message.get("id")
    params = message.get("params") or {}
    try:
        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": params.get("protocolVersion", "2025-03-26"),
                    "serverInfo": {"name": "fpds-os-analytics", "version": "0.2.0"},
                    "capabilities": {
                        "tools": {},
                        "prompts": {},
                        "resources": {},
                    },
                },
            }
        if method == "notifications/initialized":
            return None
        if method == "ping":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {}}
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"tools": server.tools()}}
        if method == "tools/call":
            return {"jsonrpc": "2.0", "id": msg_id, "result": server.call_tool(params["name"], params.get("arguments") or {})}
        if method == "prompts/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"prompts": server.prompts()}}
        if method == "prompts/get":
            return {"jsonrpc": "2.0", "id": msg_id, "result": server.get_prompt(params["name"], params.get("arguments") or {})}
        if method == "resources/list":
            return {"jsonrpc": "2.0", "id": msg_id, "result": {"resources": server.resources()}}
        if method == "resources/read":
            return {"jsonrpc": "2.0", "id": msg_id, "result": server.read_resource(params["uri"])}
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": f"Method not found: {method}"}}
    except KeyError as exc:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": f"Invalid params: missing {exc}"}}
    except ValueError as exc:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32602, "message": str(exc)}}
    except Exception as exc:
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": str(exc)}}


def serve(server: FPDSServer) -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, separators=(",", ":")) + "\n")
            sys.stdout.flush()
            continue
        response = handle_message(server, message)
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
