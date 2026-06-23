-- 057_api_key_management.sql
-- Sprint 7: API key management, usage tracking, and rate limiting.
--
-- Creates:
--   Schema:    api_admin (private, not exposed via PostgREST or Data API)
--   Tables:    api_admin.api_keys, api_admin.api_key_usage_log, api_admin.rate_limits
--   Functions: api_admin.validate_api_key(text, text, text)
--              api_admin.create_api_key(text, text, text, int, int)
--              api_admin.revoke_api_key(uuid)
--              api_admin.list_api_keys()
--   View:      api_admin.usage_summary_daily
--   Grants:    SELECT on api_admin.api_keys to fpds_analytics_api_readonly (for key validation)
--   Cron:      Nightly cleanup of expired rate limit windows
--
-- Depends on: pgcrypto extension (already enabled), pg_cron extension
--
-- NOTE: This schema is NOT exposed via Supabase Data API / PostgREST.
-- The analytics API service calls validate_api_key() via direct SQL connection.
-- Admin operations (create/revoke/list) run as postgres or via scripts only.

BEGIN;

-- ============================================================================
-- Schema
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS api_admin;

COMMENT ON SCHEMA api_admin IS
    'API key management, usage tracking, and rate limiting. Not exposed via PostgREST.';

-- ============================================================================
-- Tables
-- ============================================================================

-- Tier defaults reference (not stored in DB — enforced by application):
--   public:   25 rows/req,   60 req/min,  no key required
--   beta:    250 rows/req,  300 req/min,  key required
--   partner: 1000 rows/req, 1000 req/min, key required
--   internal: 10000 rows/req, no limit,   key required

CREATE TABLE api_admin.api_keys (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Key identity
    key_hash                TEXT NOT NULL,           -- SHA-256 hex hash of the plaintext key
    key_prefix              TEXT NOT NULL,            -- First 8 chars of plaintext key (for display/lookup: "fpds_beta_xxxxxxxx...")
    -- Owner
    user_email              TEXT,                     -- Contact email (optional — not all keys require accounts)
    user_name               TEXT,                     -- Human-readable name
    organization            TEXT,                     -- Company or org name
    -- Access control
    tier                    TEXT NOT NULL DEFAULT 'beta'
                            CHECK (tier IN ('beta', 'partner', 'internal')),
    max_rows_per_request    INTEGER NOT NULL DEFAULT 250,
    rate_limit_per_minute   INTEGER NOT NULL DEFAULT 300,
    scopes                  JSONB NOT NULL DEFAULT '["read"]'::jsonb,
    -- Lifecycle
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at              TIMESTAMPTZ,              -- NULL = never expires
    revoked_at              TIMESTAMPTZ,
    last_used_at            TIMESTAMPTZ,
    -- Metadata
    notes                   TEXT,
    created_by              TEXT NOT NULL DEFAULT 'admin'
);

-- Index for key validation (hot path)
CREATE UNIQUE INDEX idx_api_keys_key_hash ON api_admin.api_keys (key_hash);
-- Index for prefix-based lookup (admin display)
CREATE INDEX idx_api_keys_prefix ON api_admin.api_keys (key_prefix);
-- Index for active key queries
CREATE INDEX idx_api_keys_active ON api_admin.api_keys (is_active, tier)
    WHERE is_active = TRUE;

COMMENT ON TABLE api_admin.api_keys IS
    'API keys for the FPDS Analytics API. Keys are SHA-256 hashed; plaintext is shown once at creation and never stored.';
COMMENT ON COLUMN api_admin.api_keys.key_hash IS
    'SHA-256 hex digest of the plaintext API key. Used for O(1) lookup during validation.';
COMMENT ON COLUMN api_admin.api_keys.key_prefix IS
    'First 8 characters of the plaintext key. Safe for display, logs, and admin UIs (e.g. "fpds_beta").';


-- Usage log — append-only, one row per authenticated request
CREATE TABLE api_admin.api_key_usage_log (
    id                  BIGSERIAL PRIMARY KEY,
    api_key_id          UUID NOT NULL REFERENCES api_admin.api_keys(id) ON DELETE CASCADE,
    requested_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    endpoint            TEXT,                        -- e.g. '/v1/datasets/pricing.trend_fy/rows'
    dataset_id          TEXT,                        -- extracted dataset_id if applicable
    http_method         TEXT DEFAULT 'GET',
    response_status     SMALLINT,                    -- HTTP status code
    row_count           INTEGER,                     -- rows returned
    duration_ms         INTEGER,                     -- response time
    ip_address          INET
);

-- Partition-friendly index (query by key + time range)
CREATE INDEX idx_usage_log_key_time ON api_admin.api_key_usage_log (api_key_id, requested_at DESC);
-- Index for time-range analytics
CREATE INDEX idx_usage_log_time ON api_admin.api_key_usage_log (requested_at DESC);

COMMENT ON TABLE api_admin.api_key_usage_log IS
    'Append-only request log for authenticated API calls. Used for usage analytics and billing.';


-- Rate limit state — one row per active key, updated on each request
CREATE TABLE api_admin.rate_limits (
    api_key_id          UUID PRIMARY KEY REFERENCES api_admin.api_keys(id) ON DELETE CASCADE,
    window_start        TIMESTAMPTZ NOT NULL,
    request_count       INTEGER NOT NULL DEFAULT 0
);

COMMENT ON TABLE api_admin.rate_limits IS
    'Sliding-window rate limit counters per API key. Window resets after 60 seconds of inactivity.';


-- ============================================================================
-- Functions
-- ============================================================================

-- validate_api_key: Hot-path function called on every authenticated request.
-- Returns key metadata if valid, NULL if invalid/expired/revoked/rate-limited.
-- Also updates last_used_at and rate limit counters.
--
-- Returns:
--   api_key_id, tier, max_rows_per_request, rate_limited (boolean)
--
-- Design notes:
--   - SHA-256 (not bcrypt) for O(1) lookup by hash index. API keys are high-entropy
--     random strings, not human passwords — bcrypt's brute-force resistance is unnecessary
--     and the ~100ms latency per validation is unacceptable for an API hot path.
--   - Rate limiting uses a simple tumbling window (reset after 60s) rather than
--     sliding window. Good enough for v1; upgrade to token bucket if needed.

CREATE OR REPLACE FUNCTION api_admin.validate_api_key(
    p_api_key       TEXT,
    p_endpoint      TEXT DEFAULT NULL,
    p_ip_address    TEXT DEFAULT NULL
)
RETURNS TABLE (
    api_key_id              UUID,
    tier                    TEXT,
    max_rows_per_request    INTEGER,
    rate_limited            BOOLEAN,
    key_prefix              TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api_admin, extensions
AS $$
DECLARE
    v_hash          TEXT;
    v_key           api_admin.api_keys%ROWTYPE;
    v_now           TIMESTAMPTZ := clock_timestamp();
    v_window_start  TIMESTAMPTZ;
    v_count         INTEGER;
BEGIN
    -- Hash the incoming key
    v_hash := encode(digest(p_api_key, 'sha256'), 'hex');

    -- Look up the key
    SELECT * INTO v_key
    FROM api_admin.api_keys ak
    WHERE ak.key_hash = v_hash
      AND ak.is_active = TRUE
      AND (ak.expires_at IS NULL OR ak.expires_at > v_now)
      AND ak.revoked_at IS NULL;

    IF v_key.id IS NULL THEN
        RETURN;  -- Invalid, expired, or revoked
    END IF;

    -- Update last_used_at (non-blocking, best-effort)
    UPDATE api_admin.api_keys SET last_used_at = v_now WHERE id = v_key.id;

    -- Rate limiting: tumbling 60-second window
    SELECT rl.window_start, rl.request_count INTO v_window_start, v_count
    FROM api_admin.rate_limits rl
    WHERE rl.api_key_id = v_key.id;

    IF v_window_start IS NULL THEN
        -- First request ever
        INSERT INTO api_admin.rate_limits (api_key_id, window_start, request_count)
        VALUES (v_key.id, v_now, 1);
        v_count := 1;
    ELSIF v_now >= v_window_start + interval '60 seconds' THEN
        -- Window expired — reset
        UPDATE api_admin.rate_limits
        SET window_start = v_now, request_count = 1
        WHERE api_key_id = v_key.id;
        v_count := 1;
    ELSE
        -- Within window — increment
        UPDATE api_admin.rate_limits
        SET request_count = request_count + 1
        WHERE api_key_id = v_key.id
        RETURNING request_count INTO v_count;
    END IF;

    -- Return result
    RETURN QUERY SELECT
        v_key.id,
        v_key.tier,
        v_key.max_rows_per_request,
        (v_count > v_key.rate_limit_per_minute),  -- rate_limited
        v_key.key_prefix;
END;
$$;

COMMENT ON FUNCTION api_admin.validate_api_key(TEXT, TEXT, TEXT) IS
    'Validates an API key, enforces rate limits, updates usage timestamp. Returns NULL row if key is invalid/expired/rate-limited.';


-- create_api_key: Admin function to provision a new key.
-- Returns the plaintext key (shown once, never stored).

CREATE OR REPLACE FUNCTION api_admin.create_api_key(
    p_tier              TEXT DEFAULT 'beta',
    p_user_email        TEXT DEFAULT NULL,
    p_user_name         TEXT DEFAULT NULL,
    p_organization      TEXT DEFAULT NULL,
    p_max_rows          INTEGER DEFAULT NULL,
    p_rate_limit        INTEGER DEFAULT NULL,
    p_notes             TEXT DEFAULT NULL,
    p_expires_in_days   INTEGER DEFAULT NULL
)
RETURNS TABLE (
    api_key_id      UUID,
    plaintext_key   TEXT,
    key_prefix      TEXT,
    tier            TEXT,
    expires_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api_admin, extensions
AS $$
DECLARE
    v_raw_bytes     BYTEA;
    v_plaintext     TEXT;
    v_prefix        TEXT;
    v_hash          TEXT;
    v_id            UUID;
    v_expires       TIMESTAMPTZ;
    v_max_rows      INTEGER;
    v_rate          INTEGER;
BEGIN
    -- Generate 32 random bytes → 43-char base64url key
    v_raw_bytes := gen_random_bytes(32);
    -- Format: fpds_{tier}_{base64url}
    v_plaintext := 'fpds_' || p_tier || '_' || replace(replace(encode(v_raw_bytes, 'base64'), '+', '-'), '/', '_');
    -- Remove trailing '=' padding
    v_plaintext := rtrim(v_plaintext, '=');
    v_prefix := left(v_plaintext, 12);
    v_hash := encode(digest(v_plaintext, 'sha256'), 'hex');

    -- Tier defaults
    v_max_rows := COALESCE(p_max_rows, CASE p_tier
        WHEN 'beta'     THEN 250
        WHEN 'partner'  THEN 1000
        WHEN 'internal' THEN 10000
        ELSE 250
    END);
    v_rate := COALESCE(p_rate_limit, CASE p_tier
        WHEN 'beta'     THEN 300
        WHEN 'partner'  THEN 1000
        WHEN 'internal' THEN 100000  -- effectively unlimited
        ELSE 300
    END);

    -- Expiry
    IF p_expires_in_days IS NOT NULL THEN
        v_expires := now() + (p_expires_in_days || ' days')::INTERVAL;
    END IF;

    INSERT INTO api_admin.api_keys (
        key_hash, key_prefix, user_email, user_name, organization,
        tier, max_rows_per_request, rate_limit_per_minute,
        notes, expires_at
    ) VALUES (
        v_hash, v_prefix, p_user_email, p_user_name, p_organization,
        p_tier, v_max_rows, v_rate,
        p_notes, v_expires
    )
    RETURNING id INTO v_id;

    RETURN QUERY SELECT v_id, v_plaintext, v_prefix, p_tier, v_expires;
END;
$$;

COMMENT ON FUNCTION api_admin.create_api_key IS
    'Provisions a new API key. Returns the plaintext key ONCE — it is never stored. Record it immediately.';


-- revoke_api_key: Soft-revoke a key (keeps audit trail).

CREATE OR REPLACE FUNCTION api_admin.revoke_api_key(p_key_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = api_admin
AS $$
BEGIN
    UPDATE api_admin.api_keys
    SET is_active = FALSE, revoked_at = now()
    WHERE id = p_key_id AND is_active = TRUE;
    RETURN FOUND;
END;
$$;


-- list_api_keys: Admin view of all keys (never shows hashes).

CREATE OR REPLACE FUNCTION api_admin.list_api_keys(p_include_revoked BOOLEAN DEFAULT FALSE)
RETURNS TABLE (
    id                      UUID,
    key_prefix              TEXT,
    user_email              TEXT,
    user_name               TEXT,
    organization            TEXT,
    tier                    TEXT,
    max_rows_per_request    INTEGER,
    rate_limit_per_minute   INTEGER,
    is_active               BOOLEAN,
    created_at              TIMESTAMPTZ,
    expires_at              TIMESTAMPTZ,
    revoked_at              TIMESTAMPTZ,
    last_used_at            TIMESTAMPTZ,
    notes                   TEXT,
    total_requests          BIGINT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = api_admin
AS $$
    SELECT
        ak.id,
        ak.key_prefix,
        ak.user_email,
        ak.user_name,
        ak.organization,
        ak.tier,
        ak.max_rows_per_request,
        ak.rate_limit_per_minute,
        ak.is_active,
        ak.created_at,
        ak.expires_at,
        ak.revoked_at,
        ak.last_used_at,
        ak.notes,
        COALESCE(log.cnt, 0) AS total_requests
    FROM api_admin.api_keys ak
    LEFT JOIN LATERAL (
        SELECT count(*) AS cnt
        FROM api_admin.api_key_usage_log ul
        WHERE ul.api_key_id = ak.id
    ) log ON TRUE
    WHERE p_include_revoked OR ak.is_active = TRUE
    ORDER BY ak.created_at DESC;
$$;


-- ============================================================================
-- Views
-- ============================================================================

-- Daily usage summary for analytics / billing
CREATE OR REPLACE VIEW api_admin.usage_summary_daily AS
SELECT
    date_trunc('day', ul.requested_at)::DATE   AS usage_date,
    ak.id                                       AS api_key_id,
    ak.key_prefix,
    ak.tier,
    ak.user_email,
    ak.organization,
    count(*)                                    AS request_count,
    count(DISTINCT ul.dataset_id)               AS datasets_accessed,
    sum(ul.row_count)                           AS total_rows_returned,
    avg(ul.duration_ms)::INTEGER                AS avg_duration_ms,
    count(*) FILTER (WHERE ul.response_status >= 400) AS error_count
FROM api_admin.api_key_usage_log ul
JOIN api_admin.api_keys ak ON ak.id = ul.api_key_id
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1 DESC, 7 DESC;


-- ============================================================================
-- Grants
-- ============================================================================

-- The analytics API readonly role needs to:
--   1. Call validate_api_key() to check incoming requests
--   2. Insert into usage_log (append-only) for request tracking
-- It should NOT be able to create/revoke keys or read key hashes directly.

GRANT USAGE ON SCHEMA api_admin TO fpds_analytics_api_readonly;
GRANT EXECUTE ON FUNCTION api_admin.validate_api_key(TEXT, TEXT, TEXT) TO fpds_analytics_api_readonly;
GRANT INSERT ON TABLE api_admin.api_key_usage_log TO fpds_analytics_api_readonly;
GRANT USAGE ON SEQUENCE api_admin.api_key_usage_log_id_seq TO fpds_analytics_api_readonly;


-- ============================================================================
-- Maintenance: nightly cleanup of stale rate limit windows
-- ============================================================================
-- (pg_cron job — run as postgres)
-- Cleans up rate_limits rows where window is >1 hour old (long-idle keys).
-- This keeps the table small. Active keys get their rows refreshed on every request.

-- NOTE: Execute this separately after migration:
-- SELECT cron.schedule(
--     'api-rate-limit-cleanup',
--     '0 4 * * *',
--     $$DELETE FROM api_admin.rate_limits WHERE window_start < now() - interval '1 hour'$$
-- );

COMMIT;
