-- 049_topic_intel_mv_psc_decomp.sql
-- Topic Intelligence Package — Phase 2b: PSC Decomposition MV
--
-- One PSC code → many topics. Same principle as NAICS decomposition
-- but for product/service codes.
-- "Within PSC D302 (IT Systems Development), here are the actual sub-markets."
--
-- Enriched with fpds_psc_map dimensions: psc_category_label, psc_group
-- (Services/Products/R&D/Construction).
--
-- Grain: psc_code × department_code × contracting_office_id × topic
--
-- Run: nohup psql $CONN -f sql/049_topic_intel_mv_psc_decomp.sql > /tmp/049_psc_decomp.log 2>&1 &
-- Expected duration: 15-45 minutes
-- Verify: SELECT count(*) FROM topic_intelligence.mv_psc_decomposition;
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §2b
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 049: Building mv_psc_decomposition ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_psc_decomposition CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_psc_decomposition AS
SELECT
  -- PSC dimension
  pa.psc_code,
  COALESCE(ps.psc_description, pa.psc_description) AS psc_description,
  COALESCE(ps.psc_category_label, 'Unknown') AS psc_category,
  COALESCE(ps.psc_group, 'Unknown') AS psc_group,
  -- USASpending org
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
  -- Metrics
  count(*) AS assignment_count,
  sum(pa.total_obligated_amount) AS total_obligated,
  round(
    100.0 * count(*) / SUM(count(*)) OVER (PARTITION BY pa.psc_code, ta.department_code),
    2
  ) AS psc_topic_share,
  tl.document_count
FROM v2.topic_assignments ta
JOIN public.prime_awards pa
  ON ta.department_code = pa.department_code
  AND ta.record_id = pa.id
LEFT JOIN analytics_dims.fpds_psc_map ps
  ON pa.psc_code = ps.psc_code
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
  AND pa.psc_code IS NOT NULL
GROUP BY
  pa.psc_code,
  COALESCE(ps.psc_description, pa.psc_description),
  COALESCE(ps.psc_category_label, 'Unknown'),
  COALESCE(ps.psc_group, 'Unknown'),
  ta.department_code,
  COALESCE(om.contracting_dept_id, 'UNKNOWN'),
  COALESCE(dm.department_name, pa.awarding_agency_name),
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code),
  COALESCE(am.agency_name, pa.awarding_agency_name),
  pa.awarding_office_code,
  COALESCE(om.contracting_office_name, pa.awarding_office_name),
  ta.merged_model_id, ta.merged_topic_id,
  tl.label, tl.document_count;

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_psc_decomp_psc
  ON topic_intelligence.mv_psc_decomposition (psc_code);

CREATE INDEX idx_psc_decomp_dept
  ON topic_intelligence.mv_psc_decomposition (department_code);

CREATE INDEX idx_psc_decomp_fpds_dept
  ON topic_intelligence.mv_psc_decomposition (contracting_dept_id);

CREATE INDEX idx_psc_decomp_fpds_office
  ON topic_intelligence.mv_psc_decomposition (contracting_office_id);

CREATE INDEX idx_psc_decomp_psc_dept
  ON topic_intelligence.mv_psc_decomposition (psc_code, department_code);

CREATE INDEX idx_psc_decomp_psc_group
  ON topic_intelligence.mv_psc_decomposition (psc_group);

CREATE INDEX idx_psc_decomp_model_topic
  ON topic_intelligence.mv_psc_decomposition (model_id, topic_id);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_psc_decomposition TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT psc_code) AS distinct_psc,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT contracting_office_id) AS offices,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics
FROM topic_intelligence.mv_psc_decomposition;

\echo ''
\echo 'By PSC group:'
SELECT psc_group, count(*) AS rows, count(DISTINCT psc_code) AS psc_codes,
  count(DISTINCT (model_id, topic_id)) AS topics
FROM topic_intelligence.mv_psc_decomposition
GROUP BY psc_group
ORDER BY rows DESC;

\echo 'End time:'
SELECT now();
\echo '=== 049: COMPLETE ==='
