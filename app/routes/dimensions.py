"""Dimension lookup routes."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.catalog import load_catalog
from app.db import db_cursor
from app.notices import dimension_notices
from app.query_builder import build_rows_query, page_rows


router = APIRouter(prefix="/v1")


@router.get("/dimensions/{dimension_id}")
def dimension_rows(dimension_id: str, request: Request) -> dict[str, object]:
    catalog = load_catalog()
    dimension = catalog.get_dimension(dimension_id)
    dataset_like = {
        "id": f"dimension.{dimension_id}",
        "backing_view": dimension["backing_view"],
        "fields": dimension["fields"],
        "filters": dimension.get("filters", []),
        "sortable": [dimension["key"]],
        "default_sort": dimension["key"],
        "limit": 100,
        "max_limit": 1000,
    }
    params = {key: value for key, value in request.query_params.items() if key != "q"}
    sql, values, limit, offset = build_rows_query(dataset_like, params)
    with db_cursor() as cur:
        cur.execute(sql, values)
        raw_rows = cur.fetchall()
    data, next_cursor = page_rows(raw_rows, limit=limit, offset=offset)
    return {
        "data": data,
        "pagination": {
            "limit": limit,
            "next_cursor": next_cursor,
        },
        "meta": {
            "api_version": catalog.version,
            "dimension_id": dimension_id,
            "row_count": len(data),
            "notices": dimension_notices(dimension),
        },
    }
