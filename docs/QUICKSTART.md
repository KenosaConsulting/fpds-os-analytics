# Quickstart

This guide shows the first API calls a user should make.

## Use An AI Assistant First

If you want ChatGPT, Claude, Gemini, or another assistant to guide the analysis, paste this into the assistant after the hosted API is live:

```text
Use the FPDS Analytics API to help me understand federal procurement customers.
Start here: https://analytics-api.kenosaconsulting.com/v1/ai-assistant-guide

First inspect the catalog, then choose the right dataset for my question.
Use only documented filters, sorts, and fields.
Explain what the data means for customer targeting, market entry, teaming, or capture strategy.
Include the API response notice, caveats, and notices, and do not invent data.
```

Then ask your business question in normal language.

## 1. See What The API Offers

```bash
export FPDS_ANALYTICS_API_BASE_URL="https://analytics-api.kenosaconsulting.com"
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/catalog" | jq '.data[].id'
```

This returns dataset IDs such as:

```text
pricing.risk_scorecard
competition.sole_source_hotspots
concentration.vendor_market_leaders
naics.growth_leaders
geography.state_trend_fy
```

## 2. Understand One Dataset

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/competition.sole_source_hotspots" | jq
```

This tells you:

- What the dataset measures.
- Which fields it returns.
- Which filters it accepts.
- Which fields can be sorted.
- Any caveats.

## 3. Query Rows

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/competition.sole_source_hotspots/rows?limit=25" \
  | jq '.data'
```

## 4. Filter By Fiscal Year

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/competition.trend_fy/rows?fiscal_year_min=2020&fiscal_year_max=2025" \
  | jq '.data'
```

## 5. Find Industry Demand

NAICS sector `54` is Professional, Scientific, and Technical Services.

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/datasets/naics.trend_fy/rows?sector_code=54&fiscal_year_min=2022" \
  | jq '.data'
```

Public row queries are free and bounded. API keys are for paid, partner, or higher-volume access.

Every API response includes a top-level `notice` with the short data-completeness warning. Row responses also include `meta.caveats` and `meta.notices` with more detailed dataset-specific limitations.

## 6. Look Up Codes

```bash
curl -s "$FPDS_ANALYTICS_API_BASE_URL/v1/dimensions/pricing_codes" | jq '.data'
```

Use dimension endpoints when a code needs explanation.

## Common Starting Points

| Goal | Start with |
|---|---|
| Understand a customer's buying style | `pricing.agency_profile_fy` |
| Find sole-source-heavy customers | `competition.sole_source_hotspots` |
| Identify dominant vendors | `concentration.vendor_market_leaders` |
| Find growing industries | `naics.growth_leaders` |
| See where work happens | `geography.state_trend_fy` |

## Response Shape

Every row query returns:

```json
{
  "notice": "FPDS analytics are decision-support indicators, not a complete procurement universe. Do not treat department code 9700 as all DoD/Army opportunity, and do not treat place-of-performance or military postal codes as complete overseas spending.",
  "data": [],
  "pagination": {
    "limit": 100,
    "next_cursor": null
  },
  "meta": {
    "dataset_id": "competition.sole_source_hotspots",
    "source": "FPDS analytics schema",
    "source_fiscal_years": [1958, 2026],
    "row_count": 25,
    "caveats": [],
    "notices": [
      "FPDS analytics are decision-support indicators, not a complete procurement universe."
    ],
    "access": "public",
    "api_key_id": null
  }
}
```

Money values are returned as strings so downstream tools do not lose precision.
