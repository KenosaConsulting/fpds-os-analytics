-- 053_topic_intel_mv_competitive.sql
-- Topic Intelligence Package — Phase 4: Competitive Landscape MV
--
-- Who dominates each topic? Market share at semantic resolution.
-- All vendors — no artificial top-N cap. Required filters for bounded queries.
--
-- Source: v2.vendor_topic_rollup (2.3M rows, pre-aggregated)
-- Vendor names from topic_intelligence.vendor_names (554K entries, 93.7% coverage).
-- Department derived from model_id (rollup is at merged-model level, not office level).
--
-- ⚠️ PREREQUISITE: vendor_topic_rollup should be refreshed before this ships.
--    Last refresh: 2026-05-13. Check refreshed_at before releasing to production.
--
-- Grain: department_code × topic × vendor (UEI)
--
-- Run: nohup psql $CONN -f sql/053_topic_intel_mv_competitive.sql > /tmp/053_competitive.log 2>&1 &
-- Expected duration: 5-15 minutes (rollup is pre-aggregated; main work is window functions)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_competitive_landscape;
--         Expected: ~2.3M rows (filtered to merged topics)
--
-- Depends on: 044 (schema), vendor_names table
-- Reference: Build Spec v1.1 §4a
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 053: Building mv_competitive_landscape ==='
\echo 'Start time:'
SELECT now();

\echo 'Prerequisite check — vendor_topic_rollup freshness:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT entity_uei) AS distinct_vendors,
  count(DISTINCT model_id) AS distinct_models,
  min(refreshed_at)::date AS oldest_refresh,
  max(refreshed_at)::date AS newest_refresh
FROM v2.vendor_topic_rollup;

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_competitive_landscape CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_competitive_landscape AS
SELECT
  substring(vtr.model_id FROM 'v2\.1-([^-]+)-') AS department_code,
  vtr.model_id,
  vtr.topic_id,
  tl.label AS topic_label,
  vtr.entity_uei AS vendor_uei,
  vn.recipient_name AS vendor_name,
  vtr.contract_count,
  vtr.total_obligated,
  round(
    100.0 * vtr.total_obligated / NULLIF(
      SUM(vtr.total_obligated) OVER (PARTITION BY vtr.model_id, vtr.topic_id),
      0
    ),
    2
  ) AS topic_market_share,
  rank() OVER (
    PARTITION BY vtr.model_id, vtr.topic_id
    ORDER BY vtr.total_obligated DESC
  ) AS rank
FROM v2.vendor_topic_rollup vtr
JOIN v2.topic_labels tl
  ON vtr.model_id = tl.model_id
  AND vtr.topic_id = tl.topic_id
LEFT JOIN topic_intelligence.vendor_names vn
  ON vtr.entity_uei = vn.entity_uei
WHERE tl.corpus_type = 'merged';

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_competitive_dept
  ON topic_intelligence.mv_competitive_landscape (department_code);

CREATE INDEX idx_competitive_model_topic
  ON topic_intelligence.mv_competitive_landscape (model_id, topic_id);

CREATE INDEX idx_competitive_vendor
  ON topic_intelligence.mv_competitive_landscape (vendor_uei);

CREATE INDEX idx_competitive_dept_topic_rank
  ON topic_intelligence.mv_competitive_landscape (department_code, model_id, topic_id, rank);

CREATE INDEX idx_competitive_market_share
  ON topic_intelligence.mv_competitive_landscape (topic_market_share DESC);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_competitive_landscape TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  count(DISTINCT vendor_uei) AS distinct_vendors,
  count(vendor_name) AS has_vendor_name,
  round(100.0 * count(vendor_name) / count(*), 1) AS name_coverage_pct,
  round(sum(total_obligated) / 1e9, 1) AS total_obligated_billions
FROM topic_intelligence.mv_competitive_landscape;

\echo ''
\echo 'Top 10 vendors by total obligations across all topics:'
SELECT vendor_uei, vendor_name, 
  count(DISTINCT (model_id, topic_id)) AS topics_active_in,
  sum(contract_count) AS total_contracts,
  round(sum(total_obligated) / 1e9, 2) AS obligated_billions
FROM topic_intelligence.mv_competitive_landscape
WHERE vendor_name IS NOT NULL
GROUP BY vendor_uei, vendor_name
ORDER BY sum(total_obligated) DESC
LIMIT 10;

\echo 'End time:'
SELECT now();
\echo '=== 053: COMPLETE ==='
