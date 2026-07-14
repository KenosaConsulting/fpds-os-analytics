"""Composite profile routes built from existing catalog datasets."""

from __future__ import annotations

from decimal import Decimal
from typing import Any

from fastapi import APIRouter, Depends, Request

from app.auth import APIAccess, optional_api_access
from app.catalog import load_catalog
from app.db import db_cursor
from app.errors import APIError
from app.notices import BRIEF_DATA_NOTICE, data_notices
from app.query_builder import build_rows_query, page_rows


router = APIRouter(prefix="/v1")


SECTION_LIMIT = 5


def _numeric(value: Any) -> Decimal | None:
    if value in (None, ""):
        return None
    try:
        return Decimal(str(value))
    except Exception:
        return None


def _section_query(
    catalog,
    dataset_id: str,
    params: dict[str, str],
    access: APIAccess,
) -> tuple[list[dict[str, Any]] | None, dict[str, Any]]:
    dataset = catalog.get_dataset(dataset_id)
    query_params = dict(params)
    query_params["limit"] = str(min(int(query_params.get("limit", SECTION_LIMIT)), SECTION_LIMIT))
    query_params["_max_limit_override"] = str(access.max_rows_per_request)

    try:
        sql, values, limit, offset = build_rows_query(dataset, query_params)
        with db_cursor() as cur:
            cur.execute(sql, values)
            raw_rows = cur.fetchall()
        data, _next_cursor = page_rows(raw_rows, limit=limit, offset=offset)
        return data, {
            "dataset_id": dataset_id,
            "status": "ok",
            "row_count": len(data),
        }
    except Exception as exc:
        return None, {
            "dataset_id": dataset_id,
            "status": "unavailable",
            "error": exc.__class__.__name__,
        }


def _unavailable_section(dataset_id: str, reason: str) -> tuple[None, dict[str, Any]]:
    return None, {
        "dataset_id": dataset_id,
        "status": "unavailable",
        "reason": reason,
    }


def _customer_filters(params: dict[str, str]) -> dict[str, str]:
    filters = {}
    for name in ("contracting_dept_id", "contracting_agency_id"):
        value = params.get(name)
        if value:
            filters[name] = value
    if not filters:
        raise APIError(
            400,
            "missing_required_filter",
            "Profile requires contracting_dept_id or contracting_agency_id.",
            extra={"example_query": "/v1/profiles/customer?contracting_dept_id=9700"},
        )
    return filters


def _vendor_filters(params: dict[str, str]) -> dict[str, str]:
    uei = params.get("uei")
    if not uei:
        raise APIError(
            400,
            "missing_required_filter",
            "Profile requires uei.",
            extra={"example_query": "/v1/profiles/vendor?uei=ABCDEFGHIJKL"},
        )
    filters = {"uei": uei}
    for name in ("contracting_dept_id", "contracting_agency_id"):
        value = params.get(name)
        if value:
            filters[name] = value
    return filters


def _topic_filters(params: dict[str, str]) -> dict[str, str]:
    dept_code = params.get("department_code")
    if not dept_code:
        raise APIError(
            400,
            "missing_required_filter",
            "Profile requires department_code.",
            extra={"example_query": "/v1/profiles/topic?department_code=097"},
        )
    filters = {"department_code": dept_code}
    topic_id = params.get("topic_id")
    if topic_id:
        filters["topic_id"] = topic_id
    return filters


def _narrative_hints(sections: dict[str, list[dict[str, Any]] | None]) -> list[str]:
    hints: list[str] = []
    spend = (sections.get("spend_trend") or [None])[0]
    if spend:
        obligated = spend.get("net_obligated_amount") or spend.get("total_obligated")
        fiscal_year = spend.get("fiscal_year")
        if obligated and fiscal_year:
            hints.append(f"Most recent profile row is FY{fiscal_year} with about ${obligated} obligated.")

        competed_share = _numeric(spend.get("competed_obligation_share") or spend.get("competed_action_share"))
        if competed_share is not None:
            if competed_share >= Decimal("0.7"):
                hints.append("Competition posture looks relatively open: at least 70% of measured activity is competed.")
            elif competed_share <= Decimal("0.3"):
                hints.append("Competition posture looks constrained: competed activity is at or below 30% in the profile row.")

    pricing = (sections.get("pricing_posture") or [None])[0]
    if pricing:
        risk_score = _numeric(pricing.get("risk_score"))
        if risk_score is not None and risk_score >= Decimal("70"):
            hints.append("Pricing posture shows elevated cost-type or time-and-materials exposure.")

    set_aside = (sections.get("set_aside_mix") or [None])[0]
    if set_aside and set_aside.get("set_aside_family"):
        hints.append(f"Top set-aside signal is {set_aside['set_aside_family']} in the returned program mix.")

    recompetes = sections.get("recompete_signals") or []
    if recompetes:
        first = recompetes[0]
        remaining = first.get("remaining_months")
        if remaining is not None:
            hints.append(f"Nearest returned recompete signal is about {remaining} months from current completion.")

    return hints


def _vendor_narrative_hints(sections: dict[str, list[dict[str, Any]] | None]) -> list[str]:
    hints: list[str] = []
    summary = (sections.get("vendor_summary") or [None])[0]
    if summary:
        agencies = summary.get("agency_count")
        tenure = summary.get("tenure_years")
        if agencies is not None and tenure is not None:
            hints.append(f"Vendor has served {int(agencies)} agencies over {int(tenure)} years.")

    top_agencies = sections.get("top_agencies") or []
    if top_agencies:
        first = top_agencies[0]
        name = first.get("contracting_dept_name") or first.get("contracting_agency_name") or "unknown"
        obligated = first.get("net_obligated_amount") or first.get("total_obligated")
        if obligated:
            hints.append(f"Top agency is {name} with ${obligated} obligated.")

    pipeline = sections.get("recompete_pipeline") or []
    if pipeline:
        hints.append(f"{len(pipeline)} contracts in recompete pipeline.")

    return hints


def _topic_narrative_hints(sections: dict[str, list[dict[str, Any]] | None]) -> list[str]:
    hints: list[str] = []
    trends = sections.get("trends") or []
    growing = [t for t in trends if str(t.get("trend_classification", "")).lower() == "growing"]
    if growing:
        top_growing = sorted(growing, key=lambda t: _numeric(t.get("growth_pct")) or Decimal("0"), reverse=True)
        first = top_growing[0]
        label = first.get("label") or first.get("canonical_label") or "unknown"
        growth = first.get("growth_pct")
        if growth is not None:
            hints.append(f"Top growing topic: {label} with {growth}% growth.")

    landscape = sections.get("competitive_landscape") or []
    if landscape:
        by_concentration = sorted(
            landscape,
            key=lambda t: _numeric(t.get("top_vendor_share") or t.get("vendor_concentration_share")) or Decimal("0"),
            reverse=True,
        )
        if by_concentration:
            first = by_concentration[0]
            label = first.get("label") or first.get("canonical_label") or "unknown"
            share = first.get("top_vendor_share") or first.get("vendor_concentration_share")
            if share is not None:
                hints.append(f"Most concentrated topic: {label} — top vendor holds {share}%.")

    return hints


@router.get("/profiles/customer")
def customer_profile(
    request: Request,
    access: APIAccess = Depends(optional_api_access),
) -> dict[str, Any]:
    catalog = load_catalog()
    params = {key: value for key, value in request.query_params.items()}
    filters = _customer_filters(params)

    sections: dict[str, list[dict[str, Any]] | None] = {}
    section_meta: dict[str, dict[str, Any]] = {}

    section_specs = {
        "spend_trend": ("customer.agency_profile_fy", {**filters, "sort": "-fiscal_year"}),
        "top_naics": ("market.agency_naics_fy", {**filters, "sort": "-net_obligated_amount"}),
        "competition_posture": ("customer.agency_profile_fy", {**filters, "sort": "-fiscal_year", "limit": "1"}),
        "set_aside_mix": ("set_aside.agency_mix_fy", {**filters}),
        "top_incumbents": ("incumbent.agency_vendor_leaders", {**filters}),
        "vehicle_mix": ("acquisition.agency_vehicle_mix_fy", {**filters, "sort": "-net_obligated_amount"}),
        "recompete_signals": ("pipeline.recompete_watchlist", {**filters, "sort": "remaining_months"}),
    }

    for section_name, (dataset_id, section_params) in section_specs.items():
        data, meta = _section_query(catalog, dataset_id, section_params, access)
        sections[section_name] = data
        section_meta[section_name] = meta

    if filters.get("contracting_dept_id"):
        data, meta = _section_query(catalog, "pricing.risk_scorecard", {"contracting_dept_id": filters["contracting_dept_id"], "limit": "1"}, access)
    else:
        data, meta = _unavailable_section(
            "pricing.risk_scorecard",
            "The current catalog exposes pricing posture at department level only.",
        )
    sections["pricing_posture"] = data
    section_meta["pricing_posture"] = meta

    caveats = [
        "Composite profile sections are independent bounded dataset queries; null sections indicate a section-level query failure or unsupported grain.",
        "Agency-only profiles can omit department-only sections until equivalent agency-grain datasets exist.",
    ]
    notices = set()
    for meta in section_meta.values():
        dataset_id = meta.get("dataset_id")
        if dataset_id in catalog.datasets:
            notices.update(data_notices(catalog.get_dataset(str(dataset_id))))

    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": {
            **sections,
            "narrative_hints": _narrative_hints(sections),
        },
        "meta": {
            "api_version": catalog.version,
            "profile": "customer",
            "filters": filters,
            "sections": section_meta,
            "notices": sorted(notices),
            "caveats": caveats,
            "access": "api_key" if access.is_authenticated else "public",
            "api_key_id": access.key_id if access.is_authenticated else None,
        },
    }


@router.get("/profiles/vendor")
def vendor_profile(
    request: Request,
    access: APIAccess = Depends(optional_api_access),
) -> dict[str, Any]:
    catalog = load_catalog()
    params = {key: value for key, value in request.query_params.items()}
    filters = _vendor_filters(params)

    sections: dict[str, list[dict[str, Any]] | None] = {}
    section_meta: dict[str, dict[str, Any]] = {}

    section_specs = {
        "vendor_summary": ("concentration.vendor_market_leaders", {**filters}),
        "top_agencies": ("incumbent.agency_vendor_leaders", {**filters}),
        "cross_agency_footprint": ("concentration.vendor_cross_agency_rank", {**filters}),
        "top_naics": ("incumbent.agency_naics_vendor_leaders", {**filters}),
        "recompete_pipeline": ("pipeline.recompete_watchlist", {"vendor_uei": filters["uei"]}),
    }

    for section_name, (dataset_id, section_params) in section_specs.items():
        data, meta = _section_query(catalog, dataset_id, section_params, access)
        sections[section_name] = data
        section_meta[section_name] = meta

    caveats = [
        "Composite profile sections are independent bounded dataset queries; null sections indicate a section-level query failure or unsupported grain.",
        "Vendor profile sections are capped at 5 rows each; use fpds_query_dataset with uei to retrieve full results for any section.",
    ]
    notices = set()
    for meta in section_meta.values():
        dataset_id = meta.get("dataset_id")
        if dataset_id in catalog.datasets:
            notices.update(data_notices(catalog.get_dataset(str(dataset_id))))

    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": {
            **sections,
            "narrative_hints": _vendor_narrative_hints(sections),
        },
        "meta": {
            "api_version": catalog.version,
            "profile": "vendor",
            "filters": filters,
            "sections": section_meta,
            "notices": sorted(notices),
            "caveats": caveats,
            "access": "api_key" if access.is_authenticated else "public",
            "api_key_id": access.key_id if access.is_authenticated else None,
        },
    }


@router.get("/profiles/topic")
def topic_profile(
    request: Request,
    access: APIAccess = Depends(optional_api_access),
) -> dict[str, Any]:
    catalog = load_catalog()
    params = {key: value for key, value in request.query_params.items()}
    raw_q = params.pop("q", None)
    filters = _topic_filters(params)

    sections: dict[str, list[dict[str, Any]] | None] = {}
    section_meta: dict[str, dict[str, Any]] = {}

    catalog_params = {**filters, "sort": "-assignment_count"}
    if raw_q:
        catalog_params["_search_q"] = raw_q
    if "topic_id" in filters:
        catalog_params.pop("topic_id", None)

    section_specs: list[tuple[str, str, dict[str, str]]] = [
        ("topic_catalog", "topics.catalog", catalog_params),
        ("agency_profile", "topics.agency_profile", {**filters}),
        ("trends", "topics.trends", {**filters}),
    ]

    topic_id = filters.get("topic_id")
    if topic_id:
        section_specs.append(("competitive_landscape", "topics.competitive_landscape", {**filters}))
        section_specs.append(("naics_decomposition", "topics.naics_decomposition", {**filters}))

    section_specs.append(("document_links", "topics.document_links", {"department_code_document": filters["department_code"]}))

    for section_name, dataset_id, section_params in section_specs:
        data, meta = _section_query(catalog, dataset_id, section_params, access)
        sections[section_name] = data
        section_meta[section_name] = meta

    caveats = [
        "Composite profile sections are independent bounded dataset queries; null sections indicate a section-level query failure or unsupported grain.",
        "Topic profile sections are capped at 5 rows each; use fpds_query_dataset to retrieve full results for any section.",
        "Topic-level competitive and NAICS decomposition detail is only populated when topic_id is provided.",
    ]
    notices = set()
    for meta in section_meta.values():
        dataset_id = meta.get("dataset_id")
        if dataset_id in catalog.datasets:
            notices.update(data_notices(catalog.get_dataset(str(dataset_id))))

    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": {
            **sections,
            "narrative_hints": _topic_narrative_hints(sections),
        },
        "meta": {
            "api_version": catalog.version,
            "profile": "topic",
            "filters": filters,
            "sections": section_meta,
            "notices": sorted(notices),
            "caveats": caveats,
            "access": "api_key" if access.is_authenticated else "public",
            "api_key_id": access.key_id if access.is_authenticated else None,
        },
    }
