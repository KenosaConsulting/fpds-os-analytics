# FPDS Analytics MCP Server

Standalone stdio MCP server that wraps the FPDS Analytics REST API. It exposes only documented, bounded API operations and does not provide SQL, raw table access, credentials, exports, or admin functions.

## Run

```bash
FPDS_API_BASE_URL=https://YOUR_API_HOST ./.venv/bin/python -m mcp.fpds_mcp_server
```

or:

```bash
./.venv/bin/python -m mcp.fpds_mcp_server --api-base-url https://YOUR_API_HOST
```

The API base URL is the only server configuration. Public bounded REST access does not require an API key.

## Tools

- `fpds_list_datasets`: wraps `GET /v1/catalog`.
- `fpds_describe_dataset`: wraps `GET /v1/datasets/{dataset_id}`.
- `fpds_query_dataset`: wraps `GET /v1/datasets/{dataset_id}/rows`.
- `fpds_list_dimensions`: wraps `GET /v1/dimensions`.
- `fpds_lookup_dimension`: wraps `GET /v1/dimensions/{dimension_id}`.
- `fpds_resolve`: searches name-bearing dimensions with the FPDS-009 `q` search, including vehicle programs.
- `fpds_customer_profile`: wraps `GET /v1/profiles/customer`.

## Guardrails

The server is intentionally thin. Dataset IDs, filters, fields, sort keys, row limits, and dimension lookups are validated by the REST API catalog/query layer. Tool responses are structured JSON so the MCP client can do the analysis while preserving API caveats and notices.
