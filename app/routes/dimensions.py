"""Dimension lookup routes."""

from __future__ import annotations

from fastapi import APIRouter, Request

from app.catalog import load_catalog
from app.db import db_cursor
from app.notices import BRIEF_DATA_NOTICE, dimension_notices
from app.query_builder import build_rows_query, page_rows


router = APIRouter(prefix="/v1")


@router.get("/dimensions/{dimension_id}")
def dimension_rows(dimension_id: str, request: Request) -> dict[str, object]:
    catalog = load_catalog()
    dimension = catalog.get_dimension(dimension_id)
    raw_q = request.query_params.get("q")
    dataset_like = {
        "id": f"dimension.{dimension_id}",
        "backing_view": dimension["backing_view"],
        "fields": dimension["fields"],
        "filters": dimension.get("filters", []),
        "searchable_columns": dimension.get("searchable_columns", []),
        "sortable": [dimension["key"]],
        "default_sort": dimension["key"],
        "limit": 100,
        "max_limit": 1000,
        "_api_filter_allowlist": dimension["_api_filter_allowlist"],
    }
    if raw_q and dimension_id == "contracting_offices":
        dataset_like["default_predicates"] = [
            {"field": "is_active_recent", "include_values": [True], "unless_filter": "is_active_recent"},
            {"field": "name_confidence", "include_values": ["high", "medium"], "unless_filter": "name_confidence"},
        ]
    params = {key: value for key, value in request.query_params.items() if key != "q"}
    if raw_q:
        params["_search_q"] = raw_q
    sql, values, limit, offset = build_rows_query(dataset_like, params)
    with db_cursor() as cur:
        cur.execute(sql, values)
        raw_rows = cur.fetchall()
    data, next_cursor = page_rows(raw_rows, limit=limit, offset=offset)
    return {
        "notice": BRIEF_DATA_NOTICE,
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
