# Analytics Methodology

How every number in the API is computed, from raw FPDS data to final output.

## Architecture

The analytics pipeline has three layers:

```
fpds_actions (99M raw records)
    ↓  JOIN dimension tables (analytics_dims)
Materialized Views (15 MVs across 5 schemas)
    ↓  aggregate / compute shares / KPIs
Report Views (21 views)
    ↓  thin facade alias
analytics_api schema (what the API reads)
```

Each layer is auditable. The API never touches raw tables directly.

## Source Data

All analytics derive from `public.fpds_actions`, which contains every contract action reported to the Federal Procurement Data System. Each row is one contract action (award, modification, termination, etc.) with fields including:

- `signed_date` — when the action was signed
- `obligated_amount` — dollars obligated (can be negative for de-obligations)
- `base_and_all_options_value` — total potential contract value
- `contracting_dept_id` / `contracting_agency_id` — who bought it
- `uei` — Unique Entity Identifier for the vendor
- `principal_naics_code` — industry classification
- `type_of_contract_pricing` — how the contract is priced
- `extent_competed` — how the contract was competed
- `pop_state_code` / `vendor_state_code` — where work is performed vs. where the vendor is located
- Socioeconomic flags (`is_small_business`, `is_women_owned`, `is_veteran_owned`, etc.)

## Fiscal Year Computation

The federal fiscal year runs October 1 through September 30. All analytics use fiscal year, not calendar year:

```sql
CASE
    WHEN EXTRACT(month FROM signed_date) >= 10
    THEN EXTRACT(year FROM signed_date) + 1
    ELSE EXTRACT(year FROM signed_date)
END AS fiscal_year
```

A contract signed on October 15, 2024 belongs to FY2025. A contract signed on September 30, 2025 also belongs to FY2025.

## Dimension Tables

Raw FPDS codes are joined to curated dimension tables that classify each code into analytical families. These tables live in the `analytics_dims` schema:

| Table | Rows | Purpose |
|---|---|---|
| `fpds_contract_pricing_map` | 16 | Maps pricing codes (J, K, L, etc.) to families: Fixed Price, Cost Reimbursement, Time & Materials |
| `fpds_extent_competed_map` | 10 | Maps competition codes to families: Full Competition, Limited Competition, Not Competed |
| `fpds_contract_bundling_map` | 6 | Maps bundling codes to severity levels |
| `fpds_business_size_map` | 20 | Maps contracting officer size determinations to small/other-than-small |
| `fpds_action_type_map` | 18 | Classifies action types; flags `is_contract_scope` (actions that define original contract scope vs. administrative modifications) |
| `fpds_modification_reason_map` | 22 | Classifies modification reasons; flags `is_modification` (true) vs. base awards (false) |
| `fpds_naics_hierarchy_map` | 1,722 | Maps 6-digit NAICS codes to 2-digit sectors and 4-digit subsectors with labels |
| `fpds_us_state_map` | 65 | Maps state codes to names, census regions, and census divisions (includes territories and military codes) |

These dimension tables are the interpretive backbone. When the API says a contract is "Fixed Price," that classification comes from `fpds_contract_pricing_map` mapping the raw code to the `pricing_family` column.

---

## Package 1: Pricing Strategy

**Question answered:** How does this agency prefer to buy?

### Materialized Views

**`mv_fpds_pricing_agency_year`** — One row per department × agency × fiscal year × pricing code × financing type × multi-year flag × PBC flag.

Aggregates from `fpds_actions` joined to `fpds_contract_pricing_map`, `fpds_action_type_map`, and `fpds_modification_reason_map`:

- `action_count` — total contract actions
- `net_obligated_amount` — sum of all obligated amounts (positive and negative)
- `positive_obligated_amount` / `negative_obligated_amount` — separated for audit
- `contract_scope_action_count` — actions classified as contract-scope (not administrative mods)
- `base_award_action_count` / `modification_action_count` — base awards vs. modifications

**`mv_fpds_pricing_dept_year_summary`** — One row per department × fiscal year. Uses the `is_fixed_price`, `is_cost_type`, `is_time_and_materials` boolean flags from the pricing dimension table to compute:

- `fixed_price_action_count` / `fixed_price_obligated`
- `cost_type_action_count` / `cost_type_obligated`
- `tm_action_count` / `tm_obligated`
- `other_action_count` / `other_obligated` — anything not classified as the above three
- `multi_year_action_count` — contracts flagged as multi-year
- `pbc_action_count` — performance-based service contracts

### Report Views

**`pricing.trend_fy`** — Government-wide pricing trends by fiscal year. Aggregates `mv_fpds_pricing_dept_year_summary` across all departments. Computes action shares and obligation shares:

```
fixed_price_action_share = fixed_price_action_count / total_action_count
fixed_price_obligation_share = fixed_price_obligated / total_obligated
```

Same pattern for cost type, T&M. Rounded to 4 decimal places.

**`pricing.agency_profile_fy`** — Per-department pricing profile by fiscal year. Same share calculations but grouped by `contracting_dept_id`. Includes `is_current_fiscal_year_ytd` flag.

**`pricing.kpi_summary`** — Top-level KPIs across three time scopes: all years, current FY, and recent 3 years. Same metrics as trend but pre-scoped.

**`pricing.risk_scorecard`** — Per-department risk score based on recent 3-year data:

```
risk_score = cost_type_obligation_share + tm_obligation_share
```

Higher risk score means the department spends more on cost-type and T&M contracts (which carry higher cost risk for the government and different competitive dynamics for contractors).

**`pricing.dept_year_summary`** — Raw department × year summary with the MV's pricing-type-enriched columns exposed directly. This is the MV itself through the facade.

---

## Package 2: Vendor Concentration

**Question answered:** Who dominates this market, and how strong is their position?

### Materialized Views

**`mv_fpds_vendor_agency_year`** — One row per vendor (UEI) × agency × fiscal year. Filters to records where UEI, agency, and signed date are all non-null. Aggregates:

- `net_obligated_amount`, `base_and_all_options_value_sum`, `total_estimated_order_value_sum`
- `positive_obligated_amount` / `negative_obligated_amount`
- `contract_scope_action_count` / `contract_scope_obligated_amount` — using `is_contract_scope` from action type dimension
- `base_award_count` / `modification_count` with corresponding obligated amounts
- Socioeconomic flags via `BOOL_OR`: `is_small_business`, `is_veteran_owned`, `is_women_owned`, `is_minority_owned`, etc. (true if the vendor ever self-certified in that fiscal year)
- `is_co_determined_small` / `is_co_determined_large` — contracting officer size determination from `fpds_business_size_map`

**`mv_fpds_vendor_naics_agency_year`** — One row per vendor × NAICS code × agency × fiscal year. Same base filters. Adds NAICS breakdown to vendor-agency data. Includes `contract_scope_obligated_amount` for market share calculations.

**`mv_fpds_concentration_agency_naics_year`** — Market concentration metrics per agency × NAICS × fiscal year. Built from `mv_fpds_vendor_naics_agency_year` using window functions:

1. Compute each vendor's `market_share_pct` as percentage of total agency-NAICS-year obligation
2. Rank vendors by obligation descending
3. Aggregate:
   - `vendor_count` — distinct vendors in this market
   - `top_vendor_share` — market share of the #1 vendor
   - `top_3_vendor_share` / `top_5_vendor_share` — cumulative share of top 3/5
   - `hhi` — Herfindahl-Hirschman Index: `SUM(market_share_pct²)`, rounded
   - `market_concentration_level`:
     - HHI < 1500 → `COMPETITIVE`
     - HHI 1500–2499 → `MODERATE_CONCENTRATION`
     - HHI ≥ 2500 → `HIGH_CONCENTRATION`
   - Small business counts and obligations

Markets with fewer than 2 vendors or zero total obligation are excluded.

**`mv_fpds_vendor_incumbent_analysis`** — Vendor incumbency per agency. Built from `mv_fpds_vendor_agency_year`, filtered to positive obligations, grouped by vendor × agency:

- `first_fiscal_year` / `last_fiscal_year` — tenure range
- `active_year_count` — years with positive obligations
- `year_span` — last year minus first year plus one
- `consecutive_year_streak` — equals `active_year_count` only if every year in the span was active (otherwise NULL)
- `total_obligated` / `avg_annual_obligated`
- `active_year_ratio` — proportion of years with positive obligation

Requires at least 2 active fiscal years to appear.

### Report Views

**`concentration.trend_fy`** — Year-over-year market concentration trends. Per fiscal year:
- Count of analyzed markets by concentration level
- `highly_concentrated_pct = highly_concentrated_markets / analyzed_markets × 100`
- Average HHI, top vendor share, top 3 vendor share
- Average vendors per market
- Small business obligation share and average small business vendor count

**`concentration.agency_profile`** — Per-agency concentration profile across all years. Requires ≥5 analyzed markets. Shows monopoly market percentage, average HHI, average vendor count.

**`concentration.vendor_market_leaders`** — Top 500 vendors by lifetime obligation. Shows agencies served, average tenure, consecutive-year streaks ≥5 (long incumbency indicator).

**`concentration.small_biz_health_fy`** — Small business participation trends by fiscal year. Counts new small business entrants (vendors whose `first_fiscal_year` matches the current year). Computes small business vendor share, obligation share, and action share.

**`concentration.kpi_summary`** — Current FY snapshot: markets analyzed, average HHI, highly concentrated percentage, average vendors per market, small business share.

---

## Package 3: Competition Dynamics

**Question answered:** Is this market accessible to new entrants?

### Materialized Views

**`mv_fpds_competition_agency_year`** — One row per department × agency × fiscal year × competition code × bundling code × consolidation flag. Joined to `fpds_extent_competed_map` and `fpds_contract_bundling_map`. Aggregates:

- Standard obligation splits (net, positive, negative)
- `contract_scope_action_count`, `base_award_action_count`, `modification_action_count`
- `offers_received_sum` / `offers_received_avg` — number of offers on competed actions

**`mv_fpds_competition_dept_year_summary`** — One row per department × fiscal year. Uses boolean flags from dimension tables:

- `competed_action_count` / `competed_obligated` — where `is_competed = true`
- `not_competed_action_count` / `not_competed_obligated` — where `is_not_competed = true`
- `full_competition_action_count` / `full_competition_obligated`
- `limited_competition_action_count` / `limited_competition_obligated`
- `bundled_action_count` / `bundled_obligated` — where `is_bundled = true`
- `consolidated_action_count` / `consolidated_obligated` — where `consolidated_contract = 'Y'`
- Pre-computed shares: `competed_action_share`, `not_competed_action_share`, `bundled_action_share`
- `avg_offers_received` — average number of offers across actions with offer data

### Report Views

**`competition.trend_fy`** — Government-wide competition trends. Aggregates department summary across all departments per fiscal year. Computes action shares and obligation shares for competed, not-competed, full competition, limited competition, bundled, and consolidated.

**`competition.agency_profile_fy`** — Per-department competition profile. Passes through the department summary with additional obligation shares computed at the view level.

**`competition.kpi_summary`** — Three-scope summary (all years, current FY, recent 3 years) with all competition metrics.

**`competition.sole_source_hotspots`** — Departments ranked by non-competed obligation share over the recent 3 years. Filtered to departments with positive total obligation.

---

## Package 4: Industry / NAICS Demand

**Question answered:** What industries is this agency buying in, and which are growing?

### Materialized Views

**`mv_fpds_naics_agency_year`** — One row per department × agency × fiscal year × NAICS code. Derives sector (2-digit) and subsector (4-digit) codes from the NAICS code. Aggregates:

- Standard obligation and action counts
- `contract_scope_action_count` / `contract_scope_obligated`
- `base_award_count` / `modification_count`
- `distinct_vendor_count` — unique UEIs in this market segment

**`mv_fpds_naics_dept_year_summary`** — One row per department × fiscal year. Includes:

- `distinct_naics_count` / `distinct_sector_count` / `distinct_subsector_count` — industry diversity
- `distinct_vendor_count`
- `top_naics_code_by_obligation` — the NAICS code with highest obligation for this department-year
- `top_naics_obligation_share` — what fraction of total obligation the top NAICS represents

The top NAICS is computed via a CTE using `DISTINCT ON` ordered by obligation descending.

**`mv_fpds_naics_sector_dept_year`** — One row per 2-digit sector × department × fiscal year. Aggregates NAICS data at the sector level for sector-level trend analysis.

### Report Views

**`naics.trend_fy`** — Sector-level trends by fiscal year. Joined to `naics_codes` for sector labels. Computes:

- `sector_obligation_share_of_total` — this sector's share of total government-wide obligation for that fiscal year (via correlated subquery)

**`naics.agency_profile_fy`** — Per-department NAICS profile. Includes:

- `naics_diversity_ratio = distinct_naics_count / total_action_count` — higher means more diverse industry portfolio
- `top_sector_code` / `top_sector_obligation_share` — computed via correlated subqueries against the sector MV

**`naics.growth_leaders`** — NAICS codes ranked by year-over-year obligation change. Full outer join between current FY and prior FY data:

```
obligation_growth_rate = (current - prior) / ABS(prior)
obligation_change = current - prior
```

Ordered by absolute obligation change descending.

**`naics.kpi_summary`** — Three-scope summary with NAICS diversity metrics:

- `avg_vendors_per_naics = vendor_interactions / distinct_naics_count`
- `avg_obligation_per_naics = total_obligated / distinct_naics_count`

---

## Package 5: Geography

**Question answered:** Where does contract work happen, and does it stay local?

### Materialized Views

**`mv_fpds_geo_pop_state_agency_year`** — One row per place-of-performance state × country × department × agency × fiscal year. The base geographic fact table. Missing state codes become `'XX'`.

**`mv_fpds_geo_pop_state_year`** — Aggregates the above across agencies. Adds `is_domestic` flag (USA or XX = domestic).

**`mv_fpds_geo_dept_year_summary`** — One row per department × fiscal year. Computes geographic flow metrics:

- `domestic_action_count` / `domestic_obligated` — where `pop_country_code = 'USA'` or NULL
- `international_action_count` / `international_obligated` — non-USA, non-NULL country codes
- `in_state_action_count` / `in_state_obligated` — where vendor state matches performance state
- `out_of_state_action_count` / `out_of_state_obligated` — where they differ

**`mv_fpds_geo_vendor_vs_pop`** — One row per vendor state × performance state × fiscal year × in-state flag. The vendor-to-performance flow matrix. Used to identify geographic mismatch patterns (e.g., Virginia vendors performing work in Maryland).

### Report Views

**`geography.state_trend_fy`** — Per-state trends joined to the state dimension table for census region and division. Domestic records only.

**`geography.regional_summary_fy`** — Census region aggregates by fiscal year. Excludes "Unknown" and "Territory" regions.

**`geography.mismatch_leaders`** — Top 100 vendor-state to performance-state pairs by obligation over the recent 3 years. Excludes unknown states. Minimum $1M obligation threshold. Includes census region for both vendor and performance states.

**`geography.kpi_summary`** — Three-scope summary with:

- `domestic_obligated_share = domestic_obligated / total_obligated`
- `in_state_obligated_share = in_state_obligated / total_obligated`

The in-state share uses the department-year summary (which computes the match at the action level) rather than the state-year summary.

---

## Package 6: Set-Aside & Socioeconomic Programs

**Question answered:** Does this customer use small-business set-asides, and which programs?

### Dimension Table

**`fpds_set_aside_code_map`** — 20 codes mapping FPDS `type_of_set_aside` values to human-readable labels and program families:

| Family | Codes | Description |
|---|---|---|
| Small business | SBA, SBP, RSB, VSB, ESB | Total, partial, reserved, very small, emerging |
| 8(a) | 8A, 8AN, 8AC, HS2, HS3 | Competed, sole source, SDB, HUBZone combo |
| HUBZone | HZC, HZS | Set-aside and sole source |
| SDVOSB | SDVOSBC, SDVOSBS, SDVOBS | Set-aside and sole source |
| WOSB | WOSB | Women-owned small business |
| Veteran-owned | VSA, VSS | VA-only set-aside and sole source |
| No set aside | NONE | Explicitly no set-aside used |
| Unknown | UNKNOWN | NULL, blank, or not reported |

Each code carries `is_positive_set_aside` (true if an actual program was used) and `is_known_status` (true if the field was explicitly coded, even as NONE). Historical codes include `valid_from` and `valid_to` dates.

### Materialized Views

**`mv_fpds_setaside_agency_year_summary`** — One row per department × agency × fiscal year. 9,106 rows. The core set-aside fact table at the agency level. Joined to `fpds_set_aside_code_map`, `fpds_action_type_map`, `fpds_modification_reason_map`, and `fpds_value_bucket_map`.

Key metrics:
- `known_setaside_status_count` / `unknown_setaside_status_count` — data quality indicators
- `no_setaside_action_count` / `positive_setaside_action_count` — actions with/without a set-aside program
- `contract_scope_*` variants — same metrics filtered to contract-scope actions (excluding admin mods)
- Pre-computed shares: `setaside_action_share_known`, `setaside_obligation_share_known`
- Modification breakdown: `funding_only_mod_count`, `admin_mod_count`, `option_exercise_mod_count`, `scope_change_mod_count`, `cancellation_closeout_mod_count`
- Value bucket distributions: counts of awards by base value and obligated value ranges

**`mv_fpds_setaside_agency_year_award_type`** — One row per department × agency × fiscal year × award type × set-aside code. 125,541 rows. The detailed cross-tab showing which award types (delivery orders, definitive contracts, BPA calls, FSS orders, etc.) use which set-aside programs.

**`mv_fpds_setaside_office_year_summary`** — One row per department × agency × office × fiscal year. 137,770 rows. Same metrics as the agency summary but at contracting-office granularity.

**`mv_fpds_setaside_office_year_award_type`** — One row per department × agency × office × fiscal year × award type × set-aside code. 887,208 rows. The full detail cross-tab at office level.

### Report Views

**`set_aside.trend_fy`** — Government-wide set-aside trends. Aggregates `mv_fpds_setaside_agency_year_summary` across all agencies per fiscal year. Computes shares against known-status actions (not total) to avoid deflation from missing data:

```
setaside_action_share_known = positive_setaside_action_count / known_setaside_status_count
setaside_obligation_share_known = positive_setaside_net_obligated / known_status_net_obligated
```

Also computes `unknown_status_share` as a data quality indicator.

**`set_aside.family_trend_fy`** — Trends by set-aside family (8(a), Small Business, WOSB, HUBZone, SDVOSB, etc.). Shows each program's share of total set-aside activity.

**`set_aside.agency_profile_fy`** — Per-agency profile with `friendliness_rank` — a ranking of agencies by the share of contract-scope known-status actions that use a positive set-aside. Higher rank means the agency directs more of its known procurement through small-business programs.

**`set_aside.agency_mix_fy`** — Cross-tab of agency × set-aside code. Shows exactly how much each agency spends through each specific program (8(a) Competed vs. 8(a) Sole Source vs. HUBZone, etc.). Includes `agency_setaside_rank` ordering programs by obligation within each agency.

**`set_aside.office_profile_fy`** — Same as agency profile but at contracting-office level. This is the highest-granularity set-aside view in the API — it answers "which office at Army is most friendly to small businesses?"

**`set_aside.kpi_summary`** — Three-scope summary: all years, current FY, and recent 3-year contact activity.

### Known Status vs. Total Actions

FPDS set-aside coding has changed over time. Early records often lack set-aside classification entirely. The `unknown_status_share` metric tracks this: in recent fiscal years it is typically 10-15%, but in the current FY it can spike to 75%+ as records are still being coded.

All set-aside shares are computed against **known-status actions**, not total actions, to avoid artificially deflating participation rates due to missing data. This is a deliberate methodology choice — it means rates are accurate for the subset of classified actions but may not represent the universe.

---

## Computation Notes

### Obligation Amounts

`obligated_amount` in FPDS can be negative (de-obligations, downward modifications). All `net_obligated_amount` columns are true net sums including negative values. Where positive and negative are separated (`positive_obligated_amount`, `negative_obligated_amount`), they use `CASE WHEN > 0` and `CASE WHEN < 0` filters respectively.

Empty string values are handled via `NULLIF(obligated_amount, '')::numeric` throughout.

### Contract Scope vs. All Actions

Many MVs distinguish "contract scope" actions from all actions. Contract scope actions are those classified by `fpds_action_type_map.is_contract_scope = true` — these represent the original award and substantive modifications, excluding purely administrative changes. This distinction matters for market sizing: administrative modifications inflate action counts without representing real market activity.

### Socioeconomic Flags

FPDS stores socioeconomic certifications as text `'true'`/`'false'` strings, not booleans. The vendor MVs use `BOOL_OR(field = 'true')` to aggregate — a vendor is flagged as small business if they self-certified in *any* action that fiscal year.

### HHI (Herfindahl-Hirschman Index)

Computed as the sum of squared market share percentages:

```
HHI = SUM(market_share_pct²)
```

Where `market_share_pct = 100 × vendor_obligation / total_market_obligation`. Scale is 0–10,000. A market with one vendor has HHI = 10,000. The DOJ/FTC thresholds used:

- < 1,500: Competitive
- 1,500–2,499: Moderate concentration
- ≥ 2,500: High concentration

### Current Fiscal Year

All "current FY" computations use:

```sql
CASE
    WHEN EXTRACT(month FROM CURRENT_DATE) >= 10
    THEN EXTRACT(year FROM CURRENT_DATE) + 1
    ELSE EXTRACT(year FROM CURRENT_DATE)
END
```

Current FY data is always year-to-date and flagged as `is_current_fiscal_year_ytd = true`.

### Time Scopes

KPI summaries use three scopes:
- **all_years_core** — entire dataset history
- **current_fy** — current fiscal year only (YTD)
- **recent_3yr** — current fiscal year minus 2 through current

### Share Computations

All percentage shares are computed as ratios and rounded to 4 decimal places (e.g., 0.6234 = 62.34%). Division by zero is guarded with `NULLIF(denominator, 0)`.
