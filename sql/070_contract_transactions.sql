-- ──────────────────────────────────────────────────────────────────────────────
-- 070: Contract Transaction History
-- ──────────────────────────────────────────────────────────────────────────────
-- Exposes the transaction-level detail from fpds_actions so analysts and
-- AI agents can see what each modification on a contract actually did —
-- the description, reason, obligation amount, and dates for every action.
--
-- This is the "drill-down" layer: our pre-aggregated analytics views tell
-- you WHICH contracts are expiring; this view tells you WHAT HAPPENED on
-- each one.  The description_of_contract_requirement and
-- reason_for_modification_desc fields are the key differentiators — they
-- give you the SOW language and mod rationale that no aggregated view can.
--
-- Grain: one row per (piid, mod_number, transaction_number)
-- Required filter: piid (indexed)
-- ──────────────────────────────────────────────────────────────────────────────

BEGIN;

-- ── View: pipeline_intelligence.v_contract_transactions ──────────────────────

CREATE OR REPLACE VIEW pipeline_intelligence.v_contract_transactions AS
SELECT
    -- Identity
    a.piid,
    a.mod_number,
    a.transaction_number,
    a.shard_month,

    -- What this action is
    a.description_of_contract_requirement,
    a.reason_for_modification,
    a.reason_for_modification_desc,
    a.contract_action_type,
    a.contract_action_type_desc,

    -- Money
    a.obligated_amount::numeric,
    a.base_and_all_options_value::numeric,
    a.base_and_exercised_options_value::numeric,

    -- Dates
    a.effective_date::date,
    a.signed_date::date,
    a.current_completion_date::date,
    a.ultimate_completion_date::date,

    -- Who
    a.vendor_name,
    a.uei,
    a.contracting_dept_id,
    a.contracting_dept_name,
    a.contracting_agency_id,
    a.contracting_agency_name,
    a.contracting_office_id,
    a.contracting_office_name,

    -- What they're buying
    a.product_or_service_code,
    a.product_or_service_code_desc,
    a.principal_naics_code,
    a.principal_naics_code_desc,

    -- Competition
    a.extent_competed,
    a.extent_competed_desc,
    a.set_aside,
    a.set_aside_desc,
    a.offers_received::int,

    -- Parent IDV (if this is a task order)
    a.idv_piid,
    a.idv_agency_id,
    a.idv_mod_number

FROM public.fpds_actions a;

COMMENT ON VIEW pipeline_intelligence.v_contract_transactions IS
    'Transaction-level detail for any contract PIID — modifications, descriptions, obligations, dates. Required filter: piid.';

-- ── API facade (security_barrier) ───────────────────────────────────────────

CREATE OR REPLACE VIEW pipeline_intelligence.report_deck_contract_transactions
WITH (security_barrier = true) AS
SELECT * FROM pipeline_intelligence.v_contract_transactions;

COMMENT ON VIEW pipeline_intelligence.report_deck_contract_transactions IS
    'API facade for v_contract_transactions with security_barrier.';

-- ── Grant ────────────────────────────────────────────────────────────────────

GRANT SELECT ON pipeline_intelligence.report_deck_contract_transactions
    TO fpds_analytics_api_readonly;

COMMIT;
