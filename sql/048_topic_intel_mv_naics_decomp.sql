-- 048_topic_intel_mv_naics_decomp.sql
-- Topic Intelligence Package — Phase 2a: NAICS Decomposition MV
--
-- One NAICS code → many topics. The signature differentiation view.
-- "Within NAICS 541512 at Army, here are the actual sub-markets."
--
-- Grain: naics_code × department_code × contracting_office_id × topic
-- FPDS hierarchy derived through fpds_contracting_office_map.
--
-- Run: nohup psql $CONN -f sql/048_topic_intel_mv_naics_decomp.sql > /tmp/048_naics_decomp.log 2>&1 &
-- Expected duration: 15-45 minutes (joins 12M awards assignments to prime_awards + dims)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_naics_decomposition;
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §2a
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 048: Building mv_naics_decomposition ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_naics_decomposition CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_naics_decomposition AS
SELECT
  -- NAICS dimension
  pa.naics_code,
  max(pa.naics_description) AS naics_description,
  -- USASpending org (topic model boundary)
  ta.department_code,
  -- FPDS org hierarchy
  COALESCE(om.contracting_dept_id, 'UNKNOWN') AS contracting_dept_id,
  COALESCE(dm.department_name, pa.awarding_agency_name) AS contracting_dept_name,
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code) AS contracting_agency_id,
  COALESCE(am.agency_name, pa.awarding_agency_name) AS contracting_agency_name,
  pa.awarding_office_code AS contracting_office_id,
  COALESCE(om.contracting_office_name, pa.awarding_office_name) AS contracting_office_name,
  -- Topic identity
  ta.merged_model_id AS model_id,
  ta.merged_topic_id AS topic_id,
  tl.label AS topic_label,
  tl.description AS topic_description,
  -- Metrics
  count(*) AS assignment_count,
  sum(pa.total_obligated_amount) AS total_obligated,
  round(
    100.0 * count(*) / SUM(count(*)) OVER (PARTITION BY pa.naics_code, ta.department_code),
    2
  ) AS naics_topic_share,
  tl.document_count
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
  AND pa.naics_code IS NOT NULL
GROUP BY
  pa.naics_code,
  ta.department_code,
  COALESCE(om.contracting_dept_id, 'UNKNOWN'),
  COALESCE(dm.department_name, pa.awarding_agency_name),
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code),
  COALESCE(am.agency_name, pa.awarding_agency_name),
  pa.awarding_office_code,
  COALESCE(om.contracting_office_name, pa.awarding_office_name),
  ta.merged_model_id, ta.merged_topic_id,
  tl.label, tl.description, tl.document_count;

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_naics_decomp_naics
  ON topic_intelligence.mv_naics_decomposition (naics_code);

CREATE INDEX idx_naics_decomp_dept
  ON topic_intelligence.mv_naics_decomposition (department_code);

CREATE INDEX idx_naics_decomp_fpds_dept
  ON topic_intelligence.mv_naics_decomposition (contracting_dept_id);

CREATE INDEX idx_naics_decomp_fpds_office
  ON topic_intelligence.mv_naics_decomposition (contracting_office_id);

CREATE INDEX idx_naics_decomp_naics_dept
  ON topic_intelligence.mv_naics_decomposition (naics_code, department_code);

CREATE INDEX idx_naics_decomp_model_topic
  ON topic_intelligence.mv_naics_decomposition (model_id, topic_id);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_naics_decomposition TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT naics_code) AS distinct_naics,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT contracting_office_id) AS offices,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics
FROM topic_intelligence.mv_naics_decomposition;

\echo ''
\echo 'Top 5 NAICS by topic diversity:'
SELECT naics_code, naics_description,
  count(DISTINCT (model_id, topic_id)) AS topic_count,
  sum(assignment_count) AS total_assignments
FROM topic_intelligence.mv_naics_decomposition
GROUP BY naics_code, naics_description
ORDER BY topic_count DESC
LIMIT 5;

\echo 'End time:'
SELECT now();
\echo '=== 048: COMPLETE ==='
