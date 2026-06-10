-- FPDS-018: New-entrant cohorts by contracting agency and fiscal year.
--
-- Source columns verified 2026-06-10:
--   vendor_concentration.mv_fpds_vendor_agency_year:
--     uei, contracting_agency_id, fiscal_year, vendor_name, action_count,
--     net_obligated_amount, positive_obligated_amount
--   pipeline_intelligence.mv_contract_family:
--     vendor_uei, contracting_agency_id, fiscal_year_of_base, set_aside_code,
--     total_obligated
--
-- The cohort grain is agency x first active fiscal year. First active year
-- is derived from the existing vendor_concentration MV, not from the source
-- action table.

CREATE MATERIALIZED VIEW vendor_concentration.mv_fpds_entrants_agency_cohort_fy AS
WITH vendor_years AS (
    SELECT
        mv.uei,
        mv.contracting_agency_id,
        mv.fiscal_year,
        MAX(mv.vendor_name) AS vendor_name,
        SUM(mv.action_count) AS action_count,
        SUM(mv.net_obligated_amount) AS net_obligated_amount,
        SUM(mv.positive_obligated_amount) AS positive_obligated_amount
    FROM vendor_concentration.mv_fpds_vendor_agency_year mv
    WHERE mv.uei IS NOT NULL
      AND mv.uei != ''
      AND mv.contracting_agency_id IS NOT NULL
      AND mv.contracting_agency_id != ''
      AND mv.net_obligated_amount > 0
    GROUP BY mv.uei, mv.contracting_agency_id, mv.fiscal_year
),
first_years AS (
    SELECT
        vy.uei,
        vy.contracting_agency_id,
        MIN(vy.fiscal_year) AS first_active_fy
    FROM vendor_years vy
    GROUP BY vy.uei, vy.contracting_agency_id
),
cohort_vendors AS (
    SELECT
        fy.uei,
        fy.contracting_agency_id,
        fy.first_active_fy,
        vy.vendor_name,
        vy.action_count AS first_year_action_count,
        vy.net_obligated_amount AS first_year_obligated,
        vy.positive_obligated_amount AS first_year_positive_obligated,
        CASE WHEN surv.uei IS NOT NULL THEN true ELSE false END AS survived_2fy
    FROM first_years fy
    JOIN vendor_years vy
      ON vy.uei = fy.uei
     AND vy.contracting_agency_id = fy.contracting_agency_id
     AND vy.fiscal_year = fy.first_active_fy
    LEFT JOIN vendor_years surv
      ON surv.uei = fy.uei
     AND surv.contracting_agency_id = fy.contracting_agency_id
     AND surv.fiscal_year = fy.first_active_fy + 2
    WHERE fy.first_active_fy >= 2010
),
first_year_setaside AS (
    SELECT
        cf.vendor_uei AS uei,
        cf.contracting_agency_id,
        cf.fiscal_year_of_base AS first_active_fy,
        SUM(cf.total_obligated) FILTER (
            WHERE cf.set_aside_code IS NOT NULL
              AND cf.set_aside_code NOT IN ('', 'NONE', 'UNKNOWN')
        ) AS set_aside_obligated,
        SUM(cf.total_obligated) AS set_aside_derivation_obligated
    FROM pipeline_intelligence.mv_contract_family cf
    WHERE cf.vendor_uei IS NOT NULL
      AND cf.vendor_uei != ''
      AND cf.contracting_agency_id IS NOT NULL
      AND cf.contracting_agency_id != ''
      AND cf.fiscal_year_of_base >= 2010
      AND cf.total_obligated > 0
    GROUP BY cf.vendor_uei, cf.contracting_agency_id, cf.fiscal_year_of_base
),
latest_year AS (
    SELECT MAX(fiscal_year) AS fiscal_year
    FROM vendor_years
)
SELECT
    cv.contracting_agency_id,
    am.parent_department_id AS contracting_dept_id,
    cv.first_active_fy AS fiscal_year,
    CASE
        WHEN cv.first_active_fy = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    COUNT(*) AS new_vendor_count,
    SUM(cv.first_year_obligated) AS first_year_obligated_total,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cv.first_year_obligated)
        AS median_first_year_obligated,
    SUM(cv.first_year_action_count) AS first_year_action_count,
    SUM(COALESCE(fys.set_aside_obligated, 0)) AS set_aside_first_year_obligated,
    ROUND(
        SUM(COALESCE(fys.set_aside_obligated, 0))
        / NULLIF(SUM(COALESCE(fys.set_aside_derivation_obligated, 0)), 0),
        4
    ) AS set_aside_first_year_obligation_share,
    CASE
        WHEN cv.first_active_fy >= ly.fiscal_year - 1 THEN NULL
        ELSE ROUND(
            COUNT(*) FILTER (WHERE cv.survived_2fy)::numeric
            / NULLIF(COUNT(*), 0),
            4
        )
    END AS survival_2fy_rate,
    COUNT(*) FILTER (WHERE cv.survived_2fy) AS survived_2fy_vendor_count
FROM cohort_vendors cv
CROSS JOIN latest_year ly
LEFT JOIN first_year_setaside fys
  ON fys.uei = cv.uei
 AND fys.contracting_agency_id = cv.contracting_agency_id
 AND fys.first_active_fy = cv.first_active_fy
LEFT JOIN analytics_dims.fpds_agency_map am
  ON cv.contracting_agency_id = am.agency_id
GROUP BY
    cv.contracting_agency_id,
    am.parent_department_id,
    cv.first_active_fy,
    ly.fiscal_year;

CREATE INDEX IF NOT EXISTS mv_entrants_agency_cohort_fy_agency_year_idx
    ON vendor_concentration.mv_fpds_entrants_agency_cohort_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_entrants_agency_cohort_fy_dept_year_idx
    ON vendor_concentration.mv_fpds_entrants_agency_cohort_fy
    (contracting_dept_id, fiscal_year);

CREATE OR REPLACE VIEW vendor_concentration.report_deck_entrants_agency_cohort_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.fiscal_year,
    mv.is_current_fiscal_year_ytd,
    mv.new_vendor_count,
    mv.first_year_obligated_total,
    mv.median_first_year_obligated,
    mv.first_year_action_count,
    mv.set_aside_first_year_obligated,
    mv.set_aside_first_year_obligation_share,
    mv.survival_2fy_rate,
    mv.survived_2fy_vendor_count
FROM vendor_concentration.mv_fpds_entrants_agency_cohort_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm
  ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON mv.contracting_agency_id = am.agency_id;

COMMENT ON VIEW vendor_concentration.report_deck_entrants_agency_cohort_fy IS
'New-entrant cohorts by contracting agency and fiscal year. First active year is derived from vendor_concentration.mv_fpds_vendor_agency_year; set-aside share is derived from first-year contract families where available.';

CREATE OR REPLACE VIEW analytics_api.entrants_agency_cohort_fy
WITH (security_barrier = true) AS
SELECT * FROM vendor_concentration.report_deck_entrants_agency_cohort_fy;

COMMENT ON VIEW analytics_api.entrants_agency_cohort_fy IS
'New vendor cohorts by agency and fiscal year: entrant counts, first-year obligation size, set-aside share where derivable, and two-fiscal-year survival.';

GRANT SELECT ON analytics_api.entrants_agency_cohort_fy TO fpds_analytics_api_readonly;
