-- 046_topic_intel_mv_agency_profile.sql
-- Topic Intelligence Package — Phase 1b: Agency Profile MV
--
-- Department × merged topic with office-level grain and FPDS org hierarchy.
-- Primary dimension: USASpending department_code (topic model boundary).
-- FPDS hierarchy (contracting_dept_id, contracting_agency_id, contracting_office_id)
-- derived through fpds_contracting_office_map for cross-analytics compatibility.
--
-- Run: nohup psql $CONN -f sql/046_topic_intel_mv_agency_profile.sql > /tmp/046_agency_profile.log 2>&1 &
-- Expected duration: 15-30 minutes (joins 12M awards assignments to 24.5M prime_awards + 3 dim lookups)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_agency_profile;
--         Expected: tens of thousands of rows (office × topic combinations)
--
-- Depends on: 044 (schema), 045 (catalog — no hard dependency, but logical ordering)
-- Reference: Build Spec v1.1 §1b
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 046: Building mv_agency_profile ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_agency_profile CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_agency_profile AS
SELECT
  -- USASpending org (topic model boundary)
  ta.department_code,
  -- FPDS org hierarchy (cross-analytics compatible)
  COALESCE(om.contracting_dept_id, 'UNKNOWN') AS contracting_dept_id,
  COALESCE(dm.department_name, pa.awarding_agency_name, 'Unknown') AS contracting_dept_name,
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code) AS contracting_agency_id,
  COALESCE(am.agency_name, pa.awarding_agency_name) AS contracting_agency_name,
  pa.awarding_office_code AS contracting_office_id,
  COALESCE(om.contracting_office_name, pa.awarding_office_name) AS contracting_office_name,
  -- Topic identity
  ta.merged_model_id AS model_id,
  ta.merged_topic_id AS topic_id,
  tl.label AS topic_label,
  tl.description AS topic_description,
  tl.naics_alignment,
  -- Metrics
  count(*) AS assignment_count,
  count(*) FILTER (WHERE ta.corpus_type = 'awards') AS awards_count,
  count(*) FILTER (WHERE ta.corpus_type = 'sam') AS sam_count,
  sum(pa.total_obligated_amount) AS total_obligated,
  round(
    100.0 * count(*) / SUM(count(*)) OVER (PARTITION BY ta.department_code),
    2
  ) AS topic_share,
  rank() OVER (
    PARTITION BY ta.department_code
    ORDER BY count(*) DESC
  ) AS rank
FROM v2.topic_assignments ta
JOIN public.prime_awards pa
  ON ta.department_code = pa.department_code
  AND ta.record_id = pa.id
LEFT JOIN analytics_dims.fpds_contracting_office_map om
  ON pa.awarding_office_code = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_department_map dm
  ON om.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON om.contracting_agency_id = am.agency_id
JOIN v2.topic_labels tl
  ON ta.merged_model_id = tl.model_id
  AND ta.merged_topic_id = tl.topic_id
WHERE ta.corpus_type = 'awards'
  AND ta.merged_topic_id IS NOT NULL
  AND tl.corpus_type = 'merged'
GROUP BY
  ta.department_code,
  COALESCE(om.contracting_dept_id, 'UNKNOWN'),
  COALESCE(dm.department_name, pa.awarding_agency_name, 'Unknown'),
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code),
  COALESCE(am.agency_name, pa.awarding_agency_name),
  pa.awarding_office_code,
  COALESCE(om.contracting_office_name, pa.awarding_office_name),
  ta.merged_model_id,
  ta.merged_topic_id,
  tl.label,
  tl.description,
  tl.naics_alignment;

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_agency_profile_dept
  ON topic_intelligence.mv_agency_profile (department_code);

CREATE INDEX idx_agency_profile_fpds_dept
  ON topic_intelligence.mv_agency_profile (contracting_dept_id);

CREATE INDEX idx_agency_profile_fpds_agency
  ON topic_intelligence.mv_agency_profile (contracting_agency_id);

CREATE INDEX idx_agency_profile_fpds_office
  ON topic_intelligence.mv_agency_profile (contracting_office_id);

CREATE INDEX idx_agency_profile_model_topic
  ON topic_intelligence.mv_agency_profile (model_id, topic_id);

CREATE INDEX idx_agency_profile_dept_rank
  ON topic_intelligence.mv_agency_profile (department_code, rank);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_agency_profile TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS usa_departments,
  count(DISTINCT contracting_dept_id) AS fpds_departments,
  count(DISTINCT contracting_office_id) AS distinct_offices,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  round(sum(total_obligated) / 1e9, 1) AS total_obligated_billions,
  min(rank) AS min_rank,
  max(rank) AS max_rank
FROM topic_intelligence.mv_agency_profile;

\echo ''
\echo 'Top 5 departments by topic count:'
SELECT department_code, count(DISTINCT topic_id) AS topic_count, sum(assignment_count) AS total_assignments
FROM topic_intelligence.mv_agency_profile
GROUP BY department_code
ORDER BY topic_count DESC
LIMIT 5;

\echo 'End time:'
SELECT now();
\echo '=== 046: COMPLETE ==='
