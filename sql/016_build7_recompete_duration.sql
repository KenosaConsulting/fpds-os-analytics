-- Build 7: Recompete Pipeline & Duration Profiles
--
-- Schema: pipeline_intelligence (new)
-- MV 1: contract family grouping (award-level aggregation)
-- MV 2: duration profile aggregation
-- Estimated rows: 15M–25M (contract families), 200K–500K (duration profiles)
-- Build time: 60–120 min on 99M source rows
--
-- This is the most complex and most differentiated build. It groups
-- individual contract actions into contract families, computes duration
-- and remaining time, and surfaces recompete candidates with confidence
-- scoring.
--
-- Prerequisites: P1, P2, P3 (org dims)

-- ═══════════════════════════════════════════════════════════════════════════
-- SCHEMA
-- ═══════════════════════════════════════════════════════════════════════════

CREATE SCHEMA IF NOT EXISTS pipeline_intelligence;
COMMENT ON SCHEMA pipeline_intelligence IS
'Contract lifecycle intelligence: recompete watchlists, duration profiles, and expiration signals.';


-- ═══════════════════════════════════════════════════════════════════════════
-- MV 1: CONTRACT FAMILY
-- Groups individual actions into contract families using (piid, agency_id).
-- Each row represents one contract entity with its lifecycle attributes.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE MATERIALIZED VIEW pipeline_intelligence.mv_contract_family AS
WITH ranked_actions AS (
    SELECT
        fa.piid,
        fa.contracting_agency_id,
        fa.contracting_dept_id,
        fa.contracting_office_id,
        fa.uei,
        COALESCE(
            NULLIF(fa.vendor_name, ''),
            NULLIF(fa.vendor_legal_organization_name, ''),
            NULLIF(fa.contractor_name, '')
        ) AS vendor_name,
        fa.principal_naics_code,
        fa.product_or_service_code,
        COALESCE(fa.set_aside, 'UNKNOWN') AS set_aside_code,
        fa.extent_competed,
        fa.effective_date,
        fa.current_completion_date,
        fa.ultimate_completion_date,
        fa.signed_date,
        NULLIF(fa.obligated_amount, '')::numeric AS obligated,
        NULLIF(fa.base_and_all_options_value, '')::numeric AS base_all_options,
        COALESCE(fa.reason_for_modification, 'BASE') AS mod_reason,
        fa.mod_number,
        ROW_NUMBER() OVER (
            PARTITION BY fa.piid, fa.contracting_agency_id
            ORDER BY fa.signed_date::timestamp DESC NULLS LAST, fa.mod_number DESC NULLS LAST
        ) AS recency_rank,
        ROW_NUMBER() OVER (
            PARTITION BY fa.piid, fa.contracting_agency_id
            ORDER BY fa.signed_date::timestamp ASC NULLS LAST, fa.mod_number ASC NULLS LAST
        ) AS earliest_rank
    FROM public.fpds_actions fa
    WHERE fa.piid IS NOT NULL AND fa.piid != ''
      AND fa.contracting_agency_id IS NOT NULL AND fa.contracting_agency_id != ''
      AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
)
SELECT
    ra.piid,
    ra.contracting_agency_id,

    -- From most recent action
    (ARRAY_AGG(ra.contracting_dept_id ORDER BY ra.recency_rank)
        FILTER (WHERE ra.recency_rank = 1))[1] AS contracting_dept_id,
    (ARRAY_AGG(ra.contracting_office_id ORDER BY ra.recency_rank)
        FILTER (WHERE ra.recency_rank = 1))[1] AS contracting_office_id,
    (ARRAY_AGG(ra.uei ORDER BY ra.recency_rank)
        FILTER (WHERE ra.recency_rank = 1))[1] AS vendor_uei,
    (ARRAY_AGG(ra.vendor_name ORDER BY ra.recency_rank)
        FILTER (WHERE ra.recency_rank = 1))[1] AS vendor_name,

    -- From base award (earliest action)
    (ARRAY_AGG(ra.principal_naics_code ORDER BY ra.earliest_rank)
        FILTER (WHERE ra.earliest_rank = 1))[1] AS principal_naics_code,
    (ARRAY_AGG(ra.product_or_service_code ORDER BY ra.earliest_rank)
        FILTER (WHERE ra.earliest_rank = 1))[1] AS product_or_service_code,
    (ARRAY_AGG(ra.set_aside_code ORDER BY ra.earliest_rank)
        FILTER (WHERE ra.earliest_rank = 1))[1] AS set_aside_code,
    (ARRAY_AGG(ra.extent_competed ORDER BY ra.earliest_rank)
        FILTER (WHERE ra.earliest_rank = 1))[1] AS extent_competed,

    -- Date envelope
    MIN(ra.effective_date::date) AS effective_date,
    MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
             THEN ra.current_completion_date::date ELSE NULL END) AS current_completion_date,
    MAX(CASE WHEN ra.ultimate_completion_date ~ '^\d{4}'
             THEN ra.ultimate_completion_date::date ELSE NULL END) AS ultimate_completion_date,
    MIN(ra.signed_date::date) AS base_award_date,
    MAX(ra.signed_date::date) AS latest_action_date,

    -- Financial
    SUM(ra.obligated) AS total_obligated,
    MAX(ra.base_all_options) AS base_and_all_options_value,
    COUNT(*) AS action_count,
    COUNT(*) FILTER (WHERE ra.mod_reason != 'BASE') AS modification_count,

    -- Fiscal years
    CASE WHEN EXTRACT(month FROM MIN(ra.signed_date::timestamp)) >= 10
         THEN EXTRACT(year FROM MIN(ra.signed_date::timestamp))::int + 1
         ELSE EXTRACT(year FROM MIN(ra.signed_date::timestamp))::int
    END AS fiscal_year_of_base,
    CASE WHEN EXTRACT(month FROM MAX(ra.signed_date::timestamp)) >= 10
         THEN EXTRACT(year FROM MAX(ra.signed_date::timestamp))::int + 1
         ELSE EXTRACT(year FROM MAX(ra.signed_date::timestamp))::int
    END AS fiscal_year_of_latest,

    -- Duration (months between effective and completion)
    CASE WHEN MIN(ra.effective_date::date) IS NOT NULL
          AND MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
                       THEN ra.current_completion_date::date ELSE NULL END) IS NOT NULL
          AND MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
                       THEN ra.current_completion_date::date ELSE NULL END)
              > MIN(ra.effective_date::date)
         THEN EXTRACT(EPOCH FROM (
             MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
                      THEN ra.current_completion_date::date ELSE NULL END)
             - MIN(ra.effective_date::date)
         ))::int / (86400 * 30)  -- approximate months
         ELSE NULL
    END AS duration_months,

    -- Remaining months from today
    CASE WHEN MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
                       THEN ra.current_completion_date::date ELSE NULL END) IS NOT NULL
         THEN EXTRACT(EPOCH FROM (
             MAX(CASE WHEN ra.current_completion_date ~ '^\d{4}'
                      THEN ra.current_completion_date::date ELSE NULL END)
             - CURRENT_DATE
         ))::int / (86400 * 30)
         ELSE NULL
    END AS remaining_months

FROM ranked_actions ra
GROUP BY ra.piid, ra.contracting_agency_id;


-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE UNIQUE INDEX IF NOT EXISTS mv_contract_family_uq
    ON pipeline_intelligence.mv_contract_family (piid, contracting_agency_id);

CREATE INDEX IF NOT EXISTS mv_contract_family_agency_idx
    ON pipeline_intelligence.mv_contract_family (contracting_agency_id);

CREATE INDEX IF NOT EXISTS mv_contract_family_office_idx
    ON pipeline_intelligence.mv_contract_family (contracting_office_id);

CREATE INDEX IF NOT EXISTS mv_contract_family_dept_idx
    ON pipeline_intelligence.mv_contract_family (contracting_dept_id);

CREATE INDEX IF NOT EXISTS mv_contract_family_completion_idx
    ON pipeline_intelligence.mv_contract_family (current_completion_date);

CREATE INDEX IF NOT EXISTS mv_contract_family_remaining_idx
    ON pipeline_intelligence.mv_contract_family (remaining_months);

CREATE INDEX IF NOT EXISTS mv_contract_family_vendor_idx
    ON pipeline_intelligence.mv_contract_family (vendor_uei);

CREATE INDEX IF NOT EXISTS mv_contract_family_naics_idx
    ON pipeline_intelligence.mv_contract_family (principal_naics_code);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Recompete watchlist: contracts approaching expiration
CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_recompete_watchlist AS
SELECT
    cf.piid,
    cf.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    cf.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    cf.contracting_office_id,
    om.contracting_office_name,
    cf.vendor_uei,
    cf.vendor_name,
    cf.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    cf.product_or_service_code,
    pm.psc_description,
    cf.set_aside_code,
    sam.label AS set_aside_label,
    cf.extent_competed,
    ecm.competition_family,
    cf.effective_date,
    cf.current_completion_date,
    cf.ultimate_completion_date,
    cf.base_award_date,
    cf.latest_action_date,
    cf.total_obligated,
    cf.base_and_all_options_value,
    cf.action_count,
    cf.modification_count,
    cf.duration_months,
    cf.remaining_months,
    -- Expiration bucket
    CASE
        WHEN cf.remaining_months IS NULL THEN 'unknown'
        WHEN cf.remaining_months < -6 THEN 'expired_6mo_plus'
        WHEN cf.remaining_months < 0 THEN 'recently_expired'
        WHEN cf.remaining_months <= 6 THEN '0_to_6_months'
        WHEN cf.remaining_months <= 12 THEN '6_to_12_months'
        WHEN cf.remaining_months <= 18 THEN '12_to_18_months'
        WHEN cf.remaining_months <= 24 THEN '18_to_24_months'
        ELSE '24_months_plus'
    END AS expiration_bucket,
    -- Recompete confidence
    CASE
        WHEN cf.duration_months IS NULL OR cf.remaining_months IS NULL THEN 'low'
        WHEN cf.duration_months >= 12
             AND cf.total_obligated > 100000
             AND cf.action_count >= 2
             AND ecm.is_competed
             THEN 'high'
        WHEN cf.duration_months >= 6
             AND cf.total_obligated > 25000
             THEN 'medium'
        ELSE 'low'
    END AS recompete_confidence
FROM pipeline_intelligence.mv_contract_family cf
LEFT JOIN analytics_dims.fpds_department_map dm ON cf.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON cf.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON cf.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON cf.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_psc_map pm ON cf.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_set_aside_code_map sam ON cf.set_aside_code = sam.raw_code
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm ON cf.extent_competed = ecm.raw_code
WHERE cf.remaining_months BETWEEN -6 AND 24
  AND cf.total_obligated > 25000
  AND cf.current_completion_date IS NOT NULL;


-- Duration profile: median/avg contract length by agency × NAICS
CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_duration_profile AS
SELECT
    cf.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    cf.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    cf.principal_naics_code,
    nh.naics_desc AS principal_naics_description,
    COUNT(*) AS contract_count,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY cf.duration_months) AS median_duration_months,
    ROUND(AVG(cf.duration_months), 1) AS avg_duration_months,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY cf.duration_months) AS p25_duration_months,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY cf.duration_months) AS p75_duration_months,
    ROUND(COUNT(*) FILTER (WHERE cf.duration_months < 12)::numeric / NULLIF(COUNT(*), 0), 4)
        AS share_under_12_months,
    ROUND(COUNT(*) FILTER (WHERE cf.duration_months BETWEEN 12 AND 36)::numeric / NULLIF(COUNT(*), 0), 4)
        AS share_12_to_36_months,
    ROUND(COUNT(*) FILTER (WHERE cf.duration_months > 36)::numeric / NULLIF(COUNT(*), 0), 4)
        AS share_over_36_months,
    ROUND(AVG(cf.total_obligated), 0) AS avg_obligated,
    SUM(cf.total_obligated) AS total_obligated
FROM pipeline_intelligence.mv_contract_family cf
LEFT JOIN analytics_dims.fpds_department_map dm ON cf.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON cf.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON cf.principal_naics_code = nh.naics_code
WHERE cf.duration_months IS NOT NULL
  AND cf.duration_months > 0
  AND cf.duration_months < 600  -- filter outliers (>50 years)
  AND cf.total_obligated > 0
GROUP BY cf.contracting_dept_id, dm.department_name,
         cf.contracting_agency_id, am.agency_name, am.agency_short_name,
         cf.principal_naics_code, nh.naics_desc
HAVING COUNT(*) >= 10;  -- minimum sample size


-- Agency recompete summary: upcoming expirations aggregated
CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_agency_recompete_summary AS
SELECT
    cf.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    cf.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    COUNT(*) FILTER (WHERE cf.remaining_months BETWEEN 0 AND 6) AS expiring_0_6_months,
    SUM(cf.total_obligated) FILTER (WHERE cf.remaining_months BETWEEN 0 AND 6) AS obligated_0_6_months,
    COUNT(*) FILTER (WHERE cf.remaining_months BETWEEN 6 AND 12) AS expiring_6_12_months,
    SUM(cf.total_obligated) FILTER (WHERE cf.remaining_months BETWEEN 6 AND 12) AS obligated_6_12_months,
    COUNT(*) FILTER (WHERE cf.remaining_months BETWEEN 12 AND 18) AS expiring_12_18_months,
    SUM(cf.total_obligated) FILTER (WHERE cf.remaining_months BETWEEN 12 AND 18) AS obligated_12_18_months,
    COUNT(*) FILTER (WHERE cf.remaining_months BETWEEN 18 AND 24) AS expiring_18_24_months,
    SUM(cf.total_obligated) FILTER (WHERE cf.remaining_months BETWEEN 18 AND 24) AS obligated_18_24_months,
    COUNT(*) AS total_active_contracts,
    SUM(cf.total_obligated) AS total_obligated
FROM pipeline_intelligence.mv_contract_family cf
LEFT JOIN analytics_dims.fpds_department_map dm ON cf.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON cf.contracting_agency_id = am.agency_id
WHERE cf.remaining_months >= 0
  AND cf.remaining_months <= 24
  AND cf.total_obligated > 25000
  AND cf.current_completion_date IS NOT NULL
GROUP BY cf.contracting_dept_id, dm.department_name, dm.department_short_name,
         cf.contracting_agency_id, am.agency_name, am.agency_short_name
HAVING COUNT(*) >= 5;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.pipeline_recompete_watchlist
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.report_deck_recompete_watchlist;

COMMENT ON VIEW analytics_api.pipeline_recompete_watchlist IS
'Contracts approaching expiration within -6 to +24 months. Includes incumbent vendor, NAICS, PSC, set-aside, duration, and recompete confidence scoring. CRITICAL CAVEAT: period-of-performance end dates are signals, not guaranteed recompete dates.';

CREATE OR REPLACE VIEW analytics_api.pipeline_duration_profile
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.report_deck_duration_profile;

COMMENT ON VIEW analytics_api.pipeline_duration_profile IS
'Contract duration profiles by agency × NAICS. Shows median/avg/P25/P75 contract length and share by duration bucket. Answers: are Army IT contracts 1-year or 5-year?';

CREATE OR REPLACE VIEW analytics_api.pipeline_agency_recompete_summary
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.report_deck_agency_recompete_summary;

COMMENT ON VIEW analytics_api.pipeline_agency_recompete_summary IS
'Per-agency upcoming contract expiration summary. Counts and obligation totals by expiration window (0-6mo, 6-12mo, 12-18mo, 18-24mo).';
