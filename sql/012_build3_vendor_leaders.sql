-- Build 3: Vendor Leaders by Agency and Office
--
-- Schema: vendor_concentration (existing)
-- New MV: mv_fpds_vendor_office_year (vendor × office × FY)
-- Report views built on EXISTING MVs + new office MV
-- Estimated new MV rows: 5M–15M
-- Build time: 60–120 min on 99M source rows
--
-- The existing mv_fpds_vendor_agency_year and mv_fpds_vendor_naics_agency_year
-- already contain vendor × agency data. This build adds:
--   1. Office-level vendor MV (new)
--   2. Report views that rank vendors within agencies (from existing MVs)
--   3. Report views that rank vendors within offices (from new MV)
--   4. Agency × NAICS vendor leaders (from existing MV)
--
-- Prerequisites: P1, P2, P3 (org dims)

-- ═══════════════════════════════════════════════════════════════════════════
-- NEW MATERIALIZED VIEW: vendor × office × fiscal year
-- ═══════════════════════════════════════════════════════════════════════════

-- Disable statement timeout for MV builds (99M row scans)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE MATERIALIZED VIEW vendor_concentration.mv_fpds_vendor_office_year AS
SELECT
    fa.uei,
    fa.contracting_office_id,
    fa.contracting_agency_id,
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,

    -- Vendor identity (most recent name wins)
    COALESCE(
        MIN(NULLIF(fa.vendor_name, '')),
        MIN(NULLIF(fa.vendor_legal_organization_name, '')),
        MIN(NULLIF(fa.contractor_name, ''))
    ) AS vendor_name,

    -- Socioeconomic flags
    BOOL_OR(fa.is_small_business = 'true') AS is_small_business,
    BOOL_OR(fa.is_veteran_owned = 'true') AS is_veteran_owned,
    BOOL_OR(fa.is_service_related_disabled_veteran_owned_business = 'true') AS is_sdvosb,
    BOOL_OR(fa.is_women_owned = 'true') AS is_women_owned,
    BOOL_OR(fa.is_minority_owned = 'true') AS is_minority_owned,
    BOOL_OR(fa.is_sba_certified8_a_program_participant = 'true') AS is_8a,
    BOOL_OR(fa.is_sba_certified_hub_zone = 'true') AS is_hubzone,

    -- Volume
    COUNT(*) AS action_count,
    SUM(CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END) AS contract_scope_action_count,

    -- Obligations
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(CASE WHEN atm.is_contract_scope
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS contract_scope_obligated,
    SUM(CASE WHEN NULLIF(fa.obligated_amount, '')::numeric > 0
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS positive_obligated_amount,

    -- Top NAICS at this vendor-office
    MODE() WITHIN GROUP (ORDER BY fa.principal_naics_code) AS top_naics_code,
    MODE() WITHIN GROUP (ORDER BY fa.product_or_service_code) AS top_psc_code

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
WHERE fa.uei IS NOT NULL AND fa.uei != ''
  AND fa.contracting_office_id IS NOT NULL AND fa.contracting_office_id != ''
  AND fa.contracting_agency_id IS NOT NULL AND fa.contracting_agency_id != ''
  AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY
    fa.uei,
    fa.contracting_office_id,
    fa.contracting_agency_id,
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;

-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE UNIQUE INDEX IF NOT EXISTS mv_vendor_office_year_uq
    ON vendor_concentration.mv_fpds_vendor_office_year
    (uei, contracting_office_id, contracting_agency_id, contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vendor_office_year_office_idx
    ON vendor_concentration.mv_fpds_vendor_office_year
    (contracting_office_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vendor_office_year_agency_idx
    ON vendor_concentration.mv_fpds_vendor_office_year
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vendor_office_year_dept_idx
    ON vendor_concentration.mv_fpds_vendor_office_year
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vendor_office_year_uei_idx
    ON vendor_concentration.mv_fpds_vendor_office_year
    (uei);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Agency vendor leaders: top vendors per agency (from EXISTING mv_fpds_vendor_agency_year)
CREATE OR REPLACE VIEW vendor_concentration.report_deck_agency_vendor_leaders AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
vendor_totals AS (
    SELECT
        mv.contracting_agency_id,
        mv.contracting_dept_id,
        mv.uei,
        mv.vendor_name,
        mv.is_small_business,
        mv.is_veteran_owned,
        mv.is_women_owned,
        mv.is_minority_owned,
        SUM(mv.net_obligated_amount) AS total_obligated,
        SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                 THEN mv.net_obligated_amount ELSE 0 END) AS recent_3yr_obligated,
        SUM(mv.action_count) AS total_action_count,
        MIN(mv.fiscal_year) AS first_active_fy,
        MAX(mv.fiscal_year) AS last_active_fy,
        COUNT(DISTINCT mv.fiscal_year) AS active_fy_count
    FROM vendor_concentration.mv_fpds_vendor_agency_year mv
    CROSS JOIN current_fy cfy
    WHERE mv.net_obligated_amount > 0
    GROUP BY mv.contracting_agency_id, mv.contracting_dept_id,
             mv.uei, mv.vendor_name,
             mv.is_small_business, mv.is_veteran_owned,
             mv.is_women_owned, mv.is_minority_owned
    HAVING SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                    THEN mv.net_obligated_amount ELSE 0 END) > 0
)
SELECT
    vt.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    vt.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    vt.uei,
    vt.vendor_name,
    vt.is_small_business,
    vt.is_veteran_owned,
    vt.is_women_owned,
    vt.is_minority_owned,
    vt.total_obligated,
    vt.recent_3yr_obligated,
    vt.total_action_count,
    vt.first_active_fy,
    vt.last_active_fy,
    vt.active_fy_count,
    (vt.last_active_fy - vt.first_active_fy + 1) AS tenure_years,
    ROW_NUMBER() OVER (
        PARTITION BY vt.contracting_agency_id
        ORDER BY vt.recent_3yr_obligated DESC
    ) AS vendor_rank
FROM vendor_totals vt
LEFT JOIN analytics_dims.fpds_department_map dm ON vt.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON vt.contracting_agency_id = am.agency_id;


-- Office vendor leaders: top vendors per office (from NEW mv_fpds_vendor_office_year)
CREATE OR REPLACE VIEW vendor_concentration.report_deck_office_vendor_leaders AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
vendor_totals AS (
    SELECT
        mv.contracting_office_id,
        mv.contracting_agency_id,
        mv.contracting_dept_id,
        mv.uei,
        -- Most recent name across years
        (ARRAY_AGG(mv.vendor_name ORDER BY mv.fiscal_year DESC))[1] AS vendor_name,
        BOOL_OR(mv.is_small_business) AS is_small_business,
        BOOL_OR(mv.is_veteran_owned) AS is_veteran_owned,
        BOOL_OR(mv.is_women_owned) AS is_women_owned,
        BOOL_OR(mv.is_minority_owned) AS is_minority_owned,
        BOOL_OR(mv.is_8a) AS is_8a,
        BOOL_OR(mv.is_hubzone) AS is_hubzone,
        BOOL_OR(mv.is_sdvosb) AS is_sdvosb,
        SUM(mv.net_obligated_amount) AS total_obligated,
        SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                 THEN mv.net_obligated_amount ELSE 0 END) AS recent_3yr_obligated,
        SUM(mv.action_count) AS total_action_count,
        MIN(mv.fiscal_year) AS first_active_fy,
        MAX(mv.fiscal_year) AS last_active_fy,
        COUNT(DISTINCT mv.fiscal_year) AS active_fy_count,
        -- Most common NAICS/PSC
        MODE() WITHIN GROUP (ORDER BY mv.top_naics_code) AS primary_naics_code,
        MODE() WITHIN GROUP (ORDER BY mv.top_psc_code) AS primary_psc_code
    FROM vendor_concentration.mv_fpds_vendor_office_year mv
    CROSS JOIN current_fy cfy
    WHERE mv.net_obligated_amount > 0
    GROUP BY mv.contracting_office_id, mv.contracting_agency_id,
             mv.contracting_dept_id, mv.uei
    HAVING SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                    THEN mv.net_obligated_amount ELSE 0 END) > 0
)
SELECT
    vt.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    vt.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    vt.contracting_office_id,
    om.contracting_office_name,
    vt.uei,
    vt.vendor_name,
    vt.is_small_business,
    vt.is_veteran_owned,
    vt.is_women_owned,
    vt.is_minority_owned,
    vt.is_8a,
    vt.is_hubzone,
    vt.is_sdvosb,
    vt.total_obligated,
    vt.recent_3yr_obligated,
    vt.total_action_count,
    vt.first_active_fy,
    vt.last_active_fy,
    vt.active_fy_count,
    (vt.last_active_fy - vt.first_active_fy + 1) AS tenure_years,
    vt.primary_naics_code,
    nh.naics_desc AS primary_naics_description,
    vt.primary_psc_code,
    ROW_NUMBER() OVER (
        PARTITION BY vt.contracting_office_id
        ORDER BY vt.recent_3yr_obligated DESC
    ) AS vendor_rank
FROM vendor_totals vt
LEFT JOIN analytics_dims.fpds_department_map dm ON vt.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON vt.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON vt.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON vt.primary_naics_code = nh.naics_code;


-- Agency × NAICS vendor leaders (from EXISTING mv_fpds_vendor_naics_agency_year)
CREATE OR REPLACE VIEW vendor_concentration.report_deck_agency_naics_vendor_leaders AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
vendor_totals AS (
    SELECT
        mv.contracting_agency_id,
        mv.principal_naics_code,
        mv.uei,
        SUM(mv.contract_scope_obligated_amount) AS total_obligated,
        SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                 THEN mv.contract_scope_obligated_amount ELSE 0 END) AS recent_3yr_obligated,
        SUM(mv.action_count) AS total_action_count,
        BOOL_OR(mv.is_small_business) AS is_small_business,
        MIN(mv.fiscal_year) AS first_active_fy,
        MAX(mv.fiscal_year) AS last_active_fy,
        COUNT(DISTINCT mv.fiscal_year) AS active_fy_count
    FROM vendor_concentration.mv_fpds_vendor_naics_agency_year mv
    CROSS JOIN current_fy cfy
    WHERE mv.contract_scope_obligated_amount > 0
    GROUP BY mv.contracting_agency_id, mv.principal_naics_code, mv.uei
    HAVING SUM(CASE WHEN mv.fiscal_year >= cfy.fy - 2
                    THEN mv.contract_scope_obligated_amount ELSE 0 END) > 0
)
SELECT
    vt.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    am.parent_department_id AS contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    vt.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    nh.sector_label,
    vt.uei,
    vt.is_small_business,
    vt.total_obligated,
    vt.recent_3yr_obligated,
    vt.total_action_count,
    vt.first_active_fy,
    vt.last_active_fy,
    vt.active_fy_count,
    ROW_NUMBER() OVER (
        PARTITION BY vt.contracting_agency_id, vt.principal_naics_code
        ORDER BY vt.recent_3yr_obligated DESC
    ) AS vendor_rank
FROM vendor_totals vt
LEFT JOIN analytics_dims.fpds_agency_map am ON vt.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_department_map dm ON am.parent_department_id = dm.department_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON vt.principal_naics_code = nh.naics_code;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.incumbent_agency_vendor_leaders
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_agency_vendor_leaders;

COMMENT ON VIEW analytics_api.incumbent_agency_vendor_leaders IS
'Top vendors per agency ranked by recent 3-year obligation. Shows incumbents, tenure, and socioeconomic status at the agency level.';

CREATE OR REPLACE VIEW analytics_api.incumbent_office_vendor_leaders
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_office_vendor_leaders;

COMMENT ON VIEW analytics_api.incumbent_office_vendor_leaders IS
'Top vendors per contracting office ranked by recent 3-year obligation. Office-level incumbency with primary NAICS, PSC, socioeconomic flags, and tenure.';

CREATE OR REPLACE VIEW analytics_api.incumbent_agency_naics_vendor_leaders
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_agency_naics_vendor_leaders;

COMMENT ON VIEW analytics_api.incumbent_agency_naics_vendor_leaders IS
'Top vendors per agency × NAICS market ranked by recent 3-year obligation. Answers "who wins Army 541512?"';
