```
        ╔═══════════════════════════════════════════════════════════════════╗
        ║                                                                   ║
        ║     ███████ ██████  ██████  ███████                               ║
        ║     ██      ██   ██ ██   ██ ██          Federal Procurement       ║
        ║     █████   ██████  ██   ██ ███████     Data Science              ║
        ║     ██      ██      ██   ██      ██                               ║
        ║     ██      ██      ██████  ███████     Analytics API             ║
        ║                                                                   ║
        ║     ▁▂▃▄▅▆▇  COMPETITIVE INTELLIGENCE ENGINE  ▇▆▅▄▃▂▁             ║
        ║                                                                   ║
        ║     ┌───────────────────────────────────────────────────────┐     ║
        ║     │  67 datasets · 16 dimensions · 99M+ federal actions   │     ║
        ║     │  REST + MCP  · MIT License   · Zero config to start   │     ║
        ║     └───────────────────────────────────────────────────────┘     ║
        ║                                                                   ║
        ╚═══════════════════════════════════════════════════════════════════╝
```

> **The federal government spends $700+ billion a year on contracts.
> Every transaction is public record.
> Contractors don't need raw data, they need to make decisions.**

This API turns 99 million FPDS contract actions into the
intelligence that wins proposals — pricing patterns, incumbent maps, market
entry difficulty scores, vehicle-program winners, recompete timelines, and 63
more analytics datasets — ready to query from a single endpoint.

No database to run. No data to download. No PhD required.

---

## ⚡ Three Commands to Your First Insight

```bash
# See what's available
curl -s "https://analytics-api.kenosaconsulting.com/v1/catalog" | jq '.data[].id'

# Who dominates Army IT services?
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/concentration.vendor_market_leaders/rows?contracting_dept_id=9700&principal_naics_code=541512&limit=10" | jq '.data'

# What's expiring in the next 12 months?
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/pipeline.recompete_watchlist/rows?contracting_dept_id=9700&remaining_months_max=12&limit=10" | jq '.data'
```

That's it. You're doing market intelligence now.

---

## 🎯 What Problem This Solves

Every government contractor faces the same challenge: **the data is free but
the analysis is expensive.**

FPDS (the Federal Procurement Data System) publishes every contract action the
US government makes. It's public. It's comprehensive. And it's also 99 million rows
of coded, transaction-level records that tell you almost nothing useful unless
you already know what you're looking for. Try digging through over 37,000,000,000 data points and tell me if you want to go the brute force route...

Most contractors solve this by paying five- or six-figure subscriptions to
platforms that repackage the same public data behind login walls. Or they assign
a human analyst to spend weeks in spreadsheets. Or they guess.

**This API is a different approach.** We pre-compute the analytical questions
that actually matter for capture strategy — and serve the answers as clean,
filterable, documented datasets with human-readable labels, metadata, caveats,
and enough context for an analyst (human or AI) to draw conclusions without
touching raw data.

Think of it this way:

> 📖 FPDS is the Atlas. This API is GPS.

---

## 🧬 What You Get: 12 Intelligence Packages

Each package answers a strategic question. Each contains multiple datasets
tuned for different grains and use cases.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                                                                     │
  │  PACKAGE                      QUESTION IT ANSWERS                   │
  │  ═══════                      ════════════════════                  │
  │                                                                     │
  │  Pricing Strategy             How does this customer prefer to buy? │
  │  Vendor Concentration         Who already owns this market?         │
  │  Competition Dynamics         Can a new vendor actually get in?     │
  │  Industry / NAICS Demand      What work is growing — and where?     │
  │  Geography                    Does local presence matter here?      │
  │  Set-Aside Programs           Which small-biz programs get used?    │
  │  PSC Classification           What exactly do they buy?             │
  │  Vehicle Mix                  Do I need a GWAC, Schedule, or IDIQ?  │
  │  Vehicle Programs             Which exact OASIS / SEWP / MAS paths? │
  │  Funding Flows                Who funds the work vs. who buys it?   │
  │  Recompete Pipeline           What contracts are expiring soon?     │
  │  Fiscal Seasonality           When does this customer spend?        │
  │                                                                     │
  └─────────────────────────────────────────────────────────────────────┘
```

Plus four **cross-cutting analytics** that don't belong to a single package:

| Dataset | What it tells you |
|---|---|
| **Customer 360 Profile** | One endpoint, eight analytical sections — spend trends, competition posture, incumbent map, pricing mix, vehicle preferences, recompete signals, all assembled for a single customer |
| **New-Entrant Cohorts** | How many new vendors enter each market per year, their first-win characteristics, set-aside paths, and 2-year survival rates |
| **Market Entry Difficulty** | A composite score blending HHI concentration, sole-source share, vehicle dependence, average offers received, and incumbent tenure — one number that says "how hard is this market to crack" |
| **Award-Size Distribution** | Median, P25, and P75 award sizes by agency × NAICS, plus under-SAT (simplified acquisition threshold) share |

**67 datasets. 16 code-lookup dimensions. Every query bounded, parameterized,
and documented.**

### Vehicle-program deployment note

The vehicle-program package adds three dataset surfaces:
`acquisition.vehicle_program_usage_fy`,
`acquisition.vehicle_program_summary`, and
`acquisition.vehicle_program_vendors`, plus the `vehicle_programs`
dimension. These dataset views depend on the corrected Step-4
`customer_intelligence.mv_fpds_vehicle_program_*_norm` materialized views.
If those `_norm` MVs are not present in the target database, only the
`vehicle_programs` dimension will be live after migration.

---

## 🤖 Wire It Into Your AI — MCP Integration

The API ships with a built-in **Model Context Protocol (MCP) server** — which
means Claude, Cursor, Windsurf, VS Code Copilot, and any MCP-compatible AI
assistant can query federal procurement data directly, without you writing a
single line of code.

**Why this matters:** Instead of copy-pasting API responses into chat windows,
your AI assistant becomes a procurement analyst. It can browse the catalog,
pick the right dataset, apply filters, interpret caveats, and explain what the
data means for your capture strategy — all in natural language.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "python",
      "args": ["-m", "mcp.fpds_mcp_server"],
      "cwd": "/path/to/fpds-os-analytics",
      "env": {
        "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
      }
    }
  }
}
```

### Cursor / Windsurf

Add to your project's `.cursor/mcp.json` (Cursor) or MCP config (Windsurf):

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "python",
      "args": ["-m", "mcp.fpds_mcp_server"],
      "cwd": "/path/to/fpds-os-analytics",
      "env": {
        "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
      }
    }
  }
}
```

### VS Code (GitHub Copilot / Continue)

Add to `.vscode/mcp.json`:

```json
{
  "servers": {
    "fpds-analytics": {
      "command": "python",
      "args": ["-m", "mcp.fpds_mcp_server"],
      "cwd": "${workspaceFolder}",
      "env": {
        "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
      }
    }
  }
}
```

### Any MCP Client (Generic stdio)

```bash
FPDS_API_BASE_URL=https://analytics-api.kenosaconsulting.com \
  python -m mcp.fpds_mcp_server
```

### What Your AI Can Do Once Connected

| MCP Tool | What it does |
|---|---|
| `fpds_list_datasets` | Browse all 61 analytics datasets with descriptions |
| `fpds_describe_dataset` | See fields, filters, sorts, caveats, and example queries for any dataset |
| `fpds_query_dataset` | Query rows with filters, sorting, and pagination |
| `fpds_list_dimensions` | Browse code-lookup tables (agencies, NAICS, PSC, etc.) |
| `fpds_lookup_dimension` | Translate coded values to human-readable names |
| `fpds_resolve` | Search by name across agencies, offices, NAICS, PSC, departments, and vehicle programs |
| `fpds_customer_profile` | Get a full Customer 360 profile — eight analytical sections in one call |

**Try asking your AI:**

> "Who are the top 5 incumbent vendors for Army cybersecurity contracts?"

> "Show me NAICS codes that are growing fastest at the Department of Energy."

> "What contracts at HHS are expiring in the next 6 months and worth over $10M?"

> "Give me a competitive analysis for entering the Navy's IT services market."

The AI will pick the right dataset, apply filters, and interpret the results —
including caveats about data limitations, current fiscal year incompleteness,
and deobligation effects.

---

## 🔬 The Capture Strategist's Workflow

This is the path from "I want to win federal work" to "here's exactly who to
target, why, and when":

```
  Step 1   What's growing?
  ──────   naics.growth_leaders → Find NAICS markets with rising demand

  Step 2   Who's buying it?
  ──────   naics.agency_profile_fy → Match growing markets to agencies

  Step 3   Can I get in?
  ──────   market.entry_difficulty_score → One number: how hard is entry?
           competition.agency_profile_fy → Competed vs. sole-source split

  Step 4   Who's already there?
  ──────   concentration.vendor_market_leaders → Incumbent map with HHI
           entrants.agency_cohort_fy → How do new vendors fare here?

  Step 5   How do they buy?
  ──────   pricing.agency_profile_fy → Fixed-price vs. cost-type mix
           acquisition.agency_vehicle_mix_fy → GWAC / Schedule / IDIQ

  Step 6   What's expiring?
  ──────   pipeline.recompete_watchlist → Contracts ending in 6–24 months
           pipeline.duration_profile → Typical contract lengths

  Step 7   When do they spend?
  ──────   seasonality.agency_month_fy → Fiscal-month obligation patterns
           → Q4 spike? Time your white papers accordingly

  Step 8   Where's the work?
  ──────   geography.city_leaders → Sub-state drill-down
           geography.mismatch_leaders → Vendor HQ vs. performance site

  Step 9   One-call summary
  ──────   GET /v1/profiles/customer → Full Customer 360 in one request
```

> **The goal:** Who should we target, why them, how hard will entry be, what's
> expiring soon, and what customer-specific story should we tell in the
> proposal?

---

## 🎮 Use It Without Code

### With Any AI Assistant (No MCP Required)

Paste this into ChatGPT, Claude, Gemini, or any AI that can make HTTP requests:

```text
Use the FPDS Analytics API to help me understand federal procurement customers.
API base: https://analytics-api.kenosaconsulting.com

Start by calling GET /v1/ai-assistant-guide for instructions.
Then GET /v1/catalog to see available datasets.
Use only documented filters, sorts, and fields.
Explain what the data means for capture strategy.
Always include API caveats and never invent data.
```

### With CSV Export

Any dataset query supports `?format=csv` for direct spreadsheet use:

```bash
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/naics.growth_leaders/rows?limit=50&format=csv" > growth_leaders.csv
```

### With the REST API Directly

Every endpoint is documented with example queries in the catalog:

```bash
# Describe a dataset (see fields, filters, example queries, caveats)
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/competition.sole_source_hotspots" | jq

# Query with filters and sorting
curl -s "https://analytics-api.kenosaconsulting.com/v1/datasets/pricing.agency_profile_fy/rows?contracting_dept_id=9700&fiscal_year=2025&sort=-total_obligated&limit=25" | jq '.data'

# Look up a NAICS code by name
curl -s "https://analytics-api.kenosaconsulting.com/v1/dimensions/naics?q=cybersecurity" | jq '.data'

# Full customer profile in one call
curl -s "https://analytics-api.kenosaconsulting.com/v1/profiles/customer?contracting_dept_id=9700" | jq
```

---

## 📊 Sample Response

```json
{
  "notice": "FPDS analytics are decision-support indicators, not a complete procurement universe.",
  "data": [
    {
      "contracting_dept_id": "9700",
      "contracting_dept_name": "DEPT OF DEFENSE",
      "department_short_name": "DoD",
      "fiscal_year": 2025,
      "is_current_fiscal_year_ytd": true,
      "total_obligated": "125000000.00",
      "distinct_naics_count": 12,
      "top_naics_code_by_obligation": "541330",
      "action_count": 42
    }
  ],
  "pagination": { "limit": 25, "next_cursor": null },
  "meta": {
    "dataset_id": "naics.trend_fy",
    "source": "FPDS analytics schema",
    "data_as_of": "2026-06-10T00:00:00Z",
    "row_count": 1,
    "access": "public"
  }
}
```

Every response includes:
- **`notice`** — Reminds consumers this is analytical, not legal/procurement authority
- **`data`** — Human-readable labels alongside codes (no more guessing what `9700` means)
- **`meta.data_as_of`** — When the underlying data was last refreshed
- **`pagination`** — Bounded results with cursor support

---

## 📡 API Reference

| Function | Endpoint | Purpose |
|---|---|---|
| Service metadata | `GET /v1` | API version and status |
| Health check | `GET /v1/health` | Service and catalog health |
| AI assistant guide | `GET /v1/ai-assistant-guide` | Paste-ready instructions for any AI |
| List datasets | `GET /v1/catalog` | Browse all 58 analytics datasets |
| Describe dataset | `GET /v1/datasets/{id}` | Fields, filters, sorts, caveats, examples |
| Query rows | `GET /v1/datasets/{id}/rows` | Bounded analytics with filters and pagination |
| Customer 360 | `GET /v1/profiles/customer` | Eight-section customer intelligence profile |
| List dimensions | `GET /v1/dimensions` | Browse code-lookup tables |
| Query dimension | `GET /v1/dimensions/{id}` | Translate codes to names |
| Resolve by name | `GET /v1/dimensions/{id}?q=` | Search dimensions by name substring |

**Self-healing errors:** Send a bad filter? The error response tells you
exactly which filters are valid, which fields are sortable, and gives you an
example query that works. No more guessing.

---

## 🏗️ Architecture

```
  ┌─────────────────────┐      ┌──────────────────┐      ┌───────────────┐
  │  public.fpds_actions │      │  26 SQL templates │      │  Materialized │
  │  (99M+ rows)        │─────▶│  in sql/          │─────▶│  Views + MVs  │
  │  Read-only source   │      │  Run at refresh   │      │  (analytics)  │
  └─────────────────────┘      └──────────────────┘      └───────┬───────┘
                                                                  │
                                                                  ▼
  ┌─────────────────────┐      ┌──────────────────┐      ┌───────────────┐
  │  MCP Server         │      │  FastAPI app/     │      │ analytics_api │
  │  (7 tools, stdio)   │◀────▶│  Catalog-driven   │◀────▶│ facade schema │
  │  For AI assistants  │      │  REST endpoints   │      │ (read-only)   │
  └─────────────────────┘      └──────────────────┘      └───────────────┘
```

**Security boundary:** The API server connects as `fpds_analytics_api_readonly`
with `SELECT`-only access to the `analytics_api` facade schema. No raw tables,
no writes, no arbitrary SQL. Dataset IDs, filter names, sort keys, and row
limits are all validated against the catalog before any query is built.

---

## 📚 Documentation

| Document | What's in it |
|---|---|
| [CHANGELOG.md](CHANGELOG.md) | What changed and when — sprint by sprint |
| [docs/QUICKSTART.md](docs/QUICKSTART.md) | Your first API calls in 2 minutes |
| [docs/METHODOLOGY.md](docs/METHODOLOGY.md) | How every number is computed — source data, MVs, formulas |
| [docs/DATASETS.md](docs/DATASETS.md) | Field-by-field reference for all 67 datasets |
| [docs/API_FUNCTIONS.md](docs/API_FUNCTIONS.md) | Detailed endpoint documentation |
| [docs/AI_ASSISTANT_GUIDE.md](docs/AI_ASSISTANT_GUIDE.md) | Instructions for AI assistants |
| [docs/LLM_INTEGRATIONS.md](docs/LLM_INTEGRATIONS.md) | MCP, ChatGPT, Claude, and Gemini integration guide |
| [docs/CAVEATS.md](docs/CAVEATS.md) | Data limitations you should know about |
| [openapi.yaml](openapi.yaml) | Machine-readable API contract (OpenAPI 3.1) |
| [SECURITY.md](SECURITY.md) | Security model and responsible disclosure |

---

## 🛠️ Developer Setup

```bash
git clone https://github.com/KenosaConsulting/fpds-os-analytics.git
cd fpds-os-analytics
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest tests -q   # 67 tests, should be green
```

The test suite validates catalog contracts, query guardrails, and API behavior
without a database connection. To run the API server against live data, see the
[deployment docs](docs/DEPLOYMENT.md).

---

## 📦 Repository Layout

```
fpds-os-analytics/
├── app/              FastAPI service (routes, query builder, catalog loader)
├── catalog/          Dataset + dimension registries (single source of truth)
│   ├── datasets.yaml     67 datasets with filters, sorts, fields, caveats
│   └── dimensions.yaml   16 code-lookup dimensions
├── mcp/              MCP server for AI assistants (7 tools, stdio transport)
├── sql/              26 numbered database templates (MVs, views, indexes)
├── tests/            Guardrail + contract tests (67 tests)
├── docs/             User and developer documentation
├── examples/         Example API calls
├── openapi.yaml      OpenAPI 3.1 specification
├── Dockerfile        Container image
└── run-local.sh      Local development launcher
```

---

## ⚖️ Access & Licensing

**Open source, MIT licensed.** Use it, fork it, build on it.

Discovery endpoints are public — browse the catalog, read dataset
documentation, look up dimension codes, and query bounded row samples without
an API key. Key-authenticated access provides higher rate limits and larger
result sets.

The API does not expose arbitrary SQL, raw source tables, bulk database dumps,
or write operations. It never will.

---

## ⚠️ Caveats

This is an analytical tool, not a procurement authority.

- **FPDS obligations include deobligations and corrections** — dollar values can
  be negative for individual transactions
- **Current fiscal year data is year-to-date** — flagged with
  `is_current_fiscal_year_ytd` so you know
- **Vendor records exclude entries missing key fields** — coverage is high but
  not 100%
- **Q4 obligation share is NULL for deobligation-heavy entities** — when an
  entity's full-year obligations are zero or negative, the ratio is undefined
- **This is decision support, not legal advice** — always verify against primary
  sources for formal procurement actions

Full details: [docs/CAVEATS.md](docs/CAVEATS.md)

---

Got down here and still couldn't find what you need? No worries! Don't hesitate to reach out with your ideas and we'll build it for you.

Phone: (305) 522-8140 | Email: nkalosakenyon@kenosaconsulting.com | Linkedin: https://www.linkedin.com/in/nate-kalosa-kenyon-84b132190/

<p align="center">
  Built by <a href="https://kenosaconsulting.com">Kenosa Consulting</a><br/>
  <em>Evidence-first federal intelligence.</em>
</p>
