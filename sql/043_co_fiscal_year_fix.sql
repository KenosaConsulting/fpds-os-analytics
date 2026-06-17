-- FPDS-022 Fix: Rebuild contact objects with signed_date-derived fiscal year
-- Root cause: fiscal_year column is 99.97% NULL in fpds_actions
-- Fix: derive FY from signed_date (federal FY: Oct=next year)
-- Runs sequentially: drop column → directory → MV A → MV B
-- Protocol: session-pooler, XL compute (16 vCPU), statement_timeout=0

SET statement_timeout = 0;
SET work_mem = '1GB';
SET max_parallel_workers_per_gather = 8;
SET hash_mem_multiplier = 8;

-- ============================================================
-- 0. Drop the misleading fiscal_year column
-- (instant — PG marks dropped, doesn't rewrite table)
-- ============================================================

ALTER TABLE public.fpds_actions DROP COLUMN IF EXISTS fiscal_year;

SELECT 'COLUMN_DROPPED' AS status;

-- ============================================================
-- 1. Rebuild Contact Directory (037 corrected)
--    Derive FY from signed_date instead of fiscal_year
-- ============================================================

DROP TABLE IF EXISTS analytics_dims.fpds_procurement_contact CASCADE;

CREATE TABLE analytics_dims.fpds_procurement_contact AS
WITH creator_stats AS (
    SELECT
        UPPER(TRIM(created_by)) AS user_id,
        COUNT(*) AS actions_created,
        SUM(obligated_amount::NUMERIC) AS obligated_created,
        COUNT(DISTINCT uei) AS distinct_vendors_created,
        COUNT(DISTINCT contracting_dept_id) AS depts_created,
        MIN(CASE WHEN signed_date IS NOT NULL AND signed_date != '' THEN
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
        END) AS first_fy_created,
        MAX(CASE WHEN signed_date IS NOT NULL AND signed_date != '' THEN
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
        END) AS last_fy_created
    FROM public.fpds_actions
    WHERE created_by IS NOT NULL
    GROUP BY UPPER(TRIM(created_by))
),
approver_stats AS (
    SELECT
        UPPER(TRIM(approved_by)) AS user_id,
        COUNT(*) AS actions_approved,
        SUM(obligated_amount::NUMERIC) AS obligated_approved,
        COUNT(DISTINCT uei) AS distinct_vendors_approved,
        COUNT(DISTINCT contracting_dept_id) AS depts_approved,
        MIN(CASE WHEN signed_date IS NOT NULL AND signed_date != '' THEN
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
        END) AS first_fy_approved,
        MAX(CASE WHEN signed_date IS NOT NULL AND signed_date != '' THEN
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
        END) AS last_fy_approved
    FROM public.fpds_actions
    WHERE approved_by IS NOT NULL
    GROUP BY UPPER(TRIM(approved_by))
),
combined AS (
    SELECT
        COALESCE(c.user_id, a.user_id) AS user_id,
        COALESCE(c.actions_created, 0) AS lifetime_actions_created,
        COALESCE(a.actions_approved, 0) AS lifetime_actions_approved,
        COALESCE(c.obligated_created, 0) AS lifetime_obligated_created,
        COALESCE(a.obligated_approved, 0) AS lifetime_obligated_approved,
        COALESCE(c.distinct_vendors_created, 0) AS distinct_vendors_created,
        COALESCE(a.distinct_vendors_approved, 0) AS distinct_vendors_approved,
        LEAST(c.first_fy_created, a.first_fy_approved) AS first_seen_fy,
        GREATEST(c.last_fy_created, a.last_fy_approved) AS last_seen_fy,
        GREATEST(COALESCE(c.depts_created, 0), COALESCE(a.depts_approved, 0)) AS max_depts_span,
        ARRAY_REMOVE(ARRAY[
            CASE WHEN c.user_id IS NOT NULL THEN 'creator' END,
            CASE WHEN a.user_id IS NOT NULL THEN 'approver' END
        ], NULL) AS roles_seen
    FROM creator_stats c
    FULL OUTER JOIN approver_stats a ON c.user_id = a.user_id
)
SELECT
    cm.user_id,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM analytics_dims.fpds_user_classification_rule r
            WHERE cm.user_id ILIKE r.pattern
        ) THEN 'system'
        WHEN cm.max_depts_span > 10 THEN 'system'
        WHEN cm.user_id ~ '^[A-Z]+\.[A-Z]+.*@.*\.(GOV|MIL)$' THEN 'human'
        ELSE 'unknown'
    END AS user_class,
    CASE
        WHEN EXISTS (
            SELECT 1 FROM analytics_dims.fpds_user_classification_rule r
            WHERE cm.user_id ILIKE r.pattern
        ) THEN 'rule'
        WHEN cm.max_depts_span > 10 THEN 'behavioral'
        WHEN cm.user_id ~ '^[A-Z]+\.[A-Z]+.*@.*\.(GOV|MIL)$' THEN 'format'
        ELSE NULL
    END AS class_source,
    CASE
        WHEN cm.user_id ~ '^[A-Z]+\.[A-Z]+.*@' THEN
            INITCAP(
                SPLIT_PART(SPLIT_PART(cm.user_id, '@', 1), '.', 1) || ' ' ||
                SPLIT_PART(SPLIT_PART(cm.user_id, '@', 1), '.', 2)
            )
        ELSE NULL
    END AS display_name,
    CASE WHEN cm.user_id LIKE '%@%' THEN cm.user_id ELSE NULL END AS email,
    CASE
        WHEN cm.user_id ~ '^[A-Z]+\.[A-Z]+.*@.*\.(GOV|MIL)$' THEN 'high'
        WHEN cm.user_id ~ '^[A-Z]+\.[A-Z]+' THEN 'medium'
        ELSE 'low'
    END AS name_confidence,
    cm.roles_seen,
    cm.first_seen_fy,
    cm.last_seen_fy,
    (cm.last_seen_fy >= (EXTRACT(YEAR FROM CURRENT_DATE)::INT - 1)) AS is_active_recent,
    cm.lifetime_actions_created,
    cm.lifetime_actions_approved,
    cm.lifetime_obligated_created,
    cm.lifetime_obligated_approved,
    cm.distinct_vendors_created,
    cm.distinct_vendors_approved,
    cm.max_depts_span,
    0::BIGINT AS max_actions_any_single_fy
FROM combined cm;

ALTER TABLE analytics_dims.fpds_procurement_contact ADD PRIMARY KEY (user_id);
CREATE INDEX idx_contact_user_class ON analytics_dims.fpds_procurement_contact (user_class);
CREATE INDEX idx_contact_active_recent ON analytics_dims.fpds_procurement_contact (is_active_recent) WHERE user_class = 'human';
CREATE INDEX idx_contact_last_seen ON analytics_dims.fpds_procurement_contact (last_seen_fy DESC);

SELECT 'DIRECTORY_PASS1' AS status, COUNT(*) AS total,
       COUNT(*) FILTER (WHERE user_class = 'human') AS humans,
       COUNT(*) FILTER (WHERE user_class = 'system') AS systems,
       COUNT(*) FILTER (WHERE user_class = 'unknown') AS unknowns,
       COUNT(*) FILTER (WHERE last_seen_fy IS NOT NULL) AS has_fy,
       COUNT(*) FILTER (WHERE is_active_recent) AS active_recent
FROM analytics_dims.fpds_procurement_contact;

-- ---- Pass 2: behavioral backstop (same as original 037) ----

WITH per_user_fy AS (
    SELECT user_id, MAX(fy_actions) AS max_fy
    FROM (
        SELECT UPPER(TRIM(created_by)) AS user_id,
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END AS fiscal_year,
            COUNT(*) AS fy_actions
        FROM public.fpds_actions
        WHERE created_by IS NOT NULL
          AND signed_date IS NOT NULL AND signed_date != ''
        GROUP BY UPPER(TRIM(created_by)),
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
        UNION ALL
        SELECT UPPER(TRIM(approved_by)) AS user_id,
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END AS fiscal_year,
            COUNT(*) AS fy_actions
        FROM public.fpds_actions
        WHERE approved_by IS NOT NULL
          AND signed_date IS NOT NULL AND signed_date != ''
        GROUP BY UPPER(TRIM(approved_by)),
            CASE WHEN EXTRACT(MONTH FROM signed_date::DATE) >= 10
                 THEN EXTRACT(YEAR FROM signed_date::DATE)::INT + 1
                 ELSE EXTRACT(YEAR FROM signed_date::DATE)::INT
            END
    ) sub
    GROUP BY user_id
)
UPDATE analytics_dims.fpds_procurement_contact c
SET max_actions_any_single_fy = p.max_fy
FROM per_user_fy p
WHERE c.user_id = p.user_id;

UPDATE analytics_dims.fpds_procurement_contact
SET user_class = 'system',
    class_source = 'behavioral'
WHERE user_class IN ('unknown', 'human')
  AND max_actions_any_single_fy > 5000;

COMMENT ON TABLE analytics_dims.fpds_procurement_contact IS
    'FPDS-022: One row per distinct user identity from created_by/approved_by. '
    'FY derived from signed_date (federal FY: Oct-Sep). '
    'Classified as human/system/unknown via pattern rules + behavioral backstop + format heuristic.';

SELECT 'DIRECTORY_COMPLETE' AS status,
       COUNT(*) FILTER (WHERE user_class = 'human') AS humans,
       COUNT(*) FILTER (WHERE user_class = 'system') AS systems,
       COUNT(*) FILTER (WHERE user_class = 'unknown') AS unknowns,
       COUNT(*) FILTER (WHERE is_active_recent AND user_class = 'human') AS active_recent_humans,
       MIN(last_seen_fy) FILTER (WHERE user_class = 'human') AS min_human_fy,
       MAX(last_seen_fy) FILTER (WHERE user_class = 'human') AS max_human_fy
FROM analytics_dims.fpds_procurement_contact;

-- ============================================================
-- 2. Rebuild MV A — Contact × Office × FY (038 corrected)
-- ============================================================

DROP MATERIALIZED VIEW IF EXISTS customer_intelligence.mv_fpds_contact_office_fy CASCADE;

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_contact_office_fy AS
WITH creator_office AS (
    SELECT
        UPPER(TRIM(a.created_by)) AS user_id,
        'creator' AS role,
        a.contracting_dept_id,
        a.contracting_dept_name,
        a.contracting_agency_id,
        a.contracting_agency_name,
        a.contracting_office_id,
        a.contracting_office_name,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END AS fiscal_year,
        COUNT(*) AS action_count,
        SUM(a.obligated_amount::NUMERIC) AS obligated_amount,
        COUNT(DISTINCT a.uei) AS distinct_vendor_count,
        SUM(CASE WHEN a.contracting_officer_business_size_determination = 'S'
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS small_biz_obligated,
        COUNT(*) FILTER (WHERE a.set_aside IS NOT NULL AND a.set_aside != '') AS set_aside_action_count,
        COUNT(*) FILTER (WHERE a.extent_competed IN ('G', 'H', 'J')
            OR a.extent_competed IS NULL
            OR a.extent_competed = '') AS sole_source_action_count
    FROM public.fpds_actions a
    WHERE a.created_by IS NOT NULL
      AND a.signed_date IS NOT NULL AND a.signed_date != ''
    GROUP BY
        UPPER(TRIM(a.created_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.contracting_office_id, a.contracting_office_name,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END
),
approver_office AS (
    SELECT
        UPPER(TRIM(a.approved_by)) AS user_id,
        'approver' AS role,
        a.contracting_dept_id,
        a.contracting_dept_name,
        a.contracting_agency_id,
        a.contracting_agency_name,
        a.contracting_office_id,
        a.contracting_office_name,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END AS fiscal_year,
        COUNT(*) AS action_count,
        SUM(a.obligated_amount::NUMERIC) AS obligated_amount,
        COUNT(DISTINCT a.uei) AS distinct_vendor_count,
        SUM(CASE WHEN a.contracting_officer_business_size_determination = 'S'
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS small_biz_obligated,
        COUNT(*) FILTER (WHERE a.set_aside IS NOT NULL AND a.set_aside != '') AS set_aside_action_count,
        COUNT(*) FILTER (WHERE a.extent_competed IN ('G', 'H', 'J')
            OR a.extent_competed IS NULL
            OR a.extent_competed = '') AS sole_source_action_count
    FROM public.fpds_actions a
    WHERE a.approved_by IS NOT NULL
      AND a.signed_date IS NOT NULL AND a.signed_date != ''
    GROUP BY
        UPPER(TRIM(a.approved_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.contracting_office_id, a.contracting_office_name,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END
)
SELECT
    v.user_id,
    c.user_class,
    c.display_name,
    c.email,
    v.role,
    v.contracting_dept_id,
    v.contracting_dept_name,
    v.contracting_agency_id,
    v.contracting_agency_name,
    v.contracting_office_id,
    v.contracting_office_name,
    v.fiscal_year,
    v.action_count,
    v.obligated_amount,
    v.distinct_vendor_count,
    v.small_biz_obligated,
    v.set_aside_action_count,
    v.sole_source_action_count
FROM (
    SELECT * FROM creator_office
    UNION ALL
    SELECT * FROM approver_office
) v
JOIN analytics_dims.fpds_procurement_contact c ON c.user_id = v.user_id;

CREATE INDEX idx_mv_contact_office_fy_user ON customer_intelligence.mv_fpds_contact_office_fy (user_id);
CREATE INDEX idx_mv_contact_office_fy_class ON customer_intelligence.mv_fpds_contact_office_fy (user_class);
CREATE INDEX idx_mv_contact_office_fy_office ON customer_intelligence.mv_fpds_contact_office_fy (contracting_office_id);
CREATE INDEX idx_mv_contact_office_fy_agency ON customer_intelligence.mv_fpds_contact_office_fy (contracting_agency_id);
CREATE INDEX idx_mv_contact_office_fy_dept ON customer_intelligence.mv_fpds_contact_office_fy (contracting_dept_id);
CREATE INDEX idx_mv_contact_office_fy_fy ON customer_intelligence.mv_fpds_contact_office_fy (fiscal_year);
CREATE INDEX idx_mv_contact_office_fy_human_active ON customer_intelligence.mv_fpds_contact_office_fy (contracting_agency_id, fiscal_year) WHERE user_class = 'human';

SELECT 'MV_A_COMPLETE' AS status, COUNT(*) AS total_rows,
       COUNT(DISTINCT user_id) AS distinct_contacts,
       COUNT(*) FILTER (WHERE user_class = 'human') AS human_rows,
       MIN(fiscal_year) AS min_fy, MAX(fiscal_year) AS max_fy
FROM customer_intelligence.mv_fpds_contact_office_fy;

-- ============================================================
-- 3. Rebuild MV B — Contact × NAICS × Agency × FY (039 corrected)
-- ============================================================

DROP MATERIALIZED VIEW IF EXISTS customer_intelligence.mv_fpds_contact_naics_agency_fy CASCADE;

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_contact_naics_agency_fy AS
WITH creator_naics AS (
    SELECT
        UPPER(TRIM(a.created_by)) AS user_id,
        a.contracting_dept_id,
        a.contracting_dept_name,
        a.contracting_agency_id,
        a.contracting_agency_name,
        a.principal_naics_code,
        LEFT(a.principal_naics_code, 4) AS naics_group,
        LEFT(a.principal_naics_code, 2) AS naics_sector,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END AS fiscal_year,
        COUNT(*) AS action_count,
        SUM(a.obligated_amount::NUMERIC) AS obligated_amount,
        COUNT(DISTINCT a.uei) AS distinct_vendor_count,
        SUM(CASE WHEN a.set_aside IS NOT NULL AND a.set_aside != ''
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS set_aside_obligated,
        SUM(CASE WHEN a.extent_competed IN ('G', 'H', 'J')
            OR a.extent_competed IS NULL OR a.extent_competed = ''
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS sole_source_obligated
    FROM public.fpds_actions a
    WHERE a.created_by IS NOT NULL
      AND a.principal_naics_code IS NOT NULL
      AND a.principal_naics_code != ''
      AND a.signed_date IS NOT NULL AND a.signed_date != ''
    GROUP BY
        UPPER(TRIM(a.created_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.principal_naics_code,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END
),
approver_naics AS (
    SELECT
        UPPER(TRIM(a.approved_by)) AS user_id,
        a.contracting_dept_id,
        a.contracting_dept_name,
        a.contracting_agency_id,
        a.contracting_agency_name,
        a.principal_naics_code,
        LEFT(a.principal_naics_code, 4) AS naics_group,
        LEFT(a.principal_naics_code, 2) AS naics_sector,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END AS fiscal_year,
        COUNT(*) AS action_count,
        SUM(a.obligated_amount::NUMERIC) AS obligated_amount,
        COUNT(DISTINCT a.uei) AS distinct_vendor_count,
        SUM(CASE WHEN a.set_aside IS NOT NULL AND a.set_aside != ''
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS set_aside_obligated,
        SUM(CASE WHEN a.extent_competed IN ('G', 'H', 'J')
            OR a.extent_competed IS NULL OR a.extent_competed = ''
            THEN a.obligated_amount::NUMERIC ELSE 0 END) AS sole_source_obligated
    FROM public.fpds_actions a
    WHERE a.approved_by IS NOT NULL
      AND a.principal_naics_code IS NOT NULL
      AND a.principal_naics_code != ''
      AND a.signed_date IS NOT NULL AND a.signed_date != ''
    GROUP BY
        UPPER(TRIM(a.approved_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.principal_naics_code,
        CASE WHEN EXTRACT(MONTH FROM a.signed_date::DATE) >= 10
             THEN EXTRACT(YEAR FROM a.signed_date::DATE)::INT + 1
             ELSE EXTRACT(YEAR FROM a.signed_date::DATE)::INT
        END
)
SELECT
    v.user_id,
    c.user_class,
    c.display_name,
    c.email,
    v.contracting_dept_id,
    v.contracting_dept_name,
    v.contracting_agency_id,
    v.contracting_agency_name,
    v.principal_naics_code,
    v.naics_group,
    v.naics_sector,
    v.fiscal_year,
    v.action_count,
    v.obligated_amount,
    v.distinct_vendor_count,
    v.set_aside_obligated,
    v.sole_source_obligated
FROM (
    SELECT * FROM creator_naics
    UNION ALL
    SELECT * FROM approver_naics
) v
JOIN analytics_dims.fpds_procurement_contact c ON c.user_id = v.user_id;

CREATE INDEX idx_mv_contact_naics_user ON customer_intelligence.mv_fpds_contact_naics_agency_fy (user_id);
CREATE INDEX idx_mv_contact_naics_class ON customer_intelligence.mv_fpds_contact_naics_agency_fy (user_class);
CREATE INDEX idx_mv_contact_naics_agency ON customer_intelligence.mv_fpds_contact_naics_agency_fy (contracting_agency_id);
CREATE INDEX idx_mv_contact_naics_dept ON customer_intelligence.mv_fpds_contact_naics_agency_fy (contracting_dept_id);
CREATE INDEX idx_mv_contact_naics_code ON customer_intelligence.mv_fpds_contact_naics_agency_fy (principal_naics_code);
CREATE INDEX idx_mv_contact_naics_group ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_group);
CREATE INDEX idx_mv_contact_naics_sector ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_sector);
CREATE INDEX idx_mv_contact_naics_fy ON customer_intelligence.mv_fpds_contact_naics_agency_fy (fiscal_year);
CREATE INDEX idx_mv_contact_naics_human_naics ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_group, contracting_agency_id) WHERE user_class = 'human';

SELECT 'MV_B_COMPLETE' AS status, COUNT(*) AS total_rows,
       COUNT(DISTINCT user_id) AS distinct_contacts,
       COUNT(*) FILTER (WHERE user_class = 'human') AS human_rows,
       COUNT(DISTINCT principal_naics_code) AS distinct_naics,
       MIN(fiscal_year) AS min_fy, MAX(fiscal_year) AS max_fy
FROM customer_intelligence.mv_fpds_contact_naics_agency_fy;

-- ============================================================
-- 4. Re-apply views/facades/grants (042 + 042b depend on rebuilt MVs)
--    CASCADE drops on the MVs killed the views — recreate them
-- ============================================================

-- 042 views (abbreviated — same definitions, just need to exist again)
\i /Users/kalosa-kenyon/code/fpds-os-analytics/sql/042_co_report_views_facades_grants.sql
\i /Users/kalosa-kenyon/code/fpds-os-analytics/sql/042b_co_contact_detail_view.sql

-- ============================================================
-- 5. Final verification
-- ============================================================

SELECT 'REBUILD_COMPLETE' AS status, now() AS completed_at;
