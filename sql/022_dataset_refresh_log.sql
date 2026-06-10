-- Template migration: dataset freshness metadata.
-- The external refresh process outside this repo must add one INSERT per dataset
-- refresh into analytics_dims.dataset_refresh_log. Creating the empty table and
-- API reader view is in scope here; populating the table is not.

CREATE TABLE IF NOT EXISTS analytics_dims.dataset_refresh_log (
    dataset_id text PRIMARY KEY,
    source_view text NOT NULL,
    data_as_of timestamptz NOT NULL,
    refreshed_at timestamptz NOT NULL,
    notes text
);

CREATE OR REPLACE VIEW analytics_api.dataset_refresh_log
WITH (security_barrier = true) AS
SELECT
    dataset_id,
    source_view,
    data_as_of,
    refreshed_at,
    notes
FROM analytics_dims.dataset_refresh_log;

GRANT SELECT ON analytics_api.dataset_refresh_log TO fpds_analytics_api_readonly;
