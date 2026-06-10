-- Template migration: rewrite NAICS growth leaders to compare complete fiscal years.
-- The report view preserves its existing nine-column order; the API view preserves
-- those columns and appends sector_label as the existing tenth API column.

CREATE OR REPLACE VIEW naics_breakdown.report_deck_naics_growth_leaders AS
WITH fiscal_context AS (
    SELECT
        CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
             THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
             ELSE EXTRACT(year FROM CURRENT_DATE)::int
        END AS current_federal_fy
),
complete_years AS (
    SELECT
        current_federal_fy - 1 AS current_complete_fy,
        current_federal_fy - 2 AS prior_complete_fy
    FROM fiscal_context
),
naics_years AS (
    SELECT
        mv.principal_naics_code,
        mv.sector_code,
        SUM(CASE WHEN mv.fiscal_year = cy.current_complete_fy
                 THEN mv.net_obligated_amount ELSE 0 END) AS current_fy_obligated,
        SUM(CASE WHEN mv.fiscal_year = cy.prior_complete_fy
                 THEN mv.net_obligated_amount ELSE 0 END) AS prior_fy_obligated,
        SUM(CASE WHEN mv.fiscal_year = cy.current_complete_fy
                 THEN mv.action_count ELSE 0 END) AS current_fy_actions,
        SUM(CASE WHEN mv.fiscal_year = cy.prior_complete_fy
                 THEN mv.action_count ELSE 0 END) AS prior_fy_actions
    FROM naics_breakdown.mv_fpds_naics_agency_year mv
    CROSS JOIN complete_years cy
    WHERE mv.fiscal_year IN (cy.current_complete_fy, cy.prior_complete_fy)
      AND mv.principal_naics_code != 'UNKNOWN'
    GROUP BY mv.principal_naics_code, mv.sector_code
),
scored AS (
    SELECT
        ny.principal_naics_code,
        nh.naics_desc,
        ny.sector_code,
        ny.current_fy_obligated,
        ny.prior_fy_obligated,
        ny.current_fy_actions,
        ny.prior_fy_actions,
        ROUND(
            (ny.current_fy_obligated - ny.prior_fy_obligated)
            / NULLIF(ny.prior_fy_obligated, 0),
            6
        ) AS obligation_growth_rate,
        ny.current_fy_obligated - ny.prior_fy_obligated AS obligation_change
    FROM naics_years ny
    LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
        ON ny.principal_naics_code = nh.naics_code
    WHERE ny.prior_fy_obligated > 0
)
SELECT
    principal_naics_code,
    naics_desc,
    sector_code,
    current_fy_obligated,
    prior_fy_obligated,
    current_fy_actions,
    prior_fy_actions,
    obligation_growth_rate,
    obligation_change
FROM scored;

CREATE OR REPLACE VIEW analytics_api.naics_growth_leaders
WITH (security_barrier = true) AS
SELECT
    r.*,
    nh.sector_label
FROM naics_breakdown.report_deck_naics_growth_leaders r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh
    ON r.principal_naics_code = nh.naics_code;
