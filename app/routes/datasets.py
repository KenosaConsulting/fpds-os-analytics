"""Dataset row routes."""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request
from psycopg2 import errors as pg_errors

from app.auth import require_api_key
from app.catalog import load_catalog
from app.db import db_cursor
from app.errors import APIError
from app.query_builder import build_rows_query, page_rows


router = APIRouter(prefix="/v1")


@router.get("/datasets/{dataset_id}/rows")
def dataset_rows(
    dataset_id: str,
    request: Request,
    _api_key_id: str = Depends(require_api_key),
) -> dict[str, object]:
    catalog = load_catalog()
    dataset = catalog.get_dataset(dataset_id)
    params = {key: value for key, value in request.query_params.items()}
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
    return {
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
            "row_count": len(data),
            "caveats": dataset.get("caveats", []),
        },
    }
