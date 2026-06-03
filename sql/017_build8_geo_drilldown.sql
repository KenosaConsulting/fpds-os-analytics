-- Build 8: Geographic Drill-Down Below State
--
-- Schema: geographic_analysis (existing)
-- MV grain: pop_state × pop_city × pop_county × contracting_agency_id × contracting_office_id × fiscal_year
-- Estimated rows: 1M–3M
-- Build time: 45–90 min on 99M source rows
--
-- Extends existing state-level geography with city, county, and ZIP
-- drill-down. ~80% of domestic records have city/county data.
--
-- Prerequisites: P1, P2, P3 (org dims)

-- ═══════════════════════════════════════════════════════════════════════════
-- MATERIALIZED VIEW
-- ═══════════════════════════════════════════════════════════════════════════

-- Disable statement timeout for MV builds (99M row scans)
SET statement_timeout = 0;
SET work_mem = '256MB';

CREATE MATERIALIZED VIEW geographic_analysis.mv_fpds_geo_place_agency_office_fy AS
SELECT
    COALESCE(fa.pop_country_code, 'USA') AS pop_country_code,
    COALESCE(NULLIF(fa.pop_state_code, ''), 'XX') AS pop_state_code,
    COALESCE(NULLIF(fa.pop_zip_city, ''), 'Unknown') AS pop_city,
    COALESCE(NULLIF(fa.pop_zip_county, ''), 'Unknown') AS pop_county,
    LEFT(NULLIF(fa.pop_zip, ''), 5) AS pop_zip5,
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
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

    -- Market structure
    COUNT(DISTINCT fa.uei) AS distinct_vendor_count,
    SUM(CASE WHEN ecm.is_competed THEN 1 ELSE 0 END) AS competed_action_count,
    SUM(CASE WHEN fa.is_small_business = 'true'
             THEN NULLIF(fa.obligated_amount, '')::numeric ELSE 0 END) AS small_biz_obligated,

    -- Top classifications
    MODE() WITHIN GROUP (ORDER BY fa.principal_naics_code) AS top_naics_code,
    MODE() WITHIN GROUP (ORDER BY fa.product_or_service_code) AS top_psc_code,

    -- Vendor state (for mismatch analysis)
    MODE() WITHIN GROUP (ORDER BY fa.vendor_state_code) AS primary_vendor_state_code

FROM public.fpds_actions fa
LEFT JOIN analytics_dims.fpds_action_type_map atm
    ON fa.contract_action_type = atm.raw_code
    AND COALESCE(fa.contract_action_type_desc, '') = COALESCE(atm.raw_desc, '')
LEFT JOIN analytics_dims.fpds_extent_competed_map ecm
    ON fa.extent_competed = ecm.raw_code
WHERE fa.signed_date IS NOT NULL AND fa.signed_date != ''
  AND fa.contracting_office_id IS NOT NULL AND fa.contracting_office_id != ''
  -- Domestic records with at least city or county data
  AND (fa.pop_country_code IS NULL OR fa.pop_country_code = 'USA' OR fa.pop_country_code = '')
  AND (
      (fa.pop_zip_city IS NOT NULL AND fa.pop_zip_city != '')
      OR (fa.pop_zip_county IS NOT NULL AND fa.pop_zip_county != '')
  )
GROUP BY
    COALESCE(fa.pop_country_code, 'USA'),
    COALESCE(NULLIF(fa.pop_state_code, ''), 'XX'),
    COALESCE(NULLIF(fa.pop_zip_city, ''), 'Unknown'),
    COALESCE(NULLIF(fa.pop_zip_county, ''), 'Unknown'),
    LEFT(NULLIF(fa.pop_zip, ''), 5),
    fa.contracting_dept_id,
    fa.contracting_agency_id,
    fa.contracting_office_id,
    CASE
        WHEN EXTRACT(month FROM fa.signed_date::timestamp) >= 10
        THEN EXTRACT(year FROM fa.signed_date::timestamp)::integer + 1
        ELSE EXTRACT(year FROM fa.signed_date::timestamp)::integer
    END;


-- ═══════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS mv_geo_place_state_city_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (pop_state_code, pop_city, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_place_state_county_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (pop_state_code, pop_county, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_place_zip_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (pop_zip5, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_place_agency_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (contracting_agency_id, pop_state_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_place_office_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (contracting_office_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_geo_place_dept_idx
    ON geographic_analysis.mv_fpds_geo_place_agency_office_fy
    (contracting_dept_id, fiscal_year);


-- ═══════════════════════════════════════════════════════════════════════════
-- REPORT VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

-- Place profile: city/county detail with dim JOINs
CREATE OR REPLACE VIEW geographic_analysis.report_deck_geo_place_profile_fy AS
SELECT
    mv.pop_state_code,
    sm.state_name AS pop_state_name,
    sm.census_region,
    sm.census_division,
    mv.pop_city,
    mv.pop_county,
    mv.pop_zip5,
    mv.contracting_dept_id,
    dm.department_name AS contracting_dept_name,
    mv.contracting_agency_id,
    am.agency_name AS contracting_agency_name,
    am.agency_short_name,
    mv.contracting_office_id,
    om.contracting_office_name,
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
    mv.small_biz_obligated,
    mv.top_naics_code,
    nh.naics_desc AS top_naics_description,
    mv.top_psc_code,
    mv.primary_vendor_state_code,
    CASE WHEN mv.primary_vendor_state_code = mv.pop_state_code
         THEN true ELSE false END AS is_local_vendors,
    ROUND(mv.small_biz_obligated / NULLIF(mv.net_obligated_amount, 0), 4)
        AS small_biz_obligation_share
FROM geographic_analysis.mv_fpds_geo_place_agency_office_fy mv
LEFT JOIN analytics_dims.fpds_us_state_map sm ON mv.pop_state_code = sm.state_code
LEFT JOIN analytics_dims.fpds_department_map dm ON mv.contracting_dept_id = dm.department_id
LEFT JOIN analytics_dims.fpds_agency_map am ON mv.contracting_agency_id = am.agency_id
LEFT JOIN analytics_dims.fpds_contracting_office_map om ON mv.contracting_office_id = om.contracting_office_id
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON mv.top_naics_code = nh.naics_code;


-- City leaders: top cities by obligation within a state
CREATE OR REPLACE VIEW geographic_analysis.report_deck_geo_city_leaders AS
WITH current_fy AS (
    SELECT CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
                THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
                ELSE EXTRACT(year FROM CURRENT_DATE)::int END AS fy
),
city_totals AS (
    SELECT
        mv.pop_state_code,
        mv.pop_city,
        mv.pop_county,
        SUM(mv.net_obligated_amount) AS recent_3yr_obligated,
        SUM(mv.total_action_count) AS recent_3yr_actions,
        SUM(mv.distinct_vendor_count) AS recent_3yr_vendors,
        COUNT(DISTINCT mv.contracting_agency_id) AS distinct_agencies,
        MODE() WITHIN GROUP (ORDER BY mv.top_naics_code) AS primary_naics_code
    FROM geographic_analysis.mv_fpds_geo_place_agency_office_fy mv, current_fy cfy
    WHERE mv.fiscal_year >= cfy.fy - 2
      AND mv.pop_city != 'Unknown'
    GROUP BY mv.pop_state_code, mv.pop_city, mv.pop_county
    HAVING SUM(mv.net_obligated_amount) > 1000000  -- $1M minimum
)
SELECT
    ct.pop_state_code,
    sm.state_name AS pop_state_name,
    sm.census_region,
    ct.pop_city,
    ct.pop_county,
    ct.recent_3yr_obligated,
    ct.recent_3yr_actions,
    ct.recent_3yr_vendors,
    ct.distinct_agencies,
    ct.primary_naics_code,
    nh.naics_desc AS primary_naics_description,
    ROW_NUMBER() OVER (
        PARTITION BY ct.pop_state_code
        ORDER BY ct.recent_3yr_obligated DESC
    ) AS city_rank
FROM city_totals ct
LEFT JOIN analytics_dims.fpds_us_state_map sm ON ct.pop_state_code = sm.state_code
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map nh ON ct.primary_naics_code = nh.naics_code;


-- ═══════════════════════════════════════════════════════════════════════════
-- FACADE VIEWS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.geography_place_profile_fy
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_place_profile_fy;

COMMENT ON VIEW analytics_api.geography_place_profile_fy IS
'Place-of-performance detail at city/county/ZIP level. Extends state-level geography with sub-state drill-down. ~80% coverage of domestic records.';

CREATE OR REPLACE VIEW analytics_api.geography_city_leaders
WITH (security_barrier = true) AS
SELECT * FROM geographic_analysis.report_deck_geo_city_leaders;

COMMENT ON VIEW analytics_api.geography_city_leaders IS
'Top cities by 3-year obligation within each state. Minimum $1M threshold. Shows primary NAICS, vendor count, and agency diversity per city.';
