"""MCP tool registry — one module per tool family, each exports TOOLS dict.

Pattern:
    TOOLS = {
        "tool_name": ToolDef(
            schema={...},
            handler=async def handler(server, arguments) -> result,
        ),
    }

FPDSServer loads all tool schemas and dispatches calls by name.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable

Handler = Callable[..., dict[str, Any]]


@dataclass
class ToolDef:
    schema: dict[str, Any]
    handler: Handler
    tier: str = "public"  # public, tier1, tier2, tier3


def collect_all_tools(client_type: str = "rest") -> dict[str, ToolDef]:
    """Import every tool module and merge their TOOLS dicts.

    client_type: "rest" (default, no DB) or "db" (includes Supabase tools).
    """
    tools: dict[str, ToolDef] = {}

    # Always-available tools (REST-only)
    from . import discovery
    tools.update(discovery.TOOLS)

    from . import datasets
    tools.update(datasets.TOOLS)

    from . import profiles
    tools.update(profiles.TOOLS)

    from . import resolve as resolve_mod
    tools.update(resolve_mod.TOOLS)

    from . import topics as topics_mod
    tools.update(topics_mod.TOOLS)

    from . import contracts
    tools.update(contracts.TOOLS)

    from . import keywords as keywords_mod
    tools.update(keywords_mod.TOOLS)

    from . import onboarding
    tools.update(onboarding.TOOLS)

    from . import orchestrate
    tools.update(orchestrate.TOOLS)

    # DB-dependent tools
    if client_type == "db":
        from . import search
        tools.update(search.TOOLS)

    return tools


def collect_tool_schemas(client_type: str = "rest") -> list[dict[str, Any]]:
    """Return tool schemas only (for tools/list response)."""
    all_tools = collect_all_tools(client_type)
    return [td.schema for td in all_tools.values()]


# Tier definitions for auth middleware
TIER_TOOLS: dict[str, set[str]] = {
    "t05": set(),
    "tier1": {
        "fpds_customer_profile",
        "fpds_vendor_profile",
        "fpds_topic_profile",
        "fpds_contract_history",
        "fpds_vendor_compare",
        "topic_profile",
    },
    "tier2": {
        "vendor_profile",
        "sql_lookup",
        "corpus_search",
    },
    "tier3": {
        "analytics_query",
        "orchestrate_capture",
        "generate_artifact",
    },
}

TIER_LABELS: dict[str, str] = {
    "t05": "Explorer",
    "tier1": "Essentials",
    "tier2": "Professional",
    "tier3": "Enterprise",
}

TIER_ORDER = ["t05", "tier1", "tier2", "tier3"]

PUBLIC_TOOLS: set[str] = {
    "fpds_health",
    "fpds_list_datasets",
    "fpds_describe_dataset",
    "fpds_list_dimensions",
    "fpds_lookup_dimension",
    "fpds_resolve",
    "fpds_topic_search",
    "fpds_onboarding",
    "keyword_search",
    "keyword_analytics",
    "keyword_vs_topic",
    "keyword_compare",
    "keyword_vendor_profile",
}
