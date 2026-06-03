# AI Assistant Guide

This guide is for users who want to use the FPDS Analytics API through ChatGPT, Claude, Gemini, or another AI assistant.

The goal is simple: let the assistant help you choose the right procurement analytics dataset, query it safely, and explain what the result means for customer targeting.

## What To Paste Into Your Assistant

This prompt only works after `https://analytics-api.kenosaconsulting.com` is hosted and reachable.

```text
Use the FPDS Analytics API to help me understand federal procurement customers.
Start here: https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide

First inspect the catalog, then choose the right dataset for my question.
Use only documented filters, sorts, and fields.
Do not ask me for an API key for normal first-use analysis; public bounded row queries are allowed.
Explain what the data means for customer targeting, market entry, teaming, or capture strategy.
Include caveats and notices from the API response and do not invent data.
Do not ask for arbitrary SQL or raw database access.
```

Do not paste placeholder domains into an assistant. The prompt must include the real hosted API URL.

## What The API Helps You Understand

Use the API when you want to answer questions like:

- Which agencies buy the kind of work I sell?
- Is this customer open to new vendors or dominated by incumbents?
- Does this agency rely on sole-source awards?
- How does this customer prefer to buy: fixed price, cost type, T&M, performance-based, or multi-year?
- Which NAICS sectors are growing?
- Where is contract work performed?
- Who should I target, why, and how hard will it be to enter?

## How The Assistant Should Use The API

The assistant should follow this sequence:

1. Read `GET /v1/ai-assistant-guide`.
2. Read `GET /v1/catalog` to see available analytics datasets.
3. Pick the dataset that best matches the user's question.
4. Read `GET /v1/datasets/{dataset_id}` to understand fields, filters, sorts, and caveats.
5. Query `GET /v1/datasets/{dataset_id}/rows` with `limit=25` and relevant filters.
6. Explain the result in plain English.
7. Include caveats and notices from the API response.

The assistant should not use arbitrary SQL, raw tables, admin endpoints, or undocumented parameters.

The assistant should not treat department code `9700` as the full universe of all DoD, Army, or military-base opportunity. DoD-related work can appear outside `9700` through other contracting departments, funding departments, interagency vehicles, or government-wide acquisition channels.

The assistant should not treat military postal codes or place-of-performance fields as a complete measure of overseas work. OCONUS work can be coded to military postal codes, foreign locations, CONUS district offices, vendor/admin locations, or other reporting conventions.

## Common Starting Points

| User goal | Start with dataset |
|---|---|
| Understand a customer's buying style | `pricing.agency_profile_fy` |
| Compare fixed-price, cost-type, and T&M buying patterns | `pricing.trend_fy` |
| Find sole-source-heavy customers | `competition.sole_source_hotspots` |
| Check whether a market is competitive or closed | `competition.agency_profile_fy` |
| Identify dominant vendors or incumbents | `concentration.vendor_market_leaders` |
| Understand small-business health | `concentration.small_biz_health_fy` |
| Find growing industries | `naics.growth_leaders` |
| Find departments buying a NAICS sector | `naics.agency_profile_fy` |
| See where work happens | `geography.state_trend_fy` |
| Compare local vs out-of-state work patterns | `geography.mismatch_leaders` |

## If The Assistant Can Call APIs

Give it the API base URL. An API key is not needed for normal bounded row queries.

These endpoints do not require a key:

```text
GET https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide
GET https://analytics-api.kenosaconsulting.com/v1/catalog
GET https://analytics-api.kenosaconsulting.com/v1/datasets/competition.sole_source_hotspots
GET https://analytics-api.kenosaconsulting.com/v1/dimensions
GET https://analytics-api.kenosaconsulting.com/v1/datasets/competition.sole_source_hotspots/rows?limit=25
```

API keys are optional and reserved for paid, partner, or higher-volume access:

```text
GET https://analytics-api.kenosaconsulting.com/v1/datasets/competition.sole_source_hotspots/rows?limit=25
Header: X-Api-Key: YOUR_API_KEY
```

## If The Assistant Cannot Call APIs

Use this manual flow:

1. Open `https://analytics-api.kenosaconsulting.com/v1/catalog`.
2. Paste the catalog response into the assistant.
3. Ask: "Which dataset should I use for my question?"
4. Open the dataset detail URL the assistant recommends.
5. Paste that response into the assistant.
6. Ask it to build the row query URL.
7. Run the row query.
8. Paste the result back into the assistant for interpretation.

## Good User Prompts

```text
I sell cybersecurity services. Which agencies should I research first, and which datasets should we query?
```

```text
Help me understand whether Department X is open to new vendors or dominated by incumbents.
```

```text
Find customers where NAICS sector 54 demand is growing and competition looks weak.
```

```text
I want to approach an agency with a fixed-price services offer. Which pricing and competition datasets should we use?
```

## How The Assistant Should Explain Results

The assistant should translate returned rows into practical analysis:

- Target: which agency, department, NAICS, vendor, or geography matters.
- Evidence: which fields support the conclusion.
- Interpretation: what the pattern suggests for market entry or capture strategy.
- Caveats: what the data cannot prove.
- Notices: data completeness, coding, and place-of-performance limitations returned by the API.
- Next query: what to inspect next.

Example interpretation format:

```text
What the data says:
...

Why it matters:
...

How to approach the customer:
...

Caveats:
...

Notices:
...

Next useful query:
...
```
