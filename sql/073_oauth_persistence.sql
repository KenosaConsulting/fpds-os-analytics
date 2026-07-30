-- 073_oauth_persistence.sql
-- Persist OAuth clients, access tokens, and refresh tokens to the database
-- so they survive Render restarts and can be shared across instances.
--
-- Auth codes remain in-memory (5-min TTL, process-local is fine).
-- Expired tokens are cleaned up by a daily pg_cron job.
--
-- Tables:
--   api_admin.oauth_clients       — registered OAuth 2.0 clients (Claude.ai, etc.)
--   api_admin.oauth_access_tokens — active access tokens (30-day TTL)
--   api_admin.oauth_refresh_tokens — active refresh tokens (90-day TTL)

BEGIN;

-- ============================================================================
-- OAuth Clients
-- ============================================================================

CREATE TABLE api_admin.oauth_clients (
    client_id               TEXT PRIMARY KEY,
    client_secret           TEXT,
    client_name             TEXT NOT NULL,
    redirect_uris           JSONB NOT NULL DEFAULT '[]'::jsonb,
    grant_types             JSONB NOT NULL DEFAULT '["authorization_code"]'::jsonb,
    token_endpoint_auth_method TEXT DEFAULT 'none',
    scope                   TEXT DEFAULT 'fpds:read',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE api_admin.oauth_clients IS
    'Registered OAuth 2.0 clients (Claude.ai, Claude Desktop, etc.). Populated via Dynamic Client Registration.';
COMMENT ON COLUMN api_admin.oauth_clients.client_secret IS
    'Client secret for confidential clients. NULL for public clients (PKCE).';

-- ============================================================================
-- OAuth Access Tokens
-- ============================================================================

CREATE TABLE api_admin.oauth_access_tokens (
    token                   TEXT PRIMARY KEY,
    api_key                 TEXT NOT NULL,       -- The FPDS API key this token wraps
    client_id               TEXT NOT NULL REFERENCES api_admin.oauth_clients(client_id) ON DELETE CASCADE,
    scope                   TEXT NOT NULL DEFAULT 'fpds:read',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_oauth_access_tokens_expires ON api_admin.oauth_access_tokens (expires_at)
    WHERE expires_at < now();  -- Partial index for cleanup queries only

COMMENT ON TABLE api_admin.oauth_access_tokens IS
    'Active OAuth access tokens. Tokens are opaque strings that wrap an FPDS API key.';

-- ============================================================================
-- OAuth Refresh Tokens
-- ============================================================================

CREATE TABLE api_admin.oauth_refresh_tokens (
    token                   TEXT PRIMARY KEY,
    access_token            TEXT NOT NULL REFERENCES api_admin.oauth_access_tokens(token) ON DELETE CASCADE,
    api_key                 TEXT NOT NULL,
    client_id               TEXT NOT NULL,
    scope                   TEXT NOT NULL DEFAULT 'fpds:read',
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ NOT NULL
);

CREATE INDEX idx_oauth_refresh_tokens_expires ON api_admin.oauth_refresh_tokens (expires_at)
    WHERE expires_at < now();

COMMENT ON TABLE api_admin.oauth_refresh_tokens IS
    'Active OAuth refresh tokens. Used to issue new access tokens without re-authorization.';

-- ============================================================================
-- Cleanup function (called on token issue + nightly cron)
-- ============================================================================

CREATE OR REPLACE FUNCTION api_admin.cleanup_expired_oauth_tokens()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = api_admin
AS $$
    DELETE FROM api_admin.oauth_access_tokens WHERE expires_at < now();
    DELETE FROM api_admin.oauth_refresh_tokens WHERE expires_at < now();
$$;

COMMENT ON FUNCTION api_admin.cleanup_expired_oauth_tokens() IS
    'Remove expired OAuth tokens. Called daily by pg_cron and ad-hoc on token issue.';

-- ============================================================================
-- Grants
-- ============================================================================

GRANT SELECT, INSERT, DELETE ON TABLE api_admin.oauth_clients TO fpds_analytics_api_readonly;
GRANT SELECT, INSERT, DELETE ON TABLE api_admin.oauth_access_tokens TO fpds_analytics_api_readonly;
GRANT SELECT, INSERT, DELETE ON TABLE api_admin.oauth_refresh_tokens TO fpds_analytics_api_readonly;
GRANT EXECUTE ON FUNCTION api_admin.cleanup_expired_oauth_tokens() TO fpds_analytics_api_readonly;

-- ============================================================================
-- Nightly cleanup (run as postgres after migration)
-- ============================================================================
-- SELECT cron.schedule(
--     'oauth-token-cleanup',
--     '0 5 * * *',
--     $$SELECT api_admin.cleanup_expired_oauth_tokens()$$
-- );

COMMIT;
