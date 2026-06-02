-- FPDS Analytics API facade schema.
--
-- Purpose:
--   Give the public API stable, curated relation names that are decoupled from
--   internal analytics schemas. Keep this schema as the only database surface
--   visible to the API service role.
--
-- Security note:
--   These are intentionally facade views. For the strongest public-product
--   isolation, materialize these outputs into a separate analytics data mart
--   instead of exposing views in the production database.

-- The live database was missing this report view even though it exists in the
-- local analytics migration/reference. Create it before wiring the public
-- facade so the API has a complete 22-dataset surface.
CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_kpi_summary AS
WITH scope_data AS (
    SELECT
        'all_years_core' AS scope_name,
        COUNT(DISTINCT principal_naics_code) AS distinct_naics_count,
        COUNT(DISTINCT sector_code) AS distinct_sector_count,
        SUM(net_obligated_amount) AS total_obligated,
        COUNT(DISTINCT contracting_dept_id) AS dept_count,
        SUM(distinct_vendor_count) AS vendor_interactions
    FROM naics_breakdown.mv_fpds_naics_agency_year
    WHERE principal_naics_code != 'UNKNOWN'

    UNION ALL

    SELECT
        'current_fy' AS scope_name,
        COUNT(DISTINCT principal_naics_code) AS distinct_naics_count,
        COUNT(DISTINCT sector_code) AS distinct_sector_count,
        SUM(net_obligated_amount) AS total_obligated,
        COUNT(DISTINCT contracting_dept_id) AS dept_count,
        SUM(distinct_vendor_count) AS vendor_interactions
    FROM naics_breakdown.mv_fpds_naics_agency_year
    WHERE fiscal_year::INTEGER = (
        CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
             THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
             ELSE EXTRACT(year FROM CURRENT_DATE)::int
        END
    )
      AND principal_naics_code != 'UNKNOWN'

    UNION ALL

    SELECT
        'recent_3yr' AS scope_name,
        COUNT(DISTINCT principal_naics_code) AS distinct_naics_count,
        COUNT(DISTINCT sector_code) AS distinct_sector_count,
        SUM(net_obligated_amount) AS total_obligated,
        COUNT(DISTINCT contracting_dept_id) AS dept_count,
        SUM(distinct_vendor_count) AS vendor_interactions
    FROM naics_breakdown.mv_fpds_naics_agency_year
    WHERE fiscal_year::INTEGER >= (
        CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
             THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
             ELSE EXTRACT(year FROM CURRENT_DATE)::int
        END
    ) - 2
      AND principal_naics_code != 'UNKNOWN'
)
SELECT
    scope_name,
    distinct_naics_count,
    distinct_sector_count,
    total_obligated,
    dept_count,
    vendor_interactions,
    ROUND(vendor_interactions::DECIMAL / NULLIF(distinct_naics_count, 0), 2) AS avg_vendors_per_naics,
    ROUND(total_obligated::DECIMAL / NULLIF(distinct_naics_count, 0), 0) AS avg_obligation_per_naics
FROM scope_data
ORDER BY CASE scope_name
    WHEN 'all_years_core' THEN 1
    WHEN 'current_fy' THEN 2
    WHEN 'recent_3yr' THEN 3
END;

COMMENT ON VIEW naics_breakdown.report_deck_naics_kpi_summary IS
'Top-level NAICS KPIs across three time scopes: all years, current FY, recent 3 years. Shows industry diversity, vendor distribution, and spending concentration.';

CREATE SCHEMA IF NOT EXISTS analytics_api;

-- Contract pricing report views.
CREATE OR REPLACE VIEW analytics_api.pricing_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM contract_pricing.report_deck_pricing_trend_fy;

CREATE OR REPLACE VIEW analytics_api.pricing_agency_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM contract_pricing.report_deck_pricing_agency_profile_fy;

CREATE OR REPLACE VIEW analytics_api.pricing_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM contract_pricing.report_deck_pricing_kpi_summary;

CREATE OR REPLACE VIEW analytics_api.pricing_risk_scorecard
WITH (security_barrier = true) AS
SELECT * FROM contract_pricing.report_deck_pricing_risk_scorecard;

CREATE OR REPLACE VIEW analytics_api.pricing_dept_year_summary
WITH (security_barrier = true) AS
SELECT * FROM contract_pricing.mv_fpds_pricing_dept_year_summary_with_shares;

-- Vendor concentration report views.
CREATE OR REPLACE VIEW analytics_api.concentration_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_concentration_trend_fy;

CREATE OR REPLACE VIEW analytics_api.concentration_agency_profile
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_concentration_agency_profile;

CREATE OR REPLACE VIEW analytics_api.concentration_vendor_market_leaders
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_vendor_market_leaders;

CREATE OR REPLACE VIEW analytics_api.concentration_small_biz_health_fy
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_small_biz_health_fy;

CREATE OR REPLACE VIEW analytics_api.concentration_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_concentration_kpi_summary;

-- Competition dynamics report views.
CREATE OR REPLACE VIEW analytics_api.competition_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_competition_trend_fy;

CREATE OR REPLACE VIEW analytics_api.competition_agency_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_competition_agency_profile_fy;

CREATE OR REPLACE VIEW analytics_api.competition_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_competition_kpi_summary;

CREATE OR REPLACE VIEW analytics_api.competition_sole_source_hotspots
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_sole_source_hotspots;

-- NAICS report views.
CREATE OR REPLACE VIEW analytics_api.naics_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_trend_fy;

CREATE OR REPLACE VIEW analytics_api.naics_agency_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_agency_profile_fy;

CREATE OR REPLACE VIEW analytics_api.naics_growth_leaders
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_growth_leaders;

CREATE OR REPLACE VIEW analytics_api.naics_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_kpi_summary;

-- Geographic report views.
CREATE OR REPLACE VIEW analytics_api.geography_state_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_state_trend_fy;

CREATE OR REPLACE VIEW analytics_api.geography_regional_summary_fy
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_regional_summary_fy;

CREATE OR REPLACE VIEW analytics_api.geography_mismatch_leaders
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_mismatch_leaders;

CREATE OR REPLACE VIEW analytics_api.geography_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_kpi_summary;

-- Public dimension/code lookup views.
CREATE OR REPLACE VIEW analytics_api.dim_pricing_codes
WITH (security_barrier = true) AS
SELECT raw_code, raw_desc, pricing_family, risk_profile, is_fixed_price, is_cost_type,
       is_time_and_materials, is_order_dependent, sort_order, notes
FROM analytics_dims.fpds_contract_pricing_map;

CREATE OR REPLACE VIEW analytics_api.dim_competition_codes
WITH (security_barrier = true) AS
SELECT raw_code, raw_desc, competition_family, is_competed, is_full_competition,
       is_limited_competition, is_not_competed, sort_order, notes
FROM analytics_dims.fpds_extent_competed_map;

CREATE OR REPLACE VIEW analytics_api.dim_business_size_codes
WITH (security_barrier = true) AS
SELECT size_determination_code, size_determination_desc, size_category, is_small,
       is_other_than_small, sort_order, notes
FROM analytics_dims.fpds_business_size_map;

CREATE OR REPLACE VIEW analytics_api.dim_bundling_codes
WITH (security_barrier = true) AS
SELECT raw_code, raw_desc, bundling_severity, is_bundled, sort_order, notes
FROM analytics_dims.fpds_contract_bundling_map;

CREATE OR REPLACE VIEW analytics_api.dim_financing_codes
WITH (security_barrier = true) AS
SELECT raw_code, raw_desc, is_financed, sort_order, notes
FROM analytics_dims.fpds_contract_financing_map;

CREATE OR REPLACE VIEW analytics_api.dim_naics
WITH (security_barrier = true) AS
SELECT naics_code, naics_desc, sector_code, subsector_code, sector_label,
       subsector_label, sort_order, notes
FROM analytics_dims.fpds_naics_hierarchy_map;

CREATE OR REPLACE VIEW analytics_api.dim_states
WITH (security_barrier = true) AS
SELECT state_code, state_name, census_region, census_division, is_state, sort_order, notes
FROM analytics_dims.fpds_us_state_map;

COMMENT ON SCHEMA analytics_api IS 'Curated read-only facade for the public FPDS Analytics API. No raw FPDS tables are exposed.';
