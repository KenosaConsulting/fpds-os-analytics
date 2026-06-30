-- ──────────────────────────────────────────────────────────────────────────────
-- 072: Contract Modification Intelligence
-- ──────────────────────────────────────────────────────────────────────────────
-- Analyzes every contract's modification trail to surface strategic signals
-- about contract health, incumbent lock-in, and recompete viability.
--
-- Classifies modification patterns (scope growth, option-heavy, funding-only,
-- change-driven) and computes a lock-in score indicating incumbent entrenchment.
-- Compares modification activity against agency×NAICS medians to flag anomalies.
--
-- Grain: one row per piid
-- ──────────────────────────────────────────────────────────────────────────────

BEGIN;

-- ── Drop existing ────────────────────────────────────────────────────────────

DROP MATERIALIZED VIEW IF EXISTS pipeline_intelligence.mv_contract_modification_intelligence CASCADE;

-- ── Materialized View ────────────────────────────────────────────────────────

CREATE MATERIALIZED VIEW pipeline_intelligence.mv_contract_modification_intelligence AS
WITH
-- One row per modification with aggregated financials across transactions
mod_base AS (
    SELECT
        piid,
        mod_number,
        MIN(reason_for_modification) AS reason_for_modification,
        MIN(signed_date)::date AS signed_date,
        SUM(obligated_amount)::numeric AS obligated_amount
    FROM pipeline_intelligence.report_deck_contract_transactions
    WHERE piid IS NOT NULL
      AND piid != ''
      AND mod_number IS NOT NULL
      AND mod_number != ''
      AND mod_number != '0'
    GROUP BY piid, mod_number
),

-- Per-contract modification trail aggregates
mod_aggregates AS (
    SELECT
        piid,
        COUNT(*) AS mod_count,
        STRING_AGG(
            reason_for_modification,
            '-' ORDER BY signed_date ASC, mod_number ASC
        ) AS mod_pattern,
        MIN(signed_date) AS first_mod_date,
        MAX(signed_date) AS last_mod_date,
        ROUND(
            (MAX(signed_date) - MIN(signed_date))::numeric / 30.4375,
            1
        ) AS mod_span_months,
        COUNT(*) FILTER (WHERE reason_for_modification = 'B') AS scope_growth_count,
        COUNT(*) FILTER (WHERE reason_for_modification = 'F') AS option_exercise_count,
        COUNT(*) FILTER (WHERE reason_for_modification = 'C') AS funding_mod_count,
        COUNT(*) FILTER (WHERE reason_for_modification = 'A') AS change_order_count,
        COUNT(*) FILTER (WHERE obligated_amount < 0) AS deobligation_count,
        SUM(obligated_amount) FILTER (WHERE obligated_amount < 0) AS deobligation_total,
        SUM(obligated_amount) AS net_obligation_change,
        MAX(ABS(obligated_amount)) AS max_single_mod_amount
    FROM mod_base
    GROUP BY piid
),

-- Base award context (one row per piid from mod_number = '0' or null/empty)
base_awards AS (
    SELECT DISTINCT ON (piid)
        piid,
        signed_date AS base_signed_date,
        obligated_amount AS base_obligated_amount,
        current_completion_date AS base_completion_date,
        vendor_name,
        uei,
        contracting_dept_id,
        contracting_dept_name,
        contracting_agency_id,
        contracting_agency_name,
        contracting_office_id,
        contracting_office_name,
        principal_naics_code,
        principal_naics_code_desc,
        product_or_service_code,
        product_or_service_code_desc,
        extent_competed,
        extent_competed_desc
    FROM pipeline_intelligence.report_deck_contract_transactions
    WHERE piid IS NOT NULL
      AND piid != ''
      AND (mod_number = '0' OR mod_number IS NULL OR mod_number = '')
    ORDER BY piid, signed_date ASC NULLS LAST
),

-- Which contracts have any cost-reimbursement pricing
cost_reimbursement_check AS (
    SELECT DISTINCT
        fa.piid,
        TRUE AS is_cost_reimbursement
    FROM public.fpds_actions fa
    JOIN analytics_dims.fpds_contract_pricing_map pm
        ON fa.type_of_contract_pricing = pm.raw_desc
    WHERE pm.is_cost_type = TRUE
      AND fa.piid IS NOT NULL
      AND fa.piid != ''
),

-- Median mod_count per agency×NAICS (for anomaly detection)
agency_naics_medians AS (
    SELECT
        contracting_agency_id,
        principal_naics_code,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY COALESCE(ma.mod_count, 0)) AS median_mod_count,
        COUNT(*) AS cell_count
    FROM base_awards ba
    LEFT JOIN mod_aggregates ma ON ba.piid = ma.piid
    WHERE ba.contracting_agency_id IS NOT NULL
      AND ba.contracting_agency_id != ''
      AND ba.principal_naics_code IS NOT NULL
      AND ba.principal_naics_code != ''
    GROUP BY contracting_agency_id, principal_naics_code
),

-- Agency-wide median fallback for cells with fewer than 5 contracts
agency_medians AS (
    SELECT
        contracting_agency_id,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY COALESCE(ma.mod_count, 0)) AS median_mod_count
    FROM base_awards ba
    LEFT JOIN mod_aggregates ma ON ba.piid = ma.piid
    WHERE ba.contracting_agency_id IS NOT NULL
      AND ba.contracting_agency_id != ''
    GROUP BY contracting_agency_id
),

-- Combine base context with mod aggregates and median references
combined AS (
    SELECT
        ba.piid,

        -- Base contract context
        ba.base_signed_date,
        ba.base_obligated_amount,
        ba.base_completion_date,
        ba.vendor_name,
        ba.uei,
        ba.contracting_dept_id,
        ba.contracting_dept_name,
        ba.contracting_agency_id,
        ba.contracting_agency_name,
        ba.contracting_office_id,
        ba.contracting_office_name,
        ba.principal_naics_code,
        ba.principal_naics_code_desc,
        ba.product_or_service_code,
        ba.product_or_service_code_desc,
        ba.extent_competed,
        ba.extent_competed_desc,

        -- Modification trail
        COALESCE(ma.mod_count, 0) AS mod_count,
        ma.mod_pattern,
        ma.first_mod_date,
        ma.last_mod_date,
        ma.mod_span_months,
        COALESCE(ma.scope_growth_count, 0) AS scope_growth_count,
        COALESCE(ma.option_exercise_count, 0) AS option_exercise_count,
        COALESCE(ma.funding_mod_count, 0) AS funding_mod_count,
        COALESCE(ma.change_order_count, 0) AS change_order_count,
        COALESCE(ma.deobligation_count, 0) AS deobligation_count,
        ma.deobligation_total,
        ma.net_obligation_change,
        ma.max_single_mod_amount,

        -- Pricing signal
        COALESCE(cr.is_cost_reimbursement, FALSE) AS is_cost_reimbursement,

        -- Agency×NAICS median (with fallback for small cells)
        COALESCE(
            CASE WHEN anm.cell_count >= 5
                THEN anm.median_mod_count
                ELSE am.median_mod_count
            END,
            0
        ) AS agency_naics_median_mod_count

    FROM base_awards ba
    LEFT JOIN mod_aggregates ma
        ON ba.piid = ma.piid
    LEFT JOIN cost_reimbursement_check cr
        ON ba.piid = cr.piid
    LEFT JOIN agency_naics_medians anm
        ON ba.contracting_agency_id = anm.contracting_agency_id
       AND ba.principal_naics_code = anm.principal_naics_code
    LEFT JOIN agency_medians am
        ON ba.contracting_agency_id = am.contracting_agency_id
),

-- Compute lock-in score and pattern classification
scored AS (
    SELECT
        *,
        LEAST(
            COALESCE(scope_growth_count, 0) * 15
            + COALESCE(option_exercise_count, 0) * 20
            + CASE WHEN COALESCE(mod_span_months, 0) > 24 THEN 15 ELSE 0 END
            + CASE WHEN COALESCE(deobligation_count, 0) = 0 THEN 10 ELSE 0 END,
            100
        ) AS lock_in_score,
        CASE
            WHEN mod_count <= 1 THEN 'static'
            WHEN COALESCE(scope_growth_count, 0) >= 3 THEN 'scope_growth'
            WHEN COALESCE(option_exercise_count, 0) >= 1
             AND COALESCE(scope_growth_count, 0) < 3 THEN 'option_heavy'
            WHEN mod_count > 0
             AND COALESCE(scope_growth_count, 0) = 0
             AND COALESCE(option_exercise_count, 0) = 0
             AND COALESCE(change_order_count, 0) = 0 THEN 'funding_only'
            WHEN COALESCE(change_order_count, 0) >= 2 THEN 'change_driven'
            ELSE 'mixed'
        END AS pattern_classification,
        CASE
            WHEN agency_naics_median_mod_count > 0
            THEN ROUND(
                (mod_count::numeric / agency_naics_median_mod_count) * 100,
                1
            )
            ELSE NULL
        END AS mod_count_vs_median_pct
    FROM combined
)

SELECT
    piid,
    vendor_name,
    uei,
    contracting_dept_id,
    contracting_dept_name,
    contracting_agency_id,
    contracting_agency_name,
    contracting_office_id,
    contracting_office_name,
    principal_naics_code,
    principal_naics_code_desc,
    product_or_service_code,
    product_or_service_code_desc,
    extent_competed,
    extent_competed_desc,
    base_signed_date,
    base_obligated_amount,
    base_completion_date,
    mod_count,
    mod_pattern,
    first_mod_date,
    last_mod_date,
    mod_span_months,
    scope_growth_count,
    option_exercise_count,
    funding_mod_count,
    change_order_count,
    deobligation_count,
    deobligation_total,
    net_obligation_change,
    max_single_mod_amount,
    is_cost_reimbursement,
    pattern_classification,
    lock_in_score,
    agency_naics_median_mod_count,
    mod_count_vs_median_pct,
    (
        mod_count > 2 * agency_naics_median_mod_count
        OR lock_in_score >= 70
    ) AS anomaly_flag
FROM scored;

COMMENT ON MATERIALIZED VIEW pipeline_intelligence.mv_contract_modification_intelligence IS
    'Contract modification trail intelligence: pattern classification, lock-in scoring, and agency×NAICS anomaly detection. Grain: one row per piid.';

-- ── Report deck view (security_barrier) ──────────────────────────────────────

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contract_modification_intelligence
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.mv_contract_modification_intelligence;

COMMENT ON VIEW pipeline_intelligence.report_deck_contract_modification_intelligence IS
    'API facade for mv_contract_modification_intelligence with security_barrier.';

-- ── API facade (analytics_api) ───────────────────────────────────────────────

CREATE OR REPLACE VIEW analytics_api.pipeline_modification_intelligence
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.report_deck_contract_modification_intelligence;

COMMENT ON VIEW analytics_api.pipeline_modification_intelligence IS
    'Contract modification intelligence: analyzes modification trail patterns, computes lock-in scores, and flags anomalous modification activity compared to agency×NAICS medians.';

-- ── Grants ───────────────────────────────────────────────────────────────────

GRANT SELECT ON pipeline_intelligence.report_deck_contract_modification_intelligence
    TO fpds_analytics_api_readonly;

GRANT SELECT ON analytics_api.pipeline_modification_intelligence
    TO fpds_analytics_api_readonly;

COMMIT;
