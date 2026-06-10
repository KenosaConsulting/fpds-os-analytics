-- FPDS-020: Award-size distribution by agency and NAICS.
--
-- Source columns verified 2026-06-10:
--   pipeline_intelligence.mv_contract_family:
--     contracting_dept_id, contracting_agency_id, principal_naics_code,
--     total_obligated, duration_months
--   analytics_dims.fpds_department_map:
--     department_id, department_name, department_short_name
--   analytics_dims.fpds_agency_map:
--     agency_id, agency_name, agency_short_name
--   analytics_dims.fpds_naics_hierarchy_map:
--     naics_code, naics_desc, sector_code, sector_label

CREATE MATERIALIZED VIEW pipeline_intelligence.mv_award_size_distribution AS
SELECT
    cf.contracting_dept_id,
    cf.contracting_agency_id,
    cf.principal_naics_code,
    COUNT(*) AS contract_count,
    SUM(cf.total_obligated) AS total_obligated,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY cf.total_obligated) AS p25_total_obligated,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cf.total_obligated) AS median_total_obligated,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY cf.total_obligated) AS p75_total_obligated,
    ROUND(
        COUNT(*) FILTER (WHERE cf.total_obligated < 250000)::numeric
        / NULLIF(COUNT(*), 0),
        4
    ) AS share_under_sat,
    ROUND(
        COUNT(*) FILTER (WHERE cf.total_obligated < 10000)::numeric
        / NULLIF(COUNT(*), 0),
        4
    ) AS share_under_micro_purchase,
    ROUND(AVG(cf.duration_months) FILTER (WHERE cf.duration_months > 0), 1)
        AS avg_duration_months
FROM pipeline_intelligence.mv_contract_family cf
WHERE cf.total_obligated > 0
  AND cf.contracting_dept_id IS NOT NULL
  AND cf.contracting_dept_id != ''
  AND cf.contracting_agency_id IS NOT NULL
  AND cf.contracting_agency_id != ''
  AND cf.principal_naics_code IS NOT NULL
  AND cf.principal_naics_code != ''
GROUP BY
    cf.contracting_dept_id,
    cf.contracting_agency_id,
    cf.principal_naics_code
HAVING COUNT(*) >= 10;

CREATE INDEX IF NOT EXISTS mv_award_size_distribution_agency_naics_idx
    ON pipeline_intelligence.mv_award_size_distribution
    (contracting_agency_id, principal_naics_code);

CREATE INDEX IF NOT EXISTS mv_award_size_distribution_dept_naics_idx
    ON pipeline_intelligence.mv_award_size_distribution
    (contracting_dept_id, principal_naics_code);

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_award_size_distribution AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    nh.sector_code,
    nh.sector_label,
    mv.contract_count,
    mv.total_obligated,
    mv.p25_total_obligated,
    mv.median_total_obligated,
    mv.p75_total_obligated,
    mv.share_under_sat,
    mv.share_under_micro_purchase,
    mv.avg_duration_months
FROM pipeline_intelligence.mv_award_size_distribution mv
LEFT JOIN analytics_dims.fpds_department_map dm
  ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
  ON mv.principal_naics_code = nh.naics_code;

COMMENT ON VIEW pipeline_intelligence.report_deck_award_size_distribution IS
'Award-size distribution by contracting department, agency, and NAICS. Percentiles and small-award shares are computed from positive-obligation contract families.';

CREATE OR REPLACE VIEW analytics_api.pipeline_award_size_distribution
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.report_deck_award_size_distribution;

COMMENT ON VIEW analytics_api.pipeline_award_size_distribution IS
'Award-size distribution by agency and NAICS: contract count, total obligation percentiles, share under simplified acquisition threshold, share under micro-purchase, and average duration.';

GRANT SELECT ON analytics_api.pipeline_award_size_distribution TO fpds_analytics_api_readonly;
