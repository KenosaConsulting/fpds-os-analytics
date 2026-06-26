from __future__ import annotations

import asyncio
import sys
from pathlib import Path
import hashlib
from decimal import Decimal
from contextlib import contextmanager
from datetime import datetime, timezone
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import yaml


SERVICE_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE_ROOT))

from app.catalog import load_catalog  # noqa: E402
from app.errors import APIError  # noqa: E402
from app.query_builder import build_rows_query  # noqa: E402
from app.auth import APIAccess, optional_api_access, require_api_key  # noqa: E402
from app.main import _allowed_origins  # noqa: E402
from app.notices import BRIEF_DATA_NOTICE, data_notices, dimension_notices  # noqa: E402
from app.rate_limit import MemoryRateLimitStore, RateLimit, _hashed_token  # noqa: E402
from app.routes.catalog import describe_dataset, list_catalog, list_dimensions  # noqa: E402
from app.routes.datasets import dataset_data_as_of, dataset_rows  # noqa: E402
from app.routes.health import ai_assistant_guide, health, metadata  # noqa: E402
from app.routes.profiles import customer_profile  # noqa: E402
from mcp.fpds_mcp_server import FPDSServer, TYPE_TO_DIMENSION, _clean_params, handle_message  # noqa: E402


# Synthetic filters that don't map to a declared field — they generate
# special SQL (prefix match, range bounds, etc.) rather than equality.
SYNTHETIC_FILTERS = {"fiscal_year_min", "fiscal_year_max", "naics_prefix"}


def _sample_value(filter_name: str) -> str:
    if filter_name in {"fiscal_year", "fiscal_year_min", "fiscal_year_max"}:
        return "2024"
    if filter_name == "naics_prefix":
        return "5415"
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


async def _streaming_response_text(response) -> str:
    chunks = []
    async for chunk in response.body_iterator:
        chunks.append(chunk.decode("utf-8") if isinstance(chunk, bytes) else chunk)
    return "".join(chunks)


def test_catalog_has_expected_dataset_count() -> None:
    catalog = load_catalog()
    assert len(catalog.datasets) == 87
    assert len(catalog.dimensions) == 17
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
            if filter_name in SYNTHETIC_FILTERS:
                continue  # Synthetic filters generate special SQL, no backing field
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


def test_openapi_documents_data_as_of_metadata() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    meta_properties = openapi["components"]["schemas"]["ResponseMeta"]["properties"]
    assert "data_as_of" in meta_properties


def test_openapi_documents_dataset_rows_csv_format() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    rows = openapi["paths"]["/v1/datasets/{dataset_id}/rows"]["get"]
    format_param = next(param for param in rows["parameters"] if param.get("name") == "format")
    assert format_param["schema"]["enum"] == ["json", "csv"]
    assert "text/csv" in rows["responses"]["200"]["content"]


def test_openapi_documents_customer_profile_endpoint() -> None:
    with (SERVICE_ROOT / "openapi.yaml").open("r", encoding="utf-8") as fh:
        openapi = yaml.safe_load(fh)
    assert "/v1/profiles/customer" in openapi["paths"]


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
    goals = {goal["start_with_dataset"] for goal in response["common_user_goals"]}
    assert "topics.agency_profile" in goals
    assert "topics.catalog" in goals
    assert "pipeline.recompete_watchlist" in goals
    assert "contacts.office_roster" in goals
    assert "market.entry_difficulty_score" in goals


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


def test_refresh_log_template_creates_reader_view_and_grant() -> None:
    sql = (SERVICE_ROOT / "sql" / "022_dataset_refresh_log.sql").read_text(encoding="utf-8")
    assert "external refresh process outside this repo must add one INSERT per dataset" in sql
    assert "CREATE TABLE IF NOT EXISTS analytics_dims.dataset_refresh_log" in sql
    assert "CREATE OR REPLACE VIEW analytics_api.dataset_refresh_log" in sql
    assert "GRANT SELECT ON analytics_api.dataset_refresh_log TO fpds_analytics_api_readonly" in sql


def test_new_entrant_cohort_template_uses_existing_mvs_and_grants_reader() -> None:
    sql = (SERVICE_ROOT / "sql" / "023_new_entrant_cohorts.sql").read_text(encoding="utf-8")
    assert "vendor_concentration.mv_fpds_vendor_agency_year" in sql
    assert "pipeline_intelligence.mv_contract_family" in sql
    assert "public.fpds_actions" not in sql
    assert "survival_2fy_rate" in sql
    assert "GRANT SELECT ON analytics_api.entrants_agency_cohort_fy TO fpds_analytics_api_readonly" in sql


def test_award_size_distribution_template_uses_single_pass_percentiles() -> None:
    sql = (SERVICE_ROOT / "sql" / "024_award_size_distribution.sql").read_text(encoding="utf-8")
    assert "pipeline_intelligence.mv_contract_family" in sql
    assert "PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY cf.total_obligated)" in sql
    assert "PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cf.total_obligated)" in sql
    assert "PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY cf.total_obligated)" in sql
    assert "cf.total_obligated > 0" in sql
    assert "GRANT SELECT ON analytics_api.pipeline_award_size_distribution TO fpds_analytics_api_readonly" in sql


def test_market_entry_difficulty_template_exposes_weighted_components() -> None:
    sql = (SERVICE_ROOT / "sql" / "025_market_entry_difficulty_score.sql").read_text(encoding="utf-8")
    assert "CREATE OR REPLACE VIEW competition_dynamics.report_deck_market_entry_difficulty_score" in sql
    assert "vendor_concentration.mv_fpds_vendor_naics_agency_year" in sql
    assert "naics_breakdown.report_deck_naics_agency_fy" in sql
    assert "competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy" in sql
    assert "vendor_concentration.report_deck_agency_naics_vendor_leaders" in sql
    assert "0.30 * c.hhi_component" in sql
    assert "0.25 * c.not_competed_component" in sql
    assert "entry_difficulty_score" in sql
    assert "GRANT SELECT ON analytics_api.market_entry_difficulty_score TO fpds_analytics_api_readonly" in sql


def test_seasonality_template_builds_two_materialized_views_and_grants_reader() -> None:
    sql = (SERVICE_ROOT / "sql" / "026_fiscal_seasonality.sql").read_text(encoding="utf-8")
    assert "CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_agency_month_seasonality" in sql
    assert "CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_office_quarter_seasonality" in sql
    assert "fa.signed_date::date" in sql
    assert "fiscal_year >= 2010" in sql
    assert "q4_obligation_share" in sql
    assert "CREATE INDEX IF NOT EXISTS mv_agency_month_seasonality_entity_year_idx" in sql
    assert "CREATE INDEX IF NOT EXISTS mv_office_quarter_seasonality_entity_year_idx" in sql
    assert "GRANT SELECT ON analytics_api.seasonality_agency_month_fy TO fpds_analytics_api_readonly" in sql
    assert "GRANT SELECT ON analytics_api.seasonality_office_quarter_fy TO fpds_analytics_api_readonly" in sql


def test_vehicle_program_agency_fy_template_canonicalizes_pseudo_program_labels() -> None:
    sql = (SERVICE_ROOT / "sql" / "029_vehicle_program_agency_fy.sql").read_text(encoding="utf-8")
    assert "owner_agm.agency_short_name" in sql
    assert "COALESCE(vp.program_id, vc.program_id) AS resolved_program_id" in sql
    assert "regexp_replace(lower(cb.vehicle_family_label), '[^a-z0-9]+', '_', 'g')" in sql
    assert "AVG(na.offers_received) AS avg_offers_received" in sql
    assert "COUNT(DISTINCT na.winner_uei)" in sql


def test_vehicle_program_vendor_fy_template_rolls_up_by_uei_not_vendor_alias() -> None:
    sql = (SERVICE_ROOT / "sql" / "030_vehicle_program_vendor_fy.sql").read_text(encoding="utf-8")
    assert "vendor_alias_totals AS (" in sql
    assert "ROW_NUMBER() OVER (" in sql
    assert "COALESCE(ra.vendor_name, vt.vendor_uei) AS vendor_name" in sql
    assert "vehicle_program_id,\n        vendor_uei,\n        fiscal_year" in sql
    assert "vendor_name,\n        fiscal_year" not in sql.split("CREATE UNIQUE INDEX IF NOT EXISTS mv_vehicle_program_vendor_fy_uq", 1)[1]


def test_vehicle_program_runtime_replacement_templates_document_no_drop_protocol() -> None:
    agency_sql = (SERVICE_ROOT / "sql" / "031_vehicle_program_agency_fy_runtime.sql").read_text(encoding="utf-8")
    vendor_sql = (SERVICE_ROOT / "sql" / "032_vehicle_program_vendor_fy_runtime.sql").read_text(encoding="utf-8")
    assert "mv_fpds_vehicle_program_agency_fy_norm" in agency_sql
    assert "mv_fpds_vehicle_program_vendor_fy_norm" in vendor_sql
    assert "protocol forbids DROP / ALTER / REFRESH" in agency_sql
    assert "protocol forbids DROP / ALTER / REFRESH" in vendor_sql
    assert "COMMENT ON MATERIALIZED VIEW customer_intelligence.mv_fpds_vehicle_program_agency_fy_norm" in agency_sql
    assert "COMMENT ON MATERIALIZED VIEW customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm" in vendor_sql


def test_vehicle_program_views_template_targets_norm_mvs_and_grants_reader() -> None:
    sql = (SERVICE_ROOT / "sql" / "034_vehicle_program_views.sql").read_text(encoding="utf-8")
    assert "mv_fpds_vehicle_program_agency_fy_norm" in sql
    assert "mv_fpds_vehicle_program_vendor_fy_norm" in sql
    assert "CREATE OR REPLACE VIEW customer_intelligence.report_deck_vehicle_program_summary" in sql
    assert "CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_usage_fy" in sql
    assert "CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_summary" in sql
    assert "CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_vendors" in sql
    assert "GRANT SELECT ON analytics_api.acquisition_vehicle_program_usage_fy TO fpds_analytics_api_readonly" in sql
    assert "GRANT SELECT ON analytics_api.acquisition_vehicle_program_summary TO fpds_analytics_api_readonly" in sql
    assert "GRANT SELECT ON analytics_api.acquisition_vehicle_program_vendors TO fpds_analytics_api_readonly" in sql


def test_vehicle_program_dimension_template_exposes_curated_registry() -> None:
    sql = (SERVICE_ROOT / "sql" / "035_vehicle_program_dimension.sql").read_text(encoding="utf-8")
    assert "CREATE OR REPLACE VIEW analytics_api.dim_vehicle_programs" in sql
    assert "FROM analytics_dims.fpds_vehicle_program" in sql
    assert "GRANT SELECT ON analytics_api.dim_vehicle_programs TO fpds_analytics_api_readonly" in sql


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


def test_bl016_dimension_search_includes_code_columns() -> None:
    """BL-016/BL-012: fpds_resolve must find dimensions by numeric/alphanumeric codes,
    not just description text. Code columns must be in searchable_columns."""
    catalog = load_catalog()
    cases = [
        ("naics", "naics_code", "541512"),
        ("psc_codes", "psc_code", "R425"),
        ("departments", "department_id", "9700"),
        ("agencies", "agency_id", "1700"),
    ]
    for dim_id, code_field, code_value in cases:
        dimension = catalog.get_dimension(dim_id)
        assert code_field in dimension["searchable_columns"], (
            f"{dim_id}: {code_field} missing from searchable_columns"
        )
        # Verify the query builder generates ILIKE for the code column
        sql, values, _limit, _offset = build_rows_query(
            _dimension_dataset_like(dimension),
            {"_search_q": code_value},
        )
        assert f'"{code_field}" ilike %s' in sql, (
            f"{dim_id}: {code_field} ILIKE not in SQL"
        )
        assert f"%{code_value}%" in values


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


def test_vehicle_program_catalog_entries_have_required_filters_and_recent_default() -> None:
    catalog = load_catalog()
    usage = catalog.get_dataset("acquisition.vehicle_program_usage_fy")
    summary = catalog.get_dataset("acquisition.vehicle_program_summary")
    vendors = catalog.get_dataset("acquisition.vehicle_program_vendors")
    assert usage["required_filters_any"] == ["vehicle_program_id", "contracting_dept_id", "contracting_agency_id"]
    assert summary["default_predicates"] == [
        {"field": "is_active_recent", "include_values": [True], "unless_filter": "is_active_recent"}
    ]
    assert vendors["required_filters_any"] == ["vehicle_program_id", "program_owner_agency_id"]
    assert "BPA-routed schedule spending is not visible" in " ".join(summary["caveats"])
    assert "official seat-holder list" in " ".join(vendors["caveats"])


def test_vehicle_program_dimension_is_searchable_and_resolvable() -> None:
    catalog = load_catalog()
    dimension = catalog.get_dimension("vehicle_programs")
    assert dimension["backing_view"] == "analytics_api.dim_vehicle_programs"
    assert dimension["searchable_columns"] == ["program_name", "program_short_name"]
    assert TYPE_TO_DIMENSION["vehicle_programs"] == "vehicle_programs"
    assert TYPE_TO_DIMENSION["vehicle_program"] == "vehicle_programs"
    assert TYPE_TO_DIMENSION["vehicles"] == "vehicle_programs"


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


def test_bl014_public_default_limit_matches_public_row_limit(monkeypatch) -> None:
    """BL-014: public tier max_rows_per_request must match public_row_limit(),
    not a hardcoded 25. Catalog max_limit values (500-1000) must be respected
    for public access unless explicitly overridden."""
    monkeypatch.setenv("FPDS_ANALYTICS_PUBLIC_ROW_LIMIT", "100")
    access = APIAccess(key_id="public", is_authenticated=False)
    assert access.max_rows_per_request == 100, (
        f"Public default should be 100 (via public_row_limit), got {access.max_rows_per_request}"
    )

    # The override mechanism should cap at 100, not 25
    catalog = load_catalog()
    dataset = catalog.get_dataset("pricing.risk_scorecard")
    # limit=50 should now succeed (was 400 when capped at 25)
    sql, values, limit, offset = build_rows_query(
        dataset, {"limit": "50", "_max_limit_override": str(access.max_rows_per_request)}
    )
    assert limit == 50
    assert values[-2:] == [51, 0]

    # limit=100 should also succeed
    sql, values, limit, offset = build_rows_query(
        dataset, {"limit": "100", "_max_limit_override": str(access.max_rows_per_request)}
    )
    assert limit == 100

    # limit=101 should still fail (over the cap)
    try:
        build_rows_query(
            dataset, {"limit": "101", "_max_limit_override": str(access.max_rows_per_request)}
        )
    except APIError as exc:
        assert exc.detail["code"] == "limit_too_large"
    else:
        raise AssertionError("Expected limit_too_large for 101 > 100")


def test_bl014_health_endpoint_reports_correct_public_limit(monkeypatch) -> None:
    """BL-014: AI assistant guide must report the actual public_row_limit(), not hardcoded 25."""
    monkeypatch.setenv("FPDS_ANALYTICS_PUBLIC_ROW_LIMIT", "100")
    response = ai_assistant_guide()
    assert response["auth"]["public_row_limit"] == 100


def test_bl015_documented_filters_are_accepted() -> None:
    """BL-015 regression: filters that were reported as 'documented but rejected'
    in S7-012b must all work. Root cause was BL-014 (limit=25 cap masquerading
    as filter rejection), not the filters themselves."""
    catalog = load_catalog()
    # Each tuple: (dataset_id, params_with_required_filter, tested_filter_name)
    cases = [
        ("geography.mismatch_leaders", {"is_in_state": "true"}, "is_in_state"),
        ("geography.mismatch_leaders", {"is_in_state": "false"}, "is_in_state"),
        ("set_aside.family_trend_fy", {"fiscal_year_min": "2022"}, "fiscal_year_min"),
        ("set_aside.family_trend_fy", {"fiscal_year_max": "2025"}, "fiscal_year_max"),
        ("naics.trend_fy", {"fiscal_year_min": "2022"}, "fiscal_year_min"),
        ("contacts.naics_buyers", {"user_class": "human", "contracting_dept_id": "9700"}, "user_class"),
        ("funding.mismatch_flows_fy", {"is_cross_department": "true", "fiscal_year": "2024"}, "is_cross_department"),
        ("funding.mismatch_flows_fy", {"is_cross_department": "false", "fiscal_year": "2024"}, "is_cross_department"),
    ]
    for dataset_id, params, filter_name in cases:
        dataset = catalog.get_dataset(dataset_id)
        # Will raise APIError if the filter is rejected
        build_rows_query(dataset, params)


def test_bl015_documented_sorts_are_accepted() -> None:
    """BL-015 regression: sort params reported as rejected must work."""
    catalog = load_catalog()
    cases = [
        ("acquisition.vehicle_program_vendors", {"sort": "-obligated_amount", "vehicle_program_id": "gsa_oasis_small_business"}),
        ("entrants.agency_cohort_fy", {"sort": "-new_vendor_count", "contracting_dept_id": "9700"}),
        ("funding.mismatch_flows_fy", {"sort": "-net_obligated_amount", "fiscal_year": "2024"}),
    ]
    for dataset_id, params in cases:
        dataset = catalog.get_dataset(dataset_id)
        build_rows_query(dataset, params)


def test_bl023_source_fiscal_years_reflects_actual_rows(monkeypatch) -> None:
    """BL-023: source_fiscal_years must reflect actual returned rows, not hardcode [1958, 2026]."""
    class FakeCursor:
        def execute(self, sql, values):
            self.sql = sql
            self.values = values

        def fetchall(self):
            return [
                {"fiscal_year": 2023, "total_obligated": Decimal("1.0")},
                {"fiscal_year": 2024, "total_obligated": Decimal("2.0")},
                {"fiscal_year": 2025, "total_obligated": Decimal("3.0")},
            ]

        def fetchone(self):
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "pricing.trend_fy",
        SimpleNamespace(query_params={"limit": "3"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["meta"]["source_fiscal_years"] == [2023, 2025]


def test_bl023_source_fiscal_years_null_when_no_fy_column(monkeypatch) -> None:
    """BL-023: source_fiscal_years should be null when rows have no fiscal_year column."""
    class FakeCursor:
        def execute(self, sql, values):
            self.sql = sql
            self.values = values

        def fetchall(self):
            return [{"vendor_name": "Test Co", "uei": "ABC123"}]

        def fetchone(self):
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "concentration.vendor_market_leaders",
        SimpleNamespace(query_params={"limit": "1", "uei": "ABC123"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["meta"]["source_fiscal_years"] is None


def test_bl017_fields_projection_works_with_sort_and_filter() -> None:
    """BL-017 regression: fields parameter must work when combined with sort and filter.
    Root cause was BL-014 (limit=25 cap), not the fields parameter itself."""
    catalog = load_catalog()
    # Q6 scenario: acquisition.vehicle_program_vendors
    dataset = catalog.get_dataset("acquisition.vehicle_program_vendors")
    sql, values, limit, offset = build_rows_query(dataset, {
        "fields": "vendor_name,vendor_uei,obligated_amount",
        "sort": "-obligated_amount",
        "vehicle_program_id": "gsa_oasis_small_business",
        "limit": "50",
        "_max_limit_override": "100",
    })
    assert limit == 50
    assert 'select "vendor_name", "vendor_uei", "obligated_amount"' in sql

    # Q10 scenario: contacts.naics_buyers
    dataset2 = catalog.get_dataset("contacts.naics_buyers")
    sql2, values2, limit2, offset2 = build_rows_query(dataset2, {
        "fields": "user_id,display_name,action_count",
        "contracting_dept_id": "9700",
        "principal_naics_code": "541712",
        "limit": "50",
        "_max_limit_override": "100",
    })
    assert limit2 == 50
    assert 'select "user_id", "display_name", "action_count"' in sql2


def test_bl022_negative_obligations_flagged_in_response(monkeypatch) -> None:
    """BL-022: rows with negative obligations must be flagged with _negative_obligation
    and the response meta must include negative_obligation_count."""
    class FakeCursor:
        def execute(self, sql, values):
            self.sql = sql
            self.values = values

        def fetchall(self):
            return [
                {"fiscal_year": 2024, "total_obligated": Decimal("-5000000.00"), "contracting_dept_id": "7500"},
                {"fiscal_year": 2023, "total_obligated": Decimal("10000000.00"), "contracting_dept_id": "7500"},
            ]

        def fetchone(self):
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "pricing.trend_fy",
        SimpleNamespace(query_params={"limit": "2"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    # First row is negative, second is positive
    assert response["data"][0]["_negative_obligation"] is True
    assert "_negative_obligation" not in response["data"][1]
    assert response["meta"]["negative_obligation_count"] == 1


def test_bl022_no_negative_count_when_all_positive(monkeypatch) -> None:
    """BL-022: negative_obligation_count should be null when all rows are positive."""
    class FakeCursor:
        def execute(self, sql, values):
            self.sql = sql
            self.values = values

        def fetchall(self):
            return [{"fiscal_year": 2024, "total_obligated": Decimal("1000000.00")}]

        def fetchone(self):
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "pricing.trend_fy",
        SimpleNamespace(query_params={"limit": "1"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["meta"]["negative_obligation_count"] is None


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
    """Placeholder env-var keys are rejected (not treated as valid).

    With Supabase as primary backend, placeholder env-var keys simply
    don't match — the fallback returns None and the key is rejected as
    invalid (403) rather than the old 503 "unconfigured" error.
    """
    monkeypatch.setenv("FPDS_ANALYTICS_REQUIRE_AUTH", "1")
    monkeypatch.setenv("FPDS_ANALYTICS_API_KEYS", "fpds_live_replace_me")
    monkeypatch.delenv("FPDS_ANALYTICS_API_KEY_HASHES", raising=False)
    try:
        require_api_key("fpds_live_replace_me")
    except APIError as exc:
        assert exc.status_code in (403, 503)  # 403 with Supabase primary, 503 legacy
        assert exc.detail["code"] in ("invalid_api_key", "api_key_store_unconfigured")
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


def test_dataset_data_as_of_returns_iso_timestamp(monkeypatch) -> None:
    timestamp = datetime(2026, 6, 10, 12, 30, tzinfo=timezone.utc)

    class FakeCursor:
        def execute(self, sql: str, values: tuple[object, object]) -> None:
            assert "analytics_api.dataset_refresh_log" in sql
            assert values == ("pricing.trend_fy", "contract_pricing.report_deck_pricing_trend_fy")

        def fetchone(self) -> dict[str, object]:
            return {"data_as_of": timestamp}

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    catalog = load_catalog()
    assert dataset_data_as_of(catalog.get_dataset("pricing.trend_fy")) == timestamp.isoformat()


def test_dataset_data_as_of_falls_back_to_null_when_missing(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: tuple[object, object]) -> None:
            return None

        def fetchone(self) -> None:
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    catalog = load_catalog()
    assert dataset_data_as_of(catalog.get_dataset("pricing.trend_fy")) is None


def test_dataset_rows_defaults_to_json(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: list[object] | tuple[object, ...]) -> None:
            self.sql = sql
            self.values = values

        def fetchall(self) -> list[dict[str, object]]:
            assert 'from "analytics_api"."pricing_trend_fy"' in self.sql
            assert self.values[-2:] == [2, 0]
            return [{"fiscal_year": 2024, "total_obligated": Decimal("10.50")}]

        def fetchone(self) -> None:
            return None

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "pricing.trend_fy",
        SimpleNamespace(query_params={"fields": "fiscal_year,total_obligated", "limit": "1"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["data"] == [{"fiscal_year": 2024, "total_obligated": "10.50"}]
    assert response["pagination"]["limit"] == 1
    assert response["meta"]["source_fiscal_years"] == [2024, 2024]


def test_dataset_rows_csv_uses_same_bounds_and_escapes(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: list[object] | tuple[object, ...]) -> None:
            self.sql = sql
            self.values = values

        def fetchall(self) -> list[dict[str, object]]:
            assert 'from "analytics_api"."pricing_trend_fy"' in self.sql
            assert self.values[-2:] == [3, 0]
            return [
                {"fiscal_year": 2025, "total_obligated": '12, "quoted"'},
                {"fiscal_year": 2024, "total_obligated": Decimal("10.50")},
                {"fiscal_year": 2023, "total_obligated": Decimal("9.25")},
            ]

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.datasets.db_cursor", fake_db_cursor)
    response = dataset_rows(
        "pricing.trend_fy",
        SimpleNamespace(
            query_params={"fields": "fiscal_year,total_obligated", "limit": "2", "format": "csv"},
        ),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response.media_type == "text/csv; charset=utf-8"
    assert response.headers["content-disposition"] == 'attachment; filename="pricing_trend_fy_rows.csv"'
    text = asyncio.run(_streaming_response_text(response))
    assert text == 'fiscal_year,total_obligated\r\n2025,"12, ""quoted"""\r\n2024,10.50\r\n'


def test_customer_profile_orchestrates_existing_dataset_queries(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: list[object] | tuple[object, ...]) -> None:
            self.sql = sql
            self.values = values
            assert "analytics_api" in sql
            assert values[-2:] in ([2, 0], [6, 0])

        def fetchall(self) -> list[dict[str, object]]:
            if "customer_agency_profile_fy" in self.sql:
                return [
                    {
                        "fiscal_year": 2025,
                        "net_obligated_amount": Decimal("1000000"),
                        "competed_obligation_share": Decimal("0.82"),
                    }
                ]
            if "market_agency_naics_fy" in self.sql:
                return [{"principal_naics_code": "541512", "net_obligated_amount": Decimal("900000")}]
            if "set_aside_agency_mix_fy" in self.sql:
                return [{"set_aside_family": "8(a)", "net_obligated_amount": Decimal("100000")}]
            if "incumbent_agency_vendor_leaders" in self.sql:
                return [{"uei": "ABCDEFGHIJKL", "vendor_name": "Example Vendor"}]
            if "acquisition_agency_vehicle_mix_fy" in self.sql:
                return [{"vehicle_family": "IDIQ", "net_obligated_amount": Decimal("500000")}]
            if "pipeline_recompete_watchlist" in self.sql:
                return [{"piid": "W912345", "remaining_months": 4}]
            if "pricing_risk_scorecard" in self.sql:
                return [{"risk_score": Decimal("72"), "total_obligated_3yr": Decimal("3000000")}]
            return []

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.profiles.db_cursor", fake_db_cursor)
    response = customer_profile(
        SimpleNamespace(query_params={"contracting_dept_id": "9700"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["data"]["spend_trend"][0]["net_obligated_amount"] == "1000000"
    assert response["data"]["pricing_posture"][0]["risk_score"] == "72"
    assert response["meta"]["sections"]["top_naics"]["dataset_id"] == "market.agency_naics_fy"
    assert response["meta"]["sections"]["pricing_posture"]["status"] == "ok"
    assert any("Competition posture" in hint for hint in response["data"]["narrative_hints"])


def test_customer_profile_agency_only_nulls_department_pricing(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: list[object] | tuple[object, ...]) -> None:
            self.sql = sql
            assert "pricing_risk_scorecard" not in sql

        def fetchall(self) -> list[dict[str, object]]:
            return []

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.profiles.db_cursor", fake_db_cursor)
    response = customer_profile(
        SimpleNamespace(query_params={"contracting_agency_id": "1700"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["data"]["pricing_posture"] is None
    assert response["meta"]["sections"]["pricing_posture"]["status"] == "unavailable"
    assert "department level only" in response["meta"]["sections"]["pricing_posture"]["reason"]


def test_customer_profile_section_failure_is_partial(monkeypatch) -> None:
    class FakeCursor:
        def execute(self, sql: str, values: list[object] | tuple[object, ...]) -> None:
            self.sql = sql
            if "market_agency_naics_fy" in sql:
                raise RuntimeError("section failed")

        def fetchall(self) -> list[dict[str, object]]:
            return []

    @contextmanager
    def fake_db_cursor():
        yield FakeCursor()

    monkeypatch.setattr("app.routes.profiles.db_cursor", fake_db_cursor)
    response = customer_profile(
        SimpleNamespace(query_params={"contracting_dept_id": "9700"}),
        APIAccess(key_id="public", is_authenticated=False),
    )
    assert response["data"]["top_naics"] is None
    assert response["meta"]["sections"]["top_naics"]["status"] == "unavailable"
    assert response["data"]["spend_trend"] == []


def test_mcp_tools_embed_dataset_descriptions_and_handle_list() -> None:
    class FakeClient:
        def get(self, path: str, params: dict[str, object] | None = None) -> dict[str, object]:
            assert path == "/v1/catalog"
            return {
                "data": [
                    {
                        "id": "pricing.risk_scorecard",
                        "description": "Pricing risk description from the catalog.",
                    }
                ]
            }

    server = FPDSServer(FakeClient())
    response = handle_message(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    tools = response["result"]["tools"]
    query_tool = next(tool for tool in tools if tool["name"] == "fpds_query_dataset")
    assert "pricing.risk_scorecard: Pricing risk description from the catalog." in query_tool["description"]
    assert "filters" in query_tool["inputSchema"]["properties"]


def test_mcp_query_dataset_wraps_rows_endpoint() -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.calls = []

        def get(self, path: str, params: dict[str, object] | None = None) -> dict[str, object]:
            self.calls.append((path, params))
            return {"data": [{"risk_score": "71"}], "meta": {"dataset_id": "pricing.risk_scorecard"}}

    client = FakeClient()
    server = FPDSServer(client)
    result = server.call_tool(
        "fpds_query_dataset",
        {
            "dataset_id": "pricing.risk_scorecard",
            "filters": {"contracting_dept_id": "9700"},
            "fields": ["risk_score"],
            "limit": 5,
        },
    )
    assert client.calls == [
        (
            "/v1/datasets/pricing.risk_scorecard/rows",
            {"contracting_dept_id": "9700", "fields": ["risk_score"], "sort": None, "limit": 5, "cursor": None},
        )
    ]
    assert '"risk_score": "71"' in result["content"][0]["text"]


def test_mcp_resolve_wraps_dimension_search() -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.calls = []

        def get(self, path: str, params: dict[str, object] | None = None) -> dict[str, object]:
            self.calls.append((path, params))
            return {"data": [{"id": "9700", "name": "Department of Defense"}], "meta": {"dimension_id": path.rsplit("/", 1)[-1]}}

    client = FakeClient()
    server = FPDSServer(client)
    result = server.resolve({"q": "defense", "types": ["departments", "offices"], "limit": 3})
    assert client.calls == [
        ("/v1/dimensions/departments", {"q": "defense", "limit": 3}),
        ("/v1/dimensions/contracting_offices", {"q": "defense", "limit": 3}),
    ]
    assert result["results"][0]["dimension_id"] == "departments"


def test_mcp_resolve_includes_topics_in_default_search() -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.calls = []

        def get(self, path: str, params: dict[str, object] | None = None) -> dict[str, object]:
            self.calls.append((path, params))
            return {"data": [], "meta": {"dimension_id": path.rsplit("/", 1)[-1]}}

    client = FakeClient()
    server = FPDSServer(client)
    result = server.resolve({"q": "cybersecurity", "limit": 3})
    searched_dimensions = [call[0].rsplit("/", 1)[-1] for call in client.calls]
    assert "canonical_topics" in searched_dimensions


def test_mcp_resolve_supports_vehicle_program_types() -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.calls = []

        def get(self, path: str, params: dict[str, object] | None = None) -> dict[str, object]:
            self.calls.append((path, params))
            return {"data": [{"program_id": "gsa_oasis_small_business"}], "meta": {"dimension_id": path.rsplit("/", 1)[-1]}}

    client = FakeClient()
    server = FPDSServer(client)
    result = server.resolve({"q": "oasis", "types": ["vehicle_programs"], "limit": 2})
    assert client.calls == [
        ("/v1/dimensions/vehicle_programs", {"q": "oasis", "limit": 2}),
    ]
    assert result["results"][0]["dimension_id"] == "vehicle_programs"


def test_canonical_topics_dimension_is_searchable_and_resolvable() -> None:
    catalog = load_catalog()
    dimension = catalog.get_dimension("canonical_topics")
    assert dimension["backing_view"] == "analytics_api.topics_govwide_canonical"
    assert dimension["key"] == "canonical_topic_id"
    assert dimension["searchable_columns"] == ["canonical_label", "canonical_description"]
    assert TYPE_TO_DIMENSION["topics"] == "canonical_topics"
    assert TYPE_TO_DIMENSION["canonical_topics"] == "canonical_topics"


def test_topic_catalog_supports_server_side_search() -> None:
    catalog = load_catalog()
    topics_catalog = catalog.get_dataset("topics.catalog")
    govwide_canonical = catalog.get_dataset("topics.govwide_canonical")
    assert topics_catalog.get("searchable_columns") == ["label", "description", "naics_alignment"]
    assert govwide_canonical.get("searchable_columns") == ["canonical_label", "canonical_description"]
    # Verify searchable columns are declared fields
    for col in topics_catalog["searchable_columns"]:
        assert col in topics_catalog["fields"]
    for col in govwide_canonical["searchable_columns"]:
        assert col in govwide_canonical["fields"]
    # Verify query builder generates ILIKE for _search_q
    sql, values, _limit, _offset = build_rows_query(
        topics_catalog,
        {"department_code": "036", "corpus_type": "merged", "_search_q": "cyber"},
    )
    assert '"label" ilike %s' in sql
    assert '"description" ilike %s' in sql
    assert '"naics_alignment" ilike %s' in sql
    assert values[-5:-2] == ["%cyber%", "%cyber%", "%cyber%"]


def test_mcp_clean_params_flattens_filters_and_lists() -> None:
    assert _clean_params(
        {
            "filters": {"contracting_dept_id": "9700"},
            "fields": ["risk_score", "total_obligated_3yr"],
            "limit": 5,
            "cursor": None,
        }
    ) == {
        "contracting_dept_id": "9700",
        "fields": "risk_score,total_obligated_3yr",
        "limit": 5,
    }
