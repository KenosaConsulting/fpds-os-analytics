-- FPDS-017: Fiscal seasonality materialized views.
--
-- Source columns verified 2026-06-10 via pg_attribute on public.fpds_actions:
--   signed_date text, obligated_amount text, contracting_dept_id text,
--   contracting_agency_id text, contracting_office_id text, piid text
--
-- These are refresh-time aggregations only. API views read the materialized
-- aggregates and never query public.fpds_actions at request time.

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_agency_month_seasonality AS
WITH normalized_actions AS (
    SELECT
        fa.contracting_dept_id,
        fa.contracting_agency_id,
        fa.signed_date::date AS signed_date,
        NULLIF(fa.obligated_amount, '')::numeric AS obligated_amount
    FROM public.fpds_actions fa
    WHERE fa.signed_date IS NOT NULL
      AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
      AND fa.contracting_dept_id IS NOT NULL
      AND fa.contracting_dept_id != ''
      AND fa.contracting_agency_id IS NOT NULL
      AND fa.contracting_agency_id != ''
),
fiscalized AS (
    SELECT
        contracting_dept_id,
        contracting_agency_id,
        signed_date,
        obligated_amount,
        CASE WHEN EXTRACT(month FROM signed_date)::int >= 10
             THEN EXTRACT(year FROM signed_date)::int + 1
             ELSE EXTRACT(year FROM signed_date)::int
        END AS fiscal_year,
        CASE WHEN EXTRACT(month FROM signed_date)::int >= 10
             THEN EXTRACT(month FROM signed_date)::int - 9
             ELSE EXTRACT(month FROM signed_date)::int + 3
        END AS fiscal_month
    FROM normalized_actions
)
SELECT
    contracting_dept_id,
    contracting_agency_id,
    fiscal_year,
    fiscal_month,
    CEIL(fiscal_month::numeric / 3)::integer AS fiscal_quarter,
    SUM(obligated_amount) AS obligated_amount,
    COUNT(*) AS action_count
FROM fiscalized
WHERE fiscal_year >= 2010
GROUP BY
    contracting_dept_id,
    contracting_agency_id,
    fiscal_year,
    fiscal_month;

CREATE INDEX IF NOT EXISTS mv_agency_month_seasonality_entity_year_idx
    ON customer_intelligence.mv_fpds_agency_month_seasonality
    (contracting_dept_id, contracting_agency_id, fiscal_year);

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_office_quarter_seasonality AS
WITH normalized_actions AS (
    SELECT
        fa.contracting_dept_id,
        fa.contracting_agency_id,
        fa.contracting_office_id,
        fa.signed_date::date AS signed_date,
        NULLIF(fa.obligated_amount, '')::numeric AS obligated_amount
    FROM public.fpds_actions fa
    WHERE fa.signed_date IS NOT NULL
      AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}'
      AND fa.contracting_dept_id IS NOT NULL
      AND fa.contracting_dept_id != ''
      AND fa.contracting_agency_id IS NOT NULL
      AND fa.contracting_agency_id != ''
      AND fa.contracting_office_id IS NOT NULL
      AND fa.contracting_office_id != ''
),
fiscalized AS (
    SELECT
        contracting_dept_id,
        contracting_agency_id,
        contracting_office_id,
        signed_date,
        obligated_amount,
        CASE WHEN EXTRACT(month FROM signed_date)::int >= 10
             THEN EXTRACT(year FROM signed_date)::int + 1
             ELSE EXTRACT(year FROM signed_date)::int
        END AS fiscal_year,
        CEIL(
            (CASE WHEN EXTRACT(month FROM signed_date)::int >= 10
                  THEN EXTRACT(month FROM signed_date)::int - 9
                  ELSE EXTRACT(month FROM signed_date)::int + 3
             END)::numeric / 3
        )::integer AS fiscal_quarter
    FROM normalized_actions
)
SELECT
    contracting_dept_id,
    contracting_agency_id,
    contracting_office_id,
    fiscal_year,
    fiscal_quarter,
    SUM(obligated_amount) AS obligated_amount,
    COUNT(*) AS total_action_count
FROM fiscalized
WHERE fiscal_year >= 2010
GROUP BY
    contracting_dept_id,
    contracting_agency_id,
    contracting_office_id,
    fiscal_year,
    fiscal_quarter;

CREATE INDEX IF NOT EXISTS mv_office_quarter_seasonality_entity_year_idx
    ON customer_intelligence.mv_fpds_office_quarter_seasonality
    (contracting_dept_id, contracting_agency_id, contracting_office_id, fiscal_year);

CREATE OR REPLACE VIEW customer_intelligence.report_deck_agency_month_seasonality AS
WITH fy_totals AS (
    SELECT
        contracting_dept_id,
        contracting_agency_id,
        fiscal_year,
        SUM(obligated_amount) AS fy_obligated_amount,
        SUM(obligated_amount) FILTER (WHERE fiscal_quarter = 4) AS q4_obligated_amount
    FROM customer_intelligence.mv_fpds_agency_month_seasonality
    GROUP BY contracting_dept_id, contracting_agency_id, fiscal_year
)
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    mv.fiscal_month,
    mv.fiscal_quarter,
    mv.obligated_amount,
    mv.action_count,
    ROUND(ft.q4_obligated_amount / NULLIF(ft.fy_obligated_amount, 0), 4)
        AS q4_obligation_share
FROM customer_intelligence.mv_fpds_agency_month_seasonality mv
JOIN fy_totals ft
  ON ft.contracting_dept_id = mv.contracting_dept_id
 AND ft.contracting_agency_id = mv.contracting_agency_id
 AND ft.fiscal_year = mv.fiscal_year
LEFT JOIN analytics_dims.fpds_department_map dm
  ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON mv.contracting_agency_id = am.agency_id;

COMMENT ON VIEW customer_intelligence.report_deck_agency_month_seasonality IS
'Fiscal-month obligation seasonality by contracting department and agency. Q4 obligation share is repeated per entity and fiscal year.';

CREATE OR REPLACE VIEW customer_intelligence.report_deck_office_quarter_seasonality AS
WITH fy_totals AS (
    SELECT
        contracting_dept_id,
        contracting_agency_id,
        contracting_office_id,
        fiscal_year,
        SUM(obligated_amount) AS fy_obligated_amount,
        SUM(obligated_amount) FILTER (WHERE fiscal_quarter = 4) AS q4_obligated_amount
    FROM customer_intelligence.mv_fpds_office_quarter_seasonality
    GROUP BY contracting_dept_id, contracting_agency_id, contracting_office_id, fiscal_year
)
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.contracting_office_id,
    om.contracting_office_name,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    mv.fiscal_quarter,
    mv.obligated_amount,
    mv.total_action_count,
    ROUND(ft.q4_obligated_amount / NULLIF(ft.fy_obligated_amount, 0), 4)
        AS q4_obligation_share
FROM customer_intelligence.mv_fpds_office_quarter_seasonality mv
JOIN fy_totals ft
  ON ft.contracting_dept_id = mv.contracting_dept_id
 AND ft.contracting_agency_id = mv.contracting_agency_id
 AND ft.contracting_office_id = mv.contracting_office_id
 AND ft.fiscal_year = mv.fiscal_year
LEFT JOIN analytics_dims.fpds_department_map dm
  ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om
  ON mv.contracting_office_id = om.contracting_office_id;

COMMENT ON VIEW customer_intelligence.report_deck_office_quarter_seasonality IS
'Fiscal-quarter obligation seasonality by contracting office. Q4 obligation share is repeated per office and fiscal year.';

CREATE OR REPLACE VIEW analytics_api.seasonality_agency_month_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_agency_month_seasonality;

COMMENT ON VIEW analytics_api.seasonality_agency_month_fy IS
'Agency fiscal-month obligation seasonality since FY2010, including Q4 obligation share by agency and fiscal year.';

CREATE OR REPLACE VIEW analytics_api.seasonality_office_quarter_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_office_quarter_seasonality;

COMMENT ON VIEW analytics_api.seasonality_office_quarter_fy IS
'Office fiscal-quarter obligation seasonality since FY2010, including Q4 obligation share by office and fiscal year.';

GRANT SELECT ON analytics_api.seasonality_agency_month_fy TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.seasonality_office_quarter_fy TO fpds_analytics_api_readonly;
