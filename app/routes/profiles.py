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
