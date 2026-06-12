-- 033_vehicle_curation_v2_corrections.sql
-- FPDS-021 curation corrections (applied to production 2026-06-12 via MCP; this file
-- makes them reproducible for from-scratch rebuilds). Root causes, verified in prod:
--   1. DoD referenced contracts derive owning_agency_id = '9700' (dept level), so every
--      pattern constrained to a DoD sub-agency (1700/5700/9776/9768/97AS) NEVER matched.
--      All ten DoD-constrained programs had zero matches before this fix.
--   2. GSA Alliant contracts derive owning_agency_id = '4735' (FAS), not '4732'.
--   3. MAS patterns covered legacy 'GS%' only — post-2017 '47Q%' formats were invisible.
--   4. $8.6B of FSS-typed contracts under agency 3600 are VA Federal Supply Schedules —
--      a distinct program (va_fss), not GSA MAS.
--   5. FSS referenced-type is definitionally a schedule contract: type-based fallback rule
--      assigns remaining FSS-typed contracts to gsa_mas / va_fss by owning agency.
-- Result in production after corrections: matched-dollar share 23.6% -> 31.5%;
-- SeaPort family +$90.4B; Alliant +$35.2B; MAS lifetime $269.7B -> $366.0B.
-- Known residual caveat: schedule orders placed via BPAs-under-schedules carry only the
-- BPA reference (FPDS one-level referencing), so MAS totals here are direct schedule
-- orders and will read below GSA's published schedule sales. Document in catalog caveats.

-- New programs ------------------------------------------------------------------
INSERT INTO analytics_dims.fpds_vehicle_program
  (program_id, program_name, program_short_name, program_family, owning_agency_id, owning_agency_name, is_governmentwide, successor_program_id, name_source, notes)
VALUES
  ('navy_seaport_e','Navy SeaPort Enhanced (SeaPort-e)','SeaPort-e','IDIQ','1700','Dept of the Navy',false,'dod_seaport_nxg','curated','Catch-all for N00178 MACs not matched to the 2019 NxG series; later NxG rolling-admission contracts may appear here — verify by award year.'),
  ('va_fss','VA Federal Supply Schedules','VA FSS','Schedule','3600','Dept of Veterans Affairs',false,NULL,'curated','VA-administered schedules (medical/pharma). Assigned via FSS referenced-type rule, owning agency 3600.'),
  ('gsa_8a_stars_iii','GSA 8(a) STARS III GWAC','8(a) STARS III','GWAC','4732','General Services Administration',true,NULL,'curated','8(a) set-aside GWAC; 47QTCB21D award series.')
ON CONFLICT (program_id) DO NOTHING;

-- New / corrected patterns ------------------------------------------------------
INSERT INTO analytics_dims.fpds_vehicle_program_pattern (program_id, piid_pattern, ref_agency_id, priority, match_note) VALUES
  ('gsa_alliant','GS00Q09BGD%','4735',10,'Owning agency derives as 4735 (FAS) for Alliant contracts; complements 4732 row'),
  ('gsa_8a_stars_iii','47QTCB21D%','4732',10,'STARS III award series'),
  ('gsa_oasis_plus','47QRCA24D%','4732',10,'OASIS+ award series; verify totals as ordering ramps'),
  ('dod_seaport_nxg','N0017819D%','9700',10,'9700 owning-agency derivation for DoD referenced contracts; original 1700 row never matched'),
  ('dla_pharmaceutical_prime_vendor','SPM2DX%','9700',10,'9700 derivation'),
  ('dla_pharmaceutical_prime_vendor','SPE2DX%','9700',10,'9700 derivation'),
  ('dla_operational_equipment_ist','SPE8EJ%','9700',10,'9700 derivation'),
  ('ussocom_sof_glss','H9225417D0001%','9700',10,'9700 derivation'),
  ('usaf_f15ex','FA863420D%','9700',10,'9700 derivation'),
  ('usaf_c130j_ordering','FA862516D%','9700',10,'9700 derivation'),
  ('usaf_c17_gisp','FA852612D%','9700',10,'9700 derivation'),
  ('mobility_craf','HTC71118DCC%','9700',10,'9700 derivation'),
  ('usaf_jdam','FA821315D%','9700',10,'9700 derivation'),
  ('usaf_lincoln_laboratory_ffrdc','FA870215D0001%','9700',10,'9700 derivation'),
  ('gsa_mas','47QSWA%','4732',800,'MAS new-format series; FSS-typed contracts also caught by type rule'),
  ('gsa_mas','47QTCA%','4732',800,'MAS IT (Schedule 70 successor) series'),
  ('gsa_mas','47QSMA%','4732',800,'MAS series'),
  ('gsa_mas','47QSHA%','4732',800,'MAS series'),
  ('gsa_mas','47QSEA%','4732',800,'MAS series'),
  ('navy_seaport_e','N00178%','9700',900,'Low-precedence catch-all AFTER dod_seaport_nxg series'),
  ('navy_seaport_e','N00178%','1700',900,'Variant in case derivation ever resolves to 1700')
ON CONFLICT (program_id, piid_pattern, ref_agency_id, priority) DO NOTHING;

-- Re-match: fill NULL assignments only (cannot break existing correct matches) ----
UPDATE analytics_dims.fpds_vehicle_contract c
SET program_id = sub.pid
FROM (
  SELECT c2.ref_piid,
    (SELECT pt.program_id FROM analytics_dims.fpds_vehicle_program_pattern pt
     WHERE c2.ref_piid LIKE pt.piid_pattern
       AND (pt.ref_agency_id IS NULL OR pt.ref_agency_id = c2.owning_agency_id)
     ORDER BY pt.priority, pt.program_id LIMIT 1) AS pid
  FROM analytics_dims.fpds_vehicle_contract c2
  WHERE c2.program_id IS NULL
) sub
WHERE c.ref_piid = sub.ref_piid AND c.program_id IS NULL AND sub.pid IS NOT NULL;

-- FSS referenced-type fallback rule (type-based; lives here because the pattern table
-- has no vehicle_type column — any contract-table rebuild MUST re-run this step) -----
UPDATE analytics_dims.fpds_vehicle_contract
SET program_id = CASE
  WHEN owning_agency_id IN ('4730','4732','4735','4740') THEN 'gsa_mas'
  WHEN owning_agency_id = '3600' THEN 'va_fss'
END
WHERE program_id IS NULL AND vehicle_type = 'FSS'
  AND owning_agency_id IN ('4730','4732','4735','4740','3600');
