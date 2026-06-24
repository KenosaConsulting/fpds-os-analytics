-- 059_bl001_vendor_name_for_agency_naics_leaders.sql
-- S7-013 / BL-001: Add vendor_name to incumbent.agency_naics_vendor_leaders
--
-- v2: Materialize the UEI->vendor_name lookup into a table first.
--     v1 used an inline UNION of 4 sources which made queries 66+ seconds
--     (planner couldn't push predicates into the union). A materialized
--     lookup table with an index lets the join use an index scan.
--
-- Acceptance: analytics_api.incumbent_agency_naics_vendor_leaders returns vendor_name
-- alongside uei. Query latency under 2 seconds with agency filter.

BEGIN;

-- 1. Build a materialized UEI -> vendor_name lookup table.
--    Sources: vendor_names (topic_intelligence), vendor_market_leaders,
--    agency_vendor_leaders, office_vendor_leaders.
--    Deduplicate by uei (first non-null name wins; order is deterministic).
CREATE TABLE IF NOT EXISTS analytics_dims.vendor_name_by_uei (
    uei text PRIMARY KEY,
    vendor_name text NOT NULL
);

TRUNCATE analytics_dims.vendor_name_by_uei;

INSERT INTO analytics_dims.vendor_name_by_uei (uei, vendor_name)
SELECT DISTINCT ON (uei) uei, vendor_name
FROM (
    SELECT entity_uei AS uei, recipient_name AS vendor_name
    FROM topic_intelligence.vendor_names
    WHERE entity_uei IS NOT NULL AND recipient_name IS NOT NULL
    UNION ALL
    SELECT uei, vendor_name FROM vendor_concentration.report_deck_vendor_market_leaders
    WHERE uei IS NOT NULL AND vendor_name IS NOT NULL
    UNION ALL
    SELECT uei, vendor_name FROM vendor_concentration.report_deck_agency_vendor_leaders
    WHERE uei IS NOT NULL AND vendor_name IS NOT NULL
    UNION ALL
    SELECT uei, vendor_name FROM vendor_concentration.report_deck_office_vendor_leaders
    WHERE uei IS NOT NULL AND vendor_name IS NOT NULL
) combined
ORDER BY uei, vendor_name;

-- 2. Recreate the facade view with a clean indexed join.
DROP VIEW IF EXISTS analytics_api.incumbent_agency_naics_vendor_leaders;

CREATE VIEW analytics_api.incumbent_agency_naics_vendor_leaders AS
SELECT
    g.contracting_agency_id,
    g.contracting_agency_name,
    g.agency_short_name,
    g.contracting_dept_id,
    g.contracting_dept_name,
    g.principal_naics_code,
    g.principal_naics_description,
    g.sector_label,
    g.uei,
    vn.vendor_name,
    g.is_small_business,
    g.total_obligated,
    g.recent_3yr_obligated,
    g.total_action_count,
    g.first_active_fy,
    g.last_active_fy,
    g.active_fy_count,
    g.vendor_rank
FROM vendor_concentration.report_deck_agency_naics_vendor_leaders g
LEFT JOIN analytics_dims.vendor_name_by_uei vn ON vn.uei = g.uei;

GRANT SELECT ON analytics_api.incumbent_agency_naics_vendor_leaders TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_dims.vendor_name_by_uei TO fpds_analytics_api_readonly;

COMMIT;

-- Verification (run separately):
-- SELECT COUNT(*) FROM analytics_dims.vendor_name_by_uei;
-- SELECT COUNT(*) AS total, COUNT(vendor_name) AS matched FROM analytics_api.incumbent_agency_naics_vendor_leaders;
