-- FPDS-022 Step 3a: MV A — Contact × Office × FY
-- Grain: user_id × dept × agency × office × FY × role
-- Full dimensional hierarchy, full FY range
-- Source: public.fpds_actions joined to analytics_dims.fpds_procurement_contact
-- Protocol: session-pooler, statement_timeout=0

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

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
        a.fiscal_year::INT AS fiscal_year,
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
    GROUP BY
        UPPER(TRIM(a.created_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.contracting_office_id, a.contracting_office_name,
        a.fiscal_year
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
        a.fiscal_year::INT AS fiscal_year,
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
    GROUP BY
        UPPER(TRIM(a.approved_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.contracting_office_id, a.contracting_office_name,
        a.fiscal_year
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

-- Indexes
CREATE INDEX idx_mv_contact_office_fy_user ON customer_intelligence.mv_fpds_contact_office_fy (user_id);
CREATE INDEX idx_mv_contact_office_fy_class ON customer_intelligence.mv_fpds_contact_office_fy (user_class);
CREATE INDEX idx_mv_contact_office_fy_office ON customer_intelligence.mv_fpds_contact_office_fy (contracting_office_id);
CREATE INDEX idx_mv_contact_office_fy_agency ON customer_intelligence.mv_fpds_contact_office_fy (contracting_agency_id);
CREATE INDEX idx_mv_contact_office_fy_dept ON customer_intelligence.mv_fpds_contact_office_fy (contracting_dept_id);
CREATE INDEX idx_mv_contact_office_fy_fy ON customer_intelligence.mv_fpds_contact_office_fy (fiscal_year);
CREATE INDEX idx_mv_contact_office_fy_human_active ON customer_intelligence.mv_fpds_contact_office_fy (contracting_agency_id, fiscal_year) WHERE user_class = 'human';

-- Row count checkpoint
SELECT 'MV_A_COMPLETE' AS status, COUNT(*) AS total_rows,
       COUNT(DISTINCT user_id) AS distinct_contacts,
       COUNT(*) FILTER (WHERE user_class = 'human') AS human_rows,
       MIN(fiscal_year) AS min_fy, MAX(fiscal_year) AS max_fy
FROM customer_intelligence.mv_fpds_contact_office_fy;
