-- Optional Supabase hardening template for shared projects.
--
-- Use this only when the public Supabase Data API / GraphQL API should not
-- expose raw objects from the `public` schema. The FPDS Analytics API does not
-- use `anon` or `authenticated`; it connects through the restricted
-- `fpds_analytics_api_readonly` database role and reads only `analytics_api`.
--
-- Review application dependencies before applying this to an existing shared
-- Supabase project because it can break clients that read `public` objects
-- directly through PostgREST, GraphQL, or a browser Supabase client.

DO $$
DECLARE
  obj record;
BEGIN
  FOR obj IN
    SELECT n.nspname AS schema_name,
           c.relname AS object_name,
           c.relkind AS object_kind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
      AND (
        has_table_privilege('anon', c.oid, 'SELECT')
        OR has_table_privilege('authenticated', c.oid, 'SELECT')
      )
  LOOP
    EXECUTE format(
      'REVOKE SELECT ON %s %I.%I FROM anon, authenticated',
      CASE obj.object_kind
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        ELSE 'TABLE'
      END,
      obj.schema_name,
      obj.object_name
    );
  END LOOP;
END $$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE SELECT ON TABLES FROM anon, authenticated;

REVOKE USAGE ON SCHEMA public FROM anon, authenticated;
