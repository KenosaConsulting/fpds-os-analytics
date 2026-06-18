-- 050_topic_intel_mv_set_aside.sql
-- Topic Intelligence Package — Phase 2c: Set-Aside Profile MV
--
-- How do topics intersect with socioeconomic set-aside programs?
-- "In the Zero Trust topic at Army, 40% is set-aside for small business,
--  60% is full-and-open."
--
-- ⚠️ PERFORMANCE NOTE: Set-aside for awards requires jsonb extraction
-- (raw_payload->>'type_of_set_aside_code') on the prime_awards join.
-- This is the SLOWEST decomposition build — expect 30-90 minutes.
-- No workaround: set-aside is not a top-level column on prime_awards.
--
-- Set-aside codes normalized through analytics_dims.fpds_set_aside_code_map
-- into family groups (Small business, 8(a), HUBZone, SDVOSB, WOSB, etc.).
--
-- Grain: department_code × contracting_office_id × topic × set_aside_family
--
-- Run: nohup psql $CONN -f sql/050_topic_intel_mv_set_aside.sql > /tmp/050_set_aside.log 2>&1 &
-- Expected duration: 30-90 minutes (jsonb extraction overhead)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_set_aside_profile;
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §2c
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 050: Building mv_set_aside_profile ==='
\echo '⚠️  This is the slowest decomposition build (jsonb extraction). Expect 30-90 min.'
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_set_aside_profile CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_set_aside_profile AS
SELECT
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
  -- Set-aside dimension (normalized through dim table)
  COALESCE(
    sa_map.family,
    CASE
      WHEN pa.raw_payload->>'type_of_set_aside_code' IS NULL THEN 'Unknown'
      WHEN pa.raw_payload->>'type_of_set_aside_code' IN ('NONE', '') THEN 'No set aside'
      ELSE pa.raw_payload->>'type_of_set_aside'
    END
  ) AS set_aside_family,
  pa.raw_payload->>'type_of_set_aside_code' AS set_aside_code,
  COALESCE(sa_map.is_positive_set_aside, false) AS is_positive_set_aside,
  -- Metrics
  count(*) AS assignment_count,
  round(
    100.0 * count(*) / SUM(count(*)) OVER (
      PARTITION BY ta.department_code, ta.merged_model_id, ta.merged_topic_id
    ),
    2
  ) AS set_aside_share,
  sum(pa.total_obligated_amount) AS obligated_amount
FROM v2.topic_assignments ta
JOIN public.prime_awards pa
  ON ta.department_code = pa.department_code
  AND ta.record_id = pa.id
LEFT JOIN analytics_dims.fpds_set_aside_code_map sa_map
  ON pa.raw_payload->>'type_of_set_aside_code' = sa_map.raw_code
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
  COALESCE(dm.department_name, pa.awarding_agency_name),
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code),
  COALESCE(am.agency_name, pa.awarding_agency_name),
  pa.awarding_office_code,
  COALESCE(om.contracting_office_name, pa.awarding_office_name),
  ta.merged_model_id, ta.merged_topic_id, tl.label,
  COALESCE(
    sa_map.family,
    CASE
      WHEN pa.raw_payload->>'type_of_set_aside_code' IS NULL THEN 'Unknown'
      WHEN pa.raw_payload->>'type_of_set_aside_code' IN ('NONE', '') THEN 'No set aside'
      ELSE pa.raw_payload->>'type_of_set_aside'
    END
  ),
  pa.raw_payload->>'type_of_set_aside_code',
  COALESCE(sa_map.is_positive_set_aside, false);

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_set_aside_dept
  ON topic_intelligence.mv_set_aside_profile (department_code);

CREATE INDEX idx_set_aside_fpds_dept
  ON topic_intelligence.mv_set_aside_profile (contracting_dept_id);

CREATE INDEX idx_set_aside_fpds_office
  ON topic_intelligence.mv_set_aside_profile (contracting_office_id);

CREATE INDEX idx_set_aside_model_topic
  ON topic_intelligence.mv_set_aside_profile (model_id, topic_id);

CREATE INDEX idx_set_aside_family
  ON topic_intelligence.mv_set_aside_profile (set_aside_family);

CREATE INDEX idx_set_aside_dept_family
  ON topic_intelligence.mv_set_aside_profile (department_code, set_aside_family);

CREATE INDEX idx_set_aside_positive
  ON topic_intelligence.mv_set_aside_profile (is_positive_set_aside)
  WHERE is_positive_set_aside = true;

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_set_aside_profile TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT set_aside_family) AS set_aside_families,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  count(*) FILTER (WHERE is_positive_set_aside) AS positive_set_aside_rows,
  round(sum(obligated_amount) / 1e9, 1) AS total_obligated_billions
FROM topic_intelligence.mv_set_aside_profile;

\echo ''
\echo 'Set-aside family distribution:'
SELECT set_aside_family, count(*) AS rows,
  round(sum(obligated_amount) / 1e9, 1) AS obligated_billions
FROM topic_intelligence.mv_set_aside_profile
GROUP BY set_aside_family
ORDER BY rows DESC;

\echo 'End time:'
SELECT now();
\echo '=== 050: COMPLETE ==='
