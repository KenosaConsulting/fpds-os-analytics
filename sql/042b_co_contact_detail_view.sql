-- FPDS-022 Step 5b: Contact Detail View
-- "Tell me everything about this person" — one rich row per contact
-- Cross-MV aggregation: directory + MV A (offices) + MV B (NAICS) in a single query
-- This is the view the API orchestration layer can't replicate efficiently

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contact_detail AS
WITH office_summary AS (
    -- Aggregate office activity + find primary office (by obligations)
    SELECT
        user_id,
        COUNT(DISTINCT contracting_office_id) AS distinct_offices,
        COUNT(DISTINCT contracting_agency_id) AS distinct_agencies,
        COUNT(DISTINCT contracting_dept_id) AS distinct_depts,
        SUM(action_count) AS total_office_actions,
        SUM(obligated_amount) AS total_office_obligated,
        SUM(distinct_vendor_count) AS total_vendors_touched,
        SUM(small_biz_obligated) AS total_small_biz_obligated,
        SUM(set_aside_action_count) AS total_set_aside_actions,
        SUM(sole_source_action_count) AS total_sole_source_actions,
        MIN(fiscal_year) AS earliest_office_fy,
        MAX(fiscal_year) AS latest_office_fy,
        COUNT(DISTINCT fiscal_year) AS active_fiscal_years
    FROM customer_intelligence.mv_fpds_contact_office_fy
    GROUP BY user_id
),
primary_office AS (
    -- Most-obligated office per contact
    SELECT DISTINCT ON (user_id)
        user_id,
        contracting_dept_id AS primary_dept_id,
        contracting_dept_name AS primary_dept_name,
        contracting_agency_id AS primary_agency_id,
        contracting_agency_name AS primary_agency_name,
        contracting_office_id AS primary_office_id,
        contracting_office_name AS primary_office_name
    FROM (
        SELECT
            user_id,
            contracting_dept_id, contracting_dept_name,
            contracting_agency_id, contracting_agency_name,
            contracting_office_id, contracting_office_name,
            SUM(obligated_amount) AS office_total
        FROM customer_intelligence.mv_fpds_contact_office_fy
        GROUP BY user_id,
            contracting_dept_id, contracting_dept_name,
            contracting_agency_id, contracting_agency_name,
            contracting_office_id, contracting_office_name
    ) sub
    ORDER BY user_id, office_total DESC NULLS LAST
),
naics_summary AS (
    -- Aggregate NAICS activity + find primary NAICS
    SELECT
        user_id,
        COUNT(DISTINCT principal_naics_code) AS distinct_naics_codes,
        COUNT(DISTINCT naics_sector) AS distinct_naics_sectors,
        SUM(action_count) AS total_naics_actions,
        SUM(obligated_amount) AS total_naics_obligated,
        SUM(set_aside_obligated) AS total_set_aside_obligated,
        SUM(sole_source_obligated) AS total_sole_source_obligated
    FROM customer_intelligence.mv_fpds_contact_naics_agency_fy
    GROUP BY user_id
),
primary_naics AS (
    -- Most-obligated NAICS per contact
    SELECT DISTINCT ON (user_id)
        user_id,
        principal_naics_code AS primary_naics_code,
        naics_sector AS primary_naics_sector
    FROM (
        SELECT
            user_id,
            principal_naics_code,
            naics_sector,
            SUM(obligated_amount) AS naics_total
        FROM customer_intelligence.mv_fpds_contact_naics_agency_fy
        GROUP BY user_id, principal_naics_code, naics_sector
    ) sub
    ORDER BY user_id, naics_total DESC NULLS LAST
),
recent_fy AS (
    -- Last 2 FY activity from MV A for recency signal
    SELECT
        user_id,
        SUM(action_count) AS recent_2fy_actions,
        SUM(obligated_amount) AS recent_2fy_obligated
    FROM customer_intelligence.mv_fpds_contact_office_fy
    WHERE fiscal_year >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - 1)
    GROUP BY user_id
)
SELECT
    -- Identity
    c.user_id,
    c.user_class,
    c.class_source,
    c.display_name,
    c.email,
    c.name_confidence,
    c.roles_seen,
    c.is_active_recent,

    -- Career span
    c.first_seen_fy,
    c.last_seen_fy,
    (c.last_seen_fy - c.first_seen_fy + 1) AS career_span_years,
    os.active_fiscal_years,

    -- Primary assignment
    po.primary_dept_id,
    po.primary_dept_name,
    po.primary_agency_id,
    po.primary_agency_name,
    po.primary_office_id,
    po.primary_office_name,
    pn.primary_naics_code,
    pn.primary_naics_sector,

    -- Scope of work
    os.distinct_offices,
    os.distinct_agencies,
    os.distinct_depts,
    ns.distinct_naics_codes,
    ns.distinct_naics_sectors,

    -- Career totals
    c.lifetime_actions_created,
    c.lifetime_actions_approved,
    c.lifetime_obligated_created,
    c.lifetime_obligated_approved,
    c.distinct_vendors_created,
    c.distinct_vendors_approved,

    -- Behavioral profile
    CASE WHEN os.total_office_actions > 0
        THEN ROUND(os.total_set_aside_actions::NUMERIC / os.total_office_actions * 100, 1)
        ELSE NULL
    END AS set_aside_action_pct,
    CASE WHEN os.total_office_actions > 0
        THEN ROUND(os.total_sole_source_actions::NUMERIC / os.total_office_actions * 100, 1)
        ELSE NULL
    END AS sole_source_action_pct,
    CASE WHEN os.total_office_obligated > 0
        THEN ROUND(os.total_small_biz_obligated / os.total_office_obligated * 100, 1)
        ELSE NULL
    END AS small_biz_obligated_pct,
    CASE WHEN ns.total_naics_obligated > 0
        THEN ROUND(ns.total_set_aside_obligated / ns.total_naics_obligated * 100, 1)
        ELSE NULL
    END AS set_aside_obligated_pct,
    CASE WHEN ns.total_naics_obligated > 0
        THEN ROUND(ns.total_sole_source_obligated / ns.total_naics_obligated * 100, 1)
        ELSE NULL
    END AS sole_source_obligated_pct,

    -- Recency
    COALESCE(rfy.recent_2fy_actions, 0) AS recent_2fy_actions,
    COALESCE(rfy.recent_2fy_obligated, 0) AS recent_2fy_obligated,

    -- Volume signal
    c.max_actions_any_single_fy

FROM analytics_dims.fpds_procurement_contact c
LEFT JOIN office_summary os ON c.user_id = os.user_id
LEFT JOIN primary_office po ON c.user_id = po.user_id
LEFT JOIN naics_summary ns ON c.user_id = ns.user_id
LEFT JOIN primary_naics pn ON c.user_id = pn.user_id
LEFT JOIN recent_fy rfy ON c.user_id = rfy.user_id;

-- Facade
CREATE OR REPLACE VIEW analytics_api.contacts_detail AS
SELECT * FROM pipeline_intelligence.report_deck_contact_detail;

-- Grants
GRANT SELECT ON pipeline_intelligence.report_deck_contact_detail TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.contacts_detail TO fpds_analytics_api_readonly;

-- Verification — spot check a known human contact
SELECT user_id, display_name, user_class, career_span_years, active_fiscal_years,
       primary_agency_name, primary_office_name, primary_naics_code,
       distinct_offices, distinct_naics_codes,
       set_aside_action_pct, sole_source_action_pct, small_biz_obligated_pct,
       recent_2fy_actions, recent_2fy_obligated
FROM analytics_api.contacts_detail
WHERE user_class = 'human' AND is_active_recent = true AND name_confidence = 'high'
ORDER BY lifetime_obligated_created DESC NULLS LAST
LIMIT 5;
