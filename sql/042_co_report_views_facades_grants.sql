-- FPDS-022 Step 5: Report Views, Facades, Grants, Indexes, Office Coverage Stat
-- Four API datasets + one coverage metric, all backed by existing MVs (no new builds)
-- Protocol: instant DDL — views, grants, no heavy queries

-- ============================================================
-- 1. contacts.office_roster
--    "Who's actively handling procurement at this office?"
--    Source: MV A joined to directory for is_active_recent
--    Default filters (enforced at catalog level): user_class=human, is_active_recent=true
-- ============================================================

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contact_office_roster AS
SELECT
    mv.user_id,
    mv.user_class,
    mv.display_name,
    mv.email,
    c.name_confidence,
    mv.role,
    mv.contracting_dept_id,
    mv.contracting_dept_name,
    mv.contracting_agency_id,
    mv.contracting_agency_name,
    mv.contracting_office_id,
    mv.contracting_office_name,
    mv.fiscal_year,
    mv.action_count,
    mv.obligated_amount,
    mv.distinct_vendor_count,
    mv.small_biz_obligated,
    mv.set_aside_action_count,
    mv.sole_source_action_count,
    c.is_active_recent,
    c.first_seen_fy,
    c.last_seen_fy,
    c.lifetime_actions_created,
    c.lifetime_actions_approved
FROM customer_intelligence.mv_fpds_contact_office_fy mv
JOIN analytics_dims.fpds_procurement_contact c ON mv.user_id = c.user_id;

CREATE OR REPLACE VIEW analytics_api.contacts_office_roster AS
SELECT * FROM pipeline_intelligence.report_deck_contact_office_roster;

-- ============================================================
-- 2. contacts.profile_fy
--    "What does this person award, year by year?"
--    Source: MV A aggregated to user × FY (summed across offices/roles)
-- ============================================================

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contact_profile_fy AS
SELECT
    mv.user_id,
    mv.user_class,
    mv.display_name,
    mv.email,
    c.name_confidence,
    mv.fiscal_year,
    COUNT(DISTINCT mv.contracting_office_id) AS offices_active,
    COUNT(DISTINCT mv.contracting_agency_id) AS agencies_active,
    SUM(mv.action_count) AS action_count,
    SUM(mv.obligated_amount) AS obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    SUM(mv.set_aside_action_count) AS set_aside_action_count,
    SUM(mv.sole_source_action_count) AS sole_source_action_count,
    c.is_active_recent,
    c.first_seen_fy,
    c.last_seen_fy
FROM customer_intelligence.mv_fpds_contact_office_fy mv
JOIN analytics_dims.fpds_procurement_contact c ON mv.user_id = c.user_id
GROUP BY
    mv.user_id, mv.user_class, mv.display_name, mv.email,
    c.name_confidence, mv.fiscal_year,
    c.is_active_recent, c.first_seen_fy, c.last_seen_fy;

CREATE OR REPLACE VIEW analytics_api.contacts_profile_fy AS
SELECT * FROM pipeline_intelligence.report_deck_contact_profile_fy;

-- ============================================================
-- 3. contacts.naics_buyers
--    "Who buys my NAICS at this agency — and do they set work aside?"
--    Source: MV B joined to directory
-- ============================================================

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contact_naics_buyers AS
SELECT
    mv.user_id,
    mv.user_class,
    mv.display_name,
    mv.email,
    c.name_confidence,
    mv.contracting_dept_id,
    mv.contracting_dept_name,
    mv.contracting_agency_id,
    mv.contracting_agency_name,
    mv.principal_naics_code,
    mv.naics_group,
    mv.naics_sector,
    mv.fiscal_year,
    mv.action_count,
    mv.obligated_amount,
    mv.distinct_vendor_count,
    mv.set_aside_obligated,
    mv.sole_source_obligated,
    CASE WHEN mv.obligated_amount > 0
        THEN ROUND(mv.set_aside_obligated / mv.obligated_amount * 100, 1)
        ELSE NULL
    END AS set_aside_pct,
    CASE WHEN mv.obligated_amount > 0
        THEN ROUND(mv.sole_source_obligated / mv.obligated_amount * 100, 1)
        ELSE NULL
    END AS sole_source_pct,
    c.is_active_recent,
    c.first_seen_fy,
    c.last_seen_fy
FROM customer_intelligence.mv_fpds_contact_naics_agency_fy mv
JOIN analytics_dims.fpds_procurement_contact c ON mv.user_id = c.user_id;

CREATE OR REPLACE VIEW analytics_api.contacts_naics_buyers AS
SELECT * FROM pipeline_intelligence.report_deck_contact_naics_buyers;

-- ============================================================
-- 4. contacts.recompete_handlers
--    "Who handled the expiring contracts I'm chasing?"
--    Source: MV C with directory enrichment (standalone, complements watchlist columns)
-- ============================================================

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contact_recompete_handlers AS
SELECT
    cc.piid,
    cc.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    cc.creator_user_id,
    cc.creator_class,
    cc.creator_display_name,
    cc.creator_email,
    cc.creator_last_seen_fy,
    cc.creator_action_date,
    cc.approver_user_id,
    cc.approver_display_name,
    cc.approver_email,
    cc.approver_last_seen_fy,
    cc.approver_action_date,
    cf.contracting_dept_id,
    cf.contracting_office_id,
    cf.vendor_name,
    cf.principal_naics_code,
    cf.total_obligated,
    cf.current_completion_date,
    cf.remaining_months
FROM customer_intelligence.mv_fpds_contract_contacts cc
JOIN pipeline_intelligence.mv_contract_family cf
    ON cc.piid = cf.piid AND cc.contracting_agency_id = cf.contracting_agency_id
LEFT JOIN analytics_dims.fpds_agency_map am
    ON cc.contracting_agency_id = am.agency_id
WHERE cf.remaining_months >= -6
  AND cf.remaining_months <= 24
  AND cf.total_obligated > 25000
  AND cf.current_completion_date IS NOT NULL;

CREATE OR REPLACE VIEW analytics_api.contacts_recompete_handlers AS
SELECT * FROM pipeline_intelligence.report_deck_contact_recompete_handlers;

-- ============================================================
-- 5. Office coverage stat — human_attribution_share per office × FY
--    "How much of this office's buying is done by identifiable people?"
--    Source: MV A aggregated to office × FY, comparing human vs total obligations
-- ============================================================

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_office_human_coverage AS
SELECT
    contracting_dept_id,
    contracting_dept_name,
    contracting_agency_id,
    contracting_agency_name,
    contracting_office_id,
    contracting_office_name,
    fiscal_year,
    SUM(action_count) AS total_actions,
    SUM(obligated_amount) AS total_obligated,
    SUM(action_count) FILTER (WHERE user_class = 'human') AS human_actions,
    SUM(obligated_amount) FILTER (WHERE user_class = 'human') AS human_obligated,
    CASE WHEN SUM(obligated_amount) > 0
        THEN ROUND(
            SUM(obligated_amount) FILTER (WHERE user_class = 'human')
            / SUM(obligated_amount) * 100, 1
        )
        ELSE NULL
    END AS human_attribution_share,
    COUNT(DISTINCT user_id) FILTER (WHERE user_class = 'human') AS distinct_human_contacts
FROM customer_intelligence.mv_fpds_contact_office_fy
GROUP BY
    contracting_dept_id, contracting_dept_name,
    contracting_agency_id, contracting_agency_name,
    contracting_office_id, contracting_office_name,
    fiscal_year;

CREATE OR REPLACE VIEW analytics_api.contacts_office_coverage AS
SELECT * FROM pipeline_intelligence.report_deck_office_human_coverage;

-- ============================================================
-- GRANTS — all to readonly role
-- ============================================================

GRANT SELECT ON customer_intelligence.mv_fpds_contact_office_fy TO fpds_analytics_api_readonly;
GRANT SELECT ON customer_intelligence.mv_fpds_contact_naics_agency_fy TO fpds_analytics_api_readonly;
-- mv_fpds_contract_contacts grant already applied in 041

GRANT SELECT ON pipeline_intelligence.report_deck_contact_office_roster TO fpds_analytics_api_readonly;
GRANT SELECT ON pipeline_intelligence.report_deck_contact_profile_fy TO fpds_analytics_api_readonly;
GRANT SELECT ON pipeline_intelligence.report_deck_contact_naics_buyers TO fpds_analytics_api_readonly;
GRANT SELECT ON pipeline_intelligence.report_deck_contact_recompete_handlers TO fpds_analytics_api_readonly;
GRANT SELECT ON pipeline_intelligence.report_deck_office_human_coverage TO fpds_analytics_api_readonly;

GRANT SELECT ON analytics_api.contacts_office_roster TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.contacts_profile_fy TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.contacts_naics_buyers TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.contacts_recompete_handlers TO fpds_analytics_api_readonly;
GRANT SELECT ON analytics_api.contacts_office_coverage TO fpds_analytics_api_readonly;

-- ============================================================
-- Verification
-- ============================================================

SELECT 'office_roster' AS dataset, COUNT(*) AS rows FROM analytics_api.contacts_office_roster LIMIT 1;
SELECT 'naics_buyers' AS dataset, COUNT(*) AS rows FROM analytics_api.contacts_naics_buyers LIMIT 1;
SELECT 'recompete_handlers' AS dataset, COUNT(*) AS rows FROM analytics_api.contacts_recompete_handlers LIMIT 1;
