-- 058_naics_group_agency_fy.sql
-- Sprint 7 (S7-008 / BL-003): Pre-aggregated NAICS group (4-digit) dataset.
--
-- Creates a report view + facade that roll up the existing 6-digit
-- naics_breakdown.report_deck_naics_agency_fy to 4-digit NAICS group grain.
-- No new MV needed — aggregates the existing office-level MV through the
-- existing report view pattern.
--
-- Grain: contracting_dept × contracting_agency × naics_group (4-digit) × fiscal_year
--
-- Note on distinct_vendor_count: SUM of 6-digit vendor counts is an upper
-- bound (vendors may appear in multiple 6-digit codes within a group).
-- Column is named approx_vendor_count to signal this.

BEGIN;

-- ============================================================================
-- Report view: naics_breakdown.report_deck_naics_group_agency_fy
-- ============================================================================

CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_group_agency_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name            AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name                AS contracting_agency_name,
    am.agency_short_name,
    left(mv.principal_naics_code, 4)  AS naics_group,
    ng.naics_desc                 AS naics_group_description,
    mv.sector_code,
    ng_s.sector_label,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = CASE
            WHEN extract(month FROM current_date)::integer >= 10
            THEN extract(year FROM current_date)::integer + 1
            ELSE extract(year FROM current_date)::integer
        END THEN true
        ELSE false
    END AS is_current_fiscal_year_ytd,
    -- Aggregated measures (sum across 6-digit codes within the group)
    sum(mv.action_count)                    AS total_action_count,
    sum(mv.contract_scope_action_count)     AS contract_scope_action_count,
    sum(mv.net_obligated_amount)            AS net_obligated_amount,
    sum(mv.contract_scope_obligated)        AS contract_scope_obligated,
    sum(mv.positive_obligated_amount)       AS positive_obligated_amount,
    sum(mv.base_and_all_options_value_sum)  AS base_and_all_options_value,
    sum(mv.distinct_vendor_count)           AS approx_vendor_count,
    count(DISTINCT mv.principal_naics_code) AS naics_code_count
FROM naics_breakdown.mv_fpds_naics_agency_year mv
LEFT JOIN analytics_dims.fpds_department_map dm
    ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map ng
    ON left(mv.principal_naics_code, 4) = ng.naics_code
LEFT JOIN LATERAL (
    SELECT sector_label
    FROM analytics_dims.fpds_naics_hierarchy_map
    WHERE naics_code = mv.sector_code
    LIMIT 1
) ng_s ON true
GROUP BY
    mv.contracting_dept_id,
    dm.department_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name,
    am.agency_short_name,
    left(mv.principal_naics_code, 4),
    ng.naics_desc,
    mv.sector_code,
    ng_s.sector_label,
    mv.fiscal_year;


-- ============================================================================
-- Facade view: analytics_api.market_naics_group_agency_fy
-- ============================================================================

CREATE OR REPLACE VIEW analytics_api.market_naics_group_agency_fy AS
SELECT
    contracting_dept_id,
    contracting_dept_name,
    department_short_name,
    contracting_agency_id,
    contracting_agency_name,
    agency_short_name,
    naics_group,
    naics_group_description,
    sector_code,
    sector_label,
    fiscal_year,
    is_current_fiscal_year_ytd,
    total_action_count,
    contract_scope_action_count,
    net_obligated_amount,
    contract_scope_obligated,
    positive_obligated_amount,
    base_and_all_options_value,
    approx_vendor_count,
    naics_code_count
FROM naics_breakdown.report_deck_naics_group_agency_fy;


-- ============================================================================
-- Grants
-- ============================================================================

GRANT SELECT ON analytics_api.market_naics_group_agency_fy
    TO fpds_analytics_api_readonly;

COMMIT;
