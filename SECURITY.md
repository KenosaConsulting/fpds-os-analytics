# Security Policy

## Supported Surface

The public API is read-only and exposes only curated analytics datasets and dimension lookups.

Supported public endpoints:

- `GET /v1`
- `GET /v1/health`
- `GET /v1/catalog`
- `GET /v1/datasets/{dataset_id}`
- `GET /v1/datasets/{dataset_id}/rows`
- `GET /v1/dimensions`
- `GET /v1/dimensions/{dimension_id}`

## Security Boundary

The hosted service must connect to Postgres using the restricted `fpds_analytics_api_readonly` role.

That role should have:

- `USAGE` on `analytics_api`
- `SELECT` on curated `analytics_api` views

That role should not have:

- Access to raw FPDS tables
- Access to SAM tables
- Access to opportunity tables
- Access to embeddings/vector stores
- Access to chat logs
- Access to admin tables
- Write permissions

## Reporting Issues

Do not open public issues for suspected secrets, data exposure, auth bypasses, or infrastructure vulnerabilities.

Report security issues privately to Kenosa Consulting. Add the preferred security email here before public launch.
