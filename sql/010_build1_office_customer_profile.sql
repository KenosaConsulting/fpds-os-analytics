-- Build 1: Office Customer Profile
--
-- Schema: customer_intelligence (new)
-- MV grain: contracting_office_id × fiscal_year
-- Estimated rows: 200K–500K
-- Build time: 30–60 min on 99M source rows
--
-- This is the highest-impact build in Phase 2. Every analyst workflow
-- starts with "which office actually buys this work?"
--
-- Prerequisites: P1 (fpds_department_map), P2 (fpds_agency_map),
--                P3 (fpds_contracting_office_map)

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA
-- ═══════════════════════════════════════════════════════════════════════════

-- Extend statement timeout for MV builds (99M row scan)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE SCHEMA IF NOT EXISTS customer_intelligence;
COMMENT ON SCHEMA customer_intelligence IS
'Office-level customer profiles, agency rollups, and funding flow analysis. The analyst-facing "who actually buys this?" layer.';


-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW: office profile by fiscal year
-- ═══════════════════════════════════════════════════════════════════════════

CREATE MATERIALIZED VIEW customer_intelligence.mv_office_profile_fy AS
SELECT
    fa.contracting_office_id,
    fa.contracting_agency_id,
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,

    -- Volume
    COUNT(*) AS total_action_count,
    SUM(CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END) AS contract_scope_action_count,
    SUM(CASE WHEN mrm.is_modification = false THEN 1 ELSE 0 END) AS base_award_action_count,
    SUM(CASE WHEN mrm.is_modification = true THEN 1 ELSE 0 END) AS modification_action_count,

    -- Obligations
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(CASE WHEN NULLIF(fa.obligated_amount, '')::numeric > 0
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS positive_obligated_amount,
    SUM(CASE WHEN NULLIF(fa.obligated_amount, '')::numeric < 0
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS negative_obligated_amount,
    SUM(NULLIF(fa.base_and_all_options_value, '')::numeric) AS base_and_all_options_value_sum,

    -- Diversity
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    COUNT(DISTINCT fa.principal_naics_code) AS distinct_naics_count,
    COUNT(DISTINCT fa.product_or_service_code) AS distinct_psc_count,

    -- Competition
    SUM(CASE WHEN ecm.is_competed THEN 1 ELSE 0 END) AS competed_action_count,
    SUM(CASE WHEN ecm.is_not_competed THEN 1 ELSE 0 END) AS not_competed_action_count,
    SUM(CASE WHEN ecm.is_competed THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS competed_obligated,
    SUM(CASE WHEN ecm.is_not_competed THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS not_competed_obligated,
    AVG(NULLIF(fa.offers_received, '')::numeric) AS avg_offers_received,

    -- Small business
    SUM(CASE WHEN fa.is_small_business = 'true' THEN 1 ELSE 0 END) AS small_biz_action_count,
    SUM(CASE WHEN fa.is_small_business = 'true'
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS small_biz_obligated,
    SUM(CASE WHEN sam.is_positive_set_aside THEN 1 ELSE 0 END) AS positive_setaside_count,

    -- Commercial
    SUM(CASE WHEN cim.is_commercial THEN 1 ELSE 0 END) AS commercial_action_count,
    SUM(CASE WHEN cim.is_commercial
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS commercial_obligated

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_modification_reason_map mrm
    ON COALESCE(fa.reason_for_modification, 'BASE') = mrm.raw_code
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
LEFT JOIN analytics_dims.fpds_set_aside_code_map sam
    ON COALESCE(fa.set_aside, 'UNKNOWN') = sam.raw_code
LEFT JOIN analytics_dims.fpds_commercial_item_map cim
    ON COALESCE(fa.commercial_item_acquisition_procedures, 'UNKNOWN') = cim.raw_code
WHERE fa.contracting_office_id IS NOT NULL
  AND fa.contracting_office_id != ''
  AND fa.signed_date IS NOT NULL
  AND fa.signed_date != ''
GROUP BY
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

CREATE UNIQUE INDEX IF NOT EXISTS mv_office_profile_fy_uq
    ON customer_intelligence.mv_office_profile_fy
    (contracting_office_id, contracting_agency_id, contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_office_profile_fy_agency_idx
    ON customer_intelligence.mv_office_profile_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_office_profile_fy_dept_idx
    ON customer_intelligence.mv_office_profile_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_office_profile_fy_fy_idx
    ON customer_intelligence.mv_office_profile_fy
    (fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Office-level profile with dim JOINs and computed shares
CREATE OR REPLACE VIEW customer_intelligence.report_deck_office_profile_fy AS
SELECT
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int
            END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,

    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.contracting_office_id,
    om.contracting_office_name,
    om.is_active_recent AS office_is_active_recent,
    om.name_confidence AS office_name_confidence,

    -- Volume
    mv.total_action_count,
    mv.contract_scope_action_count,
    mv.base_award_action_count,
    mv.modification_action_count,

    -- Obligations
    mv.net_obligated_amount,
    mv.positive_obligated_amount,
    mv.negative_obligated_amount,
    mv.base_and_all_options_value_sum,

    -- Diversity
    mv.distinct_vendor_count,
    mv.distinct_naics_count,
    mv.distinct_psc_count,

    -- Competition metrics
    mv.competed_action_count,
    mv.not_competed_action_count,
    mv.competed_obligated,
    mv.not_competed_obligated,
    mv.avg_offers_received,
    ROUND(mv.competed_action_count::numeric
        / NULLIF(mv.competed_action_count + mv.not_competed_action_count, 0), 4)
        AS competed_action_share,
    ROUND(mv.competed_obligated
        / NULLIF(mv.competed_obligated + mv.not_competed_obligated, 0), 4)
        AS competed_obligation_share,

    -- Small business metrics
    mv.small_biz_action_count,
    mv.small_biz_obligated,
    mv.positive_setaside_count,
    ROUND(mv.small_biz_action_count::numeric
        / NULLIF(mv.total_action_count, 0), 4)
        AS small_biz_action_share,
    ROUND(mv.small_biz_obligated
        / NULLIF(mv.net_obligated_amount, 0), 4)
        AS small_biz_obligation_share,

    -- Commercial metrics
    mv.commercial_action_count,
    mv.commercial_obligated,
    ROUND(mv.commercial_action_count::numeric
        / NULLIF(mv.total_action_count, 0), 4)
        AS commercial_action_share

FROM customer_intelligence.mv_office_profile_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om
    ON mv.contracting_office_id = om.contracting_office_id;


-- Agency-level rollup from office MV
CREATE OR REPLACE VIEW customer_intelligence.report_deck_agency_customer_profile_fy AS
SELECT
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int
            END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,

    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,

    -- Rolled-up volume
    COUNT(DISTINCT mv.contracting_office_id) AS distinct_office_count,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.contract_scope_action_count) AS contract_scope_action_count,
    SUM(mv.base_award_action_count) AS base_award_action_count,

    -- Obligations
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.positive_obligated_amount) AS positive_obligated_amount,
    SUM(mv.base_and_all_options_value_sum) AS base_and_all_options_value_sum,

    -- Competition
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.competed_obligated) AS competed_obligated,
    SUM(mv.not_competed_obligated) AS not_competed_obligated,
    ROUND(SUM(mv.competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS competed_action_share,
    ROUND(SUM(mv.competed_obligated)
        / NULLIF(SUM(mv.competed_obligated) + SUM(mv.not_competed_obligated), 0), 4)
        AS competed_obligation_share,

    -- Small business
    SUM(mv.small_biz_action_count) AS small_biz_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    ROUND(SUM(mv.small_biz_obligated)
        / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,

    -- Commercial
    SUM(mv.commercial_action_count) AS commercial_action_count,
    SUM(mv.commercial_obligated) AS commercial_obligated,
    ROUND(SUM(mv.commercial_action_count)::numeric
        / NULLIF(SUM(mv.total_action_count), 0), 4)
        AS commercial_action_share

FROM customer_intelligence.mv_office_profile_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
GROUP BY
    mv.fiscal_year, mv.contracting_dept_id, dm.department_name,
    dm.department_short_name, mv.contracting_agency_id, am.agency_name,
    am.agency_short_name;


-- KPI summary across three scopes
CREATE OR REPLACE VIEW customer_intelligence.report_deck_customer_kpi_summary AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
scope_data AS (
    SELECT
        'all_years' AS scope_name,
        COUNT(DISTINCT contracting_office_id) AS distinct_offices,
        COUNT(DISTINCT contracting_agency_id) AS distinct_agencies,
        SUM(total_action_count) AS total_actions,
        SUM(net_obligated_amount) AS total_obligated,
        SUM(distinct_vendor_count) AS total_vendor_interactions,
        ROUND(SUM(competed_action_count)::numeric
            / NULLIF(SUM(competed_action_count) + SUM(not_competed_action_count), 0), 4)
            AS competed_action_share,
        ROUND(SUM(small_biz_obligated) / NULLIF(SUM(net_obligated_amount), 0), 4)
            AS small_biz_obligation_share
    FROM customer_intelligence.mv_office_profile_fy

    UNION ALL

    SELECT
        'current_fy',
        COUNT(DISTINCT contracting_office_id),
        COUNT(DISTINCT contracting_agency_id),
        SUM(total_action_count),
        SUM(net_obligated_amount),
        SUM(distinct_vendor_count),
        ROUND(SUM(competed_action_count)::numeric
            / NULLIF(SUM(competed_action_count) + SUM(not_competed_action_count), 0), 4),
        ROUND(SUM(small_biz_obligated) / NULLIF(SUM(net_obligated_amount), 0), 4)
    FROM customer_intelligence.mv_office_profile_fy, current_fy
    WHERE fiscal_year = current_fy.fy

    UNION ALL

    SELECT
        'recent_3yr',
        COUNT(DISTINCT contracting_office_id),
        COUNT(DISTINCT contracting_agency_id),
        SUM(total_action_count),
        SUM(net_obligated_amount),
        SUM(distinct_vendor_count),
        ROUND(SUM(competed_action_count)::numeric
            / NULLIF(SUM(competed_action_count) + SUM(not_competed_action_count), 0), 4),
        ROUND(SUM(small_biz_obligated) / NULLIF(SUM(net_obligated_amount), 0), 4)
    FROM customer_intelligence.mv_office_profile_fy, current_fy
    WHERE fiscal_year >= current_fy.fy - 2
)
SELECT * FROM scope_data
ORDER BY CASE scope_name
    WHEN 'all_years' THEN 1
    WHEN 'current_fy' THEN 2
    WHEN 'recent_3yr' THEN 3
END;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.customer_office_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_office_profile_fy;

COMMENT ON VIEW analytics_api.customer_office_profile_fy IS
'Per-contracting-office customer profile by fiscal year. The highest-granularity customer view — shows buying patterns, competition posture, small-business usage, and vendor diversity at the office level.';

CREATE OR REPLACE VIEW analytics_api.customer_agency_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_agency_customer_profile_fy;

COMMENT ON VIEW analytics_api.customer_agency_profile_fy IS
'Per-agency customer profile by fiscal year. Rolled up from office-level data. Includes distinct_office_count showing how many buying offices an agency operates.';

CREATE OR REPLACE VIEW analytics_api.customer_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_customer_kpi_summary;

COMMENT ON VIEW analytics_api.customer_kpi_summary IS
'Customer intelligence KPIs across three scopes: all years, current FY, recent 3 years. Shows active offices, agencies, competition rates, and small business share.';
