-- 051_topic_intel_mv_contract_type.sql
-- Topic Intelligence Package — Phase 2d: Contract Type Profile MV
--
-- How do topics intersect with contract/pricing types?
-- "Cloud Migration at DOD is 70% FFP, 20% T&M, 10% cost-type."
--
-- Contract pricing normalized through analytics_dims.fpds_contract_pricing_map
-- into pricing families (Fixed Price, Cost Reimbursement, T&M / LH, etc.)
-- with risk profile classification.
--
-- Grain: department_code × contracting_office_id × topic × pricing_family
--
-- Run: nohup psql $CONN -f sql/051_topic_intel_mv_contract_type.sql > /tmp/051_contract_type.log 2>&1 &
-- Expected duration: 15-45 minutes
-- Verify: SELECT count(*) FROM topic_intelligence.mv_contract_type_profile;
--
-- Depends on: 044 (schema)
-- Reference: Build Spec v1.1 §2d
-- Date: 2026-06-18

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

\echo '=== 051: Building mv_contract_type_profile ==='
\echo 'Start time:'
SELECT now();

------------------------------------------------------------------------
-- Drop if rebuilding
------------------------------------------------------------------------
DROP MATERIALIZED VIEW IF EXISTS topic_intelligence.mv_contract_type_profile CASCADE;

------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------
CREATE MATERIALIZED VIEW topic_intelligence.mv_contract_type_profile AS
SELECT
  -- USASpending org
  ta.department_code,
  -- FPDS org hierarchy
  COALESCE(om.contracting_dept_id, 'UNKNOWN') AS contracting_dept_id,
  COALESCE(dm.department_name, pa.awarding_agency_name) AS contracting_dept_name,
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code) AS contracting_agency_id,
  COALESCE(am.agency_name, pa.awarding_agency_name) AS contracting_agency_name,
  pa.awarding_office_code AS contracting_office_id,
  COALESCE(om.contracting_office_name, pa.awarding_office_name) AS contracting_office_name,
  -- Topic identity
  ta.merged_model_id AS model_id,
  ta.merged_topic_id AS topic_id,
  tl.label AS topic_label,
  -- Pricing dimension (normalized through dim table)
  COALESCE(pm.pricing_family, 'Unknown') AS pricing_family,
  pa.type_of_contract_pricing AS pricing_type_raw,
  COALESCE(pm.risk_profile, 'UNKNOWN') AS risk_profile,
  -- Metrics
  count(*) AS assignment_count,
  round(
    100.0 * count(*) / SUM(count(*)) OVER (
      PARTITION BY ta.department_code, ta.merged_model_id, ta.merged_topic_id
    ),
    2
  ) AS pricing_share,
  sum(pa.total_obligated_amount) AS obligated_amount
FROM v2.topic_assignments ta
JOIN public.prime_awards pa
  ON ta.department_code = pa.department_code
  AND ta.record_id = pa.id
LEFT JOIN analytics_dims.fpds_contract_pricing_map pm
  ON pa.type_of_contract_pricing = pm.raw_desc
LEFT JOIN analytics_dims.fpds_contracting_office_map om
  ON pa.awarding_office_code = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_department_map dm
  ON om.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am
  ON om.contracting_agency_id = am.agency_id
JOIN v2.topic_labels tl
  ON ta.merged_model_id = tl.model_id
  AND ta.merged_topic_id = tl.topic_id
WHERE ta.corpus_type = 'awards'
  AND ta.merged_topic_id IS NOT NULL
  AND tl.corpus_type = 'merged'
GROUP BY
  ta.department_code,
  COALESCE(om.contracting_dept_id, 'UNKNOWN'),
  COALESCE(dm.department_name, pa.awarding_agency_name),
  COALESCE(om.contracting_agency_id, pa.awarding_agency_code),
  COALESCE(am.agency_name, pa.awarding_agency_name),
  pa.awarding_office_code,
  COALESCE(om.contracting_office_name, pa.awarding_office_name),
  ta.merged_model_id, ta.merged_topic_id, tl.label,
  COALESCE(pm.pricing_family, 'Unknown'),
  pa.type_of_contract_pricing,
  COALESCE(pm.risk_profile, 'UNKNOWN');

\echo 'MV built. Creating indexes...'

------------------------------------------------------------------------
-- Indexes
------------------------------------------------------------------------
CREATE INDEX idx_contract_type_dept
  ON topic_intelligence.mv_contract_type_profile (department_code);

CREATE INDEX idx_contract_type_fpds_dept
  ON topic_intelligence.mv_contract_type_profile (contracting_dept_id);

CREATE INDEX idx_contract_type_fpds_office
  ON topic_intelligence.mv_contract_type_profile (contracting_office_id);

CREATE INDEX idx_contract_type_model_topic
  ON topic_intelligence.mv_contract_type_profile (model_id, topic_id);

CREATE INDEX idx_contract_type_family
  ON topic_intelligence.mv_contract_type_profile (pricing_family);

CREATE INDEX idx_contract_type_dept_family
  ON topic_intelligence.mv_contract_type_profile (department_code, pricing_family);

CREATE INDEX idx_contract_type_risk
  ON topic_intelligence.mv_contract_type_profile (risk_profile);

\echo 'Indexes built. Granting access...'

------------------------------------------------------------------------
-- Grants
------------------------------------------------------------------------
GRANT SELECT ON topic_intelligence.mv_contract_type_profile TO fpds_analytics_api_readonly;

------------------------------------------------------------------------
-- Verify
------------------------------------------------------------------------
\echo 'Verification:'
SELECT
  count(*) AS total_rows,
  count(DISTINCT department_code) AS departments,
  count(DISTINCT pricing_family) AS pricing_families,
  count(DISTINCT (model_id, topic_id)) AS distinct_topics,
  round(sum(obligated_amount) / 1e9, 1) AS total_obligated_billions
FROM topic_intelligence.mv_contract_type_profile;

\echo ''
\echo 'Pricing family distribution:'
SELECT pricing_family, risk_profile, count(*) AS rows,
  round(sum(obligated_amount) / 1e9, 1) AS obligated_billions
FROM topic_intelligence.mv_contract_type_profile
GROUP BY pricing_family, risk_profile
ORDER BY rows DESC;

\echo 'End time:'
SELECT now();
\echo '=== 051: COMPLETE ==='
