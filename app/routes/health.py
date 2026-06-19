"""Health and metadata routes."""

from __future__ import annotations

from fastapi import APIRouter

from app.catalog import load_catalog
from app.notices import AGENCY_CODE_NOTICES, BRIEF_DATA_NOTICE, GEOGRAPHY_NOTICES, GLOBAL_DATA_NOTICES


router = APIRouter()


@router.get("/v1")
def metadata() -> dict[str, object]:
    catalog = load_catalog()
    return {
        "notice": BRIEF_DATA_NOTICE,
        "name": "FPDS Analytics API",
        "api_version": catalog.version,
        "status": "ok",
        "documentation_url": "/docs",
        "openapi_url": "/openapi.json",
        "ai_assistant_guide_url": "/v1/ai-assistant-guide",
        "start_here": "Use /v1/ai-assistant-guide for ChatGPT, Claude, Gemini, or other AI assistant instructions.",
    }


@router.get("/v1/health")
def health() -> dict[str, object]:
    catalog = load_catalog()
    return {
        "notice": BRIEF_DATA_NOTICE,
        "status": "ok",
        "catalog_version": catalog.version,
        "dataset_count": len(catalog.datasets),
        "dimension_count": len(catalog.dimensions),
    }


@router.get("/v1/ai-assistant-guide")
def ai_assistant_guide() -> dict[str, object]:
    catalog = load_catalog()
    return {
        "notice": BRIEF_DATA_NOTICE,
        "name": "FPDS Analytics API AI Assistant Guide",
        "api_version": catalog.version,
        "purpose": (
            "Help analysts, developers, contractors, capture teams, and business-development teams "
            "understand federal procurement customers using curated FPDS analytics datasets."
        ),
        "value": [
            "Identify whether a customer is open to new vendors or dominated by incumbents.",
            "Understand how a customer buys: fixed price, cost type, time and materials, performance-based, or multi-year.",
            "Find growing NAICS sectors and departments that buy the user's capabilities.",
            "Spot sole-source-heavy agencies, competitive lanes, and geographic work patterns.",
            "Turn procurement analytics into practical customer targeting and capture strategy.",
        ],
        "assistant_instructions": [
            "Start with /v1/catalog unless the user already named a dataset.",
            "Use /v1/datasets/{dataset_id} to inspect fields, filters, sort options, and caveats before querying rows.",
            "Use /v1/datasets/{dataset_id}/rows for bounded public data retrieval. Do not ask for an API key for first-use analysis.",
            "Include X-Api-Key only when the user has a paid or partner key for higher-volume access.",
            "Prefer small, targeted requests with relevant filters instead of broad pulls.",
            "Explain results in plain English for customer targeting, market entry, teaming, or capture planning.",
            "Include the top-level notice, plus caveats and notices from the API response, especially data-completeness, DoD-code, and place-of-performance notices.",
            "Do not treat department code 9700 as the complete universe of all DoD, Army, or military-base opportunity.",
            "Do not treat military postal codes or place-of-performance fields as a complete measure of overseas work.",
            "Do not claim causality that the data does not support.",
            "Do not request arbitrary SQL, raw database tables, admin endpoints, or bulk exports.",
        ],
        "critical_notices": GLOBAL_DATA_NOTICES + AGENCY_CODE_NOTICES + GEOGRAPHY_NOTICES,
        "safe_endpoints": [
            {"name": "service_metadata", "method": "GET", "path": "/v1", "api_key_required": False},
            {"name": "list_datasets", "method": "GET", "path": "/v1/catalog", "api_key_required": False},
            {"name": "describe_dataset", "method": "GET", "path": "/v1/datasets/{dataset_id}", "api_key_required": False},
            {"name": "query_dataset", "method": "GET", "path": "/v1/datasets/{dataset_id}/rows", "api_key_required": False},
            {"name": "list_dimensions", "method": "GET", "path": "/v1/dimensions", "api_key_required": False},
            {"name": "lookup_dimension", "method": "GET", "path": "/v1/dimensions/{dimension_id}", "api_key_required": False},
        ],
        "common_user_goals": [
            {"goal": "Understand a customer's buying style", "start_with_dataset": "pricing.agency_profile_fy"},
            {"goal": "Find sole-source-heavy customers", "start_with_dataset": "competition.sole_source_hotspots"},
            {"goal": "Identify dominant vendors or incumbents", "start_with_dataset": "concentration.vendor_market_leaders"},
            {"goal": "Find growing industries", "start_with_dataset": "naics.growth_leaders"},
            {"goal": "Understand where work happens", "start_with_dataset": "geography.state_trend_fy"},
            {"goal": "Discover what an agency actually buys at sub-NAICS resolution", "start_with_dataset": "topics.agency_profile"},
            {"goal": "Search procurement topics by keyword (e.g. cybersecurity, cloud, medical devices)", "start_with_dataset": "topics.catalog"},
            {"goal": "Find expiring contracts to chase", "start_with_dataset": "pipeline.recompete_watchlist"},
            {"goal": "Identify key contracting officers at an agency", "start_with_dataset": "contacts.office_roster"},
            {"goal": "Assess how hard a market is to enter", "start_with_dataset": "market.entry_difficulty_score"},
        ],
        "copy_paste_prompt": (
            "You are helping me use the FPDS Analytics API. First read the API guide at /v1/ai-assistant-guide, "
            "then use /v1/catalog to choose the right dataset. When you query data, use only documented filters, "
            "sorts, and fields. Explain what the results mean for customer targeting, market entry, teaming, "
            "or capture strategy. Include the API response notice, caveats, and notices, and do not invent data."
        ),
        "auth": {
            "header": "X-Api-Key",
            "note": "Discovery and bounded dataset row endpoints are public. API keys are for paid, partner, or higher-volume access.",
            "public_row_limit": 25,
        },
    }
