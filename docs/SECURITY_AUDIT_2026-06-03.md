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
- Formal dependency CVE scan with an external scanner
- Remediation of unrelated Supabase schemas used by other services

## Summary

The API is safe enough to continue toward hosted testing if it is deployed with the documented read-only database role, API-key auth enabled, and edge rate limits.

Do not launch broadly until the remaining launch blockers are resolved.

## Changes Made During Audit

- Removed internal implementation topology from the public README and softened `SECURITY.md`.
- Changed CORS from wildcard-by-default to explicit opt-in.
- Added support for SHA-256 API key hashes via `FPDS_ANALYTICS_API_KEY_HASHES`.
- Made placeholder plaintext API keys fail closed.
- Added tests for hashed API keys, placeholder key rejection, and CORS defaults.
- Changed the Docker image to run as a non-root user.
- Added Dependabot for Python and GitHub Actions updates.

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
| CORS is not wildcard by default | Pass |
| Container runs as non-root | Pass |
| GitHub CI runs tests | Pass |

## Supabase Facade Verification

The live database permission check returned:

- `anon` cannot use or select from the analytics facade.
- `authenticated` cannot use or select from the analytics facade.
- The analytics API read-only role can use and select from the analytics facade.
- The analytics API read-only role cannot use a raw source analytics schema checked in the audit.

This confirms the intended API facade isolation for the free product path.

## Findings

### High: Broader Supabase project has unrelated exposed-schema advisor findings

Supabase security advisors still report pre-existing issues outside this API product, including RLS-disabled tables in exposed schemas and GraphQL object visibility for unrelated public/v2 objects.

Impact:

- This is not caused by the `fpds-os-analytics` API facade.
- It is still a launch risk if the same Supabase project is used for the public product.

Recommendation:

- Prefer a separate public analytics database/project or a materialized analytics data mart for launch.
- If using the current project, resolve exposed-schema RLS and GraphQL grants before broad public distribution.
- Do not change unrelated schemas casually because other agents/services may depend on them.

### Medium: No app-level distributed rate limiter

The app enforces per-request limits and query timeouts, but does not include a distributed rate limiter.

Impact:

- A valid API key can still generate high request volume.
- Public launch should not rely on app-level query caps alone.

Recommendation:

- Enforce rate limits at the edge/API gateway by API key and IP.
- Add request logging using non-secret key IDs.
- Consider a shared Redis-backed limiter if the host does not provide gateway limits.

### Medium: Dependency CVE scan not yet run with a dedicated scanner

`pytest` and compile checks pass, and Dependabot is configured. A dedicated dependency audit tool was not available in the local environment.

Recommendation:

- Add `pip-audit` or equivalent to CI before broad launch.
- Fail CI on high/critical vulnerabilities once the dependency baseline is stable.

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

- Choose a license.
- Add a real private security contact.
- Rotate the analytics read-only database password before hosted launch.
- Deploy behind HTTPS with `FPDS_ANALYTICS_REQUIRE_AUTH=1`.
- Configure production API keys as hashes, not plaintext values.
- Configure edge/API-gateway rate limits.
- Resolve or isolate from unrelated Supabase advisor findings.
- Add dependency CVE scanning to CI.

## Audit Commands Run

```bash
python -m pytest tests -q
python -m py_compile app/*.py app/routes/*.py
rg -n "<credential-patterns>" .
```

Supabase MCP checks:

- Facade grant verification query.
- Security advisor scan.
