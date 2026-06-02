"""Catalog loading for public analytics datasets and dimensions."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml

from .errors import APIError


SERVICE_ROOT = Path(__file__).resolve().parents[1]
CATALOG_DIR = SERVICE_ROOT / "catalog"


class Catalog:
    """In-memory representation of the checked-in public API catalog."""

    def __init__(self, datasets_doc: dict[str, Any], dimensions_doc: dict[str, Any]) -> None:
        self.version = str(datasets_doc.get("version", "unknown"))
        self.defaults = datasets_doc.get("defaults", {})
        self.datasets = {
            item["id"]: {**self.defaults, **item}
            for item in datasets_doc.get("datasets", [])
        }
        self.dimensions = {
            item["id"]: item
            for item in dimensions_doc.get("dimensions", [])
        }

    def get_dataset(self, dataset_id: str) -> dict[str, Any]:
        try:
            return self.datasets[dataset_id]
        except KeyError as exc:
            raise APIError(404, "dataset_not_found", f"Unknown dataset_id '{dataset_id}'.", param="dataset_id") from exc

    def get_dimension(self, dimension_id: str) -> dict[str, Any]:
        try:
            return self.dimensions[dimension_id]
        except KeyError as exc:
            raise APIError(404, "dimension_not_found", f"Unknown dimension_id '{dimension_id}'.", param="dimension_id") from exc

    def list_datasets(self, *, domain: str | None = None) -> list[dict[str, Any]]:
        datasets = list(self.datasets.values())
        if domain:
            datasets = [item for item in datasets if item.get("domain") == domain]
        return [public_dataset(item) for item in datasets]


def public_dataset(dataset: dict[str, Any]) -> dict[str, Any]:
    """Return catalog metadata safe for API consumers."""
    hidden = {"source_view"}
    return {key: value for key, value in dataset.items() if key not in hidden}


def public_dimension(dimension: dict[str, Any]) -> dict[str, Any]:
    hidden = {"source_table"}
    return {key: value for key, value in dimension.items() if key not in hidden}


@lru_cache(maxsize=1)
def load_catalog() -> Catalog:
    with (CATALOG_DIR / "datasets.yaml").open("r", encoding="utf-8") as fh:
        datasets_doc = yaml.safe_load(fh)
    with (CATALOG_DIR / "dimensions.yaml").open("r", encoding="utf-8") as fh:
        dimensions_doc = yaml.safe_load(fh)
    return Catalog(datasets_doc, dimensions_doc)
