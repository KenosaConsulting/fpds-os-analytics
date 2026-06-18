-- 049a_fix_psc_dim_categories.sql
-- Fix: Backfill psc_category_label in analytics_dims.fpds_psc_map
-- from public.psc_codes (GSA PSC Category Alignment April 2020).
--
-- Problem: fpds_psc_map.psc_category_label was only populated for 645 of
-- 3,314 codes (12 of 179 category groups). This causes 76% 'Unknown' in
-- any view that uses the category dimension.
--
-- Fix: UPDATE from public.psc_codes which has level_1_category and
-- level_2_category for 2,918 codes (2,847 overlap with fpds_psc_map).
--
-- Run: psql $CONN -f sql/049a_fix_psc_dim_categories.sql
-- Expected duration: instant (dim table is 3,314 rows)
-- 
-- After this: rebuild 049_topic_intel_mv_psc_decomp.sql
--             and verify dim_psc_codes shows populated categories.
--
-- Date: 2026-06-18

\echo '=== 049a: Fix PSC dim categories ==='
\echo 'Before state:'
SELECT
  count(*) AS total,
  count(psc_category_label) AS has_label,
  count(*) - count(psc_category_label) AS missing_label
FROM analytics_dims.fpds_psc_map;

------------------------------------------------------------------------
-- Step 1: Backfill psc_category_label from public.psc_codes
-- Uses level_1_category (top-level GSA category) as the label.
-- Preserves any existing non-NULL labels.
------------------------------------------------------------------------
\echo 'Updating psc_category_label from public.psc_codes...'

UPDATE analytics_dims.fpds_psc_map fm
SET psc_category_label = pc.level_1_category
FROM public.psc_codes pc
WHERE fm.psc_code = pc.psc_code
  AND fm.psc_category_label IS NULL
  AND pc.level_1_category IS NOT NULL;

\echo 'Update complete.'

------------------------------------------------------------------------
-- Step 2: For remaining NULLs — codes not in psc_codes — derive from
-- psc_group and psc_category_code where possible.
------------------------------------------------------------------------
\echo 'Backfilling remaining NULLs from psc_group...'

UPDATE analytics_dims.fpds_psc_map
SET psc_category_label = psc_group
WHERE psc_category_label IS NULL
  AND psc_group IS NOT NULL;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo ''
\echo 'After state:'
SELECT
  count(*) AS total,
  count(psc_category_label) AS has_label,
  count(*) - count(psc_category_label) AS missing_label
FROM analytics_dims.fpds_psc_map;

\echo ''
\echo 'Category distribution:'
SELECT psc_category_label, count(*) AS codes
FROM analytics_dims.fpds_psc_map
WHERE psc_category_label IS NOT NULL
GROUP BY psc_category_label
ORDER BY codes DESC;

\echo ''
\echo 'Any remaining NULLs:'
SELECT psc_code, psc_description, psc_group, psc_category_code
FROM analytics_dims.fpds_psc_map
WHERE psc_category_label IS NULL
LIMIT 10;

\echo '=== 049a: COMPLETE ==='
