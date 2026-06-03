-- Build 2: NAICS × Agency × Office Cross-Tab
--
-- Schema: naics_breakdown (existing)
-- MV grain: contracting_agency_id × contracting_office_id × principal_naics_code × fiscal_year
-- Estimated rows: 2M–5M
-- Build time: 45–90 min on 99M source rows
--
-- This is the core market-sizing cross-tab. Every BD question starts with
-- "how much does this customer spend on my NAICS?"
--
-- Prerequisites: P1, P2, P3 (org dims), fpds_naics_hierarchy_map (exists)

-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW
-- ═══════════════════════════════════════════════════════════════════════════

-- Disable statement timeout for MV builds (99M row scans)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE MATERIALIZED VIEW naics_breakdown.mv_fpds_naics_agency_office_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(fa.principal_naics_code, 'UNKNOWN') AS principal_naics_code,
    LEFT(COALESCE(fa.principal_naics_code, 'XX'), 2) AS sector_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,

    -- Volume
    COUNT(*) AS total_action_count,
    SUM(CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END) AS contract_scope_action_count,

    -- Obligations
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(CASE WHEN atm.is_contract_scope
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS contract_scope_obligated,

    -- Market structure
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    SUM(CASE WHEN ecm.is_competed THEN 1 ELSE 0 END) AS competed_action_count,
    SUM(CASE WHEN ecm.is_not_competed THEN 1 ELSE 0 END) AS not_competed_action_count,
    SUM(CASE WHEN fa.is_small_business = 'true'
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS small_biz_obligated,
    AVG(NULLIF(fa.offers_received, '')::numeric) AS avg_offers_received

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.contracting_office_id IS NOT NULL
  AND fa.contracting_office_id != ''
  AND fa.signed_date IS NOT NULL
  AND fa.signed_date != ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(fa.principal_naics_code, 'UNKNOWN'),
    LEFT(COALESCE(fa.principal_naics_code, 'XX'), 2),
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;

-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE UNIQUE INDEX IF NOT EXISTS mv_naics_agency_office_fy_uq
    ON naics_breakdown.mv_fpds_naics_agency_office_fy
    (contracting_dept_id, contracting_agency_id, contracting_office_id, principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_naics_agency_office_fy_naics_idx
    ON naics_breakdown.mv_fpds_naics_agency_office_fy
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_naics_agency_office_fy_dept_idx
    ON naics_breakdown.mv_fpds_naics_agency_office_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_naics_agency_office_fy_sector_idx
    ON naics_breakdown.mv_fpds_naics_agency_office_fy
    (sector_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_naics_agency_office_fy_office_idx
    ON naics_breakdown.mv_fpds_naics_agency_office_fy
    (contracting_office_id, fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Agency × NAICS (rolled up from office grain)
CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_agency_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    mv.sector_code,
    nh.sector_label,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int
            END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,

    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.contract_scope_action_count) AS contract_scope_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.contract_scope_obligated) AS contract_scope_obligated,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,

    -- Shares
    ROUND(SUM(mv.small_biz_obligated)
        / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,
    ROUND(SUM(mv.not_competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS not_competed_action_share

FROM naics_breakdown.mv_fpds_naics_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON mv.principal_naics_code = nh.naics_code
GROUP BY
    mv.contracting_dept_id, dm.department_name, dm.department_short_name,
    mv.contracting_agency_id, am.agency_name, am.agency_short_name,
    mv.principal_naics_code, nh.naics_desc, mv.sector_code, nh.sector_label,
    mv.fiscal_year;


-- Office × NAICS (direct from MV with dim JOINs)
CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_office_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    mv.contracting_office_id,
    om.contracting_office_name,
    mv.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    mv.sector_code,
    nh.sector_label,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int
            END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,

    mv.total_action_count,
    mv.contract_scope_action_count,
    mv.net_obligated_amount,
    mv.contract_scope_obligated,
    mv.distinct_vendor_count,
    mv.competed_action_count,
    mv.not_competed_action_count,
    mv.small_biz_obligated,
    mv.avg_offers_received,

    ROUND(mv.small_biz_obligated
        / NULLIF(mv.net_obligated_amount, 0), 4)
        AS small_biz_obligation_share,
    ROUND(mv.not_competed_action_count::numeric
        / NULLIF(mv.competed_action_count + mv.not_competed_action_count, 0), 4)
        AS not_competed_action_share

FROM naics_breakdown.mv_fpds_naics_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON mv.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON mv.principal_naics_code = nh.naics_code;


-- NAICS customer leaders: for a given NAICS, rank agencies by 3yr obligation
CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_customer_leaders AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
agency_totals AS (
    SELECT
        mv.principal_naics_code,
        mv.contracting_dept_id,
        mv.contracting_agency_id,
        SUM(mv.net_obligated_amount) AS recent_3yr_obligated,
        SUM(mv.total_action_count) AS recent_3yr_actions,
        SUM(mv.distinct_vendor_count) AS recent_3yr_vendors,
        SUM(mv.small_biz_obligated) AS recent_3yr_small_biz_obligated,
        SUM(mv.competed_action_count) AS recent_3yr_competed,
        SUM(mv.not_competed_action_count) AS recent_3yr_not_competed
    FROM naics_breakdown.mv_fpds_naics_agency_office_fy mv, current_fy
    WHERE mv.fiscal_year >= current_fy.fy - 2
      AND mv.principal_naics_code != 'UNKNOWN'
    GROUP BY mv.principal_naics_code, mv.contracting_dept_id, mv.contracting_agency_id
    HAVING SUM(mv.net_obligated_amount) > 0
)
SELECT
    at.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    nh.sector_label,
    at.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    at.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    at.recent_3yr_obligated,
    at.recent_3yr_actions,
    at.recent_3yr_vendors,
    ROUND(at.recent_3yr_small_biz_obligated
        / NULLIF(at.recent_3yr_obligated, 0), 4)
        AS small_biz_obligation_share,
    ROUND(at.recent_3yr_not_competed::numeric
        / NULLIF(at.recent_3yr_competed + at.recent_3yr_not_competed, 0), 4)
        AS not_competed_action_share,
    ROW_NUMBER() OVER (
        PARTITION BY at.principal_naics_code
        ORDER BY at.recent_3yr_obligated DESC
    ) AS customer_rank
FROM agency_totals at
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON at.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_department_map dm ON at.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON at.contracting_agency_id = am.agency_id;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.market_agency_naics_fy
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_agency_fy;

COMMENT ON VIEW analytics_api.market_agency_naics_fy IS
'Agency × NAICS market sizing by fiscal year. The core cross-tab for "how much does this customer spend on my NAICS?" Rolled up from office-level data.';

CREATE OR REPLACE VIEW analytics_api.market_office_naics_fy
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_office_fy;

COMMENT ON VIEW analytics_api.market_office_naics_fy IS
'Office × NAICS market sizing by fiscal year. Office-level granularity for "which office at this agency buys my NAICS?"';

CREATE OR REPLACE VIEW analytics_api.market_naics_customer_leaders
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_customer_leaders;

COMMENT ON VIEW analytics_api.market_naics_customer_leaders IS
'For a given NAICS code, ranks agencies by recent 3-year obligation. Answers "who are the top 10 customers for NAICS 541512?"';
