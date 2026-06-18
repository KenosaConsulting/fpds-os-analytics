-- 047_topic_intel_lineage_view.sql
-- Topic Intelligence Package — Phase 1c: Topic Lineage View
--
-- Exposes the provenance/lineage of merged topics — which per-corpus
-- topics merged into each merged topic, with classification.
-- 
-- This is a VIEW (not MV) because topic_provenance is only 50K rows.
-- No materialization overhead needed; instant to create.
--
-- Run: psql $CONN -f sql/047_topic_intel_lineage_view.sql
-- Expected duration: instant
-- Verify: SELECT count(*) FROM topic_intelligence.topic_lineage;
--         Expected: ~50,826 rows (same as v2.topic_provenance)
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §1c
-- Date: 2026-06-18

\echo '=== 047: Creating topic_lineage view ==='

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP VIEW IF EXISTS topic_intelligence.topic_lineage CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE OR REPLACE VIEW topic_intelligence.topic_lineage AS
SELECT
  tp.model_id AS merged_model_id,
  tp.topic_id AS merged_topic_id,
  tl_merged.label AS merged_topic_label,
  substring(tp.model_id FROM 'v2\.1-([^-]+)-') AS department_code,
  tp.source_corpus,
  tp.source_topic_id,
  -- Reconstruct the source model_id to join for source topic details
  -- Format: v2.1-{dept}-{corpus}-{date} → we know dept and corpus
  tl_source.model_id AS source_model_id,
  tl_source.label AS source_topic_label,
  tl_source.document_count AS source_doc_count,
  tl_source.description AS source_description,
  tl_source.naics_alignment AS source_naics_alignment,
  tp.classification,
  tp.similarity AS merge_similarity,
  tp.similarity_score,
  tp.source_topic_doc_count AS provenance_doc_count
FROM v2.topic_provenance tp
JOIN v2.topic_labels tl_merged
  ON tp.model_id = tl_merged.model_id
  AND tp.topic_id = tl_merged.topic_id
LEFT JOIN v2.topic_labels tl_source
  ON tl_source.corpus_type = tp.source_corpus
  AND tl_source.topic_id = tp.source_topic_id
  -- Match department from the merged model_id
  AND substring(tl_source.model_id FROM 'v2\.1-([^-]+)-') = substring(tp.model_id FROM 'v2\.1-([^-]+)-')
WHERE tl_merged.corpus_type = 'merged';

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.topic_lineage TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT (merged_model_id, merged_topic_id)) AS distinct_merged_topics,
  count(DISTINCT department_code) AS departments,
  count(source_topic_label) AS has_source_label
FROM topic_intelligence.topic_lineage;

\echo ''
\echo 'Classification distribution:'
SELECT classification, count(*) AS cnt
FROM topic_intelligence.topic_lineage
GROUP BY classification
ORDER BY cnt DESC;

\echo '=== 047: COMPLETE ==='
