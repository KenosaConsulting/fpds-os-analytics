-- FPDS-021 Step 4A: program x department x agency x fiscal year.
--
-- Source columns verified 2026-06-11 via pg_attribute on public.fpds_actions:
--   ref_piid text, signed_date text, obligated_amount text, contracting_dept_id text,
--   contracting_agency_id text, offers_received text, extent_competed text,
--   is_small_business text, uei text
-- analytics_dims.fpds_extent_competed_map verified for raw_code/is_competed/is_not_competed.

CREATE MATERIALIZED VIEW customer_intelligence.mv_fpds_vehicle_program_agency_fy AS
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
        vc.primary_vendor_uei
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
        cb.primary_vendor_uei
    FROM contract_basis cb
),
normalized_actions AS (
    SELECT
        rc.vehicle_program_id,
        rc.vehicle_program_name,
        rc.vehicle_program_short_name,
        rc.program_family,
        rc.is_pseudo_program,
        rc.program_owner_agency_id,
        rc.program_owner_agency_name,
        rc.is_governmentwide,
        fa.contracting_dept_id,
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
        END AS obligated_amount,
        CASE
            WHEN NULLIF(fa.offers_received, '') ~ '^[0-9]+([.][0-9]+)?$'
                THEN NULLIF(fa.offers_received, '')::numeric
            ELSE NULL::numeric
        END AS offers_received,
        COALESCE(ecm.is_competed, false) AS is_competed,
        COALESCE(ecm.is_not_competed, false) AS is_not_competed,
        COALESCE(NULLIF(fa.uei, ''), rc.primary_vendor_uei) AS winner_uei,
        CASE
            WHEN fa.is_small_business = 'true'
             AND NULLIF(fa.obligated_amount, '') ~ '^-?[0-9]+([.][0-9]+)?$'
                THEN NULLIF(fa.obligated_amount, '')::numeric
            ELSE 0::numeric
        END AS small_biz_obligated
    FROM public.fpds_actions fa
    JOIN resolved_contracts rc
        ON rc.ref_piid = fa.ref_piid
    LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
        ON ecm.raw_code = fa.extent_competed
    WHERE fa.signed_date >= '2009-10-01'
      AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$'
      AND fa.contracting_dept_id IS NOT NULL
      AND fa.contracting_dept_id <> ''
      AND fa.contracting_agency_id IS NOT NULL
      AND fa.contracting_agency_id <> ''
)
SELECT
    na.vehicle_program_id,
    na.vehicle_program_name,
    na.vehicle_program_short_name,
    na.program_family,
    na.is_pseudo_program,
    na.program_owner_agency_id,
    na.program_owner_agency_name,
    na.is_governmentwide,
    na.contracting_dept_id,
    na.contracting_agency_id,
    na.fiscal_year,
    SUM(na.obligated_amount) AS obligated_amount,
    COUNT(*)::bigint AS action_count,
    COUNT(DISTINCT na.winner_uei) FILTER (WHERE na.winner_uei IS NOT NULL) AS distinct_vendor_count,
    SUM(CASE WHEN na.is_competed THEN 1 ELSE 0 END)::bigint AS competed_action_count,
    SUM(CASE WHEN na.is_not_competed THEN 1 ELSE 0 END)::bigint AS not_competed_action_count,
    AVG(na.offers_received) AS avg_offers_received,
    SUM(na.small_biz_obligated) AS small_biz_obligated
FROM normalized_actions na
GROUP BY
    na.vehicle_program_id,
    na.vehicle_program_name,
    na.vehicle_program_short_name,
    na.program_family,
    na.is_pseudo_program,
    na.program_owner_agency_id,
    na.program_owner_agency_name,
    na.is_governmentwide,
    na.contracting_dept_id,
    na.contracting_agency_id,
    na.fiscal_year;

CREATE UNIQUE INDEX IF NOT EXISTS mv_vehicle_program_agency_fy_uq
    ON customer_intelligence.mv_fpds_vehicle_program_agency_fy
    (
        vehicle_program_id,
        contracting_dept_id,
        contracting_agency_id,
        fiscal_year
    );

CREATE INDEX IF NOT EXISTS mv_vehicle_program_agency_fy_program_idx
    ON customer_intelligence.mv_fpds_vehicle_program_agency_fy
    (vehicle_program_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_program_agency_fy_agency_idx
    ON customer_intelligence.mv_fpds_vehicle_program_agency_fy
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vehicle_program_agency_fy_dept_idx
    ON customer_intelligence.mv_fpds_vehicle_program_agency_fy
    (contracting_dept_id, fiscal_year);
