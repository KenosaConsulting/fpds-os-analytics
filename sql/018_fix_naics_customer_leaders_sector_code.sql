-- Template migration: add sector_code to the NAICS customer leaders API view.
-- Do not run this file from the API repo; apply through the controlled refresh/migration pipeline.

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
    nh.sector_code,
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

CREATE OR REPLACE VIEW analytics_api.market_naics_customer_leaders
WITH (security_barrier = true) AS
SELECT * FROM naics_breakdown.report_deck_naics_customer_leaders;
