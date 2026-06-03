from __future__ import annotations

import sys
from pathlib import Path
import hashlib

import yaml


SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

from app.catalog import load_catalog  # noqa: E402
from app.errors import APIError  # noqa: E402
from app.query_builder import build_rows_query  # noqa: E402
from app.auth import require_api_key  # noqa: E402
from app.main import _allowed_origins  # noqa: E402


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


def test_hashed_api_keys_are_accepted(monkeypatch) -> None:
    api_key = "fpds_test_key"
    digest = hashlib.sha256(api_key.encode("utf-8")).hexdigest()
    monkeypatch.setenv("FPDS_ANALYTICS_REQUIRE_AUTH", "1")
    monkeypatch.delenv("FPDS_ANALYTICS_API_KEYS", raising=False)
    monkeypatch.setenv("FPDS_ANALYTICS_API_KEY_HASHES", digest)
    assert require_api_key(api_key) == f"key_{digest[:12]}"


def test_placeholder_api_keys_fail_closed(monkeypatch) -> None:
    monkeypatch.setenv("FPDS_ANALYTICS_REQUIRE_AUTH", "1")
    monkeypatch.setenv("FPDS_ANALYTICS_API_KEYS", "fpds_live_replace_me")
    monkeypatch.delenv("FPDS_ANALYTICS_API_KEY_HASHES", raising=False)
    try:
        require_api_key("fpds_live_replace_me")
    except APIError as exc:
        assert exc.status_code == 503
        assert exc.detail["code"] == "api_key_store_unconfigured"
    else:
        raise AssertionError("Expected placeholder API key config to fail closed")


def test_cors_is_not_wildcard_by_default(monkeypatch) -> None:
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOW_ALL_ORIGINS", raising=False)
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOWED_ORIGINS", raising=False)
    assert _allowed_origins() == []


def test_cors_all_origins_requires_explicit_flag(monkeypatch) -> None:
    monkeypatch.setenv("FPDS_ANALYTICS_ALLOW_ALL_ORIGINS", "1")
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOWED_ORIGINS", raising=False)
    assert _allowed_origins() == ["*"]
