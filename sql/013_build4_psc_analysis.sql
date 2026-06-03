-- Build 4: PSC Analysis
--
-- Schema: psc_analysis (new)
-- MV grain: contracting_agency_id × contracting_office_id × psc_code × fiscal_year
-- Estimated rows: 2M–5M
-- Build time: 45–90 min on 99M source rows
--
-- PSC is the parallel classification system to NAICS. Defense and services
-- contracting officers often think in PSC, not NAICS. This package makes
-- PSC a first-class analytical surface.
--
-- Prerequisites: P4 (fpds_psc_map)

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA
-- ═══════════════════════════════════════════════════════════════════════════

-- Disable statement timeout for MV builds (99M row scans)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE SCHEMA IF NOT EXISTS psc_analysis;
COMMENT ON SCHEMA psc_analysis IS
'Product Service Code analysis: PSC trends, agency/office PSC profiles, and PSC × NAICS crosswalk.';


-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW
-- ═══════════════════════════════════════════════════════════════════════════

CREATE MATERIALIZED VIEW psc_analysis.mv_fpds_psc_agency_office_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(fa.product_or_service_code, 'UNKNOWN') AS product_or_service_code,
    COALESCE(pm.psc_group, 'Unknown') AS psc_group,
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

    -- Top NAICS co-occurring with this PSC
    MODE() WITHIN GROUP (ORDER BY fa.principal_naics_code) AS top_naics_code

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_psc_map pm
    ON fa.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.contracting_office_id IS NOT NULL AND fa.contracting_office_id != ''
  AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(fa.product_or_service_code, 'UNKNOWN'),
    COALESCE(pm.psc_group, 'Unknown'),
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;


-- ═══════════════════════════════════════════════════════════════════════════
-- PSC × NAICS CROSSWALK MV
-- ═══════════════════════════════════════════════════════════════════════════

CREATE MATERIALIZED VIEW psc_analysis.mv_fpds_psc_naics_crosswalk AS
SELECT
    COALESCE(fa.product_or_service_code, 'UNKNOWN') AS product_or_service_code,
    COALESCE(fa.principal_naics_code, 'UNKNOWN') AS principal_naics_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,
    COUNT(*) AS co_occurrence_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS co_occurrence_obligated,
    COUNT(DISTINCT fa.contracting_agency_id) AS agency_count,
    COUNT(DISTINCT fa.uei) AS vendor_count
FROM public.fpds_actions fa
WHERE fa.product_or_service_code IS NOT NULL AND fa.product_or_service_code != ''
  AND fa.principal_naics_code IS NOT NULL AND fa.principal_naics_code != ''
  AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY
    COALESCE(fa.product_or_service_code, 'UNKNOWN'),
    COALESCE(fa.principal_naics_code, 'UNKNOWN'),
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;


-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE UNIQUE INDEX IF NOT EXISTS mv_psc_agency_office_fy_uq
    ON psc_analysis.mv_fpds_psc_agency_office_fy
    (contracting_dept_id, contracting_agency_id, contracting_office_id, product_or_service_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_agency_office_fy_psc_idx
    ON psc_analysis.mv_fpds_psc_agency_office_fy
    (product_or_service_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_agency_office_fy_group_idx
    ON psc_analysis.mv_fpds_psc_agency_office_fy
    (psc_group, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_agency_office_fy_dept_idx
    ON psc_analysis.mv_fpds_psc_agency_office_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_agency_office_fy_office_idx
    ON psc_analysis.mv_fpds_psc_agency_office_fy
    (contracting_office_id, fiscal_year);

CREATE UNIQUE INDEX IF NOT EXISTS mv_psc_naics_crosswalk_uq
    ON psc_analysis.mv_fpds_psc_naics_crosswalk
    (product_or_service_code, principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_psc_naics_crosswalk_naics_idx
    ON psc_analysis.mv_fpds_psc_naics_crosswalk
    (principal_naics_code, fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- PSC trend: government-wide by fiscal year
CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_trend_fy AS
SELECT
    mv.product_or_service_code,
    pm.psc_description,
    pm.psc_category_code,
    pm.psc_category_label,
    mv.psc_group,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    ROUND(SUM(mv.small_biz_obligated) / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,
    ROUND(SUM(mv.not_competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS not_competed_action_share,
    COUNT(DISTINCT mv.contracting_agency_id) AS distinct_agency_count
FROM psc_analysis.mv_fpds_psc_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_psc_map pm ON mv.product_or_service_code = pm.psc_code
GROUP BY mv.product_or_service_code, pm.psc_description, pm.psc_category_code,
         pm.psc_category_label, mv.psc_group, mv.fiscal_year;


-- PSC agency profile
CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_agency_profile_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.product_or_service_code,
    pm.psc_description,
    mv.psc_group,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    ROUND(SUM(mv.small_biz_obligated) / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,
    ROUND(SUM(mv.not_competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS not_competed_action_share
FROM psc_analysis.mv_fpds_psc_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_psc_map pm ON mv.product_or_service_code = pm.psc_code
GROUP BY mv.contracting_dept_id, dm.department_name, mv.contracting_agency_id,
         am.agency_name, am.agency_short_name, mv.product_or_service_code,
         pm.psc_description, mv.psc_group, mv.fiscal_year;


-- PSC office profile
CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_office_profile_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    mv.contracting_office_id,
    om.contracting_office_name,
    mv.product_or_service_code,
    pm.psc_description,
    mv.psc_group,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    mv.total_action_count,
    mv.net_obligated_amount,
    mv.distinct_vendor_count,
    mv.competed_action_count,
    mv.not_competed_action_count,
    mv.small_biz_obligated,
    mv.top_naics_code,
    nh.naics_desc AS top_naics_description,
    ROUND(mv.small_biz_obligated / NULLIF(mv.net_obligated_amount, 0), 4)
        AS small_biz_obligation_share,
    ROUND(mv.not_competed_action_count::numeric
        / NULLIF(mv.competed_action_count + mv.not_competed_action_count, 0), 4)
        AS not_competed_action_share
FROM psc_analysis.mv_fpds_psc_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON mv.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_psc_map pm ON mv.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON mv.top_naics_code = nh.naics_code;


-- PSC × NAICS crosswalk
CREATE OR REPLACE VIEW psc_analysis.report_deck_psc_naics_crosswalk AS
SELECT
    xw.product_or_service_code,
    pm.psc_description,
    pm.psc_group,
    xw.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    nh.sector_label,
    xw.fiscal_year,
    xw.co_occurrence_count,
    xw.co_occurrence_obligated,
    xw.agency_count,
    xw.vendor_count
FROM psc_analysis.mv_fpds_psc_naics_crosswalk xw
LEFT JOIN analytics_dims.fpds_psc_map pm ON xw.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON xw.principal_naics_code = nh.naics_code;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.psc_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_trend_fy;

COMMENT ON VIEW analytics_api.psc_trend_fy IS
'PSC government-wide trends by fiscal year. Shows obligation volume, vendor count, competition, and small business share per PSC code.';

CREATE OR REPLACE VIEW analytics_api.psc_agency_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_agency_profile_fy;

COMMENT ON VIEW analytics_api.psc_agency_profile_fy IS
'Per-agency PSC profile by fiscal year. Answers: what PSC codes does this agency buy?';

CREATE OR REPLACE VIEW analytics_api.psc_office_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_office_profile_fy;

COMMENT ON VIEW analytics_api.psc_office_profile_fy IS
'Per-office PSC profile. Office-level PSC spending with top co-occurring NAICS code.';

CREATE OR REPLACE VIEW analytics_api.psc_naics_crosswalk
WITH (security_barrier = true) AS
SELECT * FROM psc_analysis.report_deck_psc_naics_crosswalk;

COMMENT ON VIEW analytics_api.psc_naics_crosswalk IS
'PSC × NAICS co-occurrence crosswalk. Shows which NAICS codes are most commonly paired with each PSC code across the government.';
