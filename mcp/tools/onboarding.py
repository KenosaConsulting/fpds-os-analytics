"""Onboarding tool: fpds_onboarding."""

from __future__ import annotations

from typing import Any

from . import ToolDef

_ONBOARDING_GUIDE = (
    "# FPDS Analytics: Getting Started\n\n"
    "FPDS Analytics is a read-only intelligence layer over 99M federal procurement records. "
    "It converts raw FPDS transactions into 90 pre-computed analytics datasets across 17 domains.\n\n"
    "## The 17 Domains\n\n"
    "| Domain | Key Dataset |\n"
    "|---|---|\n"
    "| Pricing | `pricing.risk_scorecard` |\n"
    "| Concentration | `concentration.vendor_market_leaders` |\n"
    "| Competition | `competition.sole_source_hotspots` |\n"
    "| NAICS | `naics.growth_leaders` |\n"
    "| Geography | `geography.state_trend_fy` |\n"
    "| Customer | `customer.agency_profile_fy` |\n"
    "| Market | `market.entry_difficulty_score` |\n"
    "| Incumbent | `incumbent.agency_vendor_leaders` |\n"
    "| Set-Aside | `set_aside.agency_profile_fy` |\n"
    "| PSC | `psc.naics_crosswalk` |\n"
    "| Acquisition | `acquisition.agency_vehicle_mix_fy` |\n"
    "| Pipeline | `pipeline.recompete_watchlist` |\n"
    "| Seasonality | `seasonality.agency_month_fy` |\n"
    "| Topics | `topics.catalog` |\n"
    "| Contacts | `contacts.naics_buyers` |\n"
    "| Entrants | `entrants.agency_cohort_fy` |\n"
    "| Funding | `funding.mismatch_flows_fy` |\n\n"
    "## Recommended Query Sequence\n\n"
    "1. **Resolve** — `fpds_resolve` to find codes from names.\n"
    "2. **Inspect** — `fpds_describe_dataset` to see filters and fields.\n"
    "3. **Query** — `fpds_query_dataset` with at least one filter.\n"
    "4. **Drill deeper** — `fpds_contract_history` for individual contracts.\n\n"
    "## Keyword vs Topic Tools\n\n"
    "- **Topics** decompose procurement into coherent sub-markets (BERTopic clusters).\n"
    "- **Keywords** map specific capabilities, vendors, and technologies to awards.\n"
    "- Use `keyword_analytics(group_by=\"vendor\")` for server-side vendor rankings.\n"
    "- Use `keyword_vs_topic` to bridge keywords to BERTopic topics.\n"
)


def _handle_onboarding(server: Any, arguments: dict[str, Any]) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": _ONBOARDING_GUIDE}]}


TOOLS: dict[str, ToolDef] = {
    "fpds_onboarding": ToolDef(
        schema={
            "name": "fpds_onboarding",
            "description": (
                "Getting-started guide and navigation map for FPDS Analytics. "
                "Returns a structured reference covering the 17 intelligence domains, "
                "common workflow patterns, and the recommended query sequence."
            ),
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        },
        handler=_handle_onboarding,
        tier="public",
    ),
}
