"""Contract tools: fpds_contract_history."""

from __future__ import annotations

from typing import Any

from . import ToolDef


def _handle_contract_history(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    piid = arguments.get("piid")
    if not piid:
        raise ValueError("Missing required argument: piid")
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
    return server.client.get("/v1/datasets/pipeline.contract_transactions/rows", params)


TOOLS: dict[str, ToolDef] = {
    "fpds_contract_history": ToolDef(
        schema={
            "name": "fpds_contract_history",
            "description": (
                "Get the transaction-level modification history for a contract PIID. "
                "Returns every modification with descriptions, reason codes, obligation "
                "amounts, and dates."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "piid": {"type": "string", "description": "Contract PIID."},
                    "reason_for_modification": {"type": "string"},
                    "contract_action_type": {"type": "string"},
                    "sort": {"type": "string", "description": "Sort field (default: -signed_date)."},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 1000},
                },
                "required": ["piid"],
                "additionalProperties": False,
            },
        },
        handler=_handle_contract_history,
        tier="tier1",
    ),
}
