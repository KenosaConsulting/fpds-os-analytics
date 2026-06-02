# FPDS Analytics API Functions

This guide explains what each API function is for, what question it answers, and how a non-technical analyst can use it to plan a better customer approach.

The API is organized into five analysis packages:

1. Pricing strategy
2. Vendor concentration
3. Competition dynamics
4. Industry / NAICS demand
5. Geography and place-of-performance flows

Every package is queried the same way:

```http
GET /v1/datasets/{dataset_id}/rows
```

Example:

```http
GET /v1/datasets/competition.sole_source_hotspots/rows?limit=25
```

The value is not that users can run SQL. The value is that they can quickly answer questions like:

- Which agencies are buying in ways that create risk?
- Where is competition weak?
- Which markets are dominated by incumbents?
- Which industries are growing?
- Where does work physically happen?
- How should I frame a capture or customer conversation?

---

## Core API Functions

| Function | Endpoint | Who uses it | What it does |
|---|---|---|---|
| Discover available analytics | `GET /v1/catalog` | Everyone | Lists all available datasets, grouped by analysis package |
| Understand one dataset | `GET /v1/datasets/{dataset_id}` | Analysts, developers | Shows fields, filters, sort options, caveats, and grain |
| Query analytics rows | `GET /v1/datasets/{dataset_id}/rows` | Analysts, tools, dashboards | Returns filtered analytics rows from a curated public view |
| Look up codes | `GET /v1/dimensions/{dimension_id}` | Analysts, developers | Explains FPDS codes such as pricing, competition, NAICS, and states |
| Check service health | `GET /v1/health` | Developers | Confirms the API is alive and shows catalog counts |
| Export bounded data | `POST /v1/exports` | Analysts | Planned phase-2 function for CSV/JSON exports |

The row endpoint accepts only approved filters and sort fields. Unsupported filters are rejected so users know when they are asking for something the dataset does not support.

---

## Package 1: Pricing Strategy

Pricing analytics explain **how an agency buys**.

Use this package when you want to know whether an agency prefers fixed-price contracts, cost-reimbursement contracts, time-and-materials, performance-based contracting, or multi-year arrangements.

Why this matters for customer approach:

- A fixed-price-heavy customer may care most about clear scope, price discipline, and execution confidence.
- A cost-type or T&M-heavy customer may be managing uncertainty, R&D, integration complexity, or mission volatility.
- A department with high pricing-risk exposure may be receptive to approaches that reduce cost growth, improve requirements clarity, or move work toward lower-risk structures.

| Dataset | What it answers | Best use |
|---|---|---|
| `pricing.trend_fy` | How has federal pricing mix changed over time? | Understand government-wide pricing direction |
| `pricing.agency_profile_fy` | How does each department buy in each fiscal year? | Build a department-level pricing profile |
| `pricing.kpi_summary` | What are the top pricing KPIs for all years, current FY, and recent 3 years? | Executive summary |
| `pricing.risk_scorecard` | Which departments have the highest cost-type plus T&M exposure? | Identify pricing-risk hotspots |
| `pricing.dept_year_summary` | What is the department-by-year pricing breakdown? | Build charts or dashboards |

Example questions:

- Which departments are most exposed to cost-type and T&M buying?
- Is a customer moving toward fixed price or away from it?
- Does this customer buy in a way that rewards mature, low-risk delivery?

Example query:

```http
GET /v1/datasets/pricing.risk_scorecard/rows?limit=25
```

---

## Package 2: Vendor Concentration

Vendor concentration analytics explain **who controls a market**.

Use this package when you want to know whether a market is competitive, moderately concentrated, or dominated by a small number of vendors.

Why this matters for customer approach:

- Highly concentrated markets usually require an incumbent-displacement strategy, teaming strategy, or niche wedge.
- Competitive markets may reward price, past performance, or differentiated capabilities.
- Small-business health metrics help identify whether an agency has room or pressure to diversify suppliers.

| Dataset | What it answers | Best use |
|---|---|---|
| `concentration.trend_fy` | Are markets becoming more or less concentrated over time? | Market structure trend analysis |
| `concentration.agency_profile` | Which agencies have the most concentrated markets? | Agency-level market profile |
| `concentration.vendor_market_leaders` | Which vendors lead by lifetime obligation? | Identify major incumbents |
| `concentration.small_biz_health_fy` | How much work flows to small businesses? | Small-business strategy |
| `concentration.kpi_summary` | What are the top concentration KPIs? | Executive summary |

Example questions:

- Is this agency dependent on a few vendors?
- Who are the likely incumbents?
- Is there evidence of small-business participation or new entrants?
- Should I compete directly, team, or target an underserved segment?

Example query:

```http
GET /v1/datasets/concentration.vendor_market_leaders/rows?limit=50
```

---

## Package 3: Competition Dynamics

Competition analytics explain **how open or closed the buying environment is**.

Use this package when you want to understand competed vs. non-competed obligations, sole-source hotspots, bundled requirements, consolidated requirements, and average offers received.

Why this matters for customer approach:

- Low competition can mean strong incumbency, urgent mission demand, limited qualified suppliers, or acquisition constraints.
- High bundling or consolidation can signal barriers for small and mid-sized firms.
- Average offers received helps estimate how crowded the market is.

| Dataset | What it answers | Best use |
|---|---|---|
| `competition.trend_fy` | How has competition changed over time? | Government-wide competition trend |
| `competition.agency_profile_fy` | How competitive is each department by fiscal year? | Customer competition profile |
| `competition.kpi_summary` | What are the top competition KPIs? | Executive summary |
| `competition.sole_source_hotspots` | Which departments have high non-competed spending? | Identify sole-source-heavy customers |

Example questions:

- Is this customer open to new entrants?
- Are awards usually competed or sole-sourced?
- Is bundling making the customer harder to access?
- Should I lead, subcontract, or build a teaming strategy?

Example query:

```http
GET /v1/datasets/competition.sole_source_hotspots/rows?limit=25
```

---

## Package 4: Industry / NAICS Demand

NAICS analytics explain **what the government buys** by industry.

Use this package when you want to understand sector demand, agency industry portfolios, growth leaders, and industry concentration inside a department.

Why this matters for customer approach:

- A growing NAICS can show where demand is expanding.
- A department with a narrow NAICS profile may have a focused mission or entrenched buying pattern.
- A department with broad NAICS diversity may support multiple entry points.

| Dataset | What it answers | Best use |
|---|---|---|
| `naics.trend_fy` | Which sectors get the most obligations by fiscal year? | Industry demand trend |
| `naics.agency_profile_fy` | What industries does each department buy in? | Customer industry profile |
| `naics.growth_leaders` | Which NAICS codes are growing fastest year over year? | Market opportunity discovery |
| `naics.kpi_summary` | What are the top NAICS diversity KPIs? | Executive summary |

Example questions:

- Which agencies are buying my type of work?
- Is my target industry growing or shrinking?
- Which departments have diverse buying portfolios?
- Where should I focus business development first?

Example query:

```http
GET /v1/datasets/naics.trend_fy/rows?sector_code=54&fiscal_year_min=2022
```

---

## Package 5: Geography And Place Of Performance

Geography analytics explain **where the money flows and where work happens**.

Use this package when you want to understand state-level obligations, regional spending, domestic vs. international work, and vendor-state to performance-state flows.

Why this matters for customer approach:

- State and region trends can identify where agencies are actually performing work.
- Vendor-state mismatch can show whether work is performed locally or exported to out-of-state vendors.
- In-state vs. out-of-state shares can help shape local presence, teaming, and hiring strategy.

| Dataset | What it answers | Best use |
|---|---|---|
| `geography.state_trend_fy` | How much work happens in each state over time? | State-level market analysis |
| `geography.regional_summary_fy` | How does spending break down by Census region? | Regional planning |
| `geography.mismatch_leaders` | Which vendor states perform work in which performance states? | Local vs. out-of-state flow analysis |
| `geography.kpi_summary` | What are the top domestic/in-state KPIs? | Executive summary |

Example questions:

- Where does this agency's work physically happen?
- Are local vendors winning local work?
- Which states export contract work to other states?
- Should I emphasize local presence or national delivery capacity?

Example query:

```http
GET /v1/datasets/geography.state_trend_fy/rows?pop_state_code=VA&fiscal_year_min=2020
```

---

## Dimension Lookups

Dimension endpoints explain codes that appear in FPDS records.

| Dimension | What it explains |
|---|---|
| `pricing_codes` | Contract pricing codes and risk families |
| `competition_codes` | Extent-competed codes and competition families |
| `business_size_codes` | Contracting officer business-size determinations |
| `bundling_codes` | Bundling severity codes |
| `financing_codes` | Contract financing codes |
| `naics` | Observed NAICS hierarchy |
| `states` | State, territory, military postal, and placeholder codes |

Example:

```http
GET /v1/dimensions/pricing_codes
```

---

## Recommended Analyst Workflow

A practical analyst workflow looks like this:

1. Start with `naics.trend_fy` to confirm where demand is growing.
2. Use `naics.agency_profile_fy` to find departments that buy that type of work.
3. Use `competition.agency_profile_fy` to see whether those departments are accessible to new competitors.
4. Use `concentration.vendor_market_leaders` and `concentration.agency_profile` to understand incumbent strength.
5. Use `pricing.agency_profile_fy` to adjust the pitch to the customer's buying style.
6. Use `geography.state_trend_fy` if local presence, place of performance, or regional strategy matters.

The output should help answer:

> Who should we target, why should we target them, how hard will entry be, and what customer-specific story should we tell?

---

## Caveats

- The API reports analytics derived from FPDS contract actions. It is not legal, procurement, or investment advice.
- FPDS includes de-obligations and corrections, so some amounts can be negative.
- Vendor concentration datasets exclude records missing UEI, agency, or signed date.
- Fiscal years use the federal October-September convention.
- The API is designed for analysis and planning, not for replacing source-record due diligence.
