-- ═══════════════════════════════════════════════════════════════════════════════
-- BL-018 Gap 6: Office × PSC × NAICS × FY
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Purpose: Enables office-level procurement category analysis at PSC × NAICS grain.
--          psc_agency_office_fy has top_naics_code only. psc_naics_agency_fy has no office.
--          Closes the BL-018 Gap 6 identified in S7-012b cross-cutting test.
--
-- Grain: contracting_office_id × product_or_service_code × principal_naics_code × fiscal_year
-- Base table: public.fpds_actions
-- Estimated rows: ~4-6M
-- ═══════════════════════════════════════════════════════════════════════════════

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

-- ── Materialized View ─────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW IF NOT EXISTS psc_analysis.mv_fpds_psc_naics_office_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    fa.product_or_service_code,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END AS fiscal_year,
    COALESCE(fa.set_aside, 'UNKNOWN') AS set_aside_code,
    COUNT(*) AS action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
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
    SUM(NULLIF(fa.base_and_all_options_value, '')::numeric) AS base_and_all_options_value_sum,
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    COUNT(DISTINCT fa.piid) AS distinct_piid_count,
    SUM(CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END) AS contract_scope_action_count,
    SUM(
        CASE WHEN atm.is_contract_scope
             THEN NULLIF(fa.obligated_amount, '')::numeric
             ELSE 0::numeric END
    ) AS contract_scope_obligated,
    SUM(CASE WHEN ecm.is_competed THEN 1 ELSE 0 END) AS competed_action_count,
    SUM(CASE WHEN ecm.is_competed = false THEN 1 ELSE 0 END) AS not_competed_action_count
FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.signed_date IS NOT NULL
  AND fa.signed_date <> ''
  AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
  AND fa.contracting_office_id IS NOT NULL
  AND fa.contracting_office_id <> ''
  AND fa.product_or_service_code IS NOT NULL
  AND fa.product_or_service_code <> ''
  AND fa.principal_naics_code IS NOT NULL
  AND fa.principal_naics_code <> ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    fa.product_or_service_code,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END,
    COALESCE(fa.set_aside, 'UNKNOWN')
HAVING
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END >= 2010;

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS mv_psc_naics_office_fy_uq
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (contracting_office_id, product_or_service_code, principal_naics_code, fiscal_year, set_aside_code);

CREATE INDEX IF NOT EXISTS mv_psc_naics_office_fy_office_fy
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (contracting_office_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_office_fy_psc_fy
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (product_or_service_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_office_fy_naics_fy
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_office_fy_agency_fy
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_office_fy_obligated
    ON psc_analysis.mv_fpds_psc_naics_office_fy
    (net_obligated_amount DESC);

-- ── Report Deck View (with label joins) ───────────────────────────────────────

CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_naics_office_fy AS
SELECT
    mv.*,
    nh.naics_desc,
    nh.sector_code,
    nh.subsector_code,
    nh.sector_label,
    nh.subsector_label,
    pm.psc_description AS psc_name,
    pm.psc_group,
    pm.psc_category_label AS psc_group_name,
    dm.department_name,
    dm.department_short_name,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name AS contracting_agency_short_name,
    om.contracting_office_name AS contracting_office_name,
    sa.label AS set_aside_name
FROM psc_analysis.mv_fpds_psc_naics_office_fy mv
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON mv.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_psc_map pm
    ON mv.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om
    ON mv.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_set_aside_code_map sa
    ON mv.set_aside_code = sa.raw_code;

-- ── Analytics API Facade ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.psc_naics_office_fy
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_naics_office_fy;

COMMENT ON VIEW analytics_api.psc_naics_office_fy IS
'Office-level procurement analysis at PSC × NAICS × fiscal year grain. Enables office-level procurement category analysis combining product/service codes with NAICS industry codes. Closes BL-018 Gap 6.';

GRANT SELECT ON analytics_api.psc_naics_office_fy TO fpds_analytics_api_readonly;
