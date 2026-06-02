# Packaging The FPDS Analytics API For GitHub

This document describes how the API should be packaged when published as an open-source/free product.

## Repository Goal

The GitHub repository should make the value obvious in the first minute:

> This API helps analysts understand how federal customers buy, who dominates their markets, where competition is weak, which industries are growing, and where contract work is performed.

The repository is not just code. It is a public product page for the analytics surface.

## Recommended Repository Layout

```text
fpds-analytics-api/
  README.md
  LICENSE
  SECURITY.md
  CONTRIBUTING.md
  openapi.yaml
  catalog/
    datasets.yaml
    dimensions.yaml
  app/
    main.py
    auth.py
    catalog.py
    db.py
    query_builder.py
    routes/
  docs/
    API_FUNCTIONS.md
    QUICKSTART.md
    DATASETS.md
    SECURITY_MODEL.md
    CAVEATS.md
  examples/
    curl/
    python/
    javascript/
  sql/
    001_analytics_api_facade.sql
    002_readonly_role_template.sql
  tests/
  Dockerfile
  requirements.txt
  .env.example
```

## Public Documentation Package

The README should be written for mixed audiences:

- Contractors and business-development teams.
- Procurement analysts.
- Data analysts.
- Developers integrating the API.

Recommended public docs:

| Document | Audience | Purpose |
|---|---|---|
| `README.md` | Everyone | Value proposition, examples, quickstart |
| `docs/API_FUNCTIONS.md` | Analysts and developers | Explains every API function/package in plain English |
| `docs/DATASETS.md` | Analysts | Dataset-by-dataset reference |
| `docs/QUICKSTART.md` | Developers | First API calls in curl/Python/JavaScript |
| `docs/SECURITY_MODEL.md` | Security reviewers | Explains why raw FPDS and internal schemas are not exposed |
| `docs/CAVEATS.md` | Analysts | Data-quality notes and limitations |
| `openapi.yaml` | Developers | Machine-readable API contract |

## What Should Be Open Source

Safe to publish:

- FastAPI service code.
- Dataset and dimension catalog format.
- OpenAPI contract.
- SQL facade templates.
- Read-only role template.
- Examples and docs.
- Tests.

Do not publish:

- Supabase passwords or connection strings.
- Service-role keys.
- Live API keys.
- Internal scoring formulas not intended for the free product.
- Raw data dumps unless deliberately released.
- Private deployment config.

## Suggested GitHub README Opening

```md
# FPDS Analytics API

Free read-only API for understanding federal procurement markets.

Use it to answer:

- How does this agency buy?
- Is this market competitive or incumbent dominated?
- Which industries are growing?
- Where is contract work performed?
- How should we approach this customer?
```

## Licensing

Recommended:

- **Apache-2.0** if we want explicit patent grant language.
- **MIT** if we want the simplest permissive developer posture.

Because this API may become part of a broader analytics/intelligence platform, Apache-2.0 is the safer default.

## Hosted Product Positioning

GitHub should publish the code and docs.

The hosted API should provide the live product:

```text
https://api.kenosaconsulting.com/fpds/v1
```

or:

```text
https://fpds-api.kenosaconsulting.com/v1
```

The hosted API should require free API keys for row access. Discovery endpoints can stay public.

## Free Tier

Recommended first free tier:

- Public docs and catalog: no key required.
- Dataset row access: free API key required.
- 60 requests/minute.
- 2,000 requests/day.
- Default `limit=100`.
- Maximum `limit=1000` unless dataset has a lower cap.
- Export jobs disabled or limited until abuse controls are in place.

## Launch Checklist

Before publishing:

- Replace placeholder domain in `openapi.yaml`.
- Add hosted API URL to README.
- Add signup instructions for a free API key.
- Add `LICENSE`, `SECURITY.md`, and `CONTRIBUTING.md`.
- Confirm `analytics_api` is not exposed to Supabase `anon` or `authenticated`.
- Confirm API runtime connects with `fpds_analytics_api_readonly`, not `postgres` or `service_role`.
- Run tests.
- Run Supabase advisors and document known non-blocking findings.
