"""Catalog discovery routes."""

from __future__ import annotations

from fastapi import APIRouter, Query
from psycopg2 import errors as pg_errors

from app.catalog import load_catalog, public_dataset, public_dimension
from app.db import db_cursor
from app.notices import BRIEF_DATA_NOTICE, GLOBAL_DATA_NOTICES, data_notices


router = APIRouter(prefix="/v1")


@router.get("/catalog")
def list_catalog(
    domain: str | None = None,
    filter_name: str | None = None,
    field_name: str | None = None,
) -> dict[str, object]:
    catalog = load_catalog()
    datasets = catalog.list_datasets(
        domain=domain, filter_name=filter_name, field_name=field_name,
    )
    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": datasets,
        "meta": {
            "api_version": catalog.version,
            "row_count": len(datasets),
            "notices": GLOBAL_DATA_NOTICES,
        },
    }


@router.get("/datasets/{dataset_id}")
def describe_dataset(dataset_id: str) -> dict[str, object]:
    catalog = load_catalog()
    dataset = public_dataset(catalog.get_dataset(dataset_id))
    # Compute source fiscal year range from the backing view
    source_fiscal_years = _fetch_source_fiscal_years(dataset)
    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": dataset,
        "meta": {
            "api_version": catalog.version,
            "dataset_id": dataset_id,
            "row_count": 1,
            "notices": data_notices(catalog.get_dataset(dataset_id)),
            "source_fiscal_years": source_fiscal_years,
        },
    }


def _fetch_source_fiscal_years(dataset: dict[str, object]) -> list[int] | None:
    fields = dataset.get("fields", [])
    if "fiscal_year" not in fields:
        return None
    backing_view = dataset.get("backing_view")
    if not backing_view or not isinstance(backing_view, str):
        return None
    # Backing view is schema-qualified (e.g. analytics_api.pricing_trend_fy).
    # Validate format before interpolating.
    parts = backing_view.split(".")
    if len(parts) != 2 or not all(part.replace("_", "").isalnum() for part in parts):
        return None
    schema, table = parts
    try:
        with db_cursor() as cur:
            cur.execute(
                f"SELECT min(fiscal_year) AS min_fy, max(fiscal_year) AS max_fy "
                f'FROM "{schema}"."{table}"'
            )
            row = cur.fetchone()
    except (pg_errors.Error, RuntimeError):
        return None
    if not row or row.get("min_fy") is None:
        return None
    return [row["min_fy"], row["max_fy"]]



@router.get("/dimensions")
def list_dimensions() -> dict[str, object]:
    catalog = load_catalog()
    dimensions = [public_dimension(item) for item in catalog.dimensions.values()]
    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": dimensions,
        "meta": {
            "api_version": catalog.version,
            "row_count": len(dimensions),
            "notices": GLOBAL_DATA_NOTICES,
        },
    }
