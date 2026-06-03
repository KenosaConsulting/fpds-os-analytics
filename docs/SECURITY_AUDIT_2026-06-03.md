# Security Audit: 2026-06-03

Scope:

- Public repository contents
- FastAPI application code
- API authentication and query construction
- Container baseline
- Supabase facade access checks for the analytics API role

Out of scope:

- Full penetration test
- Load test
- Remediation of unrelated Supabase schemas used by other services

## Summary

The API is safe enough to continue toward hosted testing if it is deployed with the documented read-only database role, API-key auth enabled, and rate limits backed by Redis or an edge gateway.

Do not launch broadly until the remaining launch blockers are resolved.

## Changes Made During Audit

- Removed internal implementation topology from the public README and softened `SECURITY.md`.
- Changed CORS from wildcard-by-default to explicit opt-in.
- Added support for SHA-256 API key hashes via `FPDS_ANALYTICS_API_KEY_HASHES`.
- Made placeholder plaintext API keys fail closed.
- Added tests for hashed API keys, placeholder key rejection, and CORS defaults.
- Changed the Docker image to run as a non-root user.
- Added Dependabot for Python and GitHub Actions updates.
- Added Redis-compatible app rate limiting with a local in-memory fallback.
- Added `pip-audit` dependency scanning to CI.
- Added the MIT license and GitHub Private Vulnerability Reporting guidance.
- Enabled RLS on live `public` tables and revoked `anon`/`authenticated` `SELECT` from live `public` objects.
- Set explicit `search_path` on the live `v2.hybrid_search`, `v2.normalize_set_aside`, and `v2.renorm_weight` functions.

## Verified Controls

| Control | Result |
|---|---|
| Dataset rows require API key by default | Pass |
| Missing API key returns 401 | Pass |
| Invalid API key returns 403 | Pass |
| Placeholder key config fails closed | Pass |
| Hashed API key config works | Pass |
| Query fields, filters, and sorts are allowlisted | Pass |
| SQL identifiers are quoted and validated | Pass |
| Query values are parameterized | Pass |
| Limit caps are enforced | Pass |
| Expensive datasets require narrowing filters | Pass |
| Query timeout is enforced | Pass |
| App-level rate limits are enabled by default | Pass |
| CORS is not wildcard by default | Pass |
| Container runs as non-root | Pass |
| GitHub CI runs tests | Pass |
| GitHub CI runs dependency audit | Pass |

## Supabase Facade Verification

The live database permission check returned:

- `anon` cannot use or select from the analytics facade.
- `authenticated` cannot use or select from the analytics facade.
- The analytics API read-only role can use and select from the analytics facade.
- The analytics API read-only role cannot use a raw source analytics schema checked in the audit.

This confirms the intended API facade isolation for the free product path.

## Findings

### Medium: Shared Supabase project still has advisor warnings outside this API

Supabase security advisors still report pre-existing issues outside this API product, including `v2` GraphQL object visibility, extensions installed in `public`, and Auth leaked-password protection being disabled.

Impact:

- This is not caused by the `fpds-os-analytics` API facade.
- It is still a launch risk if the same shared Supabase project is used for broad public product traffic without isolating this free API.

Recommendation:

- Prefer a separate public analytics database/project or a materialized analytics data mart for launch.
- If using the current project, resolve the remaining shared-project advisor warnings before broad public distribution.
- Do not change unrelated schemas casually because other agents/services may depend on them.

Notes from remediation:

- The previous `rls_disabled_in_public` finding was resolved by enabling RLS on live `public` tables.
- The remaining `rls_enabled_no_policy` entries are informational and mean those tables deny access by default unless a policy is added.
- The previous public GraphQL object visibility warnings were resolved by revoking `SELECT` from `anon` and `authenticated` on live `public` objects.
- The previous mutable `search_path` warnings were resolved by setting explicit paths on the flagged `v2` functions.
- Remaining `v2` authenticated GraphQL visibility was not changed because revoking those grants could affect existing authenticated Supabase clients.

### Low: Rate limiter needs production backing store

The app now includes rate limiting. Without `FPDS_ANALYTICS_REDIS_URL`, limits are process-local and suitable only for local testing or a single-worker deployment.

Impact:

- A multi-worker or multi-instance deployment needs Redis or an equivalent edge/API-gateway limiter to avoid per-process bypass.

Recommendation:

- Configure `FPDS_ANALYTICS_REDIS_URL` in hosted environments, or enforce equivalent limits at the edge/API gateway by API key and IP.
- Add request logging using non-secret key IDs.

### Low: API key hashes are unsalted

Production can now store SHA-256 API key hashes instead of plaintext keys. Unsalted hashes are acceptable only if generated API keys have high entropy.

Recommendation:

- Generate long random API keys.
- Do not allow user-chosen keys.
- Rotate keys if repository, CI, or host secret storage is suspected of exposure.

### Low: Public docs still include SQL templates

The SQL files are useful for transparency and self-hosting, but they show the intended facade pattern and relation names.

Recommendation:

- Keep SQL templates if the repo is meant to be open-source and self-hostable.
- Remove or simplify SQL templates only if this repository is intended to be API-client-only.

## Launch Blockers

- Rotate the analytics read-only database password before hosted launch.
- Deploy behind HTTPS with `FPDS_ANALYTICS_REQUIRE_AUTH=1`.
- Configure production API keys as hashes, not plaintext values.
- Configure Redis-backed or edge/API-gateway rate limits.
- Resolve or isolate from remaining unrelated Supabase advisor warnings.

## Audit Commands Run

```bash
python -m pytest tests -q
python -m py_compile app/*.py app/routes/*.py
python -m pip_audit -r requirements.txt
rg -n "<credential-patterns>" .
```

Supabase MCP checks:

- Facade grant verification query.
- Security advisor scan.
- Public-schema RLS and grant verification query.
