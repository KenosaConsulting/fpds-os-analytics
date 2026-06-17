-- FPDS-022 Step 4a: MV C — Contract → Contact Bridge
-- Grain: piid × contracting_agency_id (matches mv_contract_family)
-- Purpose: link each contract to its original creator and most recent human approver
-- This is the recompete watchlist's "who handled this contract" handshake.
-- Source: public.fpds_actions joined to analytics_dims.fpds_procurement_contact
-- Protocol: session-pooler, statement_timeout=0

SET statement_timeout = 0;
SET work_mem = '512MB';
SET max_parallel_workers_per_gather = 4;
SET hash_mem_multiplier = 8;

DROP MATERIALIZED VIEW IF EXISTS customer_intelligence.mv_fpds_contract_contacts CASCADE;

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_contract_contacts AS
WITH ranked_creators AS (
    -- Original creator: earliest signed_date action per contract
    SELECT
        a.piid,
        a.contracting_agency_id,
        UPPER(TRIM(a.created_by)) AS creator_user_id,
        a.signed_date::DATE AS creator_action_date,
        ROW_NUMBER() OVER (
            PARTITION BY a.piid, a.contracting_agency_id
            ORDER BY a.signed_date ASC NULLS LAST, a.created_date ASC NULLS LAST
        ) AS rn
    FROM public.fpds_actions a
    WHERE a.created_by IS NOT NULL
      AND a.piid IS NOT NULL
      AND a.contracting_agency_id IS NOT NULL
),
original_creators AS (
    SELECT piid, contracting_agency_id, creator_user_id, creator_action_date
    FROM ranked_creators
    WHERE rn = 1
),
ranked_approvers AS (
    -- Most recent human approver per contract
    SELECT
        a.piid,
        a.contracting_agency_id,
        UPPER(TRIM(a.approved_by)) AS approver_user_id,
        a.signed_date::DATE AS approver_action_date,
        ROW_NUMBER() OVER (
            PARTITION BY a.piid, a.contracting_agency_id
            ORDER BY a.signed_date DESC NULLS LAST, a.approved_date DESC NULLS LAST
        ) AS rn
    FROM public.fpds_actions a
    JOIN analytics_dims.fpds_procurement_contact c
        ON UPPER(TRIM(a.approved_by)) = c.user_id
       AND c.user_class = 'human'
    WHERE a.approved_by IS NOT NULL
      AND a.piid IS NOT NULL
      AND a.contracting_agency_id IS NOT NULL
)
SELECT
    COALESCE(oc.piid, ra.piid) AS piid,
    COALESCE(oc.contracting_agency_id, ra.contracting_agency_id) AS contracting_agency_id,

    -- Original creator
    oc.creator_user_id,
    cc.user_class AS creator_class,
    cc.display_name AS creator_display_name,
    cc.email AS creator_email,
    cc.last_seen_fy AS creator_last_seen_fy,
    oc.creator_action_date,

    -- Most recent human approver
    ra.approver_user_id,
    ca.display_name AS approver_display_name,
    ca.email AS approver_email,
    ca.last_seen_fy AS approver_last_seen_fy,
    ra.approver_action_date

FROM original_creators oc
FULL OUTER JOIN (
    SELECT piid, contracting_agency_id, approver_user_id, approver_action_date
    FROM ranked_approvers
    WHERE rn = 1
) ra ON oc.piid = ra.piid AND oc.contracting_agency_id = ra.contracting_agency_id
LEFT JOIN analytics_dims.fpds_procurement_contact cc ON oc.creator_user_id = cc.user_id
LEFT JOIN analytics_dims.fpds_procurement_contact ca ON ra.approver_user_id = ca.user_id;

-- Indexes
CREATE UNIQUE INDEX idx_mv_contract_contacts_pk ON customer_intelligence.mv_fpds_contract_contacts (piid, contracting_agency_id);
CREATE INDEX idx_mv_contract_contacts_creator ON customer_intelligence.mv_fpds_contract_contacts (creator_user_id);
CREATE INDEX idx_mv_contract_contacts_approver ON customer_intelligence.mv_fpds_contract_contacts (approver_user_id);
CREATE INDEX idx_mv_contract_contacts_creator_class ON customer_intelligence.mv_fpds_contract_contacts (creator_class);

-- Row count checkpoint
SELECT 'MV_C_COMPLETE' AS status,
       COUNT(*) AS total_rows,
       COUNT(creator_user_id) AS with_creator,
       COUNT(approver_user_id) AS with_human_approver,
       COUNT(*) FILTER (WHERE creator_class = 'human') AS human_creator_rows
FROM customer_intelligence.mv_fpds_contract_contacts;
