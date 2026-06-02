from __future__ import annotations

import sys
from pathlib import Path

import yaml


SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

from app.catalog import load_catalog  # noqa: E402
from app.errors import APIError  # noqa: E402
from app.query_builder import build_rows_query  # noqa: E402


def test_catalog_has_expected_dataset_count() -> None:
    catalog = load_catalog()
    assert len(catalog.datasets) == 22
    assert len(catalog.dimensions) == 7


def test_openapi_dataset_enum_matches_catalog() -> None:
    catalog = load_catalog()
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    enum = openapi["components"]["parameters"]["DatasetId"]["schema"]["enum"]
    assert sorted(enum) == sorted(catalog.datasets)


def test_query_builder_uses_facade_relation() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    sql, values, limit, offset = build_rows_query(dataset, {"limit": "25"})
    assert 'from "analytics_api"."pricing_risk_scorecard"' in sql
    assert "public" not in sql
    assert values[-2:] == [26, 0]
    assert limit == 25
    assert offset == 0


def test_invalid_filter_is_rejected() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    try:
        build_rows_query(dataset, {"uei": "ABCDEFGHIJKL"})
    except APIError as exc:
        assert exc.detail["code"] == "invalid_filter"
        assert exc.detail["param"] == "uei"
    else:
        raise AssertionError("Expected invalid_filter")


def test_invalid_sort_is_rejected() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    try:
        build_rows_query(dataset, {"sort": "-vendor_name"})
    except APIError as exc:
        assert exc.detail["code"] == "invalid_sort"
    else:
        raise AssertionError("Expected invalid_sort")


def test_limit_cap_is_enforced() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    try:
        build_rows_query(dataset, {"limit": "100000"})
    except APIError as exc:
        assert exc.detail["code"] == "limit_too_large"
    else:
        raise AssertionError("Expected limit_too_large")


def test_naics_growth_leaders_uses_live_facade_fields() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("naics.growth_leaders")
    sql, _values, _limit, _offset = build_rows_query(dataset, {"limit": "1"})
    assert '"obligation_change"' in sql
    assert '"obligation_growth_rate"' in sql
    assert "absolute_change" not in sql
    assert "yoy_growth_rate" not in sql


def test_expensive_datasets_require_filters() -> None:
    catalog = load_catalog()
    for dataset_id in ("concentration.small_biz_health_fy", "naics.agency_profile_fy"):
        dataset = catalog.get_dataset(dataset_id)
        try:
            build_rows_query(dataset, {"limit": "1"})
        except APIError as exc:
            assert exc.detail["code"] == "missing_required_filter"
        else:
            raise AssertionError(f"Expected missing_required_filter for {dataset_id}")
