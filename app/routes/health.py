"""Health and metadata routes."""

from __future__ import annotations

from fastapi import APIRouter

from app.catalog import load_catalog


router = APIRouter()


@router.get("/v1")
def metadata() -> dict[str, object]:
    catalog = load_catalog()
    return {
        "name": "FPDS Analytics API",
        "api_version": catalog.version,
        "status": "ok",
        "documentation_url": "/docs",
    }


@router.get("/v1/health")
def health() -> dict[str, object]:
    catalog = load_catalog()
    return {
        "status": "ok",
        "catalog_version": catalog.version,
        "dataset_count": len(catalog.datasets),
        "dimension_count": len(catalog.dimensions),
    }
