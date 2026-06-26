-- ═══════════════════════════════════════════════════════════════════════════════
-- BL-018 Gap 5: Agency × month × NAICS × FY
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Purpose: Enables queries like "monthly NAICS trends per agency."
--          Currently agency_month has no NAICS, naics_agency_year has no month.
--          Closes the BL-018 Gap 5 identified in S7-012b cross-cutting test.
--
-- Grain: contracting_agency_id × fiscal_month × principal_naics_code × fiscal_year
-- Base table: public.fpds_actions
-- Estimated rows: ~2-3M
-- ═══════════════════════════════════════════════════════════════════════════════

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

-- ── Materialized View ─────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW IF NOT EXISTS customer_intelligence.mv_fpds_agency_month_naics_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END AS fiscal_year,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp)::int >= 10
            THEN EXTRACT(month FROM fa.signed_date::timestamp)::int - 9
        ELSE EXTRACT(month FROM fa.signed_date::timestamp)::int + 3
    END AS fiscal_month,
    EXTRACT(month FROM fa.signed_date::timestamp)::int AS calendar_month,
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
    COUNT(DISTINCT fa.contracting_office_id) AS distinct_office_count,
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
  AND fa.contracting_agency_id IS NOT NULL
  AND fa.contracting_agency_id <> ''
  AND fa.principal_naics_code IS NOT NULL
  AND fa.principal_naics_code <> ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp)::int >= 10
            THEN EXTRACT(month FROM fa.signed_date::timestamp)::int - 9
        ELSE EXTRACT(month FROM fa.signed_date::timestamp)::int + 3
    END,
    EXTRACT(month FROM fa.signed_date::timestamp)::int,
    COALESCE(fa.set_aside, 'UNKNOWN')
HAVING
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
            THEN EXTRACT(year FROM fa.signed_date::timestamp)::int + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::int
    END >= 2010;

-- ── Indexes ───────────────────────────────────────────────────────────────────

CREATE UNIQUE INDEX IF NOT EXISTS mv_agency_month_naics_fy_uq
    ON customer_intelligence.mv_fpds_agency_month_naics_fy
    (contracting_agency_id, fiscal_year, fiscal_month, principal_naics_code, set_aside_code);

CREATE INDEX IF NOT EXISTS mv_agency_month_naics_fy_agency_fy
    ON customer_intelligence.mv_fpds_agency_month_naics_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_agency_month_naics_fy_dept_fy
    ON customer_intelligence.mv_fpds_agency_month_naics_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_agency_month_naics_fy_naics_fy
    ON customer_intelligence.mv_fpds_agency_month_naics_fy
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_agency_month_naics_fy_obligated
    ON customer_intelligence.mv_fpds_agency_month_naics_fy
    (net_obligated_amount DESC);

-- ── Report Deck View (with label joins) ───────────────────────────────────────

CREATE OR REPLACE VIEW customer_intelligence.report_deck_agency_month_naics_fy AS
SELECT
    mv.*,
    nh.naics_desc,
    nh.sector_code,
    nh.subsector_code,
    nh.sector_label,
    nh.subsector_label,
    dm.department_name,
    dm.department_short_name,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name AS contracting_agency_short_name,
    sa.label AS set_aside_name
FROM customer_intelligence.mv_fpds_agency_month_naics_fy mv
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON mv.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_set_aside_code_map sa
    ON mv.set_aside_code = sa.raw_code;

-- ── Analytics API Facade ──────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.customer_agency_month_naics_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_agency_month_naics_fy;

COMMENT ON VIEW analytics_api.customer_agency_month_naics_fy IS
'Agency-level monthly award patterns by NAICS and fiscal year. Enables monthly NAICS trend analysis per agency. Fiscal month: Oct=1, Nov=2, ..., Sep=12.';

GRANT SELECT ON analytics_api.customer_agency_month_naics_fy TO fpds_analytics_api_readonly;
