"""Orchestration tools: orchestrate_capture, generate_artifact, corpus_search, sql_lookup.

These tools require the capture_intel package (not available in fpds-os-analytics).
They return helpful error messages pointing to the capture_intel MCP server.
"""

from __future__ import annotations

from typing import Any

from . import ToolDef

_CAPTURE_INTEL_HINT = (
    "Use this tool via the capture_intel MCP server at "
    "https://mcp.capture.kenosaconsulting.com/mcp"
)


def _handle_not_available(name: str) -> Any:
    def handler(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
        return {
            "error": f"{name} is not yet available in this MCP endpoint.",
            "hint": _CAPTURE_INTEL_HINT,
        }
    return handler


TOOLS: dict[str, ToolDef] = {
    "orchestrate_capture": ToolDef(
        schema={
            "name": "orchestrate_capture",
            "description": (
                "Run the full capture intelligence workflow for a federal contract "
                "opportunity. Executes M1-M6 modules: agency fit, opportunity profile, "
                "customer intel, competitive landscape, contact mapping, recompete signals. "
                "Requires Tier 3 access."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "piid": {"type": "string", "description": "Procurement Instrument ID. Preferred input."},
                    "agency_code": {"type": "string"},
                    "naics": {"type": "string"},
                    "vendor_uei": {"type": "string"},
                    "vendor_name": {"type": "string"},
                    "scope": {"type": "string", "description": "'opportunity', 'account', or 'company_strategy'."},
                    "modules": {"type": "array", "items": {"type": "string"}},
                    "output_format": {"type": "string", "description": "'summary', 'full', or 'json'."},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_not_available("orchestrate_capture"),
        tier="tier3",
    ),
    "generate_artifact": ToolDef(
        schema={
            "name": "generate_artifact",
            "description": (
                "Generate a styled procurement intelligence artifact from a natural "
                "language query. Types: research_brief, agency_profile, capture_plan, "
                "competitive_brief, diligence_memo, recompete_watchlist. Requires Tier 3 access."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural language research question."},
                    "artifact_type": {"type": "string"},
                    "model_provider": {"type": "string", "description": "'deepseek' (default) or 'ollama'."},
                    "model_api_key": {"type": "string"},
                    "model_name": {"type": "string"},
                    "output_format": {"type": "string", "description": "'json' or 'markdown'."},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        },
        handler=_handle_not_available("generate_artifact"),
        tier="tier3",
    ),
    "corpus_search": ToolDef(
        schema={
            "name": "corpus_search",
            "description": (
                "Search federal procurement documents by semantic similarity. "
                "Searches strategic plans, budgets, oversight, legislation, policy "
                "using v3 IVFFlat indexes. Requires Tier 2+ access."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Natural language search query."},
                    "doc_types": {"type": "array", "items": {"type": "string"}},
                    "corpus_types": {"type": "array", "items": {"type": "string"}},
                    "dept_codes": {"type": "array", "items": {"type": "string"}},
                    "fy_min": {"type": "integer"},
                    "top_k": {"type": "integer", "minimum": 1, "maximum": 50},
                    "snippet_chars": {"type": "integer"},
                    "full_content": {"type": "boolean"},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        },
        handler=_handle_not_available("corpus_search"),
        tier="tier2",
    ),
    "sql_lookup": ToolDef(
        schema={
            "name": "sql_lookup",
            "description": (
                "Run a parameterized read-only query against allowlisted Supabase tables. "
                "All queries are SELECT-only with parameterized WHERE clauses. "
                "No raw SQL accepted."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "table": {"type": "string", "description": "Table name on allowlist."},
                    "filters": {"type": "object", "description": "Key/value WHERE conditions."},
                    "columns": {"type": "array", "items": {"type": "string"}},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "required": ["table"],
                "additionalProperties": False,
            },
        },
        handler=_handle_not_available("sql_lookup"),
        tier="tier2",
    ),
}
