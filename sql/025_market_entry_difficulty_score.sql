-- FPDS-019: Market Entry Difficulty Score by agency and NAICS.
--
-- Source columns verified 2026-06-10:
--   vendor_concentration.mv_fpds_vendor_naics_agency_year:
--     uei, principal_naics_code, contracting_agency_id, fiscal_year,
--     action_count, net_obligated_amount
--   naics_breakdown.report_deck_naics_agency_fy:
--     contracting_dept_id, contracting_agency_id, principal_naics_code,
--     sector_code, fiscal_year, net_obligated_amount, distinct_vendor_count,
--     not_competed_action_share
--   competition_dynamics.mv_fpds_competition_agency_year:
--     contracting_dept_id, contracting_agency_id, fiscal_year,
--     offers_received_avg
--   competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy:
--     contracting_dept_id, contracting_agency_id, vehicle_family, fiscal_year,
--     net_obligated_amount
--   vendor_concentration.report_deck_agency_naics_vendor_leaders:
--     contracting_agency_id, principal_naics_code, active_fy_count, vendor_rank

CREATE OR REPLACE VIEW competition_dynamics.report_deck_market_entry_difficulty_score AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
complete_fy AS (
    SELECT MAX(m.fiscal_year) AS fiscal_year
    FROM naics_breakdown.report_deck_naics_agency_fy m
    CROSS JOIN current_fy cfy
    WHERE m.fiscal_year < cfy.fy
),
market_base AS (
    SELECT
        m.contracting_dept_id,
        m.contracting_dept_name,
        m.department_short_name,
        m.contracting_agency_id,
        m.contracting_agency_name,
        m.agency_short_name,
        m.principal_naics_code,
        m.principal_naics_description,
        m.sector_code,
        m.sector_label,
        m.fiscal_year,
        m.net_obligated_amount,
        m.distinct_vendor_count,
        COALESCE(m.not_competed_action_share, 0) AS not_competed_action_share
    FROM naics_breakdown.report_deck_naics_agency_fy m
    JOIN complete_fy fy ON m.fiscal_year = fy.fiscal_year
    WHERE m.net_obligated_amount > 0
      AND m.distinct_vendor_count > 0
),
vendor_market_totals AS (
    SELECT
        v.contracting_agency_id,
        v.principal_naics_code,
        v.fiscal_year,
        SUM(v.net_obligated_amount) AS market_obligated
    FROM vendor_concentration.mv_fpds_vendor_naics_agency_year v
    JOIN complete_fy fy ON v.fiscal_year = fy.fiscal_year
    WHERE v.net_obligated_amount > 0
    GROUP BY v.contracting_agency_id, v.principal_naics_code, v.fiscal_year
),
hhi AS (
    SELECT
        v.contracting_agency_id,
        v.principal_naics_code,
        v.fiscal_year,
        ROUND(
            SUM(POWER(v.net_obligated_amount / NULLIF(t.market_obligated, 0), 2)) * 10000,
            2
        ) AS hhi,
        MAX(v.net_obligated_amount / NULLIF(t.market_obligated, 0)) AS top_vendor_obligation_share
    FROM vendor_concentration.mv_fpds_vendor_naics_agency_year v
    JOIN vendor_market_totals t
      ON t.contracting_agency_id = v.contracting_agency_id
     AND t.principal_naics_code = v.principal_naics_code
     AND t.fiscal_year = v.fiscal_year
    WHERE v.net_obligated_amount > 0
    GROUP BY v.contracting_agency_id, v.principal_naics_code, v.fiscal_year
),
agency_competition AS (
    SELECT
        c.contracting_agency_id,
        c.fiscal_year,
        AVG(c.offers_received_avg) FILTER (WHERE c.offers_received_avg IS NOT NULL)
            AS avg_offers_received
    FROM competition_dynamics.mv_fpds_competition_agency_year c
    JOIN complete_fy fy ON c.fiscal_year = fy.fiscal_year
    GROUP BY c.contracting_agency_id, c.fiscal_year
),
agency_vehicle AS (
    SELECT
        v.contracting_agency_id,
        v.fiscal_year,
        ROUND(
            SUM(v.net_obligated_amount) FILTER (
                WHERE v.vehicle_family NOT IN ('Open Market', 'Unknown')
            )
            / NULLIF(SUM(v.net_obligated_amount), 0),
            4
        ) AS vehicle_dependence_share
    FROM competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy v
    JOIN complete_fy fy ON v.fiscal_year = fy.fiscal_year
    WHERE v.net_obligated_amount > 0
    GROUP BY v.contracting_agency_id, v.fiscal_year
),
incumbent_tenure AS (
    SELECT
        l.contracting_agency_id,
        l.principal_naics_code,
        ROUND(AVG(l.active_fy_count) FILTER (WHERE l.vendor_rank <= 3), 2)
            AS avg_top3_incumbent_active_fy_count
    FROM vendor_concentration.report_deck_agency_naics_vendor_leaders l
    GROUP BY l.contracting_agency_id, l.principal_naics_code
),
components AS (
    SELECT
        mb.*,
        h.hhi,
        h.top_vendor_obligation_share,
        ac.avg_offers_received,
        av.vehicle_dependence_share,
        it.avg_top3_incumbent_active_fy_count,
        LEAST(COALESCE(h.hhi, 0) / 10000.0, 1.0) AS hhi_component,
        LEAST(GREATEST(COALESCE(mb.not_competed_action_share, 0), 0), 1) AS not_competed_component,
        LEAST(GREATEST(COALESCE(av.vehicle_dependence_share, 0), 0), 1) AS vehicle_dependence_component,
        CASE
            WHEN ac.avg_offers_received IS NULL THEN 0.5
            WHEN ac.avg_offers_received <= 1 THEN 1.0
            WHEN ac.avg_offers_received >= 5 THEN 0.0
            ELSE ROUND((5.0 - ac.avg_offers_received) / 4.0, 4)
        END AS low_offer_component,
        LEAST(COALESCE(it.avg_top3_incumbent_active_fy_count, 0) / 10.0, 1.0)
            AS incumbent_tenure_component
    FROM market_base mb
    LEFT JOIN hhi h
      ON h.contracting_agency_id = mb.contracting_agency_id
     AND h.principal_naics_code = mb.principal_naics_code
     AND h.fiscal_year = mb.fiscal_year
    LEFT JOIN agency_competition ac
      ON ac.contracting_agency_id = mb.contracting_agency_id
     AND ac.fiscal_year = mb.fiscal_year
    LEFT JOIN agency_vehicle av
      ON av.contracting_agency_id = mb.contracting_agency_id
     AND av.fiscal_year = mb.fiscal_year
    LEFT JOIN incumbent_tenure it
      ON it.contracting_agency_id = mb.contracting_agency_id
     AND it.principal_naics_code = mb.principal_naics_code
)
SELECT
    c.contracting_dept_id,
    c.contracting_dept_name,
    c.department_short_name,
    c.contracting_agency_id,
    c.contracting_agency_name,
    c.agency_short_name,
    c.principal_naics_code,
    c.principal_naics_description,
    c.sector_code,
    c.sector_label,
    c.fiscal_year AS analysis_fiscal_year,
    c.net_obligated_amount,
    c.distinct_vendor_count,
    c.hhi,
    c.top_vendor_obligation_share,
    c.not_competed_action_share,
    c.avg_offers_received,
    c.vehicle_dependence_share,
    c.avg_top3_incumbent_active_fy_count,
    ROUND(c.hhi_component, 4) AS hhi_component,
    ROUND(c.not_competed_component, 4) AS not_competed_component,
    ROUND(c.vehicle_dependence_component, 4) AS vehicle_dependence_component,
    ROUND(c.low_offer_component, 4) AS low_offer_component,
    ROUND(c.incumbent_tenure_component, 4) AS incumbent_tenure_component,
    ROUND(
        100.0 * (
            0.30 * c.hhi_component
          + 0.25 * c.not_competed_component
          + 0.15 * c.vehicle_dependence_component
          + 0.15 * c.low_offer_component
          + 0.15 * c.incumbent_tenure_component
        ),
        1
    ) AS entry_difficulty_score
FROM components c;

COMMENT ON VIEW competition_dynamics.report_deck_market_entry_difficulty_score IS
'Market Entry Difficulty Score by agency and NAICS for the most recent complete fiscal year. Score is a 0-100 weighted blend of HHI, not-competed share, vehicle dependence, low-offer intensity, and incumbent tenure.';

CREATE OR REPLACE VIEW analytics_api.market_entry_difficulty_score
WITH (security_barrier = true) AS
SELECT * FROM competition_dynamics.report_deck_market_entry_difficulty_score;

COMMENT ON VIEW analytics_api.market_entry_difficulty_score IS
'Market Entry Difficulty Score by agency and NAICS. Exposes each component and the weighted 0-100 score; higher means harder entry.';

GRANT SELECT ON analytics_api.market_entry_difficulty_score TO fpds_analytics_api_readonly;
