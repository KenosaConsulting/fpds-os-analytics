-- Phase 2 prerequisite dimension tables.
--
-- Creates 5 dimension tables needed by all Phase 2 builds:
--   P1: fpds_department_map
--   P2: fpds_agency_map
--   P3: fpds_contracting_office_map
--   P4: fpds_psc_map
--   P5: fpds_referenced_type_map
--
-- Population strategy: extract from existing MVs where possible (fast),
-- fall back to fpds_actions sample where needed.
--
-- Run this migration BEFORE any Phase 2 build migrations.

-- ═══════════════════════════════════════════════════════════════════════════
-- P1: DEPARTMENT MAP
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_department_map (
    department_id       text PRIMARY KEY,
    department_name     text NOT NULL,
    department_short_name text,
    is_dod              boolean NOT NULL DEFAULT false,
    is_civilian         boolean NOT NULL DEFAULT true,
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer,
    notes               text
);

COMMENT ON TABLE analytics_dims.fpds_department_map IS
'Maps FPDS contracting_dept_id to stable department names and classification flags. Source: curated from fpds_actions distinct values.';

-- Populate from existing MV data (most recent name wins)
INSERT INTO analytics_dims.fpds_department_map (department_id, department_name, is_dod, is_civilian, is_active, sort_order)
SELECT DISTINCT ON (contracting_dept_id)
    contracting_dept_id,
    contracting_dept_name,
    CASE WHEN contracting_dept_id = '9700' THEN true ELSE false END,
    CASE WHEN contracting_dept_id = '9700' THEN false ELSE true END,
    true,
    ROW_NUMBER() OVER (ORDER BY contracting_dept_id)
FROM set_aside_breakdown.mv_fpds_setaside_agency_year_summary
WHERE contracting_dept_id IS NOT NULL AND contracting_dept_id != ''
ORDER BY contracting_dept_id, fiscal_year DESC
ON CONFLICT (department_id) DO NOTHING;

-- Curate DoD sub-departments that share dept code 9700
-- (Army, Navy, Air Force etc. are agencies under dept 9700, not separate depts)

-- Manual short names for major departments
UPDATE analytics_dims.fpds_department_map SET department_short_name = CASE department_id
    WHEN '1200' THEN 'USDA'
    WHEN '1300' THEN 'DOC'
    WHEN '1400' THEN 'DOI'
    WHEN '1500' THEN 'DOJ'
    WHEN '1600' THEN 'DOL'
    WHEN '1900' THEN 'State'
    WHEN '2000' THEN 'Treasury'
    WHEN '2400' THEN 'OPM'
    WHEN '2800' THEN 'SSA'
    WHEN '3600' THEN 'VA'
    WHEN '4700' THEN 'GSA'
    WHEN '4900' THEN 'NSF'
    WHEN '6800' THEN 'EPA'
    WHEN '6900' THEN 'DOT'
    WHEN '7000' THEN 'DHS'
    WHEN '7200' THEN 'USAID'
    WHEN '7300' THEN 'SBA'
    WHEN '7500' THEN 'HHS'
    WHEN '8000' THEN 'NASA'
    WHEN '8600' THEN 'HUD'
    WHEN '8900' THEN 'DOE'
    WHEN '9100' THEN 'ED'
    WHEN '9700' THEN 'DoD'
    WHEN '1100' THEN 'EOP'
    WHEN '8800' THEN 'NARA'
    ELSE NULL
END
WHERE department_short_name IS NULL;


-- ═══════════════════════════════════════════════════════════════════════════
-- P2: AGENCY MAP
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_agency_map (
    agency_id           text PRIMARY KEY,
    agency_name         text NOT NULL,
    agency_short_name   text,
    parent_department_id text REFERENCES analytics_dims.fpds_department_map(department_id),
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer,
    notes               text
);

COMMENT ON TABLE analytics_dims.fpds_agency_map IS
'Maps FPDS contracting_agency_id to agency names and parent departments. Source: curated from fpds_actions distinct values. ~371 agencies.';

-- Populate from existing MV data (most recent name wins, deduplicated)
INSERT INTO analytics_dims.fpds_agency_map (agency_id, agency_name, parent_department_id, is_active, sort_order)
SELECT DISTINCT ON (contracting_agency_id)
    contracting_agency_id,
    contracting_agency_name,
    contracting_dept_id,
    true,
    ROW_NUMBER() OVER (ORDER BY contracting_dept_id, contracting_agency_id)
FROM set_aside_breakdown.mv_fpds_setaside_agency_year_summary
WHERE contracting_agency_id IS NOT NULL AND contracting_agency_id != ''
ORDER BY contracting_agency_id, fiscal_year DESC
ON CONFLICT (agency_id) DO NOTHING;

-- Manual short names for major agencies
UPDATE analytics_dims.fpds_agency_map SET agency_short_name = CASE agency_id
    WHEN '2100' THEN 'Army'
    WHEN '1700' THEN 'Navy'
    WHEN '5700' THEN 'Air Force'
    WHEN '97AS' THEN 'DISA'
    WHEN '97F0' THEN 'DLA'
    WHEN '9761' THEN 'DARPA'
    WHEN '97JC' THEN 'MDA'
    WHEN '1330' THEN 'NOAA'
    WHEN '1323' THEN 'Census'
    WHEN '1341' THEN 'NIST'
    WHEN '1344' THEN 'USPTO'
    WHEN '7001' THEN 'CBP'
    WHEN '7003' THEN 'USCG'
    WHEN '7012' THEN 'ICE'
    WHEN '7013' THEN 'TSA'
    WHEN '7014' THEN 'FEMA'
    WHEN '7022' THEN 'CISA'
    WHEN '7524' THEN 'CDC'
    WHEN '7527' THEN 'FDA'
    WHEN '7529' THEN 'NIH'
    WHEN '7530' THEN 'CMS'
    WHEN '7523' THEN 'IHS'
    WHEN '6920' THEN 'FAA'
    WHEN '6925' THEN 'FHWA'
    ELSE NULL
END
WHERE agency_short_name IS NULL;


-- ═══════════════════════════════════════════════════════════════════════════
-- P3: CONTRACTING OFFICE MAP
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_contracting_office_map (
    contracting_office_id   text PRIMARY KEY,
    contracting_office_name text,
    normalized_office_name  text,
    contracting_agency_id   text,
    contracting_dept_id     text,
    first_observed_fy       integer,
    last_observed_fy        integer,
    is_active_recent        boolean DEFAULT false,
    name_confidence         text DEFAULT 'medium',
    notes                   text
);

COMMENT ON TABLE analytics_dims.fpds_contracting_office_map IS
'Maps FPDS contracting_office_id to office names and parent org context. ~14K offices. Office names can drift over time — name_confidence indicates reliability. Use contracting_office_id as the stable key.';

-- Populate from existing office-level MV
-- Uses most recent name, first/last FY, and name confidence
INSERT INTO analytics_dims.fpds_contracting_office_map
    (contracting_office_id, contracting_office_name, contracting_agency_id,
     contracting_dept_id, first_observed_fy, last_observed_fy,
     is_active_recent, name_confidence)
SELECT
    contracting_office_id,
    -- Most recent name (by max FY)
    (ARRAY_AGG(contracting_office_name ORDER BY fiscal_year DESC))[1] AS contracting_office_name,
    -- Most recent agency
    (ARRAY_AGG(contracting_agency_id ORDER BY fiscal_year DESC))[1] AS contracting_agency_id,
    -- Most recent dept
    (ARRAY_AGG(contracting_dept_id ORDER BY fiscal_year DESC))[1] AS contracting_dept_id,
    MIN(fiscal_year) AS first_observed_fy,
    MAX(fiscal_year) AS last_observed_fy,
    -- Active in last 3 FYs
    MAX(fiscal_year) >= (
        CASE WHEN EXTRACT(month FROM CURRENT_DATE)::int >= 10
             THEN EXTRACT(year FROM CURRENT_DATE)::int + 1
             ELSE EXTRACT(year FROM CURRENT_DATE)::int
        END - 2
    ) AS is_active_recent,
    -- Name confidence based on distinct name count
    CASE
        WHEN COUNT(DISTINCT contracting_office_name) <= 1 THEN 'high'
        WHEN COUNT(DISTINCT contracting_office_name) = 2 THEN 'medium'
        ELSE 'low'
    END AS name_confidence
FROM set_aside_breakdown.mv_fpds_setaside_office_year_summary
WHERE contracting_office_id IS NOT NULL AND contracting_office_id != ''
GROUP BY contracting_office_id
ON CONFLICT (contracting_office_id) DO NOTHING;

-- Note: normalized_office_name will be populated in a future curation pass.
-- For now the raw name is used. Known issues:
--   - Some offices repeat the department name as the office name
--   - Abbreviation inconsistency (FT vs FORT, DEPT vs DEPARTMENT)
--   - Office ID 000RA appears in multiple agencies (dim uses first seen)


-- ═══════════════════════════════════════════════════════════════════════════
-- P4: PSC MAP
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_psc_map (
    psc_code            text PRIMARY KEY,
    psc_description     text,
    psc_category_code   text,
    psc_category_label  text,
    psc_group           text NOT NULL,
    is_service          boolean NOT NULL DEFAULT false,
    is_product          boolean NOT NULL DEFAULT false,
    is_r_and_d          boolean NOT NULL DEFAULT false,
    is_construction     boolean NOT NULL DEFAULT false,
    sort_order          integer,
    notes               text
);

COMMENT ON TABLE analytics_dims.fpds_psc_map IS
'Maps FPDS product_or_service_code to descriptions, category hierarchy, and service/product/R&D classification. ~3K-4K codes. PSC category is derived from the first 1-2 characters.';

-- Populate from fpds_actions (need a sample scan since no existing MV has PSC)
-- Use chatbot.mv_naics_psc which has PSC codes
INSERT INTO analytics_dims.fpds_psc_map (psc_code, psc_description, psc_category_code, psc_group, is_service, is_product, is_r_and_d, is_construction, sort_order)
SELECT DISTINCT ON (psc_code)
    psc_code,
    psc_description,
    LEFT(psc_code, 2) AS psc_category_code,
    -- Classify by first character per GSA PSC manual
    CASE
        WHEN LEFT(psc_code, 1) BETWEEN 'A' AND 'B' THEN 'R&D'
        WHEN LEFT(psc_code, 1) = 'C' THEN 'Services'       -- A&E
        WHEN LEFT(psc_code, 1) = 'D' THEN 'Services'       -- IT/ADP
        WHEN LEFT(psc_code, 1) = 'E' THEN 'Services'       -- Purchase of structures
        WHEN LEFT(psc_code, 1) = 'F' THEN 'Services'       -- Natural resources mgmt
        WHEN LEFT(psc_code, 1) = 'G' THEN 'Services'       -- Social services
        WHEN LEFT(psc_code, 1) = 'H' THEN 'Services'       -- Quality control/testing
        WHEN LEFT(psc_code, 1) = 'J' THEN 'Services'       -- Maintenance/repair of equipment
        WHEN LEFT(psc_code, 1) = 'K' THEN 'Services'       -- Modification of equipment
        WHEN LEFT(psc_code, 1) = 'L' THEN 'Services'       -- Technical representative
        WHEN LEFT(psc_code, 1) = 'M' THEN 'Services'       -- Operation of facilities
        WHEN LEFT(psc_code, 1) = 'N' THEN 'Services'       -- Installation of equipment
        WHEN LEFT(psc_code, 1) = 'P' THEN 'Services'       -- Salvage
        WHEN LEFT(psc_code, 1) = 'Q' THEN 'Services'       -- Medical
        WHEN LEFT(psc_code, 1) = 'R' THEN 'Services'       -- Professional/admin/mgmt
        WHEN LEFT(psc_code, 1) = 'S' THEN 'Services'       -- Utilities/housekeeping
        WHEN LEFT(psc_code, 1) = 'T' THEN 'Services'       -- Photographic/mapping
        WHEN LEFT(psc_code, 1) = 'U' THEN 'Services'       -- Education/training
        WHEN LEFT(psc_code, 1) = 'V' THEN 'Services'       -- Transportation
        WHEN LEFT(psc_code, 1) = 'W' THEN 'Services'       -- Lease/rental equipment
        WHEN LEFT(psc_code, 1) = 'X' THEN 'Services'       -- Lease/rental facilities
        WHEN LEFT(psc_code, 1) = 'Y' THEN 'Construction'
        WHEN LEFT(psc_code, 1) = 'Z' THEN 'Services'       -- Maintenance/repair real property
        WHEN LEFT(psc_code, 1) BETWEEN '1' AND '9' THEN 'Products'
        ELSE 'Unknown'
    END,
    -- Boolean flags
    LEFT(psc_code, 1) BETWEEN 'A' AND 'B',                           -- is_r_and_d
    LEFT(psc_code, 1) BETWEEN '1' AND '9',                           -- is_product
    false,                                                             -- is_r_and_d (set above, placeholder)
    LEFT(psc_code, 1) = 'Y',                                          -- is_construction
    ROW_NUMBER() OVER (ORDER BY psc_code)
FROM chatbot.mv_naics_psc
WHERE psc_code IS NOT NULL AND psc_code != ''
ORDER BY psc_code, contract_count DESC
ON CONFLICT (psc_code) DO NOTHING;

-- Fix boolean flags (the CASE above sets psc_group, but booleans need correction)
UPDATE analytics_dims.fpds_psc_map SET
    is_service = (psc_group = 'Services'),
    is_product = (psc_group = 'Products'),
    is_r_and_d = (psc_group = 'R&D'),
    is_construction = (psc_group = 'Construction');

-- Category labels for common PSC prefixes
UPDATE analytics_dims.fpds_psc_map SET psc_category_label = CASE psc_category_code
    WHEN 'AD' THEN 'R&D: Defense Systems'
    WHEN 'AG' THEN 'R&D: General Science'
    WHEN 'AR' THEN 'R&D: Space'
    WHEN 'BB' THEN 'R&D: Other'
    WHEN 'C1' THEN 'A&E: Construction'
    WHEN 'D3' THEN 'IT: ADP Services'
    WHEN 'D1' THEN 'IT: Facility Ops'
    WHEN 'J0' THEN 'Maint: Equipment'
    WHEN 'R4' THEN 'Professional: Admin/Mgmt'
    WHEN 'R7' THEN 'Professional: Management'
    WHEN 'S2' THEN 'Utilities: Housekeeping'
    WHEN 'U0' THEN 'Education/Training'
    WHEN 'Y1' THEN 'Construction: Buildings'
    WHEN 'Z2' THEN 'Maint: Real Property'
    ELSE NULL
END
WHERE psc_category_label IS NULL AND LENGTH(psc_category_code) >= 2;


-- ═══════════════════════════════════════════════════════════════════════════
-- P5: REFERENCED TYPE MAP (Vehicle/Acquisition Path)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_referenced_type_map (
    raw_code            text PRIMARY KEY,
    label               text NOT NULL,
    vehicle_family      text NOT NULL,
    is_gwac             boolean NOT NULL DEFAULT false,
    is_schedule         boolean NOT NULL DEFAULT false,
    is_idiq             boolean NOT NULL DEFAULT false,
    is_bpa              boolean NOT NULL DEFAULT false,
    is_boa              boolean NOT NULL DEFAULT false,
    is_open_market      boolean NOT NULL DEFAULT false,
    sort_order          integer,
    notes               text
);

COMMENT ON TABLE analytics_dims.fpds_referenced_type_map IS
'Maps FPDS referenced_type codes to vehicle/acquisition path families. Used to classify whether awards flow through GWACs, IDIQs, GSA Schedules, BPAs, or open market.';

INSERT INTO analytics_dims.fpds_referenced_type_map
    (raw_code, label, vehicle_family, is_gwac, is_schedule, is_idiq, is_bpa, is_boa, is_open_market, sort_order, notes)
VALUES
    ('A', 'GWAC',                   'GWAC',         true,  false, false, false, false, false, 10, 'Government-Wide Acquisition Contract. Vehicle access required.'),
    ('B', 'IDC (IDIQ)',             'IDIQ',         false, false, true,  false, false, false, 20, 'Indefinite Delivery Contract. Most common vehicle type (~44% of referenced awards).'),
    ('C', 'FSS (GSA Schedule)',     'GSA Schedule', false, true,  false, false, false, false, 30, 'Federal Supply Schedule (GSA Schedule). Vehicle access required.'),
    ('D', 'BOA',                    'BOA',          false, false, false, false, true,  false, 40, 'Basic Ordering Agreement.'),
    ('E', 'BPA',                    'BPA',          false, false, false, true,  false, false, 50, 'Blanket Purchase Agreement. Often established under a parent vehicle.'),
    ('NONE', 'Open Market',         'Open Market',  false, false, false, false, false, true,  60, 'No referenced IDV — award made through open market competition or direct acquisition.'),
    ('UNKNOWN', 'Unknown',          'Unknown',      false, false, false, false, false, false,  0, 'NULL or blank referenced_type in source data.')
ON CONFLICT (raw_code) DO NOTHING;


-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC FACADE VIEWS FOR NEW DIMENSIONS
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW analytics_api.dim_departments
WITH (security_barrier = true) AS
SELECT department_id, department_name, department_short_name,
       is_dod, is_civilian, is_active, sort_order, notes
FROM analytics_dims.fpds_department_map;

COMMENT ON VIEW analytics_api.dim_departments IS
'Federal department lookup. Maps contracting_dept_id to names and DoD/civilian classification.';


CREATE OR REPLACE VIEW analytics_api.dim_agencies
WITH (security_barrier = true) AS
SELECT agency_id, agency_name, agency_short_name,
       parent_department_id, is_active, sort_order, notes
FROM analytics_dims.fpds_agency_map;

COMMENT ON VIEW analytics_api.dim_agencies IS
'Federal agency/bureau lookup. Maps contracting_agency_id to names and parent department.';


CREATE OR REPLACE VIEW analytics_api.dim_contracting_offices
WITH (security_barrier = true) AS
SELECT contracting_office_id, contracting_office_name,
       normalized_office_name, contracting_agency_id,
       contracting_dept_id, first_observed_fy, last_observed_fy,
       is_active_recent, name_confidence, notes
FROM analytics_dims.fpds_contracting_office_map;

COMMENT ON VIEW analytics_api.dim_contracting_offices IS
'Contracting office lookup. ~14K offices. Office names can drift — use contracting_office_id as the stable key. name_confidence indicates reliability.';


CREATE OR REPLACE VIEW analytics_api.dim_psc_codes
WITH (security_barrier = true) AS
SELECT psc_code, psc_description, psc_category_code, psc_category_label,
       psc_group, is_service, is_product, is_r_and_d, is_construction,
       sort_order, notes
FROM analytics_dims.fpds_psc_map;

COMMENT ON VIEW analytics_api.dim_psc_codes IS
'Product Service Code (PSC) lookup. Maps FPDS PSC codes to descriptions, category hierarchy, and service/product/R&D/construction classification.';


CREATE OR REPLACE VIEW analytics_api.dim_vehicle_type_codes
WITH (security_barrier = true) AS
SELECT raw_code, label, vehicle_family,
       is_gwac, is_schedule, is_idiq, is_bpa, is_boa, is_open_market,
       sort_order, notes
FROM analytics_dims.fpds_referenced_type_map;

COMMENT ON VIEW analytics_api.dim_vehicle_type_codes IS
'Vehicle/acquisition path type lookup. Maps FPDS referenced_type codes to families: GWAC, IDIQ, GSA Schedule, BPA, BOA, Open Market.';
