# Curl Examples

```bash
API_BASE="https://api.example.com"
API_KEY="fpds_live_replace_me"
```

List datasets:

```bash
curl -s "$API_BASE/v1/catalog" | jq '.data[].id'
```

Query pricing risk:

```bash
curl -s "$API_BASE/v1/datasets/pricing.risk_scorecard/rows?limit=25" \
  -H "X-Api-Key: $API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data[] | {dept: .contracting_dept_id, risk_score, total_obligated_3yr}'
```

Query competition profile for one fiscal year:

```bash
curl -s "$API_BASE/v1/datasets/competition.agency_profile_fy/rows?fiscal_year=2025&limit=100" \
  -H "X-Api-Key: $API_KEY" \
  -H "X-Api-Version: 2026-06-02" \
  | jq '.data[0]'
```

Look up state dimension rows:

```bash
curl -s "$API_BASE/v1/dimensions/states?limit=10" | jq '.data'
```
