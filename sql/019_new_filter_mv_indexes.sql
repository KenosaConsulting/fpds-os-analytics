-- Template migration: indexes for newly reachable catalog filters.
-- Do not run this file from the API repo; apply through the controlled database pipeline.

CREATE INDEX IF NOT EXISTS mv_vendor_naics_agency_year_agency_fy_idx
    ON vendor_concentration.mv_fpds_vendor_naics_agency_year
    (contracting_agency_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_vendor_naics_agency_year_naics_fy_idx
    ON vendor_concentration.mv_fpds_vendor_naics_agency_year
    (principal_naics_code, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_naics_agency_year_dept_fy_naics_idx
    ON naics_breakdown.mv_fpds_naics_agency_year
    (contracting_dept_id, fiscal_year, principal_naics_code);

CREATE INDEX IF NOT EXISTS mv_pricing_agency_year_dept_fy_idx
    ON contract_pricing.mv_fpds_pricing_agency_year
    (contracting_dept_id, fiscal_year);

CREATE INDEX IF NOT EXISTS mv_competition_agency_year_dept_fy_idx
    ON competition_dynamics.mv_fpds_competition_agency_year
    (contracting_dept_id, fiscal_year);
