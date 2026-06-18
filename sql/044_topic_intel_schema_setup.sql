-- 044_topic_intel_schema_setup.sql
-- Topic Intelligence Package — Schema + Infrastructure Setup
-- 
-- Phase 0: Creates the topic_intelligence schema, vendor_names lookup,
-- and validates prerequisites before any MV builds.
--
-- Run: psql $CONN -f sql/044_topic_intel_schema_setup.sql
-- Expected duration: < 1 minute (schema/grants only; vendor_names already built)
-- 
-- Reference: Build Spec v1.1
-- Date: 2026-06-18

------------------------------------------------------------------------
-- Step 1: Schema
------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS topic_intelligence;
GRANT USAGE ON SCHEMA topic_intelligence TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Step 2: Vendor names table
-- Built from vendor_topic_rollup UEIs + prime_awards recipient names.
-- If table already exists with data, skip this step.
------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'topic_intelligence' AND table_name = 'vendor_names'
  ) THEN
    RAISE NOTICE 'vendor_names does not exist — build it separately';
  ELSE
    RAISE NOTICE 'vendor_names already exists — skipping';
  END IF;
END $$;

------------------------------------------------------------------------
-- Step 3: Verify prerequisites
------------------------------------------------------------------------

-- 3a: topic_intelligence schema exists
SELECT current_schema();
SET search_path TO topic_intelligence, v2, public, analytics_dims, analytics_api;

-- 3b: vendor_names row count
SELECT count(*) AS vendor_names_rows FROM topic_intelligence.vendor_names;

-- 3c: Source table row counts (approximate)
SELECT n.nspname || '.' || c.relname AS source_table, c.reltuples::bigint AS approx_rows
FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE (n.nspname, c.relname) IN (
  ('v2','topic_labels'), ('v2','topic_assignments'), ('v2','topic_keyword_facets'),
  ('v2','topic_provenance'), ('v2','vendor_topic_rollup'), ('v2','document_topic_links'),
  ('v2','topic_embeddings'), ('v2','page_documents'),
  ('public','prime_awards'), ('public','contract_opportunities')
)
ORDER BY c.reltuples DESC;

-- 3d: Dimension tables present
SELECT 'fpds_contracting_office_map' AS dim, count(*) FROM analytics_dims.fpds_contracting_office_map
UNION ALL SELECT 'fpds_department_map', count(*) FROM analytics_dims.fpds_department_map
UNION ALL SELECT 'fpds_agency_map', count(*) FROM analytics_dims.fpds_agency_map
UNION ALL SELECT 'fpds_set_aside_code_map', count(*) FROM analytics_dims.fpds_set_aside_code_map
UNION ALL SELECT 'fpds_contract_pricing_map', count(*) FROM analytics_dims.fpds_contract_pricing_map
UNION ALL SELECT 'fpds_psc_map', count(*) FROM analytics_dims.fpds_psc_map;
