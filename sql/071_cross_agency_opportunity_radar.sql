-- ──────────────────────────────────────────────────────────────────────────────
-- 071: Cross-Agency Opportunity Radar
-- ──────────────────────────────────────────────────────────────────────────────
-- Collaborative-filtering recommendation engine for federal procurement.
-- For each vendor with a multi-agency footprint, finds agencies they don't
-- currently sell to but should — based on NAICS portfolio similarity to
-- agencies where they already win. Scores recommendations by market similarity,
-- agency spend, and entry accessibility.
--
-- Grain: vendor_uei × recommended_agency_id
-- ──────────────────────────────────────────────────────────────────────────────

BEGIN;

CREATE SCHEMA IF NOT EXISTS opportunity_intelligence;
COMMENT ON SCHEMA opportunity_intelligence IS
    'Cross-agency opportunity intelligence — collaborative filtering recommendations for vendor expansion targets.';

GRANT USAGE ON SCHEMA opportunity_intelligence TO fpds_analytics_api_readonly;

-- ── Materialized View ─────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW opportunity_intelligence.mv_cross_agency_opportunity_radar AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(MONTH FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(YEAR FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(YEAR FROM CURRENT_DATE)::int END AS fy
),
recent_complete_fy AS (
    SELECT MAX(n.fiscal_year) AS fiscal_year
    FROM naics_breakdown.report_deck_naics_agency_fy n
    CROSS JOIN current_fy cfy
    WHERE n.fiscal_year < cfy.fy
),
vendor_portfolio AS (
    SELECT
        v.uei,
        v.vendor_name,
        MAX(v.is_small_business) AS is_small_business,
        COUNT(DISTINCT v.contracting_agency_id) AS agency_count
    FROM vendor_concentration.report_deck_agency_vendor_leaders v
    WHERE v.vendor_rank <= 50
    GROUP BY v.uei, v.vendor_name
    HAVING COUNT(DISTINCT v.contracting_agency_id) >= 2
),
vendor_agencies AS (
    SELECT DISTINCT
        v.uei,
        v.contracting_agency_id,
        v.contracting_agency_name
    FROM vendor_concentration.report_deck_agency_vendor_leaders v
    JOIN vendor_portfolio p ON v.uei = p.uei
    WHERE v.vendor_rank <= 50
),
agency_naics_ranked AS (
    SELECT
        n.contracting_agency_id,
        n.contracting_agency_name,
        n.principal_naics_code,
        n.net_obligated_amount,
        SUM(n.net_obligated_amount) OVER (
            PARTITION BY n.contracting_agency_id
        ) AS agency_total_obligated,
        ROW_NUMBER() OVER (
            PARTITION BY n.contracting_agency_id
            ORDER BY n.net_obligated_amount DESC
        ) AS naics_rank
    FROM naics_breakdown.report_deck_naics_agency_fy n
    JOIN recent_complete_fy fy ON n.fiscal_year = fy.fiscal_year
    WHERE n.net_obligated_amount > 0
),
agency_top5_naics AS (
    SELECT
        contracting_agency_id,
        contracting_agency_name,
        MAX(agency_total_obligated) AS agency_total_obligated,
        ARRAY_AGG(principal_naics_code ORDER BY naics_rank) AS top5_codes
    FROM agency_naics_ranked
    WHERE naics_rank <= 5
    GROUP BY contracting_agency_id, contracting_agency_name
),
vendor_naics_profile AS (
    SELECT
        vp.uei,
        vp.vendor_name,
        vp.is_small_business,
        vp.agency_count,
        ARRAY_AGG(DISTINCT nc ORDER BY nc) AS vendor_profile_naics,
        STRING_AGG(DISTINCT va.contracting_agency_name, ', ' ORDER BY va.contracting_agency_name) AS vendor_existing_agencies
    FROM vendor_portfolio vp
    JOIN vendor_agencies va ON vp.uei = va.uei
    JOIN agency_top5_naics at5 ON va.contracting_agency_id = at5.contracting_agency_id
    CROSS JOIN LATERAL unnest(at5.top5_codes) AS nc
    GROUP BY vp.uei, vp.vendor_name, vp.is_small_business, vp.agency_count
),
candidates AS (
    SELECT
        vnp.uei,
        vnp.vendor_name,
        vnp.is_small_business,
        vnp.agency_count,
        vnp.vendor_existing_agencies,
        vnp.vendor_profile_naics,
        at5.contracting_agency_id AS recommended_agency_id,
        at5.contracting_agency_name AS recommended_agency_name,
        at5.top5_codes AS recommended_agency_top5_naics,
        at5.agency_total_obligated,
        ARRAY(
            SELECT unnest(vnp.vendor_profile_naics)
            INTERSECT
            SELECT unnest(at5.top5_codes)
            ORDER BY 1
        ) AS shared_naics_arr
    FROM vendor_naics_profile vnp
    CROSS JOIN agency_top5_naics at5
    WHERE NOT EXISTS (
        SELECT 1 FROM vendor_agencies va
        WHERE va.uei = vnp.uei
          AND va.contracting_agency_id = at5.contracting_agency_id
    )
),
jaccard AS (
    SELECT
        c.*,
        CASE
            WHEN cardinality(c.shared_naics_arr) = 0 THEN 0.0
            ELSE cardinality(c.shared_naics_arr)::numeric /
                 NULLIF(
                     (cardinality(c.vendor_profile_naics)
                      + cardinality(c.recommended_agency_top5_naics)
                      - cardinality(c.shared_naics_arr))::numeric, 0
                 )
        END AS jaccard_similarity
    FROM candidates c
),
spend_max AS (
    SELECT MAX(agency_total_obligated) AS max_total_obligated FROM jaccard
),
entry_difficulty_avg AS (
    SELECT
        j.uei,
        j.recommended_agency_id,
        AVG(eds.entry_difficulty_score) AS avg_entry_difficulty
    FROM jaccard j
    CROSS JOIN LATERAL unnest(j.shared_naics_arr) AS shc(naics)
    LEFT JOIN competition_dynamics.report_deck_market_entry_difficulty_score eds
        ON eds.contracting_agency_id = j.recommended_agency_id
        AND eds.principal_naics_code = shc.naics
    WHERE cardinality(j.shared_naics_arr) > 0
    GROUP BY j.uei, j.recommended_agency_id
)
SELECT
    j.uei AS vendor_uei,
    j.vendor_name,
    j.is_small_business AS vendor_is_small_business,
    j.agency_count AS vendor_current_agency_count,
    j.recommended_agency_id,
    j.recommended_agency_name,
    COALESCE(
        (SELECT string_agg(naics, ', ' ORDER BY naics) FROM unnest(j.shared_naics_arr) AS naics),
        ''
    ) AS shared_naics_codes,
    ROUND(j.jaccard_similarity, 4) AS jaccard_similarity,
    j.agency_total_obligated AS candidate_agency_3yr_obligated,
    COALESCE(e.avg_entry_difficulty, 100.0) AS avg_entry_difficulty,
    ROUND(
        (j.jaccard_similarity * 40.0)
        + (COALESCE(j.agency_total_obligated / NULLIF(sm.max_total_obligated, 0), 0) * 30.0)
        + ((100.0 - COALESCE(e.avg_entry_difficulty, 100.0)) / 100.0 * 30.0),
        2
    ) AS recommendation_score,
    j.vendor_existing_agencies,
    COALESCE(
        (SELECT string_agg(naics, ', ' ORDER BY naics) FROM unnest(j.recommended_agency_top5_naics) AS naics),
        ''
    ) AS recommended_agency_top_naics
FROM jaccard j
CROSS JOIN spend_max sm
LEFT JOIN entry_difficulty_avg e
    ON j.uei = e.uei
    AND j.recommended_agency_id = e.recommended_agency_id
WHERE cardinality(j.shared_naics_arr) > 0;

COMMENT ON MATERIALIZED VIEW opportunity_intelligence.mv_cross_agency_opportunity_radar IS
    'Collaborative-filtering recommendation engine: for each vendor with 2+ agencies, finds agencies they don''t sell to that share NAICS profiles with agencies where they already win. Grain: vendor_uei × recommended_agency_id.';

-- ── Report Deck View ──────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW opportunity_intelligence.report_deck_cross_agency_opportunity_radar AS
SELECT * FROM opportunity_intelligence.mv_cross_agency_opportunity_radar;

COMMENT ON VIEW opportunity_intelligence.report_deck_cross_agency_opportunity_radar IS
    'Report-deck facade for mv_cross_agency_opportunity_radar.';

-- ── API Facade (security_barrier) ─────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.opportunity_radar
WITH (security_barrier = true) AS
SELECT * FROM opportunity_intelligence.report_deck_cross_agency_opportunity_radar;

COMMENT ON VIEW analytics_api.opportunity_radar IS
    'API facade for cross-agency opportunity radar with security_barrier.';

-- ── Grant ────────────────────────────────────────────────────────────────────

GRANT SELECT ON analytics_api.opportunity_radar TO fpds_analytics_api_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA opportunity_intelligence
    GRANT SELECT ON TABLES TO fpds_analytics_api_readonly;

COMMIT;
