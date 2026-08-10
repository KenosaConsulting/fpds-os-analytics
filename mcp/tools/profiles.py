"""Profile tools: customer_profile, vendor_profile, topic_profile, vendor_compare."""

from __future__ import annotations

from typing import Any

from . import ToolDef


def _handle_customer_profile(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    params: dict[str, Any] = {}
    if arguments.get("contracting_dept_id"):
        params["contracting_dept_id"] = arguments["contracting_dept_id"]
    if arguments.get("contracting_agency_id"):
        params["contracting_agency_id"] = arguments["contracting_agency_id"]
    return server.client.get("/v1/profiles/customer", params)


def _handle_vendor_profile(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    uei = arguments.get("uei")
    if not uei:
        raise ValueError("Missing required argument: uei")
    params: dict[str, Any] = {"uei": uei}
    if arguments.get("contracting_dept_id"):
        params["contracting_dept_id"] = arguments["contracting_dept_id"]
    if arguments.get("contracting_agency_id"):
        params["contracting_agency_id"] = arguments["contracting_agency_id"]
    return server.client.get("/v1/profiles/vendor", params)


def _handle_topic_profile(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    dept_code = arguments.get("department_code")
    if not dept_code:
        raise ValueError("Missing required argument: department_code")
    params: dict[str, Any] = {"department_code": dept_code}
    if arguments.get("topic_id"):
        params["topic_id"] = arguments["topic_id"]
    if arguments.get("q"):
        params["q"] = arguments["q"]
    return server.client.get("/v1/profiles/topic", params)


def _handle_vendor_compare(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    ueis = arguments.get("ueis")
    if not ueis:
        raise ValueError("Missing required argument: ueis")
    params: dict[str, Any] = {"ueis": ueis}
    if arguments.get("contracting_dept_id"):
        params["contracting_dept_id"] = arguments["contracting_dept_id"]
    if arguments.get("contracting_agency_id"):
        params["contracting_agency_id"] = arguments["contracting_agency_id"]
    return server.client.get("/v1/profiles/vendors/compare", params)


TOOLS: dict[str, ToolDef] = {
    "fpds_customer_profile": ToolDef(
        schema={
            "name": "fpds_customer_profile",
            "description": (
                "Generate a composite Customer 360 profile for a federal agency. "
                "Returns 8 analytical sections: spend trend, top NAICS, competition "
                "posture, pricing mix, set-aside usage, top incumbents, vehicle paths, "
                "and recompete signals."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "contracting_dept_id": {"type": "string", "description": "Dept code (e.g. 9700 for DoD)."},
                    "contracting_agency_id": {"type": "string", "description": "Agency code (e.g. 1700 for Navy)."},
                },
                "additionalProperties": False,
            },
        },
        handler=_handle_customer_profile,
        tier="tier1",
    ),
    "fpds_vendor_profile": ToolDef(
        schema={
            "name": "fpds_vendor_profile",
            "description": "Get a vendor intelligence profile by UEI.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "uei": {"type": "string", "description": "Vendor UEI (12 characters)."},
                    "contracting_dept_id": {"type": "string"},
                    "contracting_agency_id": {"type": "string"},
                },
                "required": ["uei"],
                "additionalProperties": False,
            },
        },
        handler=_handle_vendor_profile,
        tier="tier1",
    ),
    "fpds_topic_profile": ToolDef(
        schema={
            "name": "fpds_topic_profile",
            "description": "Get a topic intelligence profile for a federal department.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "department_code": {"type": "string", "description": "Department code."},
                    "topic_id": {"type": "integer"},
                    "q": {"type": "string", "description": "Keyword filter."},
                },
                "required": ["department_code"],
                "additionalProperties": False,
            },
        },
        handler=_handle_topic_profile,
        tier="tier1",
    ),
    "fpds_vendor_compare": ToolDef(
        schema={
            "name": "fpds_vendor_compare",
            "description": "Compare two or more vendors side-by-side.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ueis": {"type": "array", "items": {"type": "string"}},
                    "contracting_dept_id": {"type": "string"},
                    "contracting_agency_id": {"type": "string"},
                },
                "required": ["ueis"],
                "additionalProperties": False,
            },
        },
        handler=_handle_vendor_compare,
        tier="tier1",
    ),
}
