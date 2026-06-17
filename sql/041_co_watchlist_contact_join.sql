-- FPDS-022 Step 4b: Enhance Recompete Watchlist with Contact Columns
-- Replaces report_deck_recompete_watchlist and analytics_api.pipeline_recompete_watchlist
-- with versions that LEFT JOIN mv_fpds_contract_contacts for "who handled this contract"
--
-- The join adds 6 columns to the existing watchlist:
--   creator_user_id, creator_display_name, creator_class,
--   approver_user_id, approver_display_name, approver_last_seen_fy
--
-- Non-destructive: contracts without contact matches retain all existing columns (NULLs in contact fields)

-- ============================================================
-- Report view (replaces existing)
-- ============================================================

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
    CASE
        WHEN cf.duration_months IS NULL OR cf.remaining_months IS NULL THEN 'low'
        WHEN cf.duration_months >= 12 AND cf.total_obligated > 100000 AND cf.action_count >= 2 AND ecm.is_competed THEN 'high'
        WHEN cf.duration_months >= 6 AND cf.total_obligated > 25000 THEN 'medium'
        ELSE 'low'
    END AS recompete_confidence,

    -- Contact columns (FPDS-022)
    cc.creator_user_id AS contact_creator_user_id,
    cc.creator_display_name AS contact_creator_name,
    cc.creator_class AS contact_creator_class,
    cc.creator_action_date AS contact_creator_award_date,
    cc.approver_user_id AS contact_approver_user_id,
    cc.approver_display_name AS contact_approver_name,
    cc.approver_last_seen_fy AS contact_approver_last_seen_fy

FROM pipeline_intelligence.mv_contract_family cf
LEFT JOIN analytics_dims.fpds_department_map dm ON cf.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON cf.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON cf.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON cf.principal_naics_code = nh.naics_code
LEFT JOIN analytics_dims.fpds_psc_map pm ON cf.product_or_service_code = pm.psc_code
LEFT JOIN analytics_dims.fpds_set_aside_code_map sam ON cf.set_aside_code = sam.raw_code
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm ON cf.extent_competed = ecm.raw_code
LEFT JOIN customer_intelligence.mv_fpds_contract_contacts cc
    ON cf.piid = cc.piid AND cf.contracting_agency_id = cc.contracting_agency_id
WHERE cf.remaining_months >= -6
  AND cf.remaining_months <= 24
  AND cf.total_obligated > 25000
  AND cf.current_completion_date IS NOT NULL;

-- ============================================================
-- API facade (replaces existing — passes through all columns)
-- ============================================================

CREATE OR REPLACE VIEW analytics_api.pipeline_recompete_watchlist AS
SELECT * FROM pipeline_intelligence.report_deck_recompete_watchlist;

-- ============================================================
-- Grants
-- ============================================================

GRANT SELECT ON customer_intelligence.mv_fpds_contract_contacts TO fpds_analytics_api_readonly;

-- ============================================================
-- Verification
-- ============================================================

SELECT 'WATCHLIST_ENHANCED' AS status,
       COUNT(*) AS total_watchlist_rows,
       COUNT(contact_creator_user_id) AS with_creator,
       COUNT(contact_approver_user_id) AS with_approver,
       ROUND(COUNT(contact_creator_user_id)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS creator_coverage_pct,
       ROUND(COUNT(contact_approver_user_id)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 1) AS approver_coverage_pct
FROM pipeline_intelligence.report_deck_recompete_watchlist;
