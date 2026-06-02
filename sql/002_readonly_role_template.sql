-- Read-only database role template for the FPDS Analytics API.
--
-- This role is intentionally constrained to analytics_api only. It must not
-- receive USAGE or SELECT on public, chatbot, v2, source, SAM, opportunity, or
-- internal analytics schemas.
--
-- Create it as NOLOGIN first so grants can be validated safely. Convert it to
-- LOGIN with a generated password only at deployment time.

CREATE ROLE fpds_analytics_api_readonly
    NOLOGIN
    NOSUPERUSER
    NOCREATEDB
    NOCREATEROLE
    NOINHERIT
    NOREPLICATION;

REVOKE ALL ON DATABASE postgres FROM fpds_analytics_api_readonly;
GRANT CONNECT ON DATABASE postgres TO fpds_analytics_api_readonly;

REVOKE ALL ON SCHEMA public FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA analytics_dims FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA contract_pricing FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA vendor_concentration FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA competition_dynamics FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA naics_breakdown FROM fpds_analytics_api_readonly;
REVOKE ALL ON SCHEMA geographic_analysis FROM fpds_analytics_api_readonly;

GRANT USAGE ON SCHEMA analytics_api TO fpds_analytics_api_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics_api TO fpds_analytics_api_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA analytics_api
    GRANT SELECT ON TABLES TO fpds_analytics_api_readonly;

ALTER ROLE fpds_analytics_api_readonly SET statement_timeout = '15s';
ALTER ROLE fpds_analytics_api_readonly SET idle_in_transaction_session_timeout = '5s';
ALTER ROLE fpds_analytics_api_readonly SET default_transaction_read_only = on;
ALTER ROLE fpds_analytics_api_readonly SET search_path = analytics_api;

-- Security smoke-test queries to run manually after applying grants:
--
-- Should pass:
--   SELECT COUNT(*) FROM analytics_api.pricing_trend_fy;
--   SELECT * FROM analytics_api.dim_states LIMIT 5;
--
-- Should fail:
--   SELECT COUNT(*) FROM public.fpds_actions;
--   SELECT COUNT(*) FROM public.sam_registrations;
--   SELECT COUNT(*) FROM contract_pricing.mv_fpds_pricing_agency_year;
--   CREATE TABLE analytics_api.should_not_create(id int);
--
-- Deployment-only login enablement:
--   ALTER ROLE fpds_analytics_api_readonly LOGIN PASSWORD '<generated-secret>';
