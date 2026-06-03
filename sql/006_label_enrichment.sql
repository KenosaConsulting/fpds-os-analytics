-- Label enrichment: wire existing dimension tables into facade views.
--
-- Updates facade views to JOIN dim tables so API responses include
-- human-readable labels alongside raw codes. No MV rebuilds needed.
--
-- Affected packages: naics_breakdown, geographic_analysis.
-- contract_pricing and competition_dynamics already include family labels
-- from their MV definitions.

-- ─── Department name dimension ──────────────────────────────────────────────
--
-- No fpds_department_map exists yet. Use a lightweight CTE derived from
-- the set_aside_breakdown MVs which already carry dept names. This avoids
-- creating a new dim table while still enriching views.
--
-- When fpds_department_map is created later, replace the CTE with a JOIN.

-- ─── NAICS views: add NAICS description, sector label, subsector label ──────

CREATE OR REPLACE VIEW analytics_api.naics_trend_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    n.naics_desc AS principal_naics_description,
    n.sector_code,
    n.sector_label,
    n.subsector_code,
    n.subsector_label
FROM naics_breakdown.report_deck_naics_trend_fy r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n
    ON r.principal_naics_code = n.naics_code;

CREATE OR REPLACE VIEW analytics_api.naics_agency_profile_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    n.naics_desc AS top_naics_description,
    n.sector_label AS top_naics_sector_label
FROM naics_breakdown.report_deck_naics_agency_profile_fy r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n
    ON r.top_naics_code_by_obligation = n.naics_code;

CREATE OR REPLACE VIEW analytics_api.naics_growth_leaders
WITH (security_barrier = true) AS
SELECT
    r.*,
    n.naics_desc AS principal_naics_description,
    n.sector_code,
    n.sector_label
FROM naics_breakdown.report_deck_naics_growth_leaders r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n
    ON r.principal_naics_code = n.naics_code;

-- naics_kpi_summary has no NAICS code to enrich — pass through unchanged.
CREATE OR REPLACE VIEW analytics_api.naics_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_kpi_summary;


-- ─── Geography views: add state names and census regions ────────────────────

CREATE OR REPLACE VIEW analytics_api.geography_state_trend_fy
WITH (security_barrier = true) AS
SELECT
    r.*,
    s.state_name AS pop_state_name,
    s.census_region,
    s.census_division
FROM geographic_analysis.report_deck_geo_state_trend_fy r
LEFT JOIN analytics_dims.fpds_us_state_map s
    ON r.pop_state_code = s.state_code;

-- regional_summary_fy already has region labels — pass through.
CREATE OR REPLACE VIEW analytics_api.geography_regional_summary_fy
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_regional_summary_fy;

-- mismatch_leaders: enrich both vendor and performance state names.
CREATE OR REPLACE VIEW analytics_api.geography_mismatch_leaders
WITH (security_barrier = true) AS
SELECT
    r.*,
    vs.state_name AS vendor_state_name,
    vs.census_region AS vendor_census_region,
    ps.state_name AS pop_state_name,
    ps.census_region AS pop_census_region
FROM geographic_analysis.report_deck_geo_mismatch_leaders r
LEFT JOIN analytics_dims.fpds_us_state_map vs
    ON r.vendor_state_code = vs.state_code
LEFT JOIN analytics_dims.fpds_us_state_map ps
    ON r.pop_state_code = ps.state_code;

-- geo_kpi_summary has no state code — pass through.
CREATE OR REPLACE VIEW analytics_api.geography_kpi_summary
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_kpi_summary;
