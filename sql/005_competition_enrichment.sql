-- Competition dynamics enrichment: reason not competed dimension and views.
--
-- Adds context for WHY contracts are not competed, enriching the existing
-- competition_dynamics package.
--
-- Run after 001_analytics_api_facade.sql.

-- ─── Dimension table: reason not competed ───────────────────────────────────

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_reason_not_competed_map (
    raw_code            text PRIMARY KEY,
    label               text NOT NULL,
    reason_family       text NOT NULL,
    far_reference       text,
    is_sole_source      boolean NOT NULL DEFAULT false,
    is_statutory        boolean NOT NULL DEFAULT false,
    is_market_driven    boolean NOT NULL DEFAULT false,
    is_procedural       boolean NOT NULL DEFAULT false,
    sort_order          integer,
    notes               text
);

COMMENT ON TABLE analytics_dims.fpds_reason_not_competed_map IS
'Maps FPDS reason_not_competed codes to human-readable labels and classification families. Used to explain WHY contracts are not competed.';

INSERT INTO analytics_dims.fpds_reason_not_competed_map
    (raw_code, label, reason_family, far_reference, is_sole_source, is_statutory, is_market_driven, is_procedural, sort_order, notes)
VALUES
    ('ONE', 'Only One Source', 'Sole source',       'FAR 6.302-1',       true,  false, true,  false, 10,  'Only one responsible source and no other supplies or services will satisfy requirements.'),
    ('UNQ', 'Unique Source',   'Sole source',       'FAR 6.302-1(b)(1)', true,  false, true,  false, 20,  'Unique source — specific capability or item available from only one vendor.'),
    ('BND', 'Brand Name',      'Sole source',       'FAR 6.302-1(c)',    true,  false, true,  false, 30,  'Brand name description justifies a sole-source acquisition.'),
    ('PDR', 'Patent/Data Rights', 'Sole source',    'FAR 6.302-1(b)(2)', true,  false, true,  false, 40,  'Patent or data rights restrict competition to one source.'),
    ('STD', 'Standardization', 'Sole source',       'FAR 6.302-1(b)(4)', true,  false, true,  false, 50,  'Standardization requirements limit competition to one source.'),
    ('FOC', 'Follow-On Contract', 'Follow-on',      'FAR 6.302-1(a)(2)', true,  false, false, false, 60,  'Follow-on contract awarded to existing contractor. Strong incumbency indicator.'),
    ('URG', 'Urgency',         'Urgency/emergency', 'FAR 6.302-2',       false, false, false, true,  70,  'Unusual and compelling urgency prevents full competition.'),
    ('MES', 'Mobilization/Essential R&D', 'National interest', 'FAR 6.302-3', false, true, false, false, 80,  'Industrial mobilization, engineering, developmental or research capability, or expert services.'),
    ('IA',  'International Agreement', 'Statutory',  'FAR 6.302-4',       false, true,  false, false, 90,  'International agreement or treaty requires non-competitive acquisition.'),
    ('OTH', 'Authorized by Statute', 'Statutory',   'FAR 6.302-5',       false, true,  false, false, 100, 'Statute authorizes or requires non-competitive acquisition. Broad category.'),
    ('NS',  'National Security', 'National interest', 'FAR 6.302-6',     false, true,  false, false, 110, 'Disclosure of needs would compromise national security.'),
    ('PI',  'Public Interest',  'Statutory',         'FAR 6.302-7',       false, true,  false, false, 120, 'Agency head determines full competition is not in the public interest.'),
    ('SP2', 'SAP Non-Competition', 'Simplified',    'FAR 13',            false, false, false, true,  130, 'Simplified Acquisition Procedures — below SAP threshold, no competition required.'),
    ('MPT', 'Micro-Purchase Threshold', 'Simplified', NULL,              false, false, false, true,  140, 'Below micro-purchase threshold — competition not required.'),
    ('UT',  'Utilities',       'Regulated',         'FAR 41.2',          false, false, true,  false, 150, 'Regulated utility services — no market competition available.'),
    ('RES', 'Authorized Resale', 'Statutory',       'FAR 6.302-5(a)(2)(ii)', false, true, false, false, 160, 'Authorized resale under specific statutory authority.'),
    ('UR',  'Unsolicited Research Proposal', 'Sole source', 'FAR 6.302-1(a)(2)(i)', true, false, false, false, 170, 'Unsolicited research proposal accepted — sole source by nature.')
ON CONFLICT (raw_code) DO NOTHING;


-- ─── Report view: not-competed reasons by department and fiscal year ────────

-- This view reads directly from fpds_actions (not from an MV) because
-- reason_not_competed is only populated on ~16% of actions. A dedicated MV
-- would be small but adds maintenance burden for limited rows.
-- If performance becomes a concern, materialize this as a second step.

CREATE OR REPLACE VIEW competition_dynamics.report_deck_not_competed_reasons_fy AS
SELECT
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,
    fa.reason_not_competed AS reason_code,
    rnc.label AS reason_label,
    rnc.reason_family,
    rnc.far_reference,
    rnc.is_sole_source,
    rnc.is_statutory,
    rnc.is_market_driven,
    rnc.is_procedural,
    COUNT(*) AS action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(CASE WHEN NULLIF(fa.obligated_amount, '')::numeric > 0
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS positive_obligated_amount,
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    COUNT(DISTINCT fa.contracting_agency_id) AS distinct_agency_count
FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_reason_not_competed_map rnc
    ON fa.reason_not_competed = rnc.raw_code
WHERE fa.reason_not_competed IS NOT NULL
  AND fa.reason_not_competed != ''
  AND fa.signed_date IS NOT NULL
  AND fa.signed_date != ''
GROUP BY
    fa.contracting_dept_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END,
    fa.reason_not_competed,
    rnc.label,
    rnc.reason_family,
    rnc.far_reference,
    rnc.is_sole_source,
    rnc.is_statutory,
    rnc.is_market_driven,
    rnc.is_procedural
ORDER BY fa.contracting_dept_id, fiscal_year, net_obligated_amount DESC;

COMMENT ON VIEW competition_dynamics.report_deck_not_competed_reasons_fy IS
'Non-competed contract actions broken out by reason code, department, and fiscal year. Shows WHY contracts are not competed: sole source, statutory authority, urgency, simplified procedures, follow-on incumbency, etc.';


-- ─── Facade views ──────────────────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.competition_not_competed_reasons_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_not_competed_reasons_fy;

COMMENT ON VIEW analytics_api.competition_not_competed_reasons_fy IS
'Non-competed actions by reason, department, and fiscal year. Enriches competition dynamics with the WHY behind non-competition: sole source, follow-on, statutory authority, urgency, or simplified procedures.';


CREATE OR REPLACE VIEW analytics_api.dim_reason_not_competed_codes
WITH (security_barrier = true) AS
SELECT
    raw_code,
    label,
    reason_family,
    far_reference,
    is_sole_source,
    is_statutory,
    is_market_driven,
    is_procedural,
    sort_order,
    notes
FROM analytics_dims.fpds_reason_not_competed_map;

COMMENT ON VIEW analytics_api.dim_reason_not_competed_codes IS
'Reason-not-competed code lookup. Maps FPDS codes to human-readable labels, FAR references, and classification flags (sole source, statutory, market-driven, procedural).';
