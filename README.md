# FPDS Analytics API

Free read-only API for understanding federal procurement markets.

Use it to answer:

- How does this agency buy?
- Is this market competitive or incumbent dominated?
- Which industries are growing?
- Where is contract work performed?
- How should we approach this customer?

The API turns FPDS-scale procurement data into ready-to-use analytics packages for analysts, developers, contractors, capture teams, and business-development teams.

## Why This Exists

Federal procurement data is public, but useful analysis is hard.

Raw FPDS records are large, coded, and transaction-level. A contractor trying to understand a customer usually does not need 99 million rows. They need answers:

- Is this customer open to new vendors?
- Do they rely on sole-source awards?
- Are they buying fixed-price work or higher-risk contract types?
- Which vendors already dominate the market?
- Which NAICS codes are growing?
- Does work happen locally or out of state?

This API packages those answers into simple datasets that can be queried, visualized, or integrated into other tools.

## What You Can Learn

| Question | API package to use | Why it matters |
|---|---|---|
| How does the customer prefer to buy? | Pricing Strategy | Shape your pitch around fixed-price, cost-type, T&M, PBC, or multi-year buying patterns |
| Is the market open or closed? | Competition Dynamics | Decide whether to prime, team, subcontract, or avoid a crowded/closed lane |
| Who are the incumbents? | Vendor Concentration | Understand who already controls the market and how strong their position is |
| What work is growing? | Industry / NAICS Demand | Find customer demand that matches your capabilities |
| Where does the work happen? | Geography | Decide whether local presence, regional teaming, or national delivery matters |

## Analysis Packages

The API is grouped into five packages.

### 1. Pricing Strategy

Shows how agencies buy: fixed price, cost reimbursement, time and materials, performance-based contracting, and multi-year patterns.

Use this to understand whether a customer values scope certainty, flexibility, cost control, or long-term execution capacity.

Datasets:

- `pricing.trend_fy`
- `pricing.agency_profile_fy`
- `pricing.kpi_summary`
- `pricing.risk_scorecard`
- `pricing.dept_year_summary`

### 2. Vendor Concentration

Shows whether markets are competitive or dominated by a few vendors.

Use this to understand incumbent strength, small-business participation, supplier diversity, and whether a market requires a teaming or displacement strategy.

Datasets:

- `concentration.trend_fy`
- `concentration.agency_profile`
- `concentration.vendor_market_leaders`
- `concentration.small_biz_health_fy`
- `concentration.kpi_summary`

### 3. Competition Dynamics

Shows competed vs. non-competed spending, sole-source hotspots, bundling, consolidation, and average offers received.

Use this to assess whether the customer is accessible to new entrants and how difficult competition may be.

Datasets:

- `competition.trend_fy`
- `competition.agency_profile_fy`
- `competition.kpi_summary`
- `competition.sole_source_hotspots`

### 4. Industry / NAICS Demand

Shows what industries the government buys in, which sectors are growing, and how diverse each department's industry portfolio is.

Use this to find customers that buy what you sell.

Datasets:

- `naics.trend_fy`
- `naics.agency_profile_fy`
- `naics.growth_leaders`
- `naics.kpi_summary`

### 5. Geography

Shows where contract work is performed, regional spending patterns, and vendor-state to performance-state flows.

Use this to understand local presence, regional opportunity, and whether work is staying in state or flowing elsewhere.

Datasets:

- `geography.state_trend_fy`
- `geography.regional_summary_fy`
- `geography.mismatch_leaders`
- `geography.kpi_summary`

## How To Use It

The API is dataset-first.

Start by listing the available datasets:

```bash
curl -s https://api.example.com/v1/catalog | jq '.data[].id'
```

Then inspect one dataset:

```bash
curl -s https://api.example.com/v1/datasets/competition.sole_source_hotspots | jq
```

Then query rows:

```bash
curl -s "https://api.example.com/v1/datasets/competition.sole_source_hotspots/rows?limit=25" \
  -H "X-Api-Key: $FPDS_API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data'
```

Example: find NAICS sector demand for Professional, Scientific, and Technical Services:

```bash
curl -s "https://api.example.com/v1/datasets/naics.trend_fy/rows?sector_code=54&fiscal_year_min=2022" \
  -H "X-Api-Key: $FPDS_API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data'
```

## API Functions

| Function | Endpoint | Key required? | Purpose |
|---|---|---:|---|
| Service metadata | `GET /v1` | No | Basic API information |
| Health check | `GET /v1/health` | No | Service and catalog status |
| List datasets | `GET /v1/catalog` | No | Discover available analytics |
| Describe dataset | `GET /v1/datasets/{dataset_id}` | No | See fields, filters, sort options, and caveats |
| Query dataset | `GET /v1/datasets/{dataset_id}/rows` | Yes | Return analytics rows |
| List dimensions | `GET /v1/dimensions` | No | Discover code lookup tables |
| Query dimension | `GET /v1/dimensions/{dimension_id}` | No | Explain FPDS codes |
| Export data | `POST /v1/exports` | Yes | Planned phase-2 bounded exports |

Read the full function guide: [docs/API_FUNCTIONS.md](docs/API_FUNCTIONS.md).

## Recommended Analyst Workflow

1. Start with `naics.trend_fy` to see where demand is growing.
2. Use `naics.agency_profile_fy` to find departments that buy that work.
3. Use `competition.agency_profile_fy` to see whether the customer is accessible.
4. Use `concentration.vendor_market_leaders` to identify incumbent strength.
5. Use `pricing.agency_profile_fy` to tailor your pitch to how the customer buys.
6. Use `geography.state_trend_fy` if place of performance or local presence matters.

The goal is to help answer:

> Who should we target, why should we target them, how hard will entry be, and what customer-specific story should we tell?

## Documentation

| Document | Purpose |
|---|---|
| [docs/API_FUNCTIONS.md](docs/API_FUNCTIONS.md) | Plain-English explanation of each API package and function |
| [docs/DATASETS.md](docs/DATASETS.md) | Dataset-by-dataset field, filter, and sort reference |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | First API calls |
| [docs/CAVEATS.md](docs/CAVEATS.md) | Data limitations and interpretation notes |
| [docs/PACKAGING.md](docs/PACKAGING.md) | GitHub/open-source packaging plan |
| [docs/LAUNCH_CHECKLIST.md](docs/LAUNCH_CHECKLIST.md) | Practical steps before public launch |
| [docs/LLM_INTEGRATIONS.md](docs/LLM_INTEGRATIONS.md) | ChatGPT, Claude/MCP, and Gemini integration plan |
| [docs/SECURITY_AUDIT_2026-06-03.md](docs/SECURITY_AUDIT_2026-06-03.md) | Current security audit and launch blockers |
| [openapi.yaml](openapi.yaml) | Machine-readable API contract |

## Access

Discovery endpoints are public so users can understand what the API offers before requesting a key.

Dataset row endpoints require an API key. The API is dataset-first: users choose a documented dataset, apply documented filters, and receive bounded JSON rows.

The API does not provide arbitrary SQL or bulk database access.

## Developer Setup

Install dependencies:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run locally:

```bash
FPDS_ANALYTICS_REQUIRE_AUTH=0 \
ANALYTICS_DATABASE_URL="postgresql://USER:PASSWORD@HOST:5432/postgres" \
uvicorn app.main:app --reload --host 0.0.0.0 --port 8010
```

If you store the analytics database password in macOS Keychain, use the local
runner after the `fpds-analytics-api-db-password` item has been created:

```bash
./run-local.sh
```

To use a different Keychain item:

```bash
FPDS_ANALYTICS_KEYCHAIN_SERVICE=my-keychain-service ./run-local.sh
```

The runner connects as `fpds_analytics_api_readonly`, which can read only the
`analytics_api` facade schema.

Production should keep auth enabled:

```bash
FPDS_ANALYTICS_API_KEY_HASHES="sha256_hex_digest"
ANALYTICS_DATABASE_URL="postgresql://fpds_analytics_api_readonly:PASSWORD@HOST:5432/postgres"
```

## Repository Contents

| Path | Purpose |
|---|---|
| `app/` | FastAPI service implementation |
| `catalog/datasets.yaml` | Dataset registry, filters, sorts, and field allowlists |
| `catalog/dimensions.yaml` | Dimension/code lookup registry |
| `docs/` | User and developer documentation |
| `examples/` | Example API calls |
| `sql/` | Database facade and role templates |
| `tests/` | Guardrail tests |
| `Dockerfile` | Container image |
| `.env.example` | Runtime environment variables |

## License

MIT. See [LICENSE](LICENSE).

## Validation

Run tests:

```bash
python -m pytest tests -q
```

## Caveats

- This API is for analysis and planning, not legal or procurement advice.
- FPDS obligation values can include de-obligations and corrections.
- Vendor datasets exclude records missing key vendor or agency fields.
- Current fiscal year values are year-to-date and may be incomplete.

See [docs/CAVEATS.md](docs/CAVEATS.md).
