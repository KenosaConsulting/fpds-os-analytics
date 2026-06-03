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

Hosted deployments should use a least-privileged, read-only database credential.

The public API should only expose:

- Documented dataset metadata
- Documented dataset row queries
- Documented dimension lookups

The public API should not expose:

- Arbitrary SQL
- Raw operational database tables
- Administrative service data
- Write permissions

## Reporting Issues

Do not open public issues for suspected secrets, data exposure, auth bypasses, or infrastructure vulnerabilities.

Use GitHub Private Vulnerability Reporting for this repository when available.
If private reporting is unavailable, contact Kenosa Consulting privately before public disclosure.
