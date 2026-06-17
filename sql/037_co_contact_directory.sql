-- FPDS-022 Step 2: Procurement Contact Directory (two-pass build)
-- Pass 1: Build directory via hash aggregation (no window functions)
-- Pass 2: Compute behavioral backstop metric separately, UPDATE in
--
-- Source: public.fpds_actions (98.7M rows)
-- Protocol: session-pooler, statement_timeout=0, sequential

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

-- ============================================================
-- Pass 1: Build directory — simple GROUP BY, no window functions
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
        MIN(fiscal_year::INT) AS first_fy_created,
        MAX(fiscal_year::INT) AS last_fy_created
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
        MIN(fiscal_year::INT) AS first_fy_approved,
        MAX(fiscal_year::INT) AS last_fy_approved
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

    -- Classification placeholder — behavioral backstop applied in Pass 2
    -- For now: rule match and dept-span backstop only (no per-FY metric yet)
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

    -- Display name from email-format IDs
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

    -- Placeholder for Pass 2
    0::BIGINT AS max_actions_any_single_fy

FROM combined cm;

-- ============================================================
-- PK + indexes after Pass 1
-- ============================================================
ALTER TABLE analytics_dims.fpds_procurement_contact ADD PRIMARY KEY (user_id);
CREATE INDEX idx_contact_user_class ON analytics_dims.fpds_procurement_contact (user_class);
CREATE INDEX idx_contact_active_recent ON analytics_dims.fpds_procurement_contact (is_active_recent) WHERE user_class = 'human';
CREATE INDEX idx_contact_last_seen ON analytics_dims.fpds_procurement_contact (last_seen_fy DESC);

-- Pass 1 checkpoint
SELECT 'PASS_1_COMPLETE' AS status, COUNT(*) AS total_contacts,
       COUNT(*) FILTER (WHERE user_class = 'human') AS humans,
       COUNT(*) FILTER (WHERE user_class = 'system') AS systems,
       COUNT(*) FILTER (WHERE user_class = 'unknown') AS unknowns
FROM analytics_dims.fpds_procurement_contact;

-- ============================================================
-- Pass 2: Compute max actions per single FY (behavioral backstop)
-- Simple GROUP BY — no window functions
-- ============================================================

WITH per_user_fy AS (
    SELECT user_id, MAX(fy_actions) AS max_fy
    FROM (
        SELECT UPPER(TRIM(created_by)) AS user_id, fiscal_year, COUNT(*) AS fy_actions
        FROM public.fpds_actions
        WHERE created_by IS NOT NULL
        GROUP BY UPPER(TRIM(created_by)), fiscal_year
        UNION ALL
        SELECT UPPER(TRIM(approved_by)) AS user_id, fiscal_year, COUNT(*) AS fy_actions
        FROM public.fpds_actions
        WHERE approved_by IS NOT NULL
        GROUP BY UPPER(TRIM(approved_by)), fiscal_year
    ) sub
    GROUP BY user_id
)
UPDATE analytics_dims.fpds_procurement_contact c
SET max_actions_any_single_fy = p.max_fy
FROM per_user_fy p
WHERE c.user_id = p.user_id;

-- ============================================================
-- Pass 2b: Reclassify using the now-populated behavioral backstop
-- Any unknown/human with >5000 actions in a single FY → system
-- ============================================================

UPDATE analytics_dims.fpds_procurement_contact
SET user_class = 'system',
    class_source = 'behavioral'
WHERE user_class IN ('unknown', 'human')
  AND max_actions_any_single_fy > 5000;

-- ============================================================
-- Final verification
-- ============================================================

COMMENT ON TABLE analytics_dims.fpds_procurement_contact IS
    'FPDS-022: One row per distinct user identity from created_by/approved_by. '
    'Classified as human/system/unknown via pattern rules + behavioral backstop + format heuristic.';

SELECT user_class, class_source, COUNT(*) AS users,
       SUM(lifetime_actions_created + lifetime_actions_approved) AS total_actions
FROM analytics_dims.fpds_procurement_contact
GROUP BY user_class, class_source
ORDER BY user_class, class_source;
