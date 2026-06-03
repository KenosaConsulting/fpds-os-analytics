-- Build 5: Vehicle / Acquisition Path Mix
--
-- Schema: competition_dynamics (existing)
-- MV grain: contracting_agency_id × contracting_office_id × vehicle_family × fiscal_year
-- Estimated rows: 500K–2M
-- Build time: 30–60 min on 99M source rows
--
-- Classifies awards by acquisition path: GWAC, IDIQ, GSA Schedule, BPA,
-- BOA, or Open Market. Answers "do I need a vehicle to compete?"
--
-- Prerequisites: P5 (fpds_referenced_type_map)

-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW
-- ═══════════════════════════════════════════════════════════════════════════

-- Disable statement timeout for MV builds (99M row scans)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE MATERIALIZED VIEW competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy AS
SELECT
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(rtm.vehicle_family,
        CASE WHEN fa.referenced_type IS NULL OR fa.referenced_type = ''
             THEN 'Open Market' ELSE 'Unknown' END
    ) AS vehicle_family,
    COALESCE(fa.referenced_type, 'NONE') AS referenced_type_code,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,

    -- Volume
    COUNT(*) AS total_action_count,
    SUM(CASE WHEN atm.is_contract_scope THEN 1 ELSE 0 END) AS contract_scope_action_count,

    -- Obligations
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    SUM(CASE WHEN atm.is_contract_scope
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS contract_scope_obligated,

    -- Market structure
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    SUM(CASE WHEN ecm.is_competed THEN 1 ELSE 0 END) AS competed_action_count,
    SUM(CASE WHEN ecm.is_not_competed THEN 1 ELSE 0 END) AS not_competed_action_count,
    SUM(CASE WHEN fa.is_small_business = 'true'
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS small_biz_obligated,
    AVG(NULLIF(fa.offers_received, '')::numeric) AS avg_offers_received

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_referenced_type_map rtm
    ON fa.referenced_type = rtm.raw_code
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.contracting_office_id IS NOT NULL AND fa.contracting_office_id != ''
  AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    COALESCE(rtm.vehicle_family,
        CASE WHEN fa.referenced_type IS NULL OR fa.referenced_type = ''
             THEN 'Open Market' ELSE 'Unknown' END),
    COALESCE(fa.referenced_type, 'NONE'),
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;


-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE UNIQUE INDEX IF NOT EXISTS mv_vehicle_mix_uq
    ON competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy
    (contracting_agency_id, contracting_office_id, vehicle_family, referenced_type_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_mix_family_idx
    ON competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy
    (vehicle_family, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_mix_agency_idx
    ON competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_mix_dept_idx
    ON competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_mix_office_idx
    ON competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy
    (contracting_office_id, fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Government-wide vehicle mix trend
CREATE OR REPLACE VIEW competition_dynamics.report_deck_vehicle_mix_trend_fy AS
SELECT
    mv.vehicle_family,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    ROUND(SUM(mv.small_biz_obligated) / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,
    ROUND(SUM(mv.competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS competed_action_share,
    COUNT(DISTINCT mv.contracting_agency_id) AS distinct_agency_count
FROM competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy mv
GROUP BY mv.vehicle_family, mv.fiscal_year;


-- Agency vehicle mix
CREATE OR REPLACE VIEW competition_dynamics.report_deck_vehicle_mix_agency_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    dm.department_short_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.vehicle_family,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.competed_action_count) AS competed_action_count,
    SUM(mv.not_competed_action_count) AS not_competed_action_count,
    SUM(mv.small_biz_obligated) AS small_biz_obligated,
    ROUND(SUM(mv.small_biz_obligated) / NULLIF(SUM(mv.net_obligated_amount), 0), 4)
        AS small_biz_obligation_share,
    ROUND(SUM(mv.competed_action_count)::numeric
        / NULLIF(SUM(mv.competed_action_count) + SUM(mv.not_competed_action_count), 0), 4)
        AS competed_action_share
FROM competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
GROUP BY mv.contracting_dept_id, dm.department_name, dm.department_short_name,
         mv.contracting_agency_id, am.agency_name, am.agency_short_name,
         mv.vehicle_family, mv.fiscal_year;


-- Office vehicle mix
CREATE OR REPLACE VIEW competition_dynamics.report_deck_vehicle_mix_office_fy AS
SELECT
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    mv.contracting_office_id,
    om.contracting_office_name,
    mv.vehicle_family,
    mv.fiscal_year,
    CASE
        WHEN mv.fiscal_year = (
            CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                 THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                 ELSE EXTRACT(year FROM CURRENT_DATE)::int END
        ) THEN true ELSE false
    END AS is_current_fiscal_year_ytd,
    mv.total_action_count,
    mv.net_obligated_amount,
    mv.distinct_vendor_count,
    mv.competed_action_count,
    mv.not_competed_action_count,
    mv.small_biz_obligated,
    mv.avg_offers_received,
    ROUND(mv.small_biz_obligated / NULLIF(mv.net_obligated_amount, 0), 4)
        AS small_biz_obligation_share,
    ROUND(mv.competed_action_count::numeric
        / NULLIF(mv.competed_action_count + mv.not_competed_action_count, 0), 4)
        AS competed_action_share
FROM competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON mv.contracting_office_id = om.contracting_office_id;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.acquisition_vehicle_mix_trend_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_vehicle_mix_trend_fy;

COMMENT ON VIEW analytics_api.acquisition_vehicle_mix_trend_fy IS
'Government-wide vehicle family trends by fiscal year. Shows GWAC, IDIQ, GSA Schedule, BPA, BOA, and Open Market spending over time.';

CREATE OR REPLACE VIEW analytics_api.acquisition_agency_vehicle_mix_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_vehicle_mix_agency_fy;

COMMENT ON VIEW analytics_api.acquisition_agency_vehicle_mix_fy IS
'Per-agency vehicle mix by fiscal year. Answers: does this customer buy through GWACs, IDIQs, or open market?';

CREATE OR REPLACE VIEW analytics_api.acquisition_office_vehicle_mix_fy
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_vehicle_mix_office_fy;

COMMENT ON VIEW analytics_api.acquisition_office_vehicle_mix_fy IS
'Per-office vehicle mix. Office-level acquisition path detail with competition and small business metrics per vehicle family.';
