-- FPDS-022 Step 3b: MV B — Contact × NAICS × Agency × FY
-- Grain: user_id × dept × agency × NAICS (6-digit + 4-digit group + 2-digit sector) × FY
-- Full dimensional hierarchy, full FY range
-- Source: public.fpds_actions joined to analytics_dims.fpds_procurement_contact
-- Protocol: session-pooler, statement_timeout=0

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

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
        a.fiscal_year::INT AS fiscal_year,
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
    GROUP BY
        UPPER(TRIM(a.created_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.principal_naics_code,
        a.fiscal_year
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
        a.fiscal_year::INT AS fiscal_year,
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
    GROUP BY
        UPPER(TRIM(a.approved_by)),
        a.contracting_dept_id, a.contracting_dept_name,
        a.contracting_agency_id, a.contracting_agency_name,
        a.principal_naics_code,
        a.fiscal_year
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

-- Indexes
CREATE INDEX idx_mv_contact_naics_user ON customer_intelligence.mv_fpds_contact_naics_agency_fy (user_id);
CREATE INDEX idx_mv_contact_naics_class ON customer_intelligence.mv_fpds_contact_naics_agency_fy (user_class);
CREATE INDEX idx_mv_contact_naics_agency ON customer_intelligence.mv_fpds_contact_naics_agency_fy (contracting_agency_id);
CREATE INDEX idx_mv_contact_naics_dept ON customer_intelligence.mv_fpds_contact_naics_agency_fy (contracting_dept_id);
CREATE INDEX idx_mv_contact_naics_code ON customer_intelligence.mv_fpds_contact_naics_agency_fy (principal_naics_code);
CREATE INDEX idx_mv_contact_naics_group ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_group);
CREATE INDEX idx_mv_contact_naics_sector ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_sector);
CREATE INDEX idx_mv_contact_naics_fy ON customer_intelligence.mv_fpds_contact_naics_agency_fy (fiscal_year);
CREATE INDEX idx_mv_contact_naics_human_naics ON customer_intelligence.mv_fpds_contact_naics_agency_fy (naics_group, contracting_agency_id) WHERE user_class = 'human';

-- Row count checkpoint
SELECT 'MV_B_COMPLETE' AS status, COUNT(*) AS total_rows,
       COUNT(DISTINCT user_id) AS distinct_contacts,
       COUNT(*) FILTER (WHERE user_class = 'human') AS human_rows,
       COUNT(DISTINCT principal_naics_code) AS distinct_naics,
       COUNT(DISTINCT naics_group) AS distinct_naics_groups,
       MIN(fiscal_year) AS min_fy, MAX(fiscal_year) AS max_fy
FROM customer_intelligence.mv_fpds_contact_naics_agency_fy;
