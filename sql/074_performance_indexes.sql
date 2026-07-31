-- 074_performance_indexes.sql
-- Performance indexes for recompete watchlist and market queries.
-- MUST be run in Supabase SQL Editor (https://supabase.com/dashboard/project/tfrhforjvaafmqmxmtrt)
-- NOT via pooler / MCP / psql pooler connection.
--
-- Run this entire script in one go. The MVs are read-only between refreshes
-- so non-concurrent index builds are safe (brief shared lock only).
--
-- Estimated runtime: 5-15 minutes (most of it on the 18GB contract_family MV).

-- 1. Clean up any invalid leftovers from failed concurrent builds
DROP INDEX IF EXISTS pipeline_intelligence.mv_contract_family_active_idx;
DROP INDEX IF EXISTS naics_breakdown.mv_naics_agency_office_fy_dept_only_idx;

-- 2. Partial index on contract_family covering the exact WHERE clause
--    of the recompete watchlist report view. Only indexes "active" rows
--    (remaining_months in range, positive obligations, valid completion date).
--    This should be ~2-3M rows instead of 69M.
CREATE INDEX mv_contract_family_active_idx
ON pipeline_intelligence.mv_contract_family (contracting_dept_id, remaining_months)
WHERE remaining_months >= -6 AND remaining_months <= 24
  AND total_obligated > 25000 AND current_completion_date IS NOT NULL;

-- 3. Standalone dept_id index so the planner can narrow by department
--    without requiring a fiscal_year filter on market.agency_naics_fy.
CREATE INDEX mv_naics_agency_office_fy_dept_only_idx
ON naics_breakdown.mv_fpds_naics_agency_office_fy (contracting_dept_id);

-- 4. Verify
SELECT indexrelid::regclass, indisvalid
FROM pg_index
WHERE indexrelid::regclass::text IN (
    'pipeline_intelligence.mv_contract_family_active_idx',
    'naics_breakdown.mv_naics_agency_office_fy_dept_only_idx'
);
-- Both should show indisvalid = true
