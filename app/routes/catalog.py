"""Catalog discovery routes."""

from __future__ import annotations

from fastapi import APIRouter, Query

from app.catalog import load_catalog, public_dataset, public_dimension
from app.notices import BRIEF_DATA_NOTICE, GLOBAL_DATA_NOTICES, data_notices


router = APIRouter(prefix="/v1")


@router.get("/catalog")
def list_catalog(domain: str | None = Query(default=None)) -> dict[str, object]:
    catalog = load_catalog()
    datasets = catalog.list_datasets(domain=domain)
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
    return {
        "notice": BRIEF_DATA_NOTICE,
        "data": dataset,
        "meta": {
            "api_version": catalog.version,
            "dataset_id": dataset_id,
            "row_count": 1,
            "notices": data_notices(catalog.get_dataset(dataset_id)),
        },
    }


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
