# Quickstart

This guide shows the first API calls a user should make.

## 1. See What The API Offers

```bash
curl -s https://api.example.com/v1/catalog | jq '.data[].id'
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
curl -s https://api.example.com/v1/datasets/competition.sole_source_hotspots | jq
```

This tells you:

- What the dataset measures.
- Which fields it returns.
- Which filters it accepts.
- Which fields can be sorted.
- Any caveats.

## 3. Query Rows

```bash
curl -s "https://api.example.com/v1/datasets/competition.sole_source_hotspots/rows?limit=25" \
  -H "X-Api-Key: $FPDS_API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data'
```

## 4. Filter By Fiscal Year

```bash
curl -s "https://api.example.com/v1/datasets/competition.trend_fy/rows?fiscal_year_min=2020&fiscal_year_max=2025" \
  -H "X-Api-Key: $FPDS_API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data'
```

## 5. Find Industry Demand

NAICS sector `54` is Professional, Scientific, and Technical Services.

```bash
curl -s "https://api.example.com/v1/datasets/naics.trend_fy/rows?sector_code=54&fiscal_year_min=2022" \
  -H "X-Api-Key: $FPDS_API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data'
```

## 6. Look Up Codes

```bash
curl -s "https://api.example.com/v1/dimensions/pricing_codes" | jq '.data'
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
    "caveats": []
  }
}
```

Money values are returned as strings so downstream tools do not lose precision.
