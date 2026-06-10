-- Template migration: append human-readable labels to v1 analytics API views.
-- Existing view columns are preserved in their current order; new label columns
-- are appended at the end to satisfy CREATE OR REPLACE VIEW constraints.

CREATE OR REPLACE VIEW analytics_api.pricing_agency_profile_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM contract_pricing.report_deck_pricing_agency_profile_fy r
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.pricing_risk_scorecard
WITH (security_barrier = true) AS
SELECT
    r.*,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM contract_pricing.report_deck_pricing_risk_scorecard r
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.pricing_dept_year_summary
WITH (security_barrier = true) AS
SELECT
    r.*,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM contract_pricing.mv_fpds_pricing_dept_year_summary_with_shares r
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.competition_agency_profile_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM competition_dynamics.report_deck_competition_agency_profile_fy r
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.competition_sole_source_hotspots
WITH (security_barrier = true) AS
SELECT
    r.*,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM competition_dynamics.report_deck_sole_source_hotspots r
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.concentration_agency_profile
WITH (security_barrier = true) AS
SELECT
    r.*,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name
FROM vendor_concentration.report_deck_concentration_agency_profile r
LEFT JOIN analytics_dims.fpds_agency_map am
    ON r.contracting_agency_id = am.agency_id;

CREATE OR REPLACE VIEW analytics_api.naics_agency_profile_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    n.naics_desc AS top_naics_description,
    n.sector_label AS top_naics_sector_label,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name
FROM naics_breakdown.report_deck_naics_agency_profile_fy r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n
    ON r.top_naics_code_by_obligation = n.naics_code
LEFT JOIN analytics_dims.fpds_department_map dm
    ON r.contracting_dept_id = dm.department_id;

CREATE OR REPLACE VIEW analytics_api.naics_growth_leaders
WITH (security_barrier = true) AS
SELECT
    r.*,
    n.sector_label
FROM naics_breakdown.report_deck_naics_growth_leaders r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n
    ON r.principal_naics_code = n.naics_code;
