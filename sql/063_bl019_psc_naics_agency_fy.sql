-- ═══════════════════════════════════════════════════════════════════════════════
-- BL-019.2: Agency × PSC × NAICS cross-cut dataset
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Purpose: Enables queries like "what PSCs is agency X buying in NAICS Y" and
--          "which NAICS codes map to PSC Z across the government." Closes the
--          BL-019.2 gap identified in S7-012b cross-cutting test Q7.
--
-- Grain: contracting_agency_id × product_or_service_code × principal_naics_code × fiscal_year
-- Base table: public.fpds_actions
-- Estimated rows: ~5-8M (~100 agencies × ~500 PSCs × ~300 NAICS × ~20 FYs, sparse)
--
-- Note: mv_fpds_psc_naics_crosswalk already exists for PSC×NAICS co-occurrence
--       (govwide, no agency/FY grain). This new MV adds agency + FY dimensions.
-- ═══════════════════════════════════════════════════════════════════════════════

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

-- ── Materialized View ─────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW IF NOT EXISTS psc_analysis.mv_fpds_psc_naics_agency_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.product_or_service_code,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END AS fiscal_year,
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
    COUNT(DISTINCT fa.contracting_office_id) AS distinct_office_count
FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.signed_date IS NOT NULL
  AND fa.signed_date <> ''
  AND fa.product_or_service_code IS NOT NULL
  AND fa.product_or_service_code <> ''
  AND fa.principal_naics_code IS NOT NULL
  AND fa.principal_naics_code <> ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.product_or_service_code,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END;

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_uq
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (contracting_agency_id, product_or_service_code, principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_psc_fy
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (product_or_service_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_naics_fy
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_dept_fy
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_agency_fy
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_agency_fy_obligated
    ON psc_analysis.mv_fpds_psc_naics_agency_fy
    (net_obligated_amount DESC);

-- ── Report Deck View (with label joins) ───────────────────────────────────────

CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_naics_agency_fy AS
SELECT
    mv.*,
    pm.psc_description,
    pm.psc_category_code,
    pm.psc_category_label,
    pm.psc_group,
    pm.is_service,
    pm.is_product,
    pm.is_r_and_d,
    pm.is_construction,
    nh.naics_desc,
    nh.sector_code,
    nh.subsector_code,
    nh.sector_label,
    nh.subsector_label,
    dm.department_name,
    dm.department_short_name,
    am.agency_name,
    am.agency_short_name
FROM psc_analysis.mv_fpds_psc_naics_agency_fy mv
LEFT JOIN analytics_dims.fpds_psc_map pm
    ON mv.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON mv.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id;

-- ── Analytics API Facade ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.psc_naics_agency_fy
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_naics_agency_fy;

COMMENT ON VIEW analytics_api.psc_naics_agency_fy IS
'Agency spending by PSC × NAICS × fiscal year. Shows what product/service codes agencies are buying under each NAICS code. Enables cross-dimensional analysis of procurement categories. Includes competition, small business, and vendor diversity metrics.';

GRANT SELECT ON analytics_api.psc_naics_agency_fy TO fpds_analytics_api_readonly;
