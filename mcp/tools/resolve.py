"""Resolve tool: fpds_resolve — cross-dimension plain-English name search."""

from __future__ import annotations

from typing import Any

from . import ToolDef

TYPE_TO_DIMENSION = {
    "departments": "departments", "department": "departments",
    "agencies": "agencies", "agency": "agencies",
    "offices": "contracting_offices", "office": "contracting_offices",
    "contracting_offices": "contracting_offices",
    "naics": "naics",
    "psc": "psc_codes", "psc_codes": "psc_codes",
    "vehicle_program": "vehicle_programs", "vehicle_programs": "vehicle_programs",
    "vehicles": "vehicle_programs",
    "topics": "canonical_topics", "canonical_topics": "canonical_topics",
    "topic_mapping": "canonical_topic_mapping",
    "canonical_topic_mapping": "canonical_topic_mapping",
}


def _handle_resolve(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    q = arguments.get("q")
    if not q:
        raise ValueError("Missing required argument: q")
    raw_types = arguments.get("types") or [
        "agencies", "departments", "offices", "naics", "psc", "vehicle_programs", "topics"
    ]
    limit = min(int(arguments.get("limit") or 10), 100)
    results = []
    for raw_type in raw_types:
        dimension_id = TYPE_TO_DIMENSION.get(str(raw_type))
        if not dimension_id:
            continue
        response = server.client.get(
            f"/v1/dimensions/{dimension_id}", {"q": q, "limit": limit}
        )
        results.append({
            "type": raw_type,
            "dimension_id": dimension_id,
            "data": response.get("data", []),
            "meta": response.get("meta", {}),
        })
    return {"query": q, "results": results}


TOOLS: dict[str, ToolDef] = {
    "fpds_resolve": ToolDef(
        schema={
            "name": "fpds_resolve",
            "description": (
                "Resolve plain-English names to FPDS codes using dimension search. "
                "Searches departments, agencies, contracting offices, NAICS, PSC codes, "
                "vehicle programs, and canonical procurement topics."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "q": {"type": "string", "description": "Name or description fragment."},
                    "types": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional types: departments, agencies, offices, naics, psc, vehicle_programs, topics.",
                    },
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "required": ["q"],
                "additionalProperties": False,
            },
        },
        handler=_handle_resolve,
        tier="public",
    ),
}
