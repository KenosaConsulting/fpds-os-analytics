"""MCP Prompt definitions — 16 prompts (8 analytical + 8 skill-based).

Each prompt is a named template with argument declarations and a factory function
that generates the prompt messages from user-supplied arguments.
"""

from __future__ import annotations

from typing import Any


def _prompt_arg(name: str, description: str, required: bool = False) -> dict[str, Any]:
    return {"name": name, "description": description, "required": required}


_ALL_PROMPTS: list[dict[str, Any]] = []


def _register(name: str, description: str, arguments: list[dict[str, Any]]) -> None:
    _ALL_PROMPTS.append({"name": name, "description": description, "arguments": arguments})


def get_all_prompts() -> list[dict[str, Any]]:
    return list(_ALL_PROMPTS)


def _skill_prompt(server: Any, prompt_name: str, skill_name: str,
                  args: dict[str, Any]) -> list[dict[str, Any]]:
    skills = server._load_skills()
    content = skills.get(skill_name, f"# {skill_name}\n\nSkill content not available.")
    arg_lines = "\n".join(f"- **{k}**: {v}" for k, v in args.items() if v)
    header = f"**Provided inputs:**\n{arg_lines}\n\n---\n\n" if arg_lines else ""
    return [{"role": "user", "content": {"type": "text", "text": header + content}}]


PROMPT_HANDLERS: dict[str, Any] = {}


def _handler(name: str):
    def decorator(fn):
        PROMPT_HANDLERS[name] = fn
        return fn
    return decorator


# ── Analytical prompts ──────────────────────────────────────────────────────


_register(
    "assess_market_entry_difficulty",
    "Assess how structurally hard it is to enter a specific agency x NAICS market.",
    [
        _prompt_arg("naics_code", "6-digit NAICS code.", True),
        _prompt_arg("agency_name", "Optional: agency name to scope to.", False),
    ],
)


@_handler("assess_market_entry_difficulty")
def _p1(args: dict[str, Any]) -> list[dict[str, Any]]:
    naics = args.get("naics_code", "")
    agency = args.get("agency_name", "")
    agency_filter = f" at {agency}" if agency else ""
    scope_clause = f"For {agency}, " if agency else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I need to assess how hard it is to enter the market for NAICS {naics}{agency_filter}.\n\n"
            "Use the FPDS Analytics MCP tools to:\n\n"
            f"1. **Resolve the NAICS code** — use fpds_resolve.\n\n"
            f"2. **{scope_clause}Get Market Entry Difficulty Scores** — query market.entry_difficulty_score "
            f"with principal_naics_code={naics}.\n\n"
            "3. **Drill into difficulty components** — HHI, not-competed share, vehicle dependence, offer intensity, incumbent tenure.\n\n"
            "4. **Check sole-source hotspots** — query competition.sole_source_hotspots.\n\n"
            "5. **Look at award sizes** — query pipeline.award_size_distribution.\n\n"
            "6. **Identify incumbents** — query incumbent.agency_vendor_leaders.\n\n"
            "7. **Check new-entrant survival** — query entrants.agency_cohort_fy.\n\n"
            "Synthesize into: overall difficulty, top 3 hardest/easiest agencies, what drives difficulty, recommended entry strategy."
        )},
    }]


_register(
    "find_expiring_contracts",
    "Find contracts expiring soon that you can chase for recompete.",
    [
        _prompt_arg("agency_name", "Target agency name.", True),
        _prompt_arg("naics_code", "Optional: 6-digit NAICS code.", False),
        _prompt_arg("expiration_window", "0-6 months, 6-12 months, 12-18 months, or 18-24 months.", False),
    ],
)


@_handler("find_expiring_contracts")
def _p2(args: dict[str, Any]) -> list[dict[str, Any]]:
    agency = args.get("agency_name", "")
    naics = args.get("naics_code", "")
    window = args.get("expiration_window", "0-12 months")
    naics_clause = f" for NAICS {naics}" if naics else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I want to find expiring contracts for recompete at {agency}{naics_clause}. "
            f"Focus on contracts expiring within {window}.\n\n"
            "Use the FPDS Analytics MCP tools to:\n\n"
            f"1. Resolve the agency via fpds_resolve.\n\n"
            f"2. Get recompete summary via pipeline.agency_recompete_summary.\n\n"
            f"3. Pull watchlist via pipeline.recompete_watchlist.\n\n"
            "4. Identify handlers via contacts.recompete_handlers.\n\n"
            "5. For top contracts, get full history via fpds_contract_history.\n\n"
            "6. Check contract durations via pipeline.duration_profile.\n\n"
            "Synthesize into: pipeline overview, top targets with recompete confidence, "
            "modification history insights, recommended capture timeline."
        )},
    }]


_register(
    "discover_what_agency_actually_buys",
    "Discover what an agency actually buys at sub-NAICS resolution using topic intelligence.",
    [
        _prompt_arg("agency_name", "Agency name to profile.", True),
        _prompt_arg("topic_keyword", "Optional: keyword to filter topics.", False),
    ],
)


@_handler("discover_what_agency_actually_buys")
def _p3(args: dict[str, Any]) -> list[dict[str, Any]]:
    agency = args.get("agency_name", "")
    keyword = args.get("topic_keyword", "")
    keyword_clause = f" related to '{keyword}'" if keyword else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I want to understand what {agency} actually buys using topic intelligence{keyword_clause}.\n\n"
            "Use the FPDS Analytics MCP tools to:\n\n"
            f"1. Resolve the agency via fpds_resolve.\n\n"
            f"2. Browse topic catalog via topics.catalog.\n\n"
            "3. Get agency topic profile via topics.agency_profile.\n\n"
            "4. Decompose into NAICS via topics.naics_decomposition.\n\n"
            "5. Check topic trends via topics.trends (trend_classification='growing').\n\n"
            "6. Map competitive landscape via topics.competitive_landscape.\n\n"
            "7. Link topics to strategic documents via topics.document_links.\n\n"
            "8. Check govwide canonical topics via topics.govwide_canonical.\n\n"
            "Synthesize into: top 10-15 topics, growing vs declining, "
            "who dominates each topic, strategic alignment, recommended capability areas."
        )},
    }]


_register(
    "profile_customer_agency",
    "Generate a complete customer profile for a federal agency.",
    [
        _prompt_arg("agency_name", "Agency name to profile.", True),
    ],
)


@_handler("profile_customer_agency")
def _p4(args: dict[str, Any]) -> list[dict[str, Any]]:
    agency = args.get("agency_name", "")
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I want a complete procurement profile for {agency}.\n\n"
            "Use the FPDS Analytics MCP tools to:\n\n"
            f"1. Resolve the agency via fpds_resolve.\n\n"
            "2. Get Customer 360 profile via fpds_customer_profile.\n\n"
            "3. Deep-dive pricing risk via pricing.risk_scorecard.\n\n"
            "4. Understand competition via competition.agency_profile_fy.\n\n"
            "5. Examine non-competition reasons via competition.not_competed_reasons_fy.\n\n"
            "6. Analyze vehicle dependence via acquisition.agency_vehicle_mix_fy.\n\n"
            "7. Check set-aside usage via set_aside.agency_profile_fy.\n\n"
            "8. Identify incumbents via incumbent.agency_vendor_leaders.\n\n"
            "9. Assess new-entrant opportunity via entrants.agency_cohort_fy.\n\n"
            "10. Map funding flows via funding.assisted_acquisition_fy.\n\n"
            "Synthesize into: agency overview, buying behavior, incumbent landscape, "
            "accessibility scorecard, specific opportunities, recommended capture strategy."
        )},
    }]


_register(
    "find_contracting_officers_for_naics",
    "Find contracting officers who buy what you sell.",
    [
        _prompt_arg("naics_code", "6-digit NAICS code.", True),
        _prompt_arg("agency_name", "Optional: agency name.", False),
    ],
)


@_handler("find_contracting_officers_for_naics")
def _p5(args: dict[str, Any]) -> list[dict[str, Any]]:
    naics = args.get("naics_code", "")
    agency = args.get("agency_name", "")
    agency_clause = f" at {agency}" if agency else " across all agencies"
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I need to find the contracting officers who buy NAICS {naics}{agency_clause}.\n\n"
            f"Use fpds_resolve for the NAICS code"
            f"{' and agency' if agency else ''}.\n"
            f"Query contacts.naics_buyers with principal_naics_code={naics}.\n"
            "For top COs, get full profiles via contacts.detail.\n"
            "Check office coverage via contacts.office_coverage.\n"
            "Look at CO's FY trajectory via contacts.profile_fy.\n"
            "Find office roster context via contacts.office_roster.\n\n"
            "Identify: top 10 COs by obligation, set-aside-friendly COs, "
            "high sole-source COs, active COs, recompete handlers, key offices."
        )},
    }]


_register(
    "find_growth_naics_with_weak_competition",
    "Find NAICS codes where demand is growing AND competition is weak.",
    [
        _prompt_arg("sector_name", "Optional: NAICS sector.", False),
        _prompt_arg("agency_name", "Optional: agency name.", False),
        _prompt_arg("min_growth_pct", "Minimum YoY growth (default 10).", False),
    ],
)


@_handler("find_growth_naics_with_weak_competition")
def _p6(args: dict[str, Any]) -> list[dict[str, Any]]:
    sector = args.get("sector_name", "")
    agency = args.get("agency_name", "")
    min_growth = args.get("min_growth_pct", "10")
    sector_clause = f" in {sector}" if sector else ""
    agency_clause = f" for {agency}" if agency else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I'm looking for NAICS codes{sector_clause} with growing demand and weak competition{agency_clause}. "
            f"Filter for YoY growth >= {min_growth}%.\n\n"
            "1. Find growth leaders via naics.growth_leaders.\n"
            "2. Find customer agencies via market.naics_customer_leaders.\n"
            "3. Cross-reference with entry difficulty via market.entry_difficulty_score.\n"
            "4. Check concentration via concentration.agency_profile.\n"
            "5. Check competition posture via competition.agency_profile_fy.\n"
            "6. Verify with topic intelligence via topics.naics_decomposition.\n\n"
            "Synthesize into: ranked opportunity list scored by growth + accessibility, "
            "risk factors, recommended approach for top 3 targets."
        )},
    }]


_register(
    "map_vendor_competitive_landscape",
    "Map the competitive landscape: who wins where, how entrenched are they.",
    [
        _prompt_arg("agency_name", "Target agency name.", True),
        _prompt_arg("naics_code", "Optional: 6-digit NAICS code.", False),
        _prompt_arg("vendor_filter", "Optional: small business, veteran-owned, etc.", False),
    ],
)


@_handler("map_vendor_competitive_landscape")
def _p7(args: dict[str, Any]) -> list[dict[str, Any]]:
    agency = args.get("agency_name", "")
    naics = args.get("naics_code", "")
    naics_clause = f" in NAICS {naics}" if naics else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I want to map the competitive landscape at {agency}{naics_clause}.\n\n"
            f"1. Resolve the agency via fpds_resolve.\n"
            f"2. Get agency vendor leaders via incumbent.agency_vendor_leaders.\n"
            f"3. Get NAICS-grain vendor leaders via incumbent.agency_naics_vendor_leaders.\n"
            "4. For top 5 vendors, check cross-agency footprint via concentration.vendor_cross_agency_rank.\n"
            "5. Check global vendor market leaders via concentration.vendor_market_leaders.\n"
            "6. Assess new-entrant viability via entrants.agency_cohort_fy.\n"
            "7. Look at office-level vendor presence via incumbent.office_vendor_leaders.\n\n"
            "Synthesize into: competitive landscape overview, top 10 vendors with share/tenure, "
            "vulnerability analysis, new-entrant outlook, teaming partner recommendations."
        )},
    }]


_register(
    "find_agency_set_aside_opportunities",
    "Find agencies that actively use set-aside programs matching your business type.",
    [
        _prompt_arg("set_aside_type", "Your business type: 8(a), SDVOSB, WOSB, HUBZone, small business.", True),
        _prompt_arg("naics_code", "Optional: 6-digit NAICS code.", False),
        _prompt_arg("topic_keyword", "Optional: keyword for topic analysis.", False),
    ],
)


@_handler("find_agency_set_aside_opportunities")
def _p8(args: dict[str, Any]) -> list[dict[str, Any]]:
    set_aside = args.get("set_aside_type", "")
    naics = args.get("naics_code", "")
    keyword = args.get("topic_keyword", "")
    naics_clause = f" for NAICS {naics}" if naics else ""
    keyword_clause = f" in the '{keyword}' domain" if keyword else ""
    return [{
        "role": "user", "content": {"type": "text", "text": (
            f"I want to find federal agencies that actively use {set_aside} set-asides"
            f"{naics_clause}{keyword_clause}.\n\n"
            f"1. Get overall set-aside trends via set_aside.trend_fy.\n"
            f"2. Find {set_aside} family trend via set_aside.family_trend_fy.\n"
            f"3. Rank agencies by {set_aside} friendliness via set_aside.agency_profile_fy.\n"
            f"4. Check agency program mix via set_aside.agency_mix_fy.\n"
            f"5. Cross-reference with NAICS via market.agency_naics_fy.\n"
            f"6. Use topic intelligence via topics.set_aside_profile.\n"
            f"7. Check competition angle via competition.agency_profile_fy.\n\n"
            f"Synthesize into: overall {set_aside} landscape, top 10 agencies ranked by spend + growth, "
            "specific NAICS and topics flowing through set-asides, competition level, recommended targets."
        )},
    }]


# ── Skill prompts ───────────────────────────────────────────────────────────

for _skill_name, _skill_display in [
    ("vendor_market_analysis", "Analyze vendor market share and competitive landscape."),
    ("recompete_pipeline", "Identify upcoming recompete opportunities."),
    ("contracting_officer_patterns", "Analyze contracting office buying patterns."),
    ("account_plan_builder", "Build a structured account plan."),
    ("naics_opportunity_scan", "Scan a NAICS code across agencies for growth opportunities."),
    ("cross_agency_opportunity_radar", "Collaborative-filtering: find agencies a vendor should target."),
    ("teaming_partner_finder", "Find primes to team with at a target agency."),
    ("vehicle_strategy_advisor", "Advise on which contract vehicles are needed for a target agency."),
]:
    _register(_skill_name, _skill_display, [])
    # Skill prompts are loaded from skills/ directory at runtime
    PROMPT_HANDLERS[_skill_name] = _skill_name
