-- FPDS-021 Step 5: vehicle-program report views and analytics_api facades.
--
-- Verified 2026-06-12 via pg_attribute on project tfrhforjvaafmqmxmtrt:
--   customer_intelligence.mv_fpds_vehicle_program_agency_fy(_norm expected) columns
--     vehicle_program_id text
--     vehicle_program_name text
--     vehicle_program_short_name text
--     program_family text
--     is_pseudo_program boolean
--     program_owner_agency_id text
--     program_owner_agency_name text
--     is_governmentwide boolean
--     contracting_dept_id text
--     contracting_agency_id text
--     fiscal_year integer
--     obligated_amount numeric
--     action_count bigint
--     distinct_vendor_count bigint
--     competed_action_count bigint
--     not_competed_action_count bigint
--     avg_offers_received numeric
--     small_biz_obligated numeric
--   customer_intelligence.mv_fpds_vehicle_program_vendor_fy(_norm expected) columns
--     vehicle_program_id text
--     vehicle_program_name text
--     vehicle_program_short_name text
--     program_family text
--     is_pseudo_program boolean
--     program_owner_agency_id text
--     program_owner_agency_name text
--     is_governmentwide boolean
--     vendor_uei text
--     vendor_name text
--     fiscal_year integer
--     obligated_amount numeric
--     order_count bigint
--     distinct_customer_agencies integer
--   analytics_dims.fpds_department_map columns
--     department_id text
--     department_name text
--     department_short_name text
--   analytics_dims.fpds_agency_map columns
--     agency_id text
--     agency_name text
--     agency_short_name text
--   analytics_dims.fpds_vehicle_program columns
--     successor_program_id text
--     name_source text
--     notes text
--
-- Production note: these views MUST read the normalized Step-4 replacements
-- (`*_norm`) only. If those MVs are absent, this migration should fail rather
-- than silently falling back to the stale non-_norm objects.

CREATE OR REPLACE VIEW customer_intelligence.report_deck_vehicle_program_usage_fy AS
WITH usage_base AS (
    SELECT
        mv.vehicle_program_id,
        mv.vehicle_program_name,
        mv.vehicle_program_short_name,
        mv.program_family,
        mv.is_pseudo_program,
        mv.program_owner_agency_id,
        mv.program_owner_agency_name,
        mv.is_governmentwide,
        mv.contracting_dept_id,
        dept.department_name AS contracting_dept_name,
        dept.department_short_name,
        mv.contracting_agency_id,
        agency.agency_name AS contracting_agency_name,
        agency.agency_short_name,
        mv.fiscal_year,
        mv.obligated_amount,
        mv.action_count,
        mv.distinct_vendor_count,
        mv.competed_action_count,
        mv.not_competed_action_count,
        mv.avg_offers_received,
        mv.small_biz_obligated
    FROM customer_intelligence.mv_fpds_vehicle_program_agency_fy_norm mv
    LEFT JOIN analytics_dims.fpds_department_map dept
        ON dept.department_id = mv.contracting_dept_id
    LEFT JOIN analytics_dims.fpds_agency_map agency
        ON agency.agency_id = mv.contracting_agency_id
)
SELECT
    ub.vehicle_program_id,
    ub.vehicle_program_name,
    ub.vehicle_program_short_name,
    ub.program_family,
    ub.is_pseudo_program,
    ub.program_owner_agency_id,
    ub.program_owner_agency_name,
    ub.is_governmentwide,
    ub.contracting_dept_id,
    ub.contracting_dept_name,
    ub.department_short_name,
    ub.contracting_agency_id,
    ub.contracting_agency_name,
    ub.agency_short_name,
    ub.fiscal_year,
    ub.fiscal_year = (
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE)::integer >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::integer + 1
            ELSE EXTRACT(year FROM CURRENT_DATE)::integer
        END
    ) AS is_current_fiscal_year_ytd,
    ub.obligated_amount,
    ub.action_count,
    ub.distinct_vendor_count,
    ub.competed_action_count,
    ub.not_competed_action_count,
    ub.avg_offers_received,
    ub.small_biz_obligated,
    CASE
        WHEN ub.action_count > 0
            THEN ub.competed_action_count::numeric / ub.action_count::numeric
        ELSE NULL::numeric
    END AS competed_action_share,
    CASE
        WHEN ub.action_count > 0
            THEN ub.not_competed_action_count::numeric / ub.action_count::numeric
        ELSE NULL::numeric
    END AS not_competed_action_share,
    CASE
        WHEN ub.obligated_amount <> 0
            THEN ub.small_biz_obligated / ub.obligated_amount
        ELSE NULL::numeric
    END AS small_biz_obligation_share
FROM usage_base ub;

COMMENT ON VIEW customer_intelligence.report_deck_vehicle_program_usage_fy IS
'Program x customer x fiscal-year vehicle usage view over the normalized Step-4 materialized view.';

CREATE OR REPLACE VIEW customer_intelligence.report_deck_vehicle_program_summary AS
WITH agency_rollup AS (
    SELECT
        mv.vehicle_program_id,
        MAX(mv.vehicle_program_name) AS vehicle_program_name,
        MAX(mv.vehicle_program_short_name) AS vehicle_program_short_name,
        MAX(mv.program_family) AS program_family,
        BOOL_OR(mv.is_pseudo_program) AS is_pseudo_program,
        MAX(mv.program_owner_agency_id) AS program_owner_agency_id,
        MAX(mv.program_owner_agency_name) AS program_owner_agency_name,
        BOOL_OR(mv.is_governmentwide) AS is_governmentwide,
        SUM(mv.obligated_amount) AS lifetime_obligated_amount,
        SUM(mv.action_count) AS lifetime_action_count,
        COUNT(DISTINCT mv.contracting_dept_id) AS distinct_using_departments,
        COUNT(DISTINCT mv.contracting_agency_id) AS distinct_using_agencies,
        MIN(mv.fiscal_year) AS first_order_fy,
        MAX(mv.fiscal_year) AS last_order_fy,
        SUM(mv.small_biz_obligated) AS lifetime_small_biz_obligated
    FROM customer_intelligence.mv_fpds_vehicle_program_agency_fy_norm mv
    GROUP BY mv.vehicle_program_id
),
vendor_rollup AS (
    SELECT
        mv.vehicle_program_id,
        COUNT(DISTINCT mv.vendor_uei) AS distinct_winning_vendors
    FROM customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm mv
    WHERE mv.vendor_uei IS NOT NULL
      AND mv.vendor_uei <> ''
    GROUP BY mv.vehicle_program_id
)
SELECT
    ar.vehicle_program_id,
    ar.vehicle_program_name,
    ar.vehicle_program_short_name,
    ar.program_family,
    ar.is_pseudo_program,
    ar.program_owner_agency_id,
    ar.program_owner_agency_name,
    ar.is_governmentwide,
    ar.lifetime_obligated_amount,
    ar.lifetime_action_count,
    ar.distinct_using_departments,
    ar.distinct_using_agencies,
    COALESCE(vr.distinct_winning_vendors, 0::bigint) AS distinct_winning_vendors,
    ar.first_order_fy,
    ar.last_order_fy,
    ar.last_order_fy >= (
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE)::integer >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::integer + 1
            ELSE EXTRACT(year FROM CURRENT_DATE)::integer
        END - 2
    ) AS is_active_recent,
    ar.lifetime_small_biz_obligated,
    CASE
        WHEN ar.lifetime_obligated_amount <> 0
            THEN ar.lifetime_small_biz_obligated / ar.lifetime_obligated_amount
        ELSE NULL::numeric
    END AS small_biz_obligation_share,
    vp.successor_program_id,
    COALESCE(vp.name_source, CASE WHEN ar.is_pseudo_program THEN 'derived_pseudo' END) AS name_source,
    vp.notes
FROM agency_rollup ar
LEFT JOIN vendor_rollup vr
    ON vr.vehicle_program_id = ar.vehicle_program_id
LEFT JOIN analytics_dims.fpds_vehicle_program vp
    ON vp.program_id = ar.vehicle_program_id;

COMMENT ON VIEW customer_intelligence.report_deck_vehicle_program_summary IS
'One row per vehicle program or pseudo-program. Rolls up the normalized agency/vendor fiscal-year MVs into the summary layer used by the API.';

CREATE OR REPLACE VIEW customer_intelligence.report_deck_vehicle_program_vendors AS
WITH program_year_totals AS (
    SELECT
        mv.vehicle_program_id,
        mv.fiscal_year,
        SUM(mv.obligated_amount) AS total_program_obligated,
        SUM(mv.order_count) AS total_program_orders,
        COUNT(DISTINCT mv.vendor_uei) AS distinct_winning_vendors_fy
    FROM customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm mv
    GROUP BY
        mv.vehicle_program_id,
        mv.fiscal_year
),
ranked_vendors AS (
    SELECT
        mv.vehicle_program_id,
        mv.vehicle_program_name,
        mv.vehicle_program_short_name,
        mv.program_family,
        mv.is_pseudo_program,
        mv.program_owner_agency_id,
        mv.program_owner_agency_name,
        mv.is_governmentwide,
        mv.vendor_uei,
        mv.vendor_name,
        mv.fiscal_year,
        mv.obligated_amount,
        mv.order_count,
        mv.distinct_customer_agencies,
        ROW_NUMBER() OVER (
            PARTITION BY mv.vehicle_program_id, mv.fiscal_year
            ORDER BY
                mv.obligated_amount DESC,
                mv.order_count DESC,
                mv.vendor_uei
        ) AS vendor_rank_in_program_fy
    FROM customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm mv
)
SELECT
    rv.vehicle_program_id,
    rv.vehicle_program_name,
    rv.vehicle_program_short_name,
    rv.program_family,
    rv.is_pseudo_program,
    rv.program_owner_agency_id,
    rv.program_owner_agency_name,
    rv.is_governmentwide,
    rv.vendor_uei,
    rv.vendor_name,
    rv.fiscal_year,
    rv.fiscal_year = (
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE)::integer >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::integer + 1
            ELSE EXTRACT(year FROM CURRENT_DATE)::integer
        END
    ) AS is_current_fiscal_year_ytd,
    rv.obligated_amount,
    rv.order_count,
    rv.distinct_customer_agencies,
    rv.vendor_rank_in_program_fy,
    pyt.total_program_obligated,
    pyt.total_program_orders,
    pyt.distinct_winning_vendors_fy,
    CASE
        WHEN pyt.total_program_obligated <> 0
            THEN rv.obligated_amount / pyt.total_program_obligated
        ELSE NULL::numeric
    END AS vendor_obligation_share
FROM ranked_vendors rv
JOIN program_year_totals pyt
    ON pyt.vehicle_program_id = rv.vehicle_program_id
   AND pyt.fiscal_year = rv.fiscal_year;

COMMENT ON VIEW customer_intelligence.report_deck_vehicle_program_vendors IS
'Program x vendor x fiscal-year winners view over the normalized Step-4 vendor MV. Exposes yearly winner share and rank within each vehicle program.';

CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_usage_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_vehicle_program_usage_fy;

COMMENT ON VIEW analytics_api.acquisition_vehicle_program_usage_fy IS
'Customer-side usage of named vehicle programs by department, agency, and fiscal year. Use this to see which specific GWACs, schedules, and IDIQs a customer relies on.';

CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_summary
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_vehicle_program_summary;

COMMENT ON VIEW analytics_api.acquisition_vehicle_program_summary IS
'Vehicle-program summary ranked by lifetime usage, customer reach, and winner breadth. Defaults should emphasize recently active programs first.';

CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_program_vendors
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_vehicle_program_vendors;

COMMENT ON VIEW analytics_api.acquisition_vehicle_program_vendors IS
'Program x vendor x fiscal-year winners for named vehicle programs. Answers who wins on a vehicle and how concentrated that winner pool is by year.';

GRANT SELECT ON analytics_api.acquisition_vehicle_program_usage_fy TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.acquisition_vehicle_program_summary TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.acquisition_vehicle_program_vendors TO fpds_analytics_api_readonly;
