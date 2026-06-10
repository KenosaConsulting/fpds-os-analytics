from __future__ import annotations

import sys
from pathlib import Path
import hashlib
from decimal import Decimal
from urllib.parse import parse_qs, urlparse

import yaml


SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

from app.catalog import load_catalog  # noqa: E402
from app.errors import APIError  # noqa: E402
from app.query_builder import build_rows_query  # noqa: E402
from app.auth import optional_api_access, require_api_key  # noqa: E402
from app.main import _allowed_origins  # noqa: E402
from app.notices import BRIEF_DATA_NOTICE, data_notices, dimension_notices  # noqa: E402
from app.rate_limit import MemoryRateLimitStore, RateLimit, _hashed_token  # noqa: E402
from app.routes.catalog import describe_dataset, list_catalog, list_dimensions  # noqa: E402
from app.routes.health import ai_assistant_guide, health, metadata  # noqa: E402


def _sample_value(filter_name: str) -> str:
    if filter_name in {"fiscal_year", "fiscal_year_min", "fiscal_year_max"}:
        return "2024"
    if filter_name.endswith("_min") or filter_name.endswith("_max"):
        return "10000000"
    if filter_name.startswith("is_"):
        return "true"
    return "TEST"


def _required_filter_params(dataset: dict[str, object]) -> dict[str, str]:
    required_any = dataset.get("required_filters_any") or []
    if not required_any:
        return {}
    filter_name = str(required_any[0])
    return {filter_name: _sample_value(filter_name)}


def _dimension_dataset_like(dimension: dict[str, object]) -> dict[str, object]:
    return {
        "id": f"dimension.{dimension['id']}",
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


def test_catalog_has_expected_dataset_count() -> None:
    catalog = load_catalog()
    assert len(catalog.datasets) == 53
    assert len(catalog.dimensions) == 15
    assert {item["public_access"] for item in catalog.datasets.values()} == {"public_bounded", "api_key"}


def test_openapi_dataset_enum_matches_catalog() -> None:
    catalog = load_catalog()
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    enum = openapi["components"]["parameters"]["DatasetId"]["schema"]["enum"]
    assert sorted(enum) == sorted(catalog.datasets)


def test_every_dataset_has_description_and_example_queries() -> None:
    catalog = load_catalog()
    failures = []
    for dataset in catalog.datasets.values():
        description = dataset.get("description", "")
        if not isinstance(description, str) or description.count(".") < 2:
            failures.append(f"{dataset['id']}:description")
        examples = dataset.get("example_queries", [])
        if not examples:
            failures.append(f"{dataset['id']}:example_queries")
            continue
        for example in examples:
            query = example.get("query", "")
            explanation = example.get("explanation", "")
            if not query.startswith(f"/v1/datasets/{dataset['id']}/rows?"):
                failures.append(f"{dataset['id']}:example_query_path")
            if not explanation:
                failures.append(f"{dataset['id']}:example_explanation")
            params = parse_qs(urlparse(query).query)
            required_any = dataset.get("required_filters_any") or []
            if required_any and not any(name in params for name in required_any):
                failures.append(f"{dataset['id']}:example_required_filter")
    assert failures == []


def test_catalog_responses_surface_descriptions_and_examples() -> None:
    catalog_response = list_catalog(domain=None)
    describe_response = describe_dataset("pricing.risk_scorecard")
    first_dataset = catalog_response["data"][0]
    described_dataset = describe_response["data"]
    assert "description" in first_dataset
    assert "example_queries" in first_dataset
    assert described_dataset["description"]
    assert described_dataset["example_queries"][0]["query"].startswith("/v1/datasets/pricing.risk_scorecard/rows?")


def test_every_dataset_filter_is_accepted_by_runtime_query_builder() -> None:
    catalog = load_catalog()
    failures: list[str] = []
    for dataset in catalog.datasets.values():
        for filter_name in dataset.get("filters", []):
            params = _required_filter_params(dataset)
            params[str(filter_name)] = _sample_value(str(filter_name))
            try:
                build_rows_query(dataset, params)
            except APIError as exc:
                if exc.detail["code"] == "invalid_filter":
                    failures.append(f"{dataset['id']}:{filter_name} -> {exc.detail['message']}")
                else:
                    raise
    assert failures == []


def test_required_filters_are_declared_dataset_filters() -> None:
    catalog = load_catalog()
    failures = []
    for dataset in catalog.datasets.values():
        allowed_filters = set(dataset.get("filters", []))
        for filter_name in dataset.get("required_filters_any") or []:
            if filter_name not in allowed_filters:
                failures.append(f"{dataset['id']}:{filter_name}")
    assert failures == []


def test_dataset_default_sort_fields_are_sortable() -> None:
    catalog = load_catalog()
    failures = []
    for dataset in catalog.datasets.values():
        default_sort = str(dataset.get("default_sort") or "")
        sort_field = default_sort.removeprefix("-")
        if sort_field and sort_field not in set(dataset.get("sortable", [])):
            failures.append(f"{dataset['id']}:{default_sort}")
    assert failures == []


def test_dataset_filters_and_sortables_are_declared_fields_or_synthetic() -> None:
    catalog = load_catalog()
    failures = []
    for dataset in catalog.datasets.values():
        fields = set(dataset.get("fields", []))
        for filter_name in dataset.get("filters", []):
            if filter_name.endswith("_min") or filter_name.endswith("_max"):
                base_field = filter_name.rsplit("_", 1)[0]
                if base_field not in fields:
                    failures.append(f"{dataset['id']}:filter:{filter_name}")
            elif filter_name not in fields:
                failures.append(f"{dataset['id']}:filter:{filter_name}")
        for sort_name in dataset.get("sortable", []):
            if sort_name not in fields:
                failures.append(f"{dataset['id']}:sortable:{sort_name}")
    assert failures == []


def test_default_predicates_use_declared_dataset_filters() -> None:
    catalog = load_catalog()
    failures = []
    for dataset in catalog.datasets.values():
        filters = set(dataset.get("filters", []))
        fields = set(dataset.get("fields", []))
        for predicate in dataset.get("default_predicates", []):
            field = predicate.get("field")
            unless_filter = predicate.get("unless_filter", field)
            if field not in fields:
                failures.append(f"{dataset['id']}:field:{field}")
            if "min_value" not in predicate and "exclude_values" in predicate and field not in filters:
                failures.append(f"{dataset['id']}:filter_field:{field}")
            if unless_filter and unless_filter not in filters:
                failures.append(f"{dataset['id']}:unless_filter:{unless_filter}")
    assert failures == []


def test_dimension_searchable_columns_are_declared_fields() -> None:
    catalog = load_catalog()
    failures = []
    for dimension in catalog.dimensions.values():
        fields = set(dimension.get("fields", []))
        for column in dimension.get("searchable_columns", []):
            if column not in fields:
                failures.append(f"{dimension['id']}:{column}")
    assert failures == []


def test_openapi_documents_ai_assistant_guide() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    assert "/v1/ai-assistant-guide" in openapi["paths"]
    schema_ref = openapi["paths"]["/v1/ai-assistant-guide"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"]
    assert schema_ref == "#/components/schemas/AIAssistantGuide"
    assert "notice" in openapi["components"]["schemas"]["AIAssistantGuide"]["required"]
    assert "notice" in openapi["components"]["schemas"]["RowsResponse"]["required"]


def test_openapi_documents_dimension_catalog() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    assert "/v1/dimensions" in openapi["paths"]
    item_ref = openapi["paths"]["/v1/dimensions"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["properties"]["data"]["items"]["$ref"]
    assert item_ref == "#/components/schemas/Dimension"


def test_openapi_documents_dataset_metadata_fields() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    dataset_schema = openapi["components"]["schemas"]["Dataset"]
    properties = dataset_schema["properties"]
    assert "description" in dataset_schema["required"]
    assert "description" in properties
    assert "example_queries" in properties
    assert "field_descriptions" in properties


def test_openapi_documents_self_healing_error_fields() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    error_properties = openapi["components"]["schemas"]["ErrorResponse"]["properties"]["error"]["properties"]
    assert "allowed_filters" in error_properties
    assert "sortable" in error_properties
    assert "example_query" in error_properties


def test_metadata_points_to_ai_assistant_guide() -> None:
    response = metadata()
    assert response["notice"] == BRIEF_DATA_NOTICE
    assert response["ai_assistant_guide_url"] == "/v1/ai-assistant-guide"
    assert response["openapi_url"] == "/openapi.json"


def test_health_includes_brief_notice() -> None:
    response = health()
    assert response["notice"] == BRIEF_DATA_NOTICE


def test_ai_assistant_guide_defines_safe_workflow() -> None:
    response = ai_assistant_guide()
    safe_paths = {endpoint["path"] for endpoint in response["safe_endpoints"]}
    instructions = " ".join(response["assistant_instructions"])
    assert response["notice"] == BRIEF_DATA_NOTICE
    assert "/v1/catalog" in safe_paths
    assert "/v1/datasets/{dataset_id}/rows" in safe_paths
    assert "arbitrary SQL" in instructions
    assert "9700" in instructions
    assert "place-of-performance" in instructions
    assert "9700" in " ".join(response["critical_notices"])
    assert "customer targeting" in response["copy_paste_prompt"]
    assert "notices" in response["copy_paste_prompt"]


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
        assert exc.detail["allowed_filters"] == ["contracting_dept_id"]
    else:
        raise AssertionError("Expected invalid_filter")


def test_catalog_filter_allowlist_preserves_api_vs_dataset_errors() -> None:
    catalog = load_catalog()
    psc_dataset = catalog.get_dataset("psc.trend_fy")
    pricing_dataset = catalog.get_dataset("pricing.risk_scorecard")
    sql, values, _limit, _offset = build_rows_query(psc_dataset, {"psc_group": "services"})
    assert '"psc_group" = %s' in sql
    assert "services" in values

    try:
        build_rows_query(pricing_dataset, {"psc_group": "services"})
    except APIError as exc:
        assert exc.detail["code"] == "invalid_filter"
        assert "not supported for dataset" in exc.detail["message"]
        assert exc.detail["allowed_filters"] == ["contracting_dept_id"]
    else:
        raise AssertionError("Expected dataset-level invalid_filter")

    try:
        build_rows_query(pricing_dataset, {"not_a_catalog_filter": "x"})
    except APIError as exc:
        assert exc.detail["code"] == "invalid_filter"
        assert "not supported by the API" in exc.detail["message"]
        assert exc.detail["allowed_filters"] == ["contracting_dept_id"]
    else:
        raise AssertionError("Expected API-level invalid_filter")


def test_is_prefixed_filters_are_coerced_to_booleans() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("incumbent.office_vendor_leaders")
    cases = {
        "true": True,
        "false": False,
        "1": True,
        "0": False,
        "yes": True,
        "no": False,
    }
    for raw_value, expected in cases.items():
        sql, values, _limit, _offset = build_rows_query(
            dataset,
            {"contracting_office_id": "W912DY", "is_8a": raw_value},
        )
        assert '"is_8a" = %s' in sql
        assert values[1] is expected


def test_non_boolean_filters_remain_strings() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("psc.trend_fy")
    _sql, values, _limit, _offset = build_rows_query(dataset, {"psc_group": "services"})
    assert "services" in values


def test_recompete_watchlist_excludes_recently_expired_by_default() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pipeline.recompete_watchlist")
    sql, values, _limit, _offset = build_rows_query(dataset, {"contracting_dept_id": "7000"})
    assert '"expiration_bucket" <> %s' in sql
    assert "recently_expired" in values
    assert 'order by "remaining_months" asc nulls last' in sql


def test_recompete_watchlist_expiration_bucket_filter_overrides_default_predicate() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pipeline.recompete_watchlist")
    sql, values, _limit, _offset = build_rows_query(
        dataset,
        {"expiration_bucket": "recently_expired"},
    )
    assert '"expiration_bucket" <> %s' not in sql
    assert '"expiration_bucket" = %s' in sql
    assert values[0] == "recently_expired"


def test_naics_growth_leaders_applies_default_prior_year_base_floor() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("naics.growth_leaders")
    sql, values, _limit, _offset = build_rows_query(dataset, {"limit": "5"})
    assert '"prior_fy_obligated" >= %s' in sql
    assert values[0] == Decimal("10000000")


def test_naics_growth_leaders_min_base_filter_overrides_default_floor() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("naics.growth_leaders")
    sql, values, _limit, _offset = build_rows_query(
        dataset,
        {"prior_fy_obligated_min": "1000000", "limit": "5"},
    )
    assert sql.count('"prior_fy_obligated" >= %s') == 1
    assert values[0] == Decimal("1000000")


def test_trend_datasets_default_to_recent_fiscal_year_first() -> None:
    catalog = load_catalog()
    recent_first_trends = {
        "pricing.trend_fy",
        "competition.trend_fy",
        "concentration.trend_fy",
        "naics.trend_fy",
        "geography.state_trend_fy",
        "geography.regional_summary_fy",
        "set_aside.trend_fy",
        "set_aside.family_trend_fy",
        "psc.trend_fy",
        "acquisition.vehicle_trend_fy",
    }
    for dataset_id in recent_first_trends:
        dataset = catalog.get_dataset(dataset_id)
        assert dataset["default_sort"] == "-fiscal_year"


def test_new_filter_mv_index_template_covers_expected_materialized_views() -> None:
    sql = (SERVICE_ROOT / "sql" / "019_new_filter_mv_indexes.sql").read_text(encoding="utf-8")
    assert "vendor_concentration.mv_fpds_vendor_naics_agency_year" in sql
    assert "(contracting_agency_id, fiscal_year)" in sql
    assert "(principal_naics_code, fiscal_year)" in sql
    assert "naics_breakdown.mv_fpds_naics_agency_year" in sql
    assert "contract_pricing.mv_fpds_pricing_agency_year" in sql
    assert "competition_dynamics.mv_fpds_competition_agency_year" in sql


def test_dimension_q_search_uses_parameterized_ilike() -> None:
    catalog = load_catalog()
    dimension = catalog.get_dimension("departments")
    sql, values, _limit, _offset = build_rows_query(
        _dimension_dataset_like(dimension),
        {"_search_q": "homeland"},
    )
    assert '"department_name" ilike %s' in sql
    assert '"department_short_name" ilike %s' in sql
    assert "homeland" not in sql
    assert values[:2] == ["%homeland%", "%homeland%"]


def test_office_q_search_defaults_to_active_high_or_medium_confidence() -> None:
    catalog = load_catalog()
    dimension = catalog.get_dimension("contracting_offices")
    dataset_like = _dimension_dataset_like(dimension)
    dataset_like["default_predicates"] = [
        {"field": "is_active_recent", "include_values": [True], "unless_filter": "is_active_recent"},
        {"field": "name_confidence", "include_values": ["high", "medium"], "unless_filter": "name_confidence"},
    ]
    sql, values, _limit, _offset = build_rows_query(dataset_like, {"_search_q": "cecom"})
    assert '"is_active_recent" = %s' in sql
    assert '"name_confidence" in (%s, %s)' in sql
    assert values[:3] == [True, "high", "medium"]
    assert values[3:5] == ["%cecom%", "%cecom%"]


def test_office_q_search_defaults_are_overridable() -> None:
    catalog = load_catalog()
    dimension = catalog.get_dimension("contracting_offices")
    dataset_like = _dimension_dataset_like(dimension)
    dataset_like["default_predicates"] = [
        {"field": "is_active_recent", "include_values": [True], "unless_filter": "is_active_recent"},
        {"field": "name_confidence", "include_values": ["high", "medium"], "unless_filter": "name_confidence"},
    ]
    sql, values, _limit, _offset = build_rows_query(
        dataset_like,
        {"_search_q": "cecom", "is_active_recent": "false", "name_confidence": "low"},
    )
    assert '"name_confidence" in (%s, %s)' not in sql
    assert values[:2] == [False, "low"]
    assert values[2:4] == ["%cecom%", "%cecom%"]


def test_v1_label_enrichment_fields_are_declared_in_catalog() -> None:
    catalog = load_catalog()
    expected_fields = {
        "pricing.agency_profile_fy": {"contracting_dept_name", "department_short_name"},
        "pricing.risk_scorecard": {"contracting_dept_name", "department_short_name"},
        "pricing.dept_year_summary": {"contracting_dept_name", "department_short_name"},
        "competition.agency_profile_fy": {"contracting_dept_name", "department_short_name"},
        "competition.sole_source_hotspots": {"contracting_dept_name", "department_short_name"},
        "concentration.agency_profile": {"contracting_agency_name", "agency_short_name"},
        "naics.agency_profile_fy": {
            "top_naics_description",
            "top_naics_sector_label",
            "contracting_dept_name",
            "department_short_name",
        },
        "naics.growth_leaders": {"sector_label"},
    }
    for dataset_id, fields in expected_fields.items():
        assert fields <= set(catalog.get_dataset(dataset_id)["fields"])


def test_v1_label_enrichment_template_is_append_only_and_protocol_safe() -> None:
    sql = (SERVICE_ROOT / "sql" / "020_v1_label_enrichment_append.sql").read_text(encoding="utf-8")
    assert "COMMENT ON" not in sql
    assert "DROP " not in sql
    assert "ALTER " not in sql
    assert "INSERT " not in sql
    assert "UPDATE " not in sql
    assert "DELETE " not in sql
    assert "SELECT\n    r.*," in sql


def test_invalid_sort_is_rejected() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    try:
        build_rows_query(dataset, {"sort": "-vendor_name"})
    except APIError as exc:
        assert exc.detail["code"] == "invalid_sort"
        assert exc.detail["sortable"] == dataset["sortable"]
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


def test_public_limit_override_caps_no_key_queries() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    sql, values, limit, offset = build_rows_query(dataset, {"_max_limit_override": "25"})
    assert 'from "analytics_api"."pricing_risk_scorecard"' in sql
    assert values[-2:] == [26, 0]
    assert limit == 25
    assert offset == 0


def test_public_limit_override_rejects_large_no_key_queries() -> None:
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    try:
        build_rows_query(dataset, {"limit": "100", "_max_limit_override": "25"})
    except APIError as exc:
        assert exc.detail["code"] == "limit_too_large"
        assert "25" in exc.detail["message"]
    else:
        raise AssertionError("Expected limit_too_large")


def test_dataset_notices_include_dod_and_geography_limitations() -> None:
    catalog = load_catalog()
    competition_notices = " ".join(data_notices(catalog.get_dataset("competition.sole_source_hotspots")))
    geography_notices = " ".join(data_notices(catalog.get_dataset("geography.state_trend_fy")))
    states_notices = " ".join(dimension_notices(catalog.get_dimension("states")))
    assert "9700" in competition_notices
    assert "complete universe" in competition_notices
    assert "Place-of-performance" in geography_notices
    assert "OCONUS" in geography_notices
    assert "Place-of-performance" in states_notices


def test_catalog_and_describe_responses_include_notices() -> None:
    catalog_response = list_catalog(domain=None)
    describe_response = describe_dataset("geography.state_trend_fy")
    dimensions_response = list_dimensions()
    assert catalog_response["notice"] == BRIEF_DATA_NOTICE
    assert describe_response["notice"] == BRIEF_DATA_NOTICE
    assert dimensions_response["notice"] == BRIEF_DATA_NOTICE
    assert "9700" in " ".join(catalog_response["meta"]["notices"])
    assert "Place-of-performance" in " ".join(describe_response["meta"]["notices"])
    assert "9700" in " ".join(dimensions_response["meta"]["notices"])


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
            assert exc.detail["example_query"].startswith(f"/v1/datasets/{dataset_id}/rows?")
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


def test_missing_api_key_gets_public_access(monkeypatch) -> None:
    monkeypatch.setenv("FPDS_ANALYTICS_PUBLIC_ROWS_ENABLED", "1")
    monkeypatch.delenv("FPDS_ANALYTICS_API_KEYS", raising=False)
    monkeypatch.delenv("FPDS_ANALYTICS_API_KEY_HASHES", raising=False)
    access = optional_api_access(None)
    assert access.key_id == "public"
    assert access.is_authenticated is False


def test_cors_is_not_wildcard_by_default(monkeypatch) -> None:
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOW_ALL_ORIGINS", raising=False)
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOWED_ORIGINS", raising=False)
    assert _allowed_origins() == []


def test_cors_all_origins_requires_explicit_flag(monkeypatch) -> None:
    monkeypatch.setenv("FPDS_ANALYTICS_ALLOW_ALL_ORIGINS", "1")
    monkeypatch.delenv("FPDS_ANALYTICS_ALLOWED_ORIGINS", raising=False)
    assert _allowed_origins() == ["*"]


def test_memory_rate_limit_store_counts_within_window() -> None:
    store = MemoryRateLimitStore()
    key = "test-key"
    first_count, first_ttl = store.increment(key, 60)
    second_count, second_ttl = store.increment(key, 60)
    assert first_count == 1
    assert second_count == 2
    assert first_ttl > 0
    assert second_ttl > 0


def test_rate_limit_config_shape() -> None:
    limit = RateLimit(requests=10, window_seconds=60)
    assert limit.requests == 10
    assert limit.window_seconds == 60
    assert len(_hashed_token("fpds_test_key")) == 24
