-- FPDS-021 Step 3: heavy build for analytics_dims.fpds_vehicle_contract.
--
-- Source columns verified 2026-06-11 via pg_attribute on public.fpds_actions:
--   ref_piid text, ref_agency_id text, ref_agency_id_name text, referenced_type_desc text,
--   uei text, vendor_name text, signed_date text, obligated_amount text,
--   contracting_agency_id text
-- analytics_dims.fpds_agency_map verified for agency_short_name.
--
-- Run through the direct-psql heavy-statement path with statement_timeout = 0.
-- Never use the raw fiscal_year source column here; FY2010+ is signed_date >= '2009-10-01'.

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_vehicle_contract AS
WITH normalized_actions AS (
    SELECT
        fa.ref_piid,
        NULLIF(fa.ref_agency_id, '') AS ref_agency_id,
        NULLIF(fa.ref_agency_id_name, '') AS ref_agency_id_name,
        NULLIF(fa.referenced_type_desc, '') AS referenced_type_desc,
        NULLIF(fa.uei, '') AS uei,
        NULLIF(fa.vendor_name, '') AS vendor_name,
        NULLIF(fa.contracting_agency_id, '') AS contracting_agency_id,
        CASE
            WHEN NULLIF(fa.obligated_amount, '') ~ '^-?[0-9]+([.][0-9]+)?$'
                THEN NULLIF(fa.obligated_amount, '')::numeric
            ELSE 0::numeric
        END AS obligated_amount,
        CASE
            WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
                THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
            ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
        END AS fiscal_year
    FROM public.fpds_actions fa
    WHERE fa.ref_piid IS NOT NULL
      AND fa.ref_piid <> ''
      AND fa.signed_date >= '2009-10-01'
      AND fa.signed_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$'
),
piid_rollup AS (
    SELECT
        na.ref_piid,
        SUM(na.obligated_amount) AS total_obligations,
        COUNT(*)::bigint AS total_orders,
        COUNT(DISTINCT na.contracting_agency_id) FILTER (
            WHERE na.contracting_agency_id IS NOT NULL
        )::integer AS distinct_using_agencies,
        MIN(na.fiscal_year) AS first_order_fy,
        MAX(na.fiscal_year) AS last_order_fy
    FROM normalized_actions na
    GROUP BY na.ref_piid
),
agency_counts AS (
    SELECT
        na.ref_piid,
        COALESCE(na.ref_agency_id, '') AS owning_agency_id,
        COALESCE(na.ref_agency_id_name, '') AS owning_agency_name,
        COUNT(*) AS action_count,
        SUM(ABS(na.obligated_amount)) AS absolute_obligations
    FROM normalized_actions na
    GROUP BY
        na.ref_piid,
        COALESCE(na.ref_agency_id, ''),
        COALESCE(na.ref_agency_id_name, '')
),
agency_majority AS (
    SELECT
        ref_piid,
        NULLIF(owning_agency_id, '') AS owning_agency_id,
        NULLIF(owning_agency_name, '') AS owning_agency_name
    FROM (
        SELECT
            ac.*,
            ROW_NUMBER() OVER (
                PARTITION BY ac.ref_piid
                ORDER BY
                    ac.action_count DESC,
                    ac.absolute_obligations DESC,
                    ac.owning_agency_id ASC,
                    ac.owning_agency_name ASC
            ) AS rank_order
        FROM agency_counts ac
    ) ranked
    WHERE rank_order = 1
),
vehicle_type_counts AS (
    SELECT
        na.ref_piid,
        COALESCE(na.referenced_type_desc, 'Unspecified Referenced Contract') AS vehicle_type,
        COUNT(*) AS action_count,
        SUM(ABS(na.obligated_amount)) AS absolute_obligations
    FROM normalized_actions na
    GROUP BY
        na.ref_piid,
        COALESCE(na.referenced_type_desc, 'Unspecified Referenced Contract')
),
vehicle_type_majority AS (
    SELECT
        ref_piid,
        vehicle_type
    FROM (
        SELECT
            vtc.*,
            ROW_NUMBER() OVER (
                PARTITION BY vtc.ref_piid
                ORDER BY
                    vtc.action_count DESC,
                    vtc.absolute_obligations DESC,
                    vtc.vehicle_type ASC
            ) AS rank_order
        FROM vehicle_type_counts vtc
    ) ranked
    WHERE rank_order = 1
),
vendor_counts AS (
    SELECT
        na.ref_piid,
        COALESCE(na.uei, '') AS primary_vendor_uei,
        COALESCE(na.vendor_name, '') AS vendor_name,
        COUNT(*) AS action_count,
        SUM(ABS(na.obligated_amount)) AS absolute_obligations
    FROM normalized_actions na
    GROUP BY
        na.ref_piid,
        COALESCE(na.uei, ''),
        COALESCE(na.vendor_name, '')
),
vendor_majority AS (
    SELECT
        ref_piid,
        NULLIF(primary_vendor_uei, '') AS primary_vendor_uei,
        NULLIF(vendor_name, '') AS vendor_name
    FROM (
        SELECT
            vc.*,
            ROW_NUMBER() OVER (
                PARTITION BY vc.ref_piid
                ORDER BY
                    vc.action_count DESC,
                    vc.absolute_obligations DESC,
                    vc.primary_vendor_uei ASC,
                    vc.vendor_name ASC
            ) AS rank_order
        FROM vendor_counts vc
    ) ranked
    WHERE rank_order = 1
),
vendor_flags AS (
    SELECT
        na.ref_piid,
        COUNT(DISTINCT COALESCE(na.uei, na.vendor_name)) FILTER (
            WHERE COALESCE(na.uei, na.vendor_name) IS NOT NULL
        ) > 1 AS has_multi_vendor_anomaly
    FROM normalized_actions na
    GROUP BY na.ref_piid
),
pattern_matches AS (
    SELECT
        pr.ref_piid,
        p.program_id,
        ROW_NUMBER() OVER (
            PARTITION BY pr.ref_piid
            ORDER BY p.priority ASC, p.program_id ASC, p.piid_pattern ASC
        ) AS rank_order
    FROM piid_rollup pr
    LEFT JOIN agency_majority am
        ON am.ref_piid = pr.ref_piid
    JOIN analytics_dims.fpds_vehicle_program_pattern p
        ON pr.ref_piid LIKE p.piid_pattern
       AND (p.ref_agency_id = '' OR p.ref_agency_id = COALESCE(am.owning_agency_id, ''))
),
matched_program AS (
    SELECT
        pm.ref_piid,
        pm.program_id
    FROM pattern_matches pm
    WHERE pm.rank_order = 1
)
SELECT
    pr.ref_piid,
    mp.program_id,
    COALESCE(vtm.vehicle_type, 'Unspecified Referenced Contract') AS vehicle_type,
    am.owning_agency_id,
    am.owning_agency_name,
    vm.primary_vendor_uei,
    vm.vendor_name,
    TRIM(BOTH FROM (
        COALESCE(agm.agency_short_name, am.owning_agency_name, 'Unknown Agency')
        || ' '
        || COALESCE(vtm.vehicle_type, 'Unspecified Referenced Contract')
    )) || ' (' || pr.ref_piid || ')' AS derived_label,
    pr.total_obligations,
    pr.total_orders,
    pr.distinct_using_agencies,
    pr.first_order_fy,
    pr.last_order_fy,
    pr.last_order_fy >= (
        CASE
            WHEN EXTRACT(month FROM CURRENT_DATE)::integer >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::integer + 1
            ELSE EXTRACT(year FROM CURRENT_DATE)::integer
        END - 2
    ) AS is_active_recent,
    COALESCE(vf.has_multi_vendor_anomaly, false) AS has_multi_vendor_anomaly
FROM piid_rollup pr
LEFT JOIN matched_program mp
    ON mp.ref_piid = pr.ref_piid
LEFT JOIN agency_majority am
    ON am.ref_piid = pr.ref_piid
LEFT JOIN vehicle_type_majority vtm
    ON vtm.ref_piid = pr.ref_piid
LEFT JOIN vendor_majority vm
    ON vm.ref_piid = pr.ref_piid
LEFT JOIN vendor_flags vf
    ON vf.ref_piid = pr.ref_piid
LEFT JOIN analytics_dims.fpds_agency_map agm
    ON agm.agency_id = am.owning_agency_id;

COMMENT ON TABLE analytics_dims.fpds_vehicle_contract IS
'FY2010+ referenced-contract directory at ref_piid grain. Program assignment comes from ordered pattern rules; unmatched PIIDs keep a derived label for later pseudo-program rollups.';

CREATE UNIQUE INDEX IF NOT EXISTS fpds_vehicle_contract_ref_piid_uq
    ON analytics_dims.fpds_vehicle_contract (ref_piid);

CREATE INDEX IF NOT EXISTS fpds_vehicle_contract_program_recent_idx
    ON analytics_dims.fpds_vehicle_contract (program_id, is_active_recent, last_order_fy);

CREATE INDEX IF NOT EXISTS fpds_vehicle_contract_vendor_recent_idx
    ON analytics_dims.fpds_vehicle_contract (primary_vendor_uei, is_active_recent, last_order_fy);

CREATE INDEX IF NOT EXISTS fpds_vehicle_contract_agency_recent_idx
    ON analytics_dims.fpds_vehicle_contract (owning_agency_id, is_active_recent, last_order_fy);
