"""Dataset row routes."""

from __future__ import annotations

import csv
from decimal import Decimal
from io import StringIO

from fastapi import APIRouter, Depends, Request
from psycopg2 import errors as pg_errors
from fastapi.responses import StreamingResponse

from app.auth import APIAccess, optional_api_access
from app.catalog import load_catalog
from app.db import db_cursor
from app.errors import APIError
from app.notices import BRIEF_DATA_NOTICE, data_notices
from app.query_builder import build_rows_query, page_rows, selected_fields


router = APIRouter(prefix="/v1")

OBLIGATION_FIELDS = (
    "total_obligated_amount", "net_obligated_amount",
    "obligated_amount", "total_obligated_amount_3yr",
)


def _pick_obligation(row: dict[str, object]) -> object:
    for field in OBLIGATION_FIELDS:
        val = row.get(field)
        if val is not None:
            return val
    return None


def _find_prior_fy_row(data: list[dict[str, object]], prior_fy: int) -> dict[str, object] | None:
    for row in data:
        if row.get("fiscal_year") == prior_fy:
            return row
    return None


def dataset_data_as_of(dataset: dict[str, object]) -> str | None:
    try:
        with db_cursor() as cur:
            cur.execute(
                """
                select data_as_of
                from analytics_api.dataset_refresh_log
                where dataset_id = %s
                   or source_view = %s
                order by data_as_of desc
                limit 1
                """,
                (dataset["id"], dataset.get("source_view")),
            )
            row = cur.fetchone()
    except (pg_errors.UndefinedTable, pg_errors.UndefinedColumn, pg_errors.InsufficientPrivilege):
        return None
    if not row or row.get("data_as_of") is None:
        return None
    value = row["data_as_of"]
    return value.isoformat() if hasattr(value, "isoformat") else str(value)


def csv_rows(data: list[dict[str, object]], fieldnames: list[str]) -> str:
    buffer = StringIO()
    writer = csv.DictWriter(buffer, fieldnames=fieldnames, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(data)
    return buffer.getvalue()


@router.get("/datasets/{dataset_id}/rows", response_model=None)
def dataset_rows(
    dataset_id: str,
    request: Request,
    access: APIAccess = Depends(optional_api_access),
) -> dict[str, object] | StreamingResponse:
    catalog = load_catalog()
    dataset = catalog.get_dataset(dataset_id)
    params = {key: value for key, value in request.query_params.items()}
    raw_q = params.pop("q", None)
    if raw_q:
        params["_search_q"] = raw_q
    response_format = params.get("format", "json").lower()
    if response_format not in {"json", "csv"}:
        raise APIError(400, "invalid_format", "Format must be 'json' or 'csv'.", param="format")
    # Enforce per-tier row limit (public gets default, authenticated keys get their tier limit)
    params["_max_limit_override"] = str(access.max_rows_per_request)
    fields = selected_fields(dataset, params.get("fields"))
    sql, values, limit, offset = build_rows_query(dataset, params)
    try:
        with db_cursor() as cur:
            cur.execute(sql, values)
            raw_rows = cur.fetchall()
    except pg_errors.QueryCanceled as exc:
        raise APIError(
            504,
            "query_timeout",
            "The dataset query exceeded the API timeout. Add filters or request fewer rows.",
            error_type="service_unavailable",
        ) from exc
    except pg_errors.UndefinedColumn as exc:
        raise APIError(
            500,
            "dataset_contract_mismatch",
            "This dataset is temporarily unavailable because its API catalog does not match the database view.",
            error_type="service_error",
        ) from exc
    data, next_cursor = page_rows(raw_rows, limit=limit, offset=offset)
    # BL-022: Flag rows with negative obligations to prevent misleading metrics
    obligation_fields = (
        "total_obligated_amount", "net_obligated_amount",
        "obligated_amount", "total_obligated_amount_3yr",
        "cost_type_obligated_amount_3yr", "tm_obligated_amount_3yr",
        "not_competed_obligated_amount_3yr",
    )
    negative_count = 0
    for row in data:
        for field in obligation_fields:
            val = row.get(field)
            if val is not None and str(val).lstrip("-").replace(".", "").isdigit() and Decimal(str(val)) < 0:
                row["_negative_obligation"] = True
                negative_count += 1
                break
    # Trend classification: compare each FY row against prior FY for obligation growth
    dataset_fields = set(dataset.get("fields", []))
    has_fiscal_year = "fiscal_year" in dataset_fields
    has_obligation = bool(
        set(obligation_fields)
        & {field for row in data for field in row.keys()}
    ) if data else False
    if has_fiscal_year and has_obligation:
        for row in data:
            fy = row.get("fiscal_year")
            if fy is None:
                continue
            ob_value = _pick_obligation(row)
            if ob_value is None:
                continue
            prior_row = _find_prior_fy_row(data, int(fy) - 1)
            if prior_row is None:
                row["_trend_classification"] = "baseline"
                continue
            prior_ob = _pick_obligation(prior_row)
            if prior_ob is None:
                row["_trend_classification"] = "baseline"
                continue
            try:
                current = Decimal(str(ob_value))
                prior = Decimal(str(prior_ob))
                if prior == 0:
                    row["_trend_classification"] = "baseline"
                elif current > prior * Decimal("1.10"):
                    row["_trend_classification"] = "growing"
                elif current < prior * Decimal("0.90"):
                    row["_trend_classification"] = "declining"
                else:
                    row["_trend_classification"] = "stable"
            except Exception:
                row["_trend_classification"] = "baseline"
    # Check for YTD flag on any row
    ytd_present = any(row.get("is_current_fiscal_year_ytd") is True for row in data)
    if response_format == "csv":
        filename = f"{dataset_id.replace('.', '_')}_rows.csv"
        return StreamingResponse(
            iter([csv_rows(data, fields)]),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )
    data_as_of = dataset_data_as_of(dataset)
    # Compute actual fiscal year range from returned rows
    fiscal_years = [
        row.get("fiscal_year")
        for row in data
        if row.get("fiscal_year") is not None
    ]
    if fiscal_years:
        source_fiscal_years = [min(fiscal_years), max(fiscal_years)]
    else:
        source_fiscal_years = None
    # Build notices list — append YTD warning if any row flags the current partial year
    notices = data_notices(dataset)
    if ytd_present:
        notices = notices + [
            "The queried fiscal year range includes the current partial year. "
            "Rows with is_current_fiscal_year_ytd=true are year-to-date and may be incomplete."
        ]
    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": data,
        "pagination": {
            "limit": limit,
            "next_cursor": next_cursor,
        },
        "meta": {
            "api_version": catalog.version,
            "dataset_id": dataset_id,
            "source": "FPDS analytics schema",
            "source_fiscal_years": source_fiscal_years,
            "data_as_of": data_as_of,
            "row_count": len(data),
            "caveats": dataset.get("caveats", []),
            "notices": notices,
            "access": "api_key" if access.is_authenticated else "public",
            "api_key_id": access.key_id if access.is_authenticated else None,
            "negative_obligation_count": negative_count if negative_count > 0 else None,
        },
    }
