-- FPDS-021 Step 4B runtime replacement: normalized program x vendor x fiscal year.
--
-- Source columns verified 2026-06-11 via information_schema / pg_attribute:
--   analytics_dims.fpds_vehicle_contract.ref_piid text
--   analytics_dims.fpds_vehicle_contract.program_id text
--   analytics_dims.fpds_vehicle_contract.vehicle_type text
--   analytics_dims.fpds_vehicle_contract.owning_agency_id text
--   analytics_dims.fpds_vehicle_contract.owning_agency_name text
--   analytics_dims.fpds_vehicle_contract.primary_vendor_uei text
--   analytics_dims.fpds_vehicle_contract.vendor_name text
--   analytics_dims.fpds_vehicle_program.program_id text
--   analytics_dims.fpds_agency_map.agency_id text / agency_name text / agency_short_name text
--   public.fpds_actions.ref_piid text
--   public.fpds_actions.signed_date text
--   public.fpds_actions.obligated_amount text
--   public.fpds_actions.contracting_agency_id text
--   public.fpds_actions.uei text
--   public.fpds_actions.vendor_name text
--
-- This runtime MV exists because the first-pass object name is already occupied and
-- the FPDS-021 build protocol forbids DROP / ALTER / REFRESH. Step 5 report views
-- and facades must read this normalized replacement.

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm AS
WITH contract_basis AS (
    SELECT
        vc.ref_piid,
        COALESCE(vp.program_id, vc.program_id) AS resolved_program_id,
        COALESCE(NULLIF(vc.vehicle_type, ''), 'Unspecified Referenced Contract') AS vehicle_family_label,
        COALESCE(vp.owning_agency_id, vc.owning_agency_id) AS owner_agency_id,
        COALESCE(vp.owning_agency_name, owner_agm.agency_name, vc.owning_agency_name) AS owner_agency_name,
        COALESCE(owner_agm.agency_short_name, owner_agm.agency_name, vc.owning_agency_name, 'Unknown Agency') AS owner_agency_label,
        vp.program_name,
        vp.program_short_name,
        vp.program_family,
        vp.is_governmentwide,
        vc.primary_vendor_uei,
        vc.vendor_name AS primary_vendor_name
    FROM analytics_dims.fpds_vehicle_contract vc
    LEFT JOIN analytics_dims.fpds_vehicle_program vp
        ON vp.program_id = vc.program_id
    LEFT JOIN analytics_dims.fpds_agency_map owner_agm
        ON owner_agm.agency_id = COALESCE(vp.owning_agency_id, vc.owning_agency_id)
),
resolved_contracts AS (
    SELECT
        cb.ref_piid,
        COALESCE(
            cb.resolved_program_id,
            'pseudo:'
            || COALESCE(cb.owner_agency_id, 'unknown')
            || ':'
            || regexp_replace(lower(cb.vehicle_family_label), '[^a-z0-9]+', '_', 'g')
        ) AS vehicle_program_id,
        CASE
            WHEN cb.resolved_program_id IS NULL THEN
                TRIM(BOTH FROM (cb.owner_agency_label || ' ' || cb.vehicle_family_label))
            ELSE COALESCE(cb.program_name, cb.resolved_program_id)
        END AS vehicle_program_name,
        CASE
            WHEN cb.resolved_program_id IS NULL THEN
                TRIM(BOTH FROM (cb.owner_agency_label || ' ' || cb.vehicle_family_label))
            ELSE COALESCE(cb.program_short_name, cb.program_name, cb.resolved_program_id)
        END AS vehicle_program_short_name,
        COALESCE(cb.program_family, cb.vehicle_family_label) AS program_family,
        cb.resolved_program_id IS NULL AS is_pseudo_program,
        cb.owner_agency_id AS program_owner_agency_id,
        cb.owner_agency_name AS program_owner_agency_name,
        COALESCE(cb.is_governmentwide, false) AS is_governmentwide,
        cb.primary_vendor_uei,
        cb.primary_vendor_name
    FROM contract_basis cb
),
action_level AS (
    SELECT
        rc.vehicle_program_id,
        rc.vehicle_program_name,
        rc.vehicle_program_short_name,
        rc.program_family,
        rc.is_pseudo_program,
        rc.program_owner_agency_id,
        rc.program_owner_agency_name,
        rc.is_governmentwide,
        COALESCE(NULLIF(fa.uei, ''), rc.primary_vendor_uei) AS vendor_uei,
        NULLIF(BTRIM(COALESCE(fa.vendor_name, rc.primary_vendor_name)), '') AS vendor_name,
        fa.contracting_agency_id,
        CASE
            WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
                THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
            ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
        END AS fiscal_year,
        CASE
            WHEN NULLIF(fa.obligated_amount, '') ~ '^-?[0-9]+([.][0-9]+)?$'
                THEN NULLIF(fa.obligated_amount, '')::numeric
            ELSE 0::numeric
        END AS obligated_amount
    FROM public.fpds_actions fa
    JOIN resolved_contracts rc
        ON rc.ref_piid = fa.ref_piid
    WHERE fa.signed_date >= '2009-10-01'
      AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$'
      AND fa.contracting_agency_id IS NOT NULL
      AND fa.contracting_agency_id <> ''
      AND COALESCE(NULLIF(fa.uei, ''), rc.primary_vendor_uei) IS NOT NULL
),
vendor_totals AS (
    SELECT
        al.vehicle_program_id,
        al.vehicle_program_name,
        al.vehicle_program_short_name,
        al.program_family,
        al.is_pseudo_program,
        al.program_owner_agency_id,
        al.program_owner_agency_name,
        al.is_governmentwide,
        al.vendor_uei,
        al.fiscal_year,
        SUM(al.obligated_amount) AS obligated_amount,
        COUNT(*)::bigint AS order_count,
        COUNT(DISTINCT al.contracting_agency_id)::integer AS distinct_customer_agencies
    FROM action_level al
    GROUP BY
        al.vehicle_program_id,
        al.vehicle_program_name,
        al.vehicle_program_short_name,
        al.program_family,
        al.is_pseudo_program,
        al.program_owner_agency_id,
        al.program_owner_agency_name,
        al.is_governmentwide,
        al.vendor_uei,
        al.fiscal_year
),
vendor_alias_totals AS (
    SELECT
        al.vehicle_program_id,
        al.vendor_uei,
        al.fiscal_year,
        al.vendor_name,
        SUM(al.obligated_amount) AS alias_obligated_amount,
        COUNT(*)::bigint AS alias_order_count
    FROM action_level al
    GROUP BY
        al.vehicle_program_id,
        al.vendor_uei,
        al.fiscal_year,
        al.vendor_name
),
ranked_aliases AS (
    SELECT
        vat.vehicle_program_id,
        vat.vendor_uei,
        vat.fiscal_year,
        vat.vendor_name,
        ROW_NUMBER() OVER (
            PARTITION BY vat.vehicle_program_id, vat.vendor_uei, vat.fiscal_year
            ORDER BY
                CASE WHEN vat.vendor_name IS NULL THEN 1 ELSE 0 END,
                vat.alias_obligated_amount DESC,
                vat.alias_order_count DESC,
                LENGTH(COALESCE(vat.vendor_name, '')) DESC,
                COALESCE(vat.vendor_name, '')
        ) AS alias_rank
    FROM vendor_alias_totals vat
)
SELECT
    vt.vehicle_program_id,
    vt.vehicle_program_name,
    vt.vehicle_program_short_name,
    vt.program_family,
    vt.is_pseudo_program,
    vt.program_owner_agency_id,
    vt.program_owner_agency_name,
    vt.is_governmentwide,
    vt.vendor_uei,
    COALESCE(ra.vendor_name, vt.vendor_uei) AS vendor_name,
    vt.fiscal_year,
    vt.obligated_amount,
    vt.order_count,
    vt.distinct_customer_agencies
FROM vendor_totals vt
LEFT JOIN ranked_aliases ra
    ON ra.vehicle_program_id = vt.vehicle_program_id
   AND ra.vendor_uei = vt.vendor_uei
   AND ra.fiscal_year = vt.fiscal_year
   AND ra.alias_rank = 1;

CREATE UNIQUE INDEX IF NOT EXISTS mv_vehicle_program_vendor_fy_norm_uq
    ON customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm
    (
        vehicle_program_id,
        vendor_uei,
        fiscal_year
    );

CREATE INDEX IF NOT EXISTS mv_vehicle_program_vendor_fy_norm_program_idx
    ON customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm
    (vehicle_program_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_program_vendor_fy_norm_vendor_idx
    ON customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm
    (vendor_uei, fiscal_year);

COMMENT ON MATERIALIZED VIEW customer_intelligence.mv_fpds_vehicle_program_vendor_fy_norm IS
'Normalized runtime replacement for Step 4B vehicle-program x vendor x fiscal year. This exists because the original Step 4B object name is already occupied and the FPDS-021 protocol forbids drop/alter operations.';
