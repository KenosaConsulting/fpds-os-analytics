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
| Does this customer use small-business set-asides? | Set-Aside & Socioeconomic | Determine which programs (8(a), WOSB, HUBZone, SDVOSB) to pursue and which offices are friendliest |

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

### 6. Set-Aside & Socioeconomic Programs

Shows which small-business set-aside programs agencies use: 8(a), WOSB, HUBZone, SDVOSB, total small business, and unrestricted.

Use this to understand whether a customer uses set-asides, which programs they prefer, and which offices are most friendly to small businesses. Includes office-level granularity.

Datasets:

- `set_aside.trend_fy`
- `set_aside.family_trend_fy`
- `set_aside.agency_profile_fy`
- `set_aside.agency_mix_fy`
- `set_aside.office_profile_fy`
- `set_aside.kpi_summary`

## How To Use It

The API is dataset-first.

Set the API base URL for your environment first. The examples below assume the
service is deployed and reachable.

```bash
export FPDS_ANALYTICS_API_BASE_URL="https://YOUR_HOST"
# or, for authorized local maintainer testing:
# export FPDS_ANALYTICS_API_BASE_URL="http://127.0.0.1:8010"
```

Start by listing the available datasets:

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/catalog" | jq '.data[].id'
```

Then inspect one dataset:

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/competition.sole_source_hotspots" | jq
```

Then query rows:

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/competition.sole_source_hotspots/rows?limit=25" \
  | jq '.data'
```

Example: find NAICS sector demand for Professional, Scientific, and Technical Services:

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/naics.trend_fy/rows?sector_code=54&fiscal_year_min=2022&limit=25" \
  | jq '.data'
```

Free access includes catalog discovery, dataset metadata, dimension lookups, and
capped row samples. API-key access may provide higher rate limits, larger
bounded responses, exports, or support. No access tier exposes arbitrary SQL,
raw source tables, or write operations.

## Sample Response

```json
{
  "notice": "FPDS analytics are decision-support indicators, not a complete procurement universe.",
  "data": [
    {
      "contracting_dept_id": "9700",
      "fiscal_year": 2025,
      "total_action_count": 42,
      "total_obligated": "125000000.00",
      "distinct_naics_count": 12,
      "top_naics_code_by_obligation": "541330"
    }
  ],
  "pagination": {
    "limit": 25,
    "next_cursor": null
  },
  "meta": {
    "dataset_id": "naics.trend_fy",
    "source": "FPDS analytics schema",
    "row_count": 1,
    "access": "public"
  }
}
```

## Use With ChatGPT, Claude, Gemini, Or Other AI Assistants

Most users do not need to write code first. They can give an AI assistant the API base URL and ask it to follow the AI assistant guide:

```text
Use the FPDS Analytics API to help me understand federal procurement customers.
Start here: https://YOUR_HOST/v1/ai-assistant-guide

First inspect the catalog, then choose the right dataset for my question.
Use only documented filters, sorts, and fields.
Explain what the data means for customer targeting, market entry, teaming, or capture strategy.
Include the API response notice, caveats, and notices, and do not invent data.
```

Replace `https://YOUR_HOST` with the hosted API URL for the environment you are
using.

If the assistant can make HTTP requests, it should start with:

```text
GET /v1/ai-assistant-guide
GET /v1/catalog
GET /v1/datasets/{dataset_id}
GET /v1/datasets/{dataset_id}/rows
```

If the assistant cannot make HTTP requests directly, the user can paste responses from `GET /v1/catalog` and `GET /v1/datasets/{dataset_id}` into the chat, then ask the assistant which row query to run.

Read the full AI usage guide: [docs/AI_ASSISTANT_GUIDE.md](docs/AI_ASSISTANT_GUIDE.md).

## API Functions

| Function | Endpoint | Key required? | Purpose |
|---|---|---:|---|
| Service metadata | `GET /v1` | No | Basic API information |
| Health check | `GET /v1/health` | No | Service and catalog status |
| AI assistant guide | `GET /v1/ai-assistant-guide` | No | Copy/paste guidance for ChatGPT, Claude, Gemini, and similar tools |
| List datasets | `GET /v1/catalog` | No | Discover available analytics |
| Describe dataset | `GET /v1/datasets/{dataset_id}` | No | See fields, filters, sort options, and caveats |
| Query dataset | `GET /v1/datasets/{dataset_id}/rows` | No | Return bounded public analytics rows; API key optional for higher-volume access |
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
| [docs/METHODOLOGY.md](docs/METHODOLOGY.md) | How every number is computed: source data, materialized views, report views, formulas |
| [docs/IMPLEMENTATION_PLAN_V2.md](docs/IMPLEMENTATION_PLAN_V2.md) | V2 quick wins: set-aside promotion, dim labels, competition enrichment, commercial item, parent company |
| [docs/ANALYTICS_SCHEMA_DESIGN.md](docs/ANALYTICS_SCHEMA_DESIGN.md) | Database schema design notes for future analytics expansion |
| [docs/ANALYST_VIEW_IMPROVEMENTS.md](docs/ANALYST_VIEW_IMPROVEMENTS.md) | Product roadmap: analyst-facing view priorities and composite pages |
| [docs/API_FUNCTIONS.md](docs/API_FUNCTIONS.md) | Plain-English explanation of each API package and function |
| [docs/AI_ASSISTANT_GUIDE.md](docs/AI_ASSISTANT_GUIDE.md) | Instructions users can paste into ChatGPT, Claude, Gemini, or similar tools |
| [docs/DATASETS.md](docs/DATASETS.md) | Dataset-by-dataset field, filter, and sort reference |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | First API calls |
| [docs/CAVEATS.md](docs/CAVEATS.md) | Data limitations and interpretation notes |
| [docs/LLM_INTEGRATIONS.md](docs/LLM_INTEGRATIONS.md) | ChatGPT, Claude/MCP, and Gemini integration plan |
| [SECURITY.md](SECURITY.md) | Security boundary and responsible disclosure |
| [openapi.yaml](openapi.yaml) | Machine-readable API contract |

## Access

Discovery endpoints are public so users can understand what the API offers
immediately.

Free access includes catalog discovery, dataset metadata, dimension lookups, and
capped row samples. API-key access may provide higher rate limits, larger
bounded responses, exports, or support.

The API does not provide arbitrary SQL, raw source table access, bulk database
access, or write operations.

## Developer Setup

This repository does not include a public database dump, local seed data, or
credentials for the Kenosa analytics database. That is intentional: the API
runtime reads from a restricted Postgres/Supabase facade, and live credentials
must not be committed, shared in issues, or documented in public setup steps.

Unauthenticated contributors can work on the API contract, catalog metadata,
query guardrails, documentation, and tests that do not require a database.

Install dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Run the local validation suite:

```bash
python -m pytest tests -q
```

To run the API server against data, use one of these paths:

- Authorized maintainers may use a Kenosa-provisioned read-only database
  credential from an approved secret store.
- External developers may point the app at their own compatible Postgres
  database that implements the `analytics_api` facade schema.

The runtime requires either `ANALYTICS_DATABASE_URL`/`DATABASE_URL` or
component settings (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASS`).
Use only the restricted analytics API role for shared environments; never use a
`postgres`, `service_role`, owner, or write-capable credential.

Authorized maintainers who already have local secret access can use:

```bash
./run-local.sh
```

The local runner does not supply database credentials from the repository. Set
`ANALYTICS_DATABASE_URL`, or set `DB_HOST` and retrieve `DB_PASS` from your
approved local secret store before launching. If your approved local secret
store uses macOS Keychain:

```bash
FPDS_ANALYTICS_KEYCHAIN_SERVICE=my-keychain-service \
FPDS_ANALYTICS_KEYCHAIN_ACCOUNT=my-keychain-account \
./run-local.sh
```

By default the app connects as `fpds_analytics_api_readonly`, which should be
granted read access only to the `analytics_api` facade schema.

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
