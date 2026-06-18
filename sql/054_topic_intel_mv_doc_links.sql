-- 054_topic_intel_mv_doc_links.sql
-- Topic Intelligence Package — Phase 5: Document Links MV
--
-- Connects "what the government buys" (topics from procurement) to 
-- "why they buy it" (strategic documents). 318K links across 212K documents.
--
-- Document types: agency-strategic-plan, agency-budget, agency-oversight,
-- govwide-oversight, govwide-legislative, govwide-executive, agency-policy,
-- govwide-policy
--
-- Grain: topic × document
--
-- Run: nohup psql $CONN -f sql/054_topic_intel_mv_doc_links.sql > /tmp/054_doc_links.log 2>&1 &
-- Expected duration: < 5 minutes (small source tables)
-- Verify: SELECT count(*) FROM topic_intelligence.mv_document_links;
--         Expected: ~318,000 rows
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §5a
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '256MB';

\echo '=== 054: Building mv_document_links ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_document_links CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_document_links AS
SELECT
  -- Topic identity
  dtl.model_id,
  dtl.canonical_topic_id AS topic_id,
  tl.label AS topic_label,
  substring(dtl.model_id FROM 'v2\.1-([^-]+)-') AS department_code_topic,
  -- Document identity
  dtl.document_id,
  pd.title AS document_title,
  pd.document_type,
  pd.document_subtype,
  pd.department_code AS department_code_document,
  pd.fiscal_year,
  pd.source_url,
  -- Link metadata
  dtl.relevance_score,
  dtl.link_type,
  dtl.budget_signal,
  dtl.temporal_signal,
  dtl.confidence
FROM v2.document_topic_links dtl
JOIN v2.page_documents pd
  ON dtl.document_id = pd.id
JOIN v2.topic_labels tl
  ON dtl.model_id = tl.model_id
  AND dtl.canonical_topic_id = tl.topic_id;

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_doc_links_model_topic
  ON topic_intelligence.mv_document_links (model_id, topic_id);

CREATE INDEX idx_doc_links_dept_document
  ON topic_intelligence.mv_document_links (department_code_document);

CREATE INDEX idx_doc_links_doc_type
  ON topic_intelligence.mv_document_links (document_type);

CREATE INDEX idx_doc_links_dept_doctype
  ON topic_intelligence.mv_document_links (department_code_document, document_type);

CREATE INDEX idx_doc_links_doc_id
  ON topic_intelligence.mv_document_links (document_id);

CREATE INDEX idx_doc_links_dept_topic
  ON topic_intelligence.mv_document_links (department_code_topic);

CREATE INDEX idx_doc_links_fy
  ON topic_intelligence.mv_document_links (fiscal_year);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_document_links TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  count(DISTINCT document_id) AS distinct_documents,
  count(DISTINCT department_code_document) AS document_departments,
  count(DISTINCT department_code_topic) AS topic_departments
FROM topic_intelligence.mv_document_links;

\echo ''
\echo 'By document type:'
SELECT document_type, count(*) AS links, count(DISTINCT document_id) AS documents,
  count(DISTINCT (model_id, topic_id)) AS topics
FROM topic_intelligence.mv_document_links
GROUP BY document_type
ORDER BY links DESC;

\echo 'End time:'
SELECT now();
\echo '=== 054: COMPLETE ==='
