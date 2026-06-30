# FPDS Open-Source Analytics API

```
  ███████ ██████  ██████  ███████
  ██      ██   ██ ██   ██ ██          Federal Procurement
  █████   ██████  ██   ██ ███████     Data Science
  ██      ██      ██   ██      ██     Analytics API
  ██      ██      ██████  ███████
                    
```

| | |
|---|---|
| **Datasets** | 88 analytics datasets across 17 domains |
| **Dimensions** | 17 code-lookup tables (agencies, NAICS, PSC, departments, states, vehicle programs, etc.) |
| **Source data** | 99M+ FPDS contract actions (98.7M rows in `public.fpds_actions`) |
| **Interfaces** | REST API · MCP server (9 tools) · CSV export |
| **License** | MIT — open source, fork it, build on it |
| **Hosted endpoint** | `https://analytics-api.kenosaconsulting.com` |
| **Repo** | `https://github.com/KenosaConsulting/fpds-os-analytics` |

> The federal government spends $700+ billion a year on contracts. Every
> transaction is public record. Contractors don't need raw data — they need
> to make decisions.

This API turns 99 million FPDS contract actions into the intelligence that
wins proposals — pricing patterns, incumbent maps, market entry difficulty
scores, vehicle-program winners, recompete timelines, procurement officer
profiles, and 80+ more analytics datasets — ready to query from a single
endpoint.

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
US government makes — 99 million rows of coded, transaction-level records.
Useful raw material, but it tells you almost nothing about strategy until
someone aggregates it, labels it, and frames it around the questions capture
teams actually ask.

Most contractors solve this by paying five- or six-figure subscriptions to
platforms that repackage the same public data behind login walls. Or they
assign a human analyst to spend weeks in spreadsheets. Or they guess.

**This is a different approach.** We use OLAP to pre-compute the synthesis
that actually matters for contractors, government and procurement analysts — and serve the answers as clean,
filterable, documented datasets with human-readable labels, metadata, caveats,
and enough context for an analyst (human or AI) to draw conclusions without
touching raw data.

> 📖 FPDS is the Atlas. This API is GPS.

---

## 🧬 Intelligence Packages

88 datasets are organized into 17 domains. The major packages and the strategic
questions they answer:

| Package | Datasets | Question it answers |
|---|---|---|
| **Pricing Strategy** | 5 | How does this customer prefer to buy? |
| **Vendor Concentration** | 7 | Who already owns this market? |
| **Competition Dynamics** | 6 | Can a new vendor actually get in? |
| **Industry / NAICS Demand** | 4 | What work is growing — and where? |
| **Geography** | 8 | Does local presence matter here? |
| **Set-Aside Programs** | 6 | Which small-biz programs get used? |
| **PSC Classification** | 6 | What exactly do they buy? |
| **Vehicle Mix** | 6 | Do I need a GWAC, Schedule, or IDIQ? |
| **Funding Flows** | 2 | Who funds the work vs. who buys it? |
| **Recompete Pipeline** | 5 | What contracts are expiring soon? |
| **Contracting Officers** | 6 | Who handles the buying — and how? |
| **Fiscal Seasonality** | 2 | When does this customer spend? |
| **Topic Intelligence** | 11 | What sub-markets exist within a NAICS? |
| **Customer Profiles** | 5 | What's this customer's full buying pattern? |
| **Market Analysis** | 5 | Who are the customers for a given NAICS? |
| **Incumbent Tracking** | 3 | Which vendors hold which positions? |
| **New Entrants** | 1 | How do new vendors fare in this market? |

### Differentiators

**Contracting Officers package** — No competing platform maps individual
procurement personnel to their buying behavior, NAICS specialties, set-aside
tendencies, and contract history. Six datasets cover office rosters, per-CO
year-over-year profiles, NAICS buyer maps, recompete contract handlers, and
human-attribution coverage per office. The enhanced Recompete Pipeline shows
who created and approved each expiring contract.

**Topic Intelligence package** — The first machine-derived procurement topic
layer across the federal government. BERTopic decomposes broad NAICS codes
into the actual sub-markets agencies buy. 11 datasets cover topic catalogs,
NAICS/PSC decomposition, set-aside and contract-type profiles, YoY trends,
competitive landscape (all vendors, no cap), document links to strategic
plans, and 4,969 govwide canonical topics clustered across 30 departments.

**Customer 360 endpoint** — One call (`GET /v1/profiles/customer`) returns
a full eight-section customer intelligence profile: spend trends, competition
posture, incumbent map, pricing mix, vehicle preferences, recompete signals,
seasonality, and topic highlights.

**Market Entry Difficulty Score** — A composite blending HHI concentration,
sole-source share, vehicle dependence, average offers received, and incumbent
tenure — one number that says "how hard is this market to crack."

---

## 🤖 Wire It Into Your AI — MCP Integration

The API ships with a built-in **Model Context Protocol (MCP) server** — which
means Claude, Cursor, Windsurf, VS Code Copilot, OpenClaw, and any MCP-compatible AI
assistant can query federal procurement data directly, without you writing a
single line of code.

**Why this matters:** Instead of copy-pasting API responses into chat windows,
your AI assistant becomes a procurement analyst. It can browse the catalog,
pick the right dataset, apply filters, interpret caveats, and explain what the
data means for your capture strategy — all in natural language.

### Two Ways to Connect

**Option A — Remote MCP (zero install):**

Point your AI client at the hosted endpoint. No Python, no repo clone.

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "url": "https://analytics-api.kenosaconsulting.com/v1/mcp",
      "transport": "streamable-http"
    }
  }
}
```

**Claude.ai / Claude Desktop (OAuth flow):**

When you add this as a custom connector in Claude, the OAuth flow starts
automatically. You'll be redirected to a page where you enter your FPDS API
key. If you don't have one, the authorization page links to the free
self-service signup. Once authorized, Claude receives a Bearer token and all
API-key-gated datasets (recompete watchlist, customer profiles, etc.) are
unlocked automatically.

**Claude Desktop alternative** (if native streamable-http not supported):

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "npx",
      "args": ["mcp-remote", "https://analytics-api.kenosaconsulting.com/v1/mcp"]
    }
  }
}
```

**Option B — Local stdio (pip install):**

```bash
pip install fpds-os-analytics-mcp
```

```json
{
  "mcpServers": {
    "fpds-analytics": {
      "command": "fpds-mcp",
      "env": {
        "FPDS_API_BASE_URL": "https://analytics-api.kenosaconsulting.com"
      }
    }
  }
}
```

**No API key required** for bounded public queries. Add an `X-Api-Key` header
for higher rate limits and larger result sets. Get a key at
[kenosaconsulting.com/api](https://kenosaconsulting.com/api).

For full setup instructions including OpenClaw, Claude Desktop, Cursor, and
VS Code configurations, see **[docs/OPENCLAW_INTEGRATION.md](docs/OPENCLAW_INTEGRATION.md)**.

### MCP Tools (9 available)

| Tool | What it does |
|---|---|
| `fpds_list_datasets` | Browse all 88 analytics datasets with descriptions |
| `fpds_describe_dataset` | See fields, filters, sorts, caveats, and example queries for any dataset |
| `fpds_query_dataset` | Query rows with filters, sorting, and pagination |
| `fpds_list_dimensions` | Browse 17 code-lookup tables (agencies, NAICS, PSC, etc.) |
| `fpds_lookup_dimension` | Translate coded values to human-readable names |
| `fpds_resolve` | Search by name across agencies, offices, NAICS, PSC, departments, and vehicle programs |
| `fpds_customer_profile` | Get a full Customer 360 profile — eight analytical sections in one call |
| `fpds_topic_search` | Search procurement topics by keyword |
| `fpds_contract_history` | Look up contract history by PIID or UEI |

**Try asking your AI:**

> "Who are the top 5 incumbent vendors for Army cybersecurity contracts?"
>
> "Show me NAICS codes that are growing fastest at the Department of Energy."
>
> "What contracts at HHS are expiring in the next 6 months and worth over $10M?"
>
> "Give me a competitive analysis for entering the Navy's IT services market."

The AI will pick the right dataset, apply filters, and interpret the results —
including caveats about data limitations, current fiscal year incompleteness,
and deobligation effects.

### Pre-built Skills

The repo includes 5 ready-to-use skills for common govcon activities:

| Skill | Activity |
|---|---|
| [`vendor-market-analysis`](skills/vendor-market-analysis/SKILL.md) | Competitive landscape analysis |
| [`recompete-pipeline`](skills/recompete-pipeline/SKILL.md) | Expiring contract watchlist |
| [`contracting-officer-patterns`](skills/contracting-officer-patterns/SKILL.md) | Office buying patterns + contacts |
| [`account-plan-builder`](skills/account-plan-builder/SKILL.md) | Structured account plan |
| [`naics-opportunity-scan`](skills/naics-opportunity-scan/SKILL.md) | Growth opportunities by NAICS |

See [`skills/README.md`](skills/README.md) for the full catalog.

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

  Step 9   What exactly do they buy — beyond NAICS?
  ──────   topics.naics_decomposition → Sub-markets within a NAICS code
           topics.competitive_landscape → Who dominates each sub-market?
           topics.trends → Which sub-markets are growing/declining?

  Step 10  One-call summary
  ──────   GET /v1/profiles/customer → Full Customer 360 in one request
```

> **The goal:** Who should we target, why them, how hard will entry be, what's
> expiring soon, what sub-markets are growing, and what customer-specific
> story should we tell in the proposal?

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
| List datasets | `GET /v1/catalog` | Browse all 88 analytics datasets |
| Describe dataset | `GET /v1/datasets/{id}` | Fields, filters, sorts, caveats, examples |
| Query rows | `GET /v1/datasets/{id}/rows` | Bounded analytics with filters and pagination |
| Customer 360 | `GET /v1/profiles/customer` | Eight-section customer intelligence profile |
| List dimensions | `GET /v1/dimensions` | Browse 17 code-lookup tables |
| Query dimension | `GET /v1/dimensions/{id}` | Translate codes to names |
| Resolve by name | `GET /v1/dimensions/{id}?q=` | Search dimensions by name substring |
| MCP endpoint | `GET /v1/mcp` | Streamable-HTTP MCP server for AI assistants |

**Self-healing errors:** Send a bad filter? The error response tells you
exactly which filters are valid, which fields are sortable, and gives you an
example query that works. No more guessing.

---

## 🏗️ Architecture

```
  ┌──────────────────────┐      ┌───────────────────┐      ┌────────────────┐
  │ public.fpds_actions   │      │  74 SQL templates │      │ Materialized   │
  │ (99M+ rows)           │─────▶│  in sql/          │─────▶│ Views + MVs    │
  │ Read-only source      │      │  Run at refresh   │      │ (analytics)    │
  └──────────────────────┘      └───────────────────┘      └───────┬────────┘
                                                                   │
                                                                   ▼
  ┌──────────────────────┐      ┌───────────────────┐      ┌────────────────┐
  │ MCP Server            │      │ FastAPI app/       │      │ analytics_api  │
  │ (9 tools, stdio+HTTP) │◀────▶│ Catalog-driven     │◀────▶│ facade schema  │
  │ For AI assistants     │      │ REST endpoints     │      │ (read-only)    │
  └──────────────────────┘      └───────────────────┘      └────────────────┘
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
| [docs/DATASETS.md](docs/DATASETS.md) | Field-by-field reference for all 88 datasets |
| [docs/API_FUNCTIONS.md](docs/API_FUNCTIONS.md) | Detailed endpoint documentation |
| [docs/AI_ASSISTANT_GUIDE.md](docs/AI_ASSISTANT_GUIDE.md) | Instructions for AI assistants |
| [docs/OPENCLAW_INTEGRATION.md](docs/OPENCLAW_INTEGRATION.md) | OpenClaw + MCP setup guide (remote endpoint + pip install) |
| [docs/LLM_INTEGRATIONS.md](docs/LLM_INTEGRATIONS.md) | MCP, ChatGPT, Claude, and Gemini integration guide |
| [docs/CAVEATS.md](docs/CAVEATS.md) | Data limitations you should know about |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Self-deployment guide |
| [docs/DRILL-DOWN-GAPS.md](docs/DRILL-DOWN-GAPS.md) | Known gaps in drill-down coverage |
| [openapi.yaml](openapi.yaml) | Machine-readable API contract (OpenAPI 3.1) |
| [SECURITY.md](SECURITY.md) | Security model and responsible disclosure |

---

## 🛠️ Developer Setup

```bash
git clone https://github.com/KenosaConsulting/fpds-os-analytics.git
cd fpds-os-analytics
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python -m pytest tests -q   # 88 tests, should be green
```

The test suite validates catalog contracts, query guardrails, and API behavior
without a database connection. To run the API server against live data, see
[docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

---

## 📦 Repository Layout

```
fpds-os-analytics/
├── app/              FastAPI service (routes, query builder, catalog loader)
├── catalog/          Dataset + dimension registries (single source of truth)
│   ├── datasets.yaml     88 datasets with filters, sorts, fields, caveats
│   └── dimensions.yaml   17 code-lookup dimensions
├── mcp/              MCP server for AI assistants (9 tools, stdio + HTTP transport)
├── sql/              74 numbered database templates (MVs, views, indexes)
├── tests/            Guardrail + contract tests (88 tests)
├── docs/             User and developer documentation
├── examples/         Example API calls
├── skills/           5 pre-built MCP skills for common govcon activities
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

## 📞 Contact

Got down here and still couldn't find what you need? Don't hesitate to reach
out with your ideas and we'll build it for you.

- **Phone:** (305) 522-8140
- **Email:** nkalosakenyon@kenosaconsulting.com
- **LinkedIn:** https://www.linkedin.com/in/nate-kalosa-kenyon-84b132190/

<p align="center">
  Built by <a href="https://kenosaconsulting.com">Kenosa Consulting</a><br/>
  <em>Evidence-first federal intelligence.</em>
</p>
