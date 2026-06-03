-- Build 6: Funding vs. Contracting Agency Mismatch
--
-- Schema: customer_intelligence (created in Build 1)
-- MV grain: funding_agency_id × contracting_agency_id × contracting_office_id × fiscal_year
-- Estimated rows: 500K–1M
-- Build time: 30–60 min on 99M source rows
--
-- Shows money flowing from funding agencies to contracting agencies.
-- Answers "is GSA buying this on NOAA's behalf?"
--
-- Prerequisites: P1, P2 (org dims)

-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW
-- ═══════════════════════════════════════════════════════════════════════════

CREATE MATERIALIZED VIEW customer_intelligence.mv_funding_contracting_flow_fy AS
SELECT
    fa.funding_dept_id,
    fa.funding_agency_id,
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    (fa.funding_agency_id IS NOT NULL AND fa.funding_agency_id != ''
     AND fa.funding_agency_id != fa.contracting_agency_id) AS is_cross_agency,
    (fa.funding_dept_id IS NOT NULL AND fa.funding_dept_id != ''
     AND fa.funding_dept_id != fa.contracting_dept_id) AS is_cross_department,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END AS fiscal_year,

    COUNT(*) AS total_action_count,
    SUM(NULLIF(fa.obligated_amount, '')::numeric) AS net_obligated_amount,
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    COUNT(DISTINCT fa.principal_naics_code) AS distinct_naics_count,
    MODE() WITHIN GROUP (ORDER BY fa.principal_naics_code) AS top_naics_code,
    MODE() WITHIN GROUP (ORDER BY fa.product_or_service_code) AS top_psc_code

FROM public.fpds_actions fa
WHERE fa.funding_agency_id IS NOT NULL AND fa.funding_agency_id != ''
  AND fa.contracting_agency_id IS NOT NULL AND fa.contracting_agency_id != ''
  AND fa.contracting_office_id IS NOT NULL AND fa.contracting_office_id != ''
  AND fa.signed_date IS NOT NULL AND fa.signed_date != ''
GROUP BY
    fa.funding_dept_id,
    fa.funding_agency_id,
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    (fa.funding_agency_id IS NOT NULL AND fa.funding_agency_id != ''
     AND fa.funding_agency_id != fa.contracting_agency_id),
    (fa.funding_dept_id IS NOT NULL AND fa.funding_dept_id != ''
     AND fa.funding_dept_id != fa.contracting_dept_id),
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;


-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS mv_funding_flow_funding_idx
    ON customer_intelligence.mv_funding_contracting_flow_fy
    (funding_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_funding_flow_contracting_idx
    ON customer_intelligence.mv_funding_contracting_flow_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_funding_flow_cross_dept_idx
    ON customer_intelligence.mv_funding_contracting_flow_fy
    (is_cross_department, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_funding_flow_office_idx
    ON customer_intelligence.mv_funding_contracting_flow_fy
    (contracting_office_id, fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Cross-agency funding flows (mismatch only)
CREATE OR REPLACE VIEW customer_intelligence.report_deck_funding_mismatch_flows_fy AS
SELECT
    mv.fiscal_year,
    mv.funding_dept_id,
    fdm.department_name AS funding_dept_name,
    fdm.department_short_name AS funding_dept_short_name,
    mv.funding_agency_id,
    fam.agency_name AS funding_agency_name,
    fam.agency_short_name AS funding_agency_short_name,
    mv.contracting_dept_id,
    cdm.department_name AS contracting_dept_name,
    cdm.department_short_name AS contracting_dept_short_name,
    mv.contracting_agency_id,
    cam.agency_name AS contracting_agency_name,
    cam.agency_short_name AS contracting_agency_short_name,
    mv.is_cross_department,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS net_obligated_amount,
    SUM(mv.distinct_vendor_count) AS distinct_vendor_count,
    SUM(mv.distinct_naics_count) AS distinct_naics_count
FROM customer_intelligence.mv_funding_contracting_flow_fy mv
LEFT JOIN analytics_dims.fpds_department_map fdm ON mv.funding_dept_id = fdm.department_id
LEFT JOIN analytics_dims.fpds_agency_map fam ON mv.funding_agency_id = fam.agency_id
LEFT JOIN analytics_dims.fpds_department_map cdm ON mv.contracting_dept_id = cdm.department_id
LEFT JOIN analytics_dims.fpds_agency_map cam ON mv.contracting_agency_id = cam.agency_id
WHERE mv.is_cross_agency = true
GROUP BY
    mv.fiscal_year, mv.funding_dept_id, fdm.department_name, fdm.department_short_name,
    mv.funding_agency_id, fam.agency_name, fam.agency_short_name,
    mv.contracting_dept_id, cdm.department_name, cdm.department_short_name,
    mv.contracting_agency_id, cam.agency_name, cam.agency_short_name,
    mv.is_cross_department;


-- Assisted acquisition summary: per contracting agency, how much is funded by others
CREATE OR REPLACE VIEW customer_intelligence.report_deck_assisted_acquisition_fy AS
SELECT
    mv.fiscal_year,
    mv.contracting_dept_id,
    cdm.department_name AS contracting_dept_name,
    cdm.department_short_name AS contracting_dept_short_name,
    mv.contracting_agency_id,
    cam.agency_name AS contracting_agency_name,
    cam.agency_short_name AS contracting_agency_short_name,
    SUM(mv.total_action_count) AS total_action_count,
    SUM(mv.net_obligated_amount) AS total_obligated,
    SUM(CASE WHEN mv.is_cross_agency THEN mv.total_action_count ELSE 0 END) AS cross_agency_action_count,
    SUM(CASE WHEN mv.is_cross_agency THEN mv.net_obligated_amount ELSE 0 END) AS cross_agency_obligated,
    SUM(CASE WHEN mv.is_cross_department THEN mv.total_action_count ELSE 0 END) AS cross_dept_action_count,
    SUM(CASE WHEN mv.is_cross_department THEN mv.net_obligated_amount ELSE 0 END) AS cross_dept_obligated,
    ROUND(SUM(CASE WHEN mv.is_cross_agency THEN mv.net_obligated_amount ELSE 0 END)
        / NULLIF(SUM(mv.net_obligated_amount), 0), 4) AS cross_agency_obligation_share,
    ROUND(SUM(CASE WHEN mv.is_cross_department THEN mv.net_obligated_amount ELSE 0 END)
        / NULLIF(SUM(mv.net_obligated_amount), 0), 4) AS cross_dept_obligation_share
FROM customer_intelligence.mv_funding_contracting_flow_fy mv
LEFT JOIN analytics_dims.fpds_department_map cdm ON mv.contracting_dept_id = cdm.department_id
LEFT JOIN analytics_dims.fpds_agency_map cam ON mv.contracting_agency_id = cam.agency_id
GROUP BY
    mv.fiscal_year, mv.contracting_dept_id, cdm.department_name, cdm.department_short_name,
    mv.contracting_agency_id, cam.agency_name, cam.agency_short_name;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.customer_funding_mismatch_flows_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_funding_mismatch_flows_fy;

COMMENT ON VIEW analytics_api.customer_funding_mismatch_flows_fy IS
'Cross-agency funding flows by fiscal year. Shows money flowing from funding agencies to different contracting agencies. Answers: is GSA buying this on NOAA behalf?';

CREATE OR REPLACE VIEW analytics_api.customer_assisted_acquisition_fy
WITH (security_barrier = true) AS
SELECT * FROM customer_intelligence.report_deck_assisted_acquisition_fy;

COMMENT ON VIEW analytics_api.customer_assisted_acquisition_fy IS
'Per-contracting-agency assisted acquisition summary. Shows what share of an agency contracting workload is funded by another agency or department.';
