-- 055_topic_intel_api_facades.sql
-- Topic Intelligence Package — API Facade Views + Final Grants
--
-- Creates analytics_api facade views for all topic intelligence MVs.
-- These are the views the REST + MCP API reads from.
-- Pattern matches existing fpds-os-analytics facades (001_analytics_api_facade.sql).
--
-- Run LAST, after all MVs (045-054) are verified complete.
--
-- Run: psql $CONN -f sql/055_topic_intel_api_facades.sql
-- Expected duration: instant (view creation only)
-- Verify: SELECT viewname FROM pg_views WHERE schemaname = 'analytics_api' AND viewname LIKE 'topics_%';
--         Expected: 11 views
--
-- Depends on: 045-054 (all MVs built and verified)
-- Reference: Build Spec v1.1 — API Facade Views
-- Date: 2026-06-18

\echo '=== 055: Creating API facade views ==='

------------------------------------------------------------------------
-- Phase 1: Core
------------------------------------------------------------------------
\echo 'Phase 1 facades...'

CREATE OR REPLACE VIEW analytics_api.topics_catalog AS
  SELECT * FROM topic_intelligence.mv_topic_catalog;

CREATE OR REPLACE VIEW analytics_api.topics_agency_profile AS
  SELECT * FROM topic_intelligence.mv_agency_profile;

CREATE OR REPLACE VIEW analytics_api.topics_lineage AS
  SELECT * FROM topic_intelligence.topic_lineage;

------------------------------------------------------------------------
-- Phase 2: Decompositions
------------------------------------------------------------------------
\echo 'Phase 2 facades...'

CREATE OR REPLACE VIEW analytics_api.topics_naics_decomposition AS
  SELECT * FROM topic_intelligence.mv_naics_decomposition;

CREATE OR REPLACE VIEW analytics_api.topics_psc_decomposition AS
  SELECT * FROM topic_intelligence.mv_psc_decomposition;

CREATE OR REPLACE VIEW analytics_api.topics_set_aside_profile AS
  SELECT * FROM topic_intelligence.mv_set_aside_profile;

CREATE OR REPLACE VIEW analytics_api.topics_contract_type_profile AS
  SELECT * FROM topic_intelligence.mv_contract_type_profile;

------------------------------------------------------------------------
-- Phase 3: Trends
------------------------------------------------------------------------
\echo 'Phase 3 facades...'

CREATE OR REPLACE VIEW analytics_api.topics_trends AS
  SELECT * FROM topic_intelligence.mv_topic_trends;

------------------------------------------------------------------------
-- Phase 4: Competition
------------------------------------------------------------------------
\echo 'Phase 4 facades...'

CREATE OR REPLACE VIEW analytics_api.topics_competitive_landscape AS
  SELECT * FROM topic_intelligence.mv_competitive_landscape;

------------------------------------------------------------------------
-- Phase 5: Documents
------------------------------------------------------------------------
\echo 'Phase 5 facades...'

CREATE OR REPLACE VIEW analytics_api.topics_document_links AS
  SELECT * FROM topic_intelligence.mv_document_links;

------------------------------------------------------------------------
-- Grants (belt + suspenders — grant on both schemas)
------------------------------------------------------------------------
\echo 'Granting access...'

GRANT SELECT ON ALL TABLES IN SCHEMA topic_intelligence TO fpds_analytics_api_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_api TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo ''
\echo 'All topic facade views:'
SELECT viewname
FROM pg_views
WHERE schemaname = 'analytics_api' AND viewname LIKE 'topics_%'
ORDER BY viewname;

\echo ''
\echo 'Row counts per facade:'
-- Can't do dynamic SQL in plain psql, so verify each explicitly
SELECT 'topics_catalog' AS dataset, count(*) AS rows FROM analytics_api.topics_catalog
UNION ALL SELECT 'topics_agency_profile', count(*) FROM analytics_api.topics_agency_profile
UNION ALL SELECT 'topics_lineage', count(*) FROM analytics_api.topics_lineage
UNION ALL SELECT 'topics_naics_decomposition', count(*) FROM analytics_api.topics_naics_decomposition
UNION ALL SELECT 'topics_psc_decomposition', count(*) FROM analytics_api.topics_psc_decomposition
UNION ALL SELECT 'topics_set_aside_profile', count(*) FROM analytics_api.topics_set_aside_profile
UNION ALL SELECT 'topics_contract_type_profile', count(*) FROM analytics_api.topics_contract_type_profile
UNION ALL SELECT 'topics_trends', count(*) FROM analytics_api.topics_trends
UNION ALL SELECT 'topics_competitive_landscape', count(*) FROM analytics_api.topics_competitive_landscape
UNION ALL SELECT 'topics_document_links', count(*) FROM analytics_api.topics_document_links
ORDER BY dataset;

\echo '=== 055: COMPLETE ==='
