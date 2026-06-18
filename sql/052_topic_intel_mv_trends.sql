-- 052_topic_intel_mv_trends.sql
-- Topic Intelligence Package — Phase 3: Trends MV
--
-- Year-over-year topic growth and decline signals.
-- "Army's Autonomous Vehicle Sensor Systems topic grew 40% YoY while
--  Legacy Radio Communications declined 20%."
--
-- Grain: department_code × topic × fiscal_year (NOT office level —
-- office-level trends would be too sparse for meaningful signals).
-- FPDS dept included for cross-analytics joins.
--
-- Trend classification:
--   emerging  = first appeared in last 2 FYs AND growing
--   fading    = last activity 2+ FYs ago
--   growing   = YoY >= +10%
--   declining = YoY <= -10%
--   stable    = everything else
--
-- Fiscal year filter: >= 2010 (limits historical depth for relevance).
--
-- Run: nohup psql $CONN -f sql/052_topic_intel_mv_trends.sql > /tmp/052_trends.log 2>&1 &
-- Expected duration: 15-45 minutes
-- Verify: SELECT count(*) FROM topic_intelligence.mv_topic_trends;
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §3a
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 052: Building mv_topic_trends ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_topic_trends CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_topic_trends AS
WITH base AS (
  SELECT
    ta.department_code,
    -- FPDS dept (mode per department — for cross-analytics joins)
    COALESCE(om.contracting_dept_id, 'UNKNOWN') AS contracting_dept_id,
    COALESCE(dm.department_name, pa.awarding_agency_name) AS contracting_dept_name,
    ta.merged_model_id AS model_id,
    ta.merged_topic_id AS topic_id,
    pa.fiscal_year,
    count(*) AS assignment_count,
    sum(pa.total_obligated_amount) AS total_obligated
  FROM v2.topic_assignments ta
  JOIN public.prime_awards pa
    ON ta.department_code = pa.department_code
    AND ta.record_id = pa.id
  LEFT JOIN analytics_dims.fpds_contracting_office_map om
    ON pa.awarding_office_code = om.contracting_office_id
  LEFT JOIN analytics_dims.fpds_department_map dm
    ON om.contracting_dept_id = dm.department_id
  WHERE ta.corpus_type = 'awards'
    AND ta.merged_topic_id IS NOT NULL
    AND pa.fiscal_year IS NOT NULL
    AND pa.fiscal_year >= 2010
  GROUP BY
    ta.department_code,
    COALESCE(om.contracting_dept_id, 'UNKNOWN'),
    COALESCE(dm.department_name, pa.awarding_agency_name),
    ta.merged_model_id, ta.merged_topic_id,
    pa.fiscal_year
),
max_fy AS (
  SELECT max(fiscal_year) AS latest_fy FROM base
),
with_lag AS (
  SELECT b.*,
    lag(b.assignment_count) OVER w AS prior_fy_count,
    lag(b.total_obligated) OVER w AS prior_fy_obligated,
    min(b.fiscal_year) OVER topic_window AS first_fy,
    max(b.fiscal_year) OVER topic_window AS last_fy
  FROM base b
  WINDOW
    w AS (PARTITION BY b.department_code, b.model_id, b.topic_id ORDER BY b.fiscal_year),
    topic_window AS (PARTITION BY b.department_code, b.model_id, b.topic_id)
)
SELECT
  wl.department_code,
  wl.contracting_dept_id,
  wl.contracting_dept_name,
  wl.model_id,
  wl.topic_id,
  tl.label AS topic_label,
  wl.fiscal_year,
  wl.assignment_count,
  wl.total_obligated,
  wl.prior_fy_count,
  wl.assignment_count - COALESCE(wl.prior_fy_count, 0) AS yoy_change,
  CASE
    WHEN wl.prior_fy_count IS NULL OR wl.prior_fy_count = 0 THEN NULL
    ELSE round(100.0 * (wl.assignment_count - wl.prior_fy_count) / wl.prior_fy_count, 1)
  END AS yoy_growth_rate,
  CASE
    WHEN wl.first_fy >= mf.latest_fy - 1
         AND wl.assignment_count > COALESCE(wl.prior_fy_count, 0)
    THEN 'emerging'
    WHEN wl.last_fy <= mf.latest_fy - 2
    THEN 'fading'
    WHEN wl.prior_fy_count > 0
         AND (wl.assignment_count - wl.prior_fy_count)::float / wl.prior_fy_count >= 0.10
    THEN 'growing'
    WHEN wl.prior_fy_count > 0
         AND (wl.assignment_count - wl.prior_fy_count)::float / wl.prior_fy_count <= -0.10
    THEN 'declining'
    ELSE 'stable'
  END AS trend_classification,
  wl.first_fy,
  wl.last_fy
FROM with_lag wl
CROSS JOIN max_fy mf
JOIN v2.topic_labels tl
  ON wl.model_id = tl.model_id
  AND wl.topic_id = tl.topic_id
WHERE tl.corpus_type = 'merged';

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_trends_dept
  ON topic_intelligence.mv_topic_trends (department_code);

CREATE INDEX idx_trends_fpds_dept
  ON topic_intelligence.mv_topic_trends (contracting_dept_id);

CREATE INDEX idx_trends_dept_fy
  ON topic_intelligence.mv_topic_trends (department_code, fiscal_year);

CREATE INDEX idx_trends_model_topic
  ON topic_intelligence.mv_topic_trends (model_id, topic_id);

CREATE INDEX idx_trends_classification
  ON topic_intelligence.mv_topic_trends (trend_classification);

CREATE INDEX idx_trends_dept_classification
  ON topic_intelligence.mv_topic_trends (department_code, trend_classification);

CREATE INDEX idx_trends_fy
  ON topic_intelligence.mv_topic_trends (fiscal_year);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_topic_trends TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  min(fiscal_year) AS min_fy,
  max(fiscal_year) AS max_fy,
  count(DISTINCT fiscal_year) AS fy_range
FROM topic_intelligence.mv_topic_trends;

\echo ''
\echo 'Trend classification distribution (latest FY):'
SELECT trend_classification, count(*) AS topics,
  round(avg(yoy_growth_rate), 1) AS avg_growth_rate
FROM topic_intelligence.mv_topic_trends
WHERE fiscal_year = (SELECT max(fiscal_year) FROM topic_intelligence.mv_topic_trends)
GROUP BY trend_classification
ORDER BY topics DESC;

\echo 'End time:'
SELECT now();
\echo '=== 052: COMPLETE ==='
