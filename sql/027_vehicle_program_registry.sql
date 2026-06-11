-- FPDS-021 Step 3: vehicle program registry and pattern rules.
--
-- Source columns verified 2026-06-11 via pg_attribute on public.fpds_actions:
--   ref_piid text, ref_agency_id text, ref_agency_id_name text, referenced_type_desc text,
--   uei text, vendor_name text, signed_date text, obligated_amount text,
--   contracting_agency_id text, contracting_dept_id text, contracting_office_id text,
--   offers_received text, extent_competed text, extent_competed_desc text
--   analytics_dims.fpds_agency_map also verified for agency_short_name lookup.
--
-- The SQL template is the authoritative DB definition for the vehicle-program registry objects.

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_vehicle_program (
    program_id             text PRIMARY KEY,
    program_name           text NOT NULL,
    program_short_name     text,
    program_family         text NOT NULL,
    owning_agency_id       text,
    owning_agency_name     text,
    is_governmentwide      boolean NOT NULL DEFAULT false,
    successor_program_id   text,
    name_source            text NOT NULL,
    notes                  text
);

COMMENT ON TABLE analytics_dims.fpds_vehicle_program IS 'Curated program-level vehicle registry for FPDS referenced contracts. One row per analytical vehicle program, including successor links for generation changes.';

INSERT INTO analytics_dims.fpds_vehicle_program (
    program_id,
    program_name,
    program_short_name,
    program_family,
    owning_agency_id,
    owning_agency_name,
    is_governmentwide,
    successor_program_id,
    name_source,
    notes
) VALUES
    ('va_pharmaceutical_prime_vendor', 'VA Pharmaceutical Prime Vendor', 'VA PPV', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'VA pharmaceutical prime-vendor contracts; includes legacy V797P variants.'),
    ('va_community_care_network', 'VA Community Care Network', 'VA CCN', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'Region-specific CCN contracts grouped to one analytical program for step-2 curation.'),
    ('va_patient_centered_community_care', 'VA Patient Centered Community Care', 'VA PCCC', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'Legacy VA patient-centered community care vehicle preceding CCN.'),
    ('va_medical_disability_examinations', 'VA Medical Disability Examinations', 'MDE', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'Medical disability examination contracts captured in the ATOM feed as MDE / VBA exam vehicles.'),
    ('va_t4ng', 'Transformation Twenty-One Total Technology Next Generation', 'T4NG', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'VA flagship IT services vehicle.'),
    ('va_ehrm', 'VA Electronic Health Record Modernization', 'EHRM', 'IDIQ', '3600', 'VETERANS AFFAIRS, DEPARTMENT OF', false, NULL, 'curated', 'Single-award EHR modernization IDIQ.'),
    ('gsa_alliant', 'Alliant', 'GWAC - Alliant', 'GWAC', '4732', 'FEDERAL ACQUISITION SERVICE', true, 'gsa_alliant_2', 'curated', 'Original GSA Alliant GWAC.'),
    ('gsa_alliant_2', 'Alliant 2', 'GWAC - Alliant 2', 'GWAC', '4732', 'FEDERAL ACQUISITION SERVICE', true, NULL, 'curated', 'Current-generation Alliant 2 GWAC.'),
    ('gsa_oasis_unrestricted', 'One Acquisition Solution for Integrated Services Unrestricted', 'OASIS Unrestricted', 'GWAC', '4732', 'FEDERAL ACQUISITION SERVICE', true, 'gsa_oasis_plus', 'curated', 'OASIS unrestricted pool contracts use OADU PIID stems.'),
    ('gsa_oasis_small_business', 'One Acquisition Solution for Integrated Services Small Business', 'OASIS SB', 'GWAC', '4732', 'FEDERAL ACQUISITION SERVICE', true, 'gsa_oasis_plus', 'curated', 'OASIS small-business pool contracts use OADS PIID stems.'),
    ('gsa_oasis_plus', 'OASIS Plus', 'OASIS+', 'GWAC', '4732', 'FEDERAL ACQUISITION SERVICE', true, NULL, 'curated', 'Successor placeholder so legacy OASIS rows can link forward cleanly.'),
    ('gsa_eis', 'Enterprise Infrastructure Solutions', 'EIS', 'IDIQ', '4732', 'FEDERAL ACQUISITION SERVICE', true, NULL, 'curated', 'Governmentwide telecommunications and network-services vehicle.'),
    ('gsa_astro', 'ASTRO', 'ASTRO', 'IDIQ', '4732', 'FEDERAL ACQUISITION SERVICE', true, NULL, 'curated', 'GSA ASTRO family for manned/unmanned and space systems support.'),
    ('gsa_mas', 'GSA Multiple Award Schedule', 'GSA MAS', 'Schedule', '4732', 'FEDERAL ACQUISITION SERVICE', true, NULL, 'curated', 'Broad catchall for legacy and MAS schedule PIIDs after more specific GSA vehicle patterns.'),
    ('nasa_sewp_v', 'Solutions for Enterprise-Wide Procurement V', 'SEWP V', 'GWAC', '8000', 'NATIONAL AERONAUTICS AND SPACE ADMINISTRATION', true, NULL, 'curated', 'NASA SEWP V groups and set-aside pools share NNG15S PIID stems.'),
    ('nasa_jpl_ffrdc', 'Jet Propulsion Laboratory FFRDC', 'JPL', 'IDIQ', '8000', 'NATIONAL AERONAUTICS AND SPACE ADMINISTRATION', false, NULL, 'curated', 'Caltech-operated JPL sponsorship agreements and successor contracts.'),
    ('nih_cio_sp3', 'Chief Information Officer-Solutions and Partners 3', 'CIO-SP3', 'GWAC', '7529', 'NATIONAL INSTITUTES OF HEALTH', true, 'nih_cio_sp4', 'curated', 'NIH NITAAC CIO-SP3 GWAC family.'),
    ('nih_cio_sp4', 'Chief Information Officer-Solutions and Partners 4', 'CIO-SP4', 'GWAC', '7529', 'NATIONAL INSTITUTES OF HEALTH', true, NULL, 'curated', 'Successor placeholder so CIO-SP3 rows can link forward cleanly.'),
    ('dod_seaport_nxg', 'SeaPort Next Generation', 'SeaPort-NxG', 'IDIQ', '1700', 'DEPT OF THE NAVY', false, NULL, 'curated', 'Navy SeaPort-NxG services contracts.'),
    ('dla_pharmaceutical_prime_vendor', 'DLA Pharmaceutical Prime Vendor', 'DLA PV', 'IDIQ', '97AS', 'DEPT OF DEFENSE', false, NULL, 'curated', 'DLA pharmaceutical prime-vendor stems observed as SPM2DX and SPE2DX.'),
    ('dla_operational_equipment_ist', 'DLA Operational Equipment IST', 'SPE8EJ', 'IDIQ', '97AS', 'DEPT OF DEFENSE', false, NULL, 'curated', 'DLA operational equipment / industrial support stems using SPE8EJ.'),
    ('usaid_gshc_psm', 'Global Health Supply Chain - Procurement and Supply Management', 'GSHC PSM', 'IDIQ', '7200', 'AGENCY FOR INTERNATIONAL DEVELOPMENT', true, NULL, 'curated', 'USAID global health supply chain single-award IDIQ.'),
    ('cbp_southwest_border_construction', 'CBP Southwest Border Construction IDIQ', 'CBP Border IDIQ', 'IDIQ', '7014', 'U.S. CUSTOMS AND BORDER PROTECTION', false, NULL, 'curated', 'CBP multiple-award construction IDIQ for southwest border work.'),
    ('mobility_craf', 'Civil Reserve Air Fleet', 'CRAF', 'IDIQ', '9776', 'DEPT OF DEFENSE', false, NULL, 'curated', 'Air Mobility Command civil reserve air fleet transportation contracts.'),
    ('ussocom_sof_glss', 'Special Operations Forces Global Logistics Support Services', 'SOF GLSS', 'IDIQ', '9768', 'DEPT OF DEFENSE', false, NULL, 'curated', 'USSOCOM global logistics support services vehicle.'),
    ('usaf_c17_gisp', 'C-17 Government Integrated Sustainment Program', 'C-17 GISP', 'IDIQ', '5700', 'DEPT OF THE AIR FORCE', false, NULL, 'curated', 'C-17 sustainment and product-support ordering vehicle.'),
    ('usaf_c130j_ordering', 'C-130J Ordering Contract', 'C-130J', 'IDIQ', '5700', 'DEPT OF THE AIR FORCE', false, NULL, 'curated', 'C-130J five-year ordering contract.'),
    ('usaf_f15ex', 'F-15EX', 'F-15EX', 'IDIQ', '5700', 'DEPT OF THE AIR FORCE', false, NULL, 'curated', 'F-15EX ordering vehicle.'),
    ('usaf_jdam', 'JDAM SAASM Anti-Jam', 'JDAM', 'IDIQ', '5700', 'DEPT OF THE AIR FORCE', false, NULL, 'curated', 'JDAM SAASM / anti-jam ordering vehicle.'),
    ('usaf_lincoln_laboratory_ffrdc', 'MIT Lincoln Laboratory FFRDC', 'Lincoln Lab', 'IDIQ', '5700', 'DEPT OF THE AIR FORCE', false, NULL, 'curated', 'MIT Lincoln Laboratory FFRDC sponsorship agreement.')
ON CONFLICT (program_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS fpds_vehicle_program_family_idx
    ON analytics_dims.fpds_vehicle_program (program_family, owning_agency_id);

CREATE TABLE IF NOT EXISTS analytics_dims.fpds_vehicle_program_pattern (
    program_id        text NOT NULL REFERENCES analytics_dims.fpds_vehicle_program(program_id),
    piid_pattern      text NOT NULL,
    ref_agency_id     text NOT NULL DEFAULT '',
    priority          integer NOT NULL,
    match_note        text,
    PRIMARY KEY (program_id, piid_pattern, ref_agency_id, priority)
);

COMMENT ON TABLE analytics_dims.fpds_vehicle_program_pattern IS 'Ordered PIID pattern rules for program assignment. Empty ref_agency_id means the rule is agency-agnostic.';

INSERT INTO analytics_dims.fpds_vehicle_program_pattern (
    program_id,
    piid_pattern,
    ref_agency_id,
    priority,
    match_note
) VALUES
    ('va_pharmaceutical_prime_vendor', '36W79720D%', '3600', 10, 'VA PPV current stem'),
    ('va_pharmaceutical_prime_vendor', 'VA797P12D%', '3600', 10, 'VA PPV stem'),
    ('va_pharmaceutical_prime_vendor', 'VA797P12C%', '3600', 10, 'VA PPV legacy contract'),
    ('va_pharmaceutical_prime_vendor', 'V797P%', '3600', 20, 'Legacy V797P PPV variants'),
    ('va_community_care_network', '36C79119D%', '3600', 30, 'VA CCN region stems'),
    ('va_community_care_network', '36C10G19D0038%', '3600', 30, 'VA CCN region 4 single stem'),
    ('va_patient_centered_community_care', 'VA79113D%', '3600', 40, 'VA PCCC stem'),
    ('va_medical_disability_examinations', '36C10X19D%', '3600', 50, 'VA MDE 2019 stems'),
    ('va_medical_disability_examinations', '36C10X22D%', '3600', 50, 'VA MDE 2022 stems'),
    ('va_medical_disability_examinations', '36C10X23D%', '3600', 50, 'VA MDE 2023 stems'),
    ('va_medical_disability_examinations', '36C10X25D%', '3600', 50, 'VA MDE 2025 stems'),
    ('va_t4ng', 'VA11816D%', '3600', 60, 'VA T4NG stems'),
    ('va_ehrm', '36C10B18D5000%', '3600', 70, 'VA EHRM single-award stem'),
    ('gsa_alliant_2', '47QTCK18D%', '4732', 100, 'Alliant 2 GWAC stems'),
    ('gsa_alliant', 'GS00Q09BGD%', '4732', 110, 'Alliant GWAC stems'),
    ('gsa_oasis_unrestricted', 'GS00Q14OADU%', '4732', 120, 'OASIS unrestricted stems'),
    ('gsa_oasis_small_business', 'GS00Q14OADS%', '4732', 120, 'OASIS small-business stems'),
    ('gsa_eis', 'GS00Q17NSD%', '4732', 130, 'EIS stems'),
    ('gsa_astro', '47QFCA22D%', '4732', 140, 'ASTRO stems'),
    ('gsa_mas', 'GS%', '4730', 900, 'Broad GSA/FAS schedule catchall after specific GWAC and IDIQ matches'),
    ('gsa_mas', 'GS%', '4732', 900, 'Broad GSA/FAS schedule catchall after specific GWAC and IDIQ matches'),
    ('nasa_sewp_v', 'NNG15S%', '8000', 150, 'SEWP V stems across pool/group variants'),
    ('nasa_jpl_ffrdc', 'NAS703001%', '8000', 160, 'JPL sponsorship agreement'),
    ('nasa_jpl_ffrdc', 'NNN12AA01C%', '8000', 160, 'JPL successor sponsorship agreement'),
    ('nasa_jpl_ffrdc', '80NM0018D0004%', '8000', 160, 'JPL sponsorship agreement variant'),
    ('nih_cio_sp3', 'HHSN3162012%', '7529', 170, 'CIO-SP3 stems'),
    ('dod_seaport_nxg', 'N0017819D%', '1700', 180, 'SeaPort-NxG stems'),
    ('dla_pharmaceutical_prime_vendor', 'SPM2DX%', '97AS', 190, 'DLA pharmaceutical prime-vendor stems'),
    ('dla_pharmaceutical_prime_vendor', 'SPE2DX%', '97AS', 190, 'DLA pharmaceutical prime-vendor stems'),
    ('dla_operational_equipment_ist', 'SPE8EJ%', '97AS', 200, 'DLA operational equipment stems'),
    ('usaid_gshc_psm', 'AIDOAAI15%', '7200', 210, 'USAID GSHC PSM stem'),
    ('cbp_southwest_border_construction', '70B01C26D000000%', '7014', 220, 'CBP southwest border construction MA-IDIQ'),
    ('mobility_craf', 'HTC71118DCC%', '9776', 230, 'CRAF stems'),
    ('ussocom_sof_glss', 'H9225417D0001%', '9768', 240, 'SOF GLSS exact stem'),
    ('usaf_c17_gisp', 'FA852612D%', '5700', 250, 'C-17 GISP stem'),
    ('usaf_c130j_ordering', 'FA862516D%', '5700', 260, 'C-130J ordering stem'),
    ('usaf_f15ex', 'FA863420D%', '5700', 270, 'F-15EX stem'),
    ('usaf_jdam', 'FA821315D%', '5700', 280, 'JDAM stem'),
    ('usaf_lincoln_laboratory_ffrdc', 'FA870215D0001%', '5700', 290, 'MIT Lincoln Laboratory sponsorship agreement')
ON CONFLICT (program_id, piid_pattern, ref_agency_id, priority) DO NOTHING;

CREATE INDEX IF NOT EXISTS fpds_vehicle_program_pattern_priority_idx
    ON analytics_dims.fpds_vehicle_program_pattern (priority, program_id);

-- The heavy CTAS build for analytics_dims.fpds_vehicle_contract lives in
-- sql/028_vehicle_contract_build.sql so it can be run via the direct-psql path.
