-- 045_topic_intel_mv_catalog.sql
-- Topic Intelligence Package — Phase 1a: Topic Catalog MV
--
-- One row per topic with pre-aggregated keyword summary, provenance 
-- classification, and assignment counts.
--
-- Run: nohup psql $CONN -f sql/045_topic_intel_mv_catalog.sql > /tmp/045_catalog.log 2>&1 &
-- Expected duration: 5-15 minutes (keyword_facets aggregation is heaviest)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_topic_catalog;
--         Expected: ~25,883 rows
--
-- Reference: Build Spec v1.1 §1a
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 045: Building mv_topic_catalog ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_topic_catalog CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_topic_catalog AS
WITH keyword_agg AS (
  -- Pre-aggregate top 10 keywords per topic from the 40M-row MV
  SELECT model_id, topic_id,
    array_agg(keyword ORDER BY (prime_award_count + sam_opportunity_count) DESC)
      FILTER (WHERE rn <= 10) AS top_keywords
  FROM (
    SELECT model_id, topic_id, keyword, prime_award_count, sam_opportunity_count,
      row_number() OVER (
        PARTITION BY model_id, topic_id
        ORDER BY (prime_award_count + sam_opportunity_count) DESC
      ) AS rn
    FROM v2.topic_keyword_facets
  ) ranked
  GROUP BY model_id, topic_id
),
provenance_summary AS (
  -- Lineage classification summary per merged topic
  SELECT model_id, topic_id,
    count(DISTINCT source_corpus) AS corpus_count,
    string_agg(DISTINCT classification, ', ' ORDER BY classification) AS classifications,
    count(*) AS lineage_count
  FROM v2.topic_provenance
  GROUP BY model_id, topic_id
),
assignment_counts AS (
  -- Assignment totals: merged path for merged topics, origin path for per-corpus topics
  SELECT model_id, topic_id,
    sum(cnt) AS assignment_count,
    sum(awards_cnt) AS awards_count,
    sum(sam_cnt) AS sam_count
  FROM (
    -- Merged assignments (for merged topics)
    SELECT merged_model_id AS model_id, merged_topic_id AS topic_id,
      count(*) AS cnt,
      count(*) FILTER (WHERE corpus_type = 'awards') AS awards_cnt,
      count(*) FILTER (WHERE corpus_type = 'sam') AS sam_cnt
    FROM v2.topic_assignments
    WHERE merged_topic_id IS NOT NULL
    GROUP BY merged_model_id, merged_topic_id
    UNION ALL
    -- Origin assignments (for per-corpus topics: awards, sam, web, web-govwide)
    SELECT origin_model_id AS model_id, origin_topic_id AS topic_id,
      count(*) AS cnt,
      count(*) FILTER (WHERE corpus_type = 'awards') AS awards_cnt,
      count(*) FILTER (WHERE corpus_type = 'sam') AS sam_cnt
    FROM v2.topic_assignments
    GROUP BY origin_model_id, origin_topic_id
  ) combined
  GROUP BY model_id, topic_id
)
SELECT
  tl.model_id,
  tl.topic_id,
  substring(tl.model_id FROM 'v2\.1-([^-]+)-') AS department_code,
  tl.corpus_type,
  tl.label,
  tl.description,
  tl.contextual_description,
  tl.naics_alignment,
  tl.document_count,
  tl.coherence_score,
  tl.keywords AS model_keywords,
  ka.top_keywords,
  COALESCE(ps.corpus_count, 0) AS source_corpus_count,
  ps.classifications AS lineage_classification,
  COALESCE(ac.assignment_count, 0) AS assignment_count,
  COALESCE(ac.awards_count, 0) AS awards_count,
  COALESCE(ac.sam_count, 0) AS sam_count
FROM v2.topic_labels tl
LEFT JOIN keyword_agg ka ON tl.model_id = ka.model_id AND tl.topic_id = ka.topic_id
LEFT JOIN provenance_summary ps ON tl.model_id = ps.model_id AND tl.topic_id = ps.topic_id
LEFT JOIN assignment_counts ac ON tl.model_id = ac.model_id AND tl.topic_id = ac.topic_id;

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_topic_catalog_dept
  ON topic_intelligence.mv_topic_catalog (department_code);

CREATE INDEX idx_topic_catalog_corpus
  ON topic_intelligence.mv_topic_catalog (corpus_type);

CREATE INDEX idx_topic_catalog_dept_corpus
  ON topic_intelligence.mv_topic_catalog (department_code, corpus_type);

CREATE INDEX idx_topic_catalog_model_topic
  ON topic_intelligence.mv_topic_catalog (model_id, topic_id);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_topic_catalog TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS departments,
  count(*) FILTER (WHERE corpus_type = 'merged') AS merged_topics,
  count(*) FILTER (WHERE assignment_count > 0) AS has_assignments,
  count(*) FILTER (WHERE top_keywords IS NOT NULL) AS has_keywords,
  count(*) FILTER (WHERE lineage_classification IS NOT NULL) AS has_lineage
FROM topic_intelligence.mv_topic_catalog;

\echo 'End time:'
SELECT now();
\echo '=== 045: COMPLETE ==='
