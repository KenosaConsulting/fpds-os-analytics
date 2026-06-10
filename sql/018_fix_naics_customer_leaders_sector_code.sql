CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_customer_leaders AS
WITH current_fy AS (
         SELECT
                CASE
                    WHEN EXTRACT(month FROM CURRENT_DATE)::integer >= 10 THEN EXTRACT(year FROM CURRENT_DATE)::integer + 1
                    ELSE EXTRACT(year FROM CURRENT_DATE)::integer
                END AS fy
        ), agency_totals AS (
         SELECT mv.principal_naics_code,
            mv.contracting_dept_id,
            mv.contracting_agency_id,
            mv.sector_code,
            sum(mv.net_obligated_amount) AS recent_3yr_obligated,
            sum(mv.total_action_count) AS recent_3yr_actions,
            sum(mv.distinct_vendor_count) AS recent_3yr_vendors,
            sum(mv.small_biz_obligated) AS recent_3yr_small_biz_obligated,
            sum(mv.competed_action_count) AS recent_3yr_competed,
            sum(mv.not_competed_action_count) AS recent_3yr_not_competed
           FROM naics_breakdown.mv_fpds_naics_agency_office_fy mv,
            current_fy
          WHERE mv.fiscal_year >= (current_fy.fy - 2) AND mv.principal_naics_code <> 'UNKNOWN'::text
          GROUP BY mv.principal_naics_code, mv.contracting_dept_id, mv.contracting_agency_id, mv.sector_code
         HAVING sum(mv.net_obligated_amount) > 0::numeric
        )
 SELECT at.principal_naics_code,
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
    round(at.recent_3yr_small_biz_obligated / NULLIF(at.recent_3yr_obligated, 0::numeric), 4) AS small_biz_obligation_share,
    round(at.recent_3yr_not_competed / NULLIF(at.recent_3yr_competed + at.recent_3yr_not_competed, 0::numeric), 4) AS not_competed_action_share,
    row_number() OVER (PARTITION BY at.principal_naics_code ORDER BY at.recent_3yr_obligated DESC) AS customer_rank,
    at.sector_code
   FROM agency_totals at
     LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON at.principal_naics_code = nh.naics_code
     LEFT JOIN analytics_dims.fpds_department_map dm ON at.contracting_dept_id = dm.department_id
     LEFT JOIN analytics_dims.fpds_agency_map am ON at.contracting_agency_id = am.agency_id;

CREATE OR REPLACE VIEW analytics_api.market_naics_customer_leaders
WITH (security_barrier = true) AS
 SELECT principal_naics_code,
    principal_naics_description,
    sector_label,
    contracting_dept_id,
    contracting_dept_name,
    department_short_name,
    contracting_agency_id,
    contracting_agency_name,
    agency_short_name,
    recent_3yr_obligated,
    recent_3yr_actions,
    recent_3yr_vendors,
    small_biz_obligation_share,
    not_competed_action_share,
    customer_rank,
    sector_code
   FROM naics_breakdown.report_deck_naics_customer_leaders;
