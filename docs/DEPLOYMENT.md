# Deployment

Target production URL:

```text
https://analytics-api.kenosaconsulting.com
```

## Required Runtime Settings

Set these in the hosting platform's secret manager:

```env
FPDS_ANALYTICS_REQUIRE_AUTH=1
FPDS_ANALYTICS_API_KEY_HASHES=sha256_hex_digest
FPDS_ANALYTICS_ALLOWED_ORIGINS=https://kenosaconsulting.com
ANALYTICS_DATABASE_URL=postgresql://fpds_analytics_api_readonly:PASSWORD@HOST:5432/postgres
```

For multi-worker or multi-instance deployments, also set:

```env
FPDS_ANALYTICS_REDIS_URL=redis://...
```

Do not deploy with `postgres`, `service_role`, or any broad database credential.

## Cloudflare DNS

`kenosaconsulting.com` is on Cloudflare nameservers. Create one DNS record after the hosting platform provides the service hostname.

Use a CNAME in most managed-host cases:

```text
Type: CNAME
Name: analytics-api
Target: HOSTING_PROVIDER_SERVICE_HOSTNAME
Proxy: DNS only until the host verifies the custom domain, then enable proxy if supported
TTL: Auto
```

If the hosting platform provides static IPs instead, use `A` or `AAAA` records for `analytics-api`.

## Host Requirements

The service is a containerized FastAPI app.

The host must support:

- Docker builds from this repository.
- HTTPS custom domains.
- Secret environment variables.
- A stable outbound connection to Supabase Postgres.
- A health check against `GET /v1/health`.

The container listens on `${PORT:-8010}`.

## Verification

After deployment and DNS propagation:

```bash
curl -s https://analytics-api.kenosaconsulting.com/v1/health
curl -s https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide
curl -s https://analytics-api.kenosaconsulting.com/v1/catalog
```

Then test an authenticated row query:

```bash
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/competition.sole_source_hotspots/rows?limit=5" \
  -H "X-Api-Key: $FPDS_API_KEY"
```

## AI Assistant Smoke Test

Paste this into ChatGPT, Claude, Gemini, or a similar assistant after the domain resolves:

```text
Use the FPDS Analytics API to help me understand what customers are palatable for my new construction company focused on international Army bases. I was enlisted in the Army for decades and gained sophisticated maintenance experience for heavy machinery and specialized construction.

Start here: https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide

First inspect the catalog, then choose the right dataset for my question. Use only documented filters, sorts, and fields. Explain what the data means for customer targeting, market entry, teaming, or capture strategy. Include caveats and do not invent data.
```
