-- FPDS-021 Step 7: vehicle_programs dimension exposure.
--
-- Verified 2026-06-12 via pg_attribute on project tfrhforjvaafmqmxmtrt:
--   analytics_dims.fpds_vehicle_program.program_id text
--   analytics_dims.fpds_vehicle_program.program_name text
--   analytics_dims.fpds_vehicle_program.program_short_name text
--   analytics_dims.fpds_vehicle_program.program_family text
--   analytics_dims.fpds_vehicle_program.owning_agency_id text
--   analytics_dims.fpds_vehicle_program.owning_agency_name text
--   analytics_dims.fpds_vehicle_program.is_governmentwide boolean
--   analytics_dims.fpds_vehicle_program.successor_program_id text
--   analytics_dims.fpds_vehicle_program.name_source text
--   analytics_dims.fpds_vehicle_program.notes text

CREATE OR REPLACE VIEW analytics_api.dim_vehicle_programs
WITH (security_barrier = true) AS
SELECT
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
FROM analytics_dims.fpds_vehicle_program;

COMMENT ON VIEW analytics_api.dim_vehicle_programs IS
'Curated vehicle-program registry used by the vehicle-level analytics package. Search by program name or short name.';

GRANT SELECT ON analytics_api.dim_vehicle_programs TO fpds_analytics_api_readonly;
