"""Topic tools: fpds_topic_search, topic_profile (DB-backed)."""

from __future__ import annotations

from typing import Any

from . import ToolDef

DEFAULT_LIMIT = 25


def _handle_topic_search(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    q = arguments.get("q")
    if not q:
        raise ValueError("Missing required argument: q")
    limit = min(int(arguments.get("limit") or DEFAULT_LIMIT), 100)
    include_canonical = arguments.get("include_canonical", True)
    department_code = arguments.get("department_code")

    results: dict[str, Any] = {"query": q, "sections": []}

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
        response = server.client.get("/v1/datasets/topics.catalog/rows", catalog_params)
        data = response.get("data", [])
        results["sections"].append({
            "source": "topics.catalog (merged topics)",
            "matched": len(data),
            "data": data,
        })
    except Exception as exc:
        results["sections"].append({"source": "topics.catalog", "error": str(exc)})

    if include_canonical:
        try:
            response = server.client.get("/v1/datasets/topics.govwide_canonical/rows", {
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


def _handle_topic_profile(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dept_code = arguments.get("department_code")
    if not dept_code:
        raise ValueError("Missing required argument: department_code")
    top_k = min(int(arguments.get("top_k", 20)), 100)

    if hasattr(server, "_db") and server._db is not None:
        try:
            rows = server._db.fetch_topic_profile(dept_code, top_k)
            return {"department_code": dept_code, "topic_count": len(rows), "topics": rows}
        except Exception:
            pass

    try:
        return server.client.get("/v1/profiles/topic", {
            "department_code": dept_code, "q": arguments.get("q"),
        })
    except Exception:
        return server.client.get("/v1/datasets/topics.agency_profile/rows", {
            "department_code": dept_code, "sort": "-assignment_count", "limit": top_k,
        })


TOOLS: dict[str, ToolDef] = {
    "fpds_topic_search": ToolDef(
        schema={
            "name": "fpds_topic_search",
            "description": (
                "Search procurement topics by keyword. Finds machine-derived sub-market "
                "topics matching a text query across merged topics and govwide canonical topics."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "q": {"type": "string", "description": "Topic search query."},
                    "department_code": {"type": "string"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100},
                    "include_canonical": {"type": "boolean"},
                },
                "required": ["q"],
                "additionalProperties": False,
            },
        },
        handler=_handle_topic_search,
        tier="public",
    ),
    "topic_profile": ToolDef(
        schema={
            "name": "topic_profile",
            "description": (
                "Get topic intelligence profile for a federal department. "
                "Returns top procurement topics by assignment frequency."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "department_code": {"type": "string", "description": "Department code."},
                    "top_k": {"type": "integer", "minimum": 1, "maximum": 100},
                },
                "required": ["department_code"],
                "additionalProperties": False,
            },
        },
        handler=_handle_topic_profile,
        tier="tier1",
    ),
}
