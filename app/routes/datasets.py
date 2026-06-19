"""Dataset row routes."""

from __future__ import annotations

import csv
from io import StringIO

from fastapi import APIRouter, Depends, Request
from psycopg2 import errors as pg_errors
from fastapi.responses import StreamingResponse

from app.auth import APIAccess, optional_api_access, public_row_limit
from app.catalog import load_catalog
from app.db import db_cursor
from app.errors import APIError
from app.notices import BRIEF_DATA_NOTICE, data_notices
from app.query_builder import build_rows_query, page_rows, selected_fields


router = APIRouter(prefix="/v1")


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
    if not access.is_authenticated:
        params["_max_limit_override"] = str(public_row_limit())
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
    if response_format == "csv":
        filename = f"{dataset_id.replace('.', '_')}_rows.csv"
        return StreamingResponse(
            iter([csv_rows(data, fields)]),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )
    data_as_of = dataset_data_as_of(dataset)
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
            "source_fiscal_years": [1958, 2026],
            "data_as_of": data_as_of,
            "row_count": len(data),
            "caveats": dataset.get("caveats", []),
            "notices": data_notices(dataset),
            "access": "api_key" if access.is_authenticated else "public",
            "api_key_id": access.key_id if access.is_authenticated else None,
        },
    }
