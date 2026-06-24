-- ═══════════════════════════════════════════════════════════════════════════════
-- BL-019.1: State × NAICS × FY cross-cut dataset
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Purpose: Enables queries like "where is money flowing for NAICS 541512 by state"
--          and "which states have the most vendor concentration in this NAICS."
--          Closes the BL-019.1 gap identified in S7-012b cross-cutting test Q14.
--
-- Grain: pop_state_code × principal_naics_code × fiscal_year
-- Base table: public.fpds_actions
-- Estimated rows: ~3-5M (60 states/territories × ~1000 active NAICS × ~20 FYs)
--
-- Build pattern: matches mv_fpds_geo_pop_state_agency_year and
--                mv_fpds_naics_agency_year conventions
-- ═══════════════════════════════════════════════════════════════════════════════

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

-- ── Materialized View ─────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW IF NOT EXISTS geographic_analysis.mv_fpds_geo_state_naics_fy AS
SELECT
    COALESCE(fa.pop_state_code, 'XX') AS pop_state_code,
    MIN(fa.pop_state_name) AS pop_state_name,
    COALESCE(fa.pop_country_code, 'USA') AS pop_country_code,
    fa.contracting_dept_id,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END AS fiscal_year,
    COUNT(*) AS action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(NULLIF(fa.base_and_all_options_value, '')::numeric) AS base_and_all_options_value_sum,
    SUM(
        CASE WHEN NULLIF(fa.obligated_amount, '')::numeric > 0
             THEN NULLIF(fa.obligated_amount, '')::numeric
             ELSE 0::numeric END
    ) AS positive_obligated_amount,
    SUM(
        CASE WHEN NULLIF(fa.obligated_amount, '')::numeric < 0
             THEN NULLIF(fa.obligated_amount, '')::numeric
             ELSE 0::numeric END
    ) AS negative_obligated_amount,
    SUM(
        CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END
    ) AS contract_scope_action_count,
    SUM(
        CASE WHEN atm.is_contract_scope
             THEN NULLIF(fa.obligated_amount, '')::numeric
             ELSE 0::numeric END
    ) AS contract_scope_obligated,
    SUM(
        CASE WHEN fa.is_small_business = 'true'
             THEN NULLIF(fa.obligated_amount, '')::numeric
             ELSE 0::numeric END
    ) AS small_biz_obligated,
    SUM(
        CASE WHEN ecm.is_competed THEN 1 ELSE 0 END
    ) AS competed_action_count,
    SUM(
        CASE WHEN ecm.is_competed = false THEN 1 ELSE 0 END
    ) AS not_competed_action_count,
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    COUNT(DISTINCT fa.contracting_agency_id) AS distinct_agency_count,
    COUNT(DISTINCT fa.contracting_office_id) AS distinct_office_count
FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.signed_date IS NOT NULL
  AND fa.signed_date <> ''
  AND fa.principal_naics_code IS NOT NULL
  AND fa.principal_naics_code <> ''
  AND (fa.pop_country_code IS NULL OR fa.pop_country_code = 'USA' OR fa.pop_country_code = '')
GROUP BY
    COALESCE(fa.pop_state_code, 'XX'),
    COALESCE(fa.pop_country_code, 'USA'),
    fa.contracting_dept_id,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END;

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS mv_geo_state_naics_fy_uq
    ON geographic_analysis.mv_fpds_geo_state_naics_fy
    (pop_state_code, contracting_dept_id, principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_state_naics_fy_state_fy
    ON geographic_analysis.mv_fpds_geo_state_naics_fy
    (pop_state_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_state_naics_fy_naics_fy
    ON geographic_analysis.mv_fpds_geo_state_naics_fy
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_state_naics_fy_dept_fy
    ON geographic_analysis.mv_fpds_geo_state_naics_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_state_naics_fy_obligated
    ON geographic_analysis.mv_fpds_geo_state_naics_fy
    (net_obligated_amount DESC);

-- ── Report Deck View (with label joins) ───────────────────────────────────────

CREATE OR REPLACE VIEW geographic_analysis.report_deck_geo_state_naics_fy AS
SELECT
    mv.*,
    nh.naics_desc,
    nh.sector_code,
    nh.subsector_code,
    nh.sector_label,
    nh.subsector_label,
    dm.department_name,
    dm.department_short_name,
    sm.state_name AS pop_state_name_clean,
    sm.census_region AS pop_census_region,
    sm.census_division AS pop_census_division,
    sm.is_state AS is_us_state
FROM geographic_analysis.mv_fpds_geo_state_naics_fy mv
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON mv.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_us_state_map sm
    ON mv.pop_state_code = sm.state_code;

-- ── Analytics API Facade ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.geography_state_naics_fy
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_state_naics_fy;

COMMENT ON VIEW analytics_api.geography_state_naics_fy IS
'Geographic spending by state × NAICS × fiscal year. Shows where federal money flows by industry at the state level. Includes obligation amounts, vendor counts, competition metrics, and small business share. Enables state-level market analysis for specific NAICS codes.';

GRANT SELECT ON analytics_api.geography_state_naics_fy TO fpds_analytics_api_readonly;
