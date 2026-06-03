# Launch Checklist

Use this checklist to move FPDS Analytics API from local testing to a public free product.

## 1. Repository

- Keep the open-source license in place.
- Confirm the public README says exactly who the API helps and what questions it answers.
- Keep `openapi.yaml`, `catalog/datasets.yaml`, and `docs/DATASETS.md` in sync.
- Keep SQL templates free of credentials.
- Require CI to pass before merging to `main`.

## 2. Database Isolation

- Use only the `fpds_analytics_api_readonly` database role in hosted environments.
- Grant the role `USAGE` and `SELECT` only on the `analytics_api` facade schema.
- Do not grant access to raw FPDS, SAM, opportunity, embedding, chat, or admin schemas.
- Keep the facade schema outside Supabase exposed API schemas unless intentionally publishing through PostgREST.
- Rotate the read-only database password before public launch.

## 3. Hosted API

- Deploy behind HTTPS.
- Use `https://analytics-api.kenosaconsulting.com` as the public base URL.
- Keep `FPDS_ANALYTICS_REQUIRE_AUTH=1`.
- Keep `FPDS_ANALYTICS_PUBLIC_ROWS_ENABLED=1` for bounded free access.
- Set `FPDS_ANALYTICS_PUBLIC_ROW_LIMIT=25` or another conservative public limit.
- Set `FPDS_ANALYTICS_API_KEYS` from secret storage.
- Prefer `FPDS_ANALYTICS_API_KEY_HASHES` over plaintext keys in production.
- Set `ANALYTICS_DATABASE_URL` from secret storage.
- Configure Redis-backed app rate limiting with `FPDS_ANALYTICS_REDIS_URL` or add edge/WAF rate limits by API key and IP.
- Add request logging with non-secret API key IDs only.
- Add uptime monitoring on `/v1/health`.

## 4. Product Readiness

- Publish a stable base URL.
- Publish a request form for free API keys.
- Publish clear usage limits.
- Publish attribution and data caveats.
- Create a few analyst examples:
  - Find a customer's buying style.
  - Find sole-source-heavy customers.
  - Find incumbent-heavy markets.
  - Find growing NAICS sectors.
  - Compare local vs out-of-state performance.

## 5. LLM Integrations

- Ship a ChatGPT Action using `openapi.yaml`.
- Ship a Claude remote MCP connector after the MCP bridge is implemented.
- Ship Gemini function declarations for `list_datasets`, `describe_dataset`, `query_dataset`, and `lookup_dimension`.
- Keep every LLM tool on the same safe API surface. Do not add arbitrary SQL tools.

## 6. Operational Follow-Ups

- Decide whether exports remain phase 2 or are hidden until implemented.
- Add a changelog before versioned public releases.
- Keep GitHub Private Vulnerability Reporting enabled.
- Rotate the analytics read-only database password before public launch.
- Address remaining Supabase advisor warnings that belong to the shared project before using it for broad public traffic.
