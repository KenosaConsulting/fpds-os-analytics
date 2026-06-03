# Phase 2 Build Plan: New Analytical Capabilities

**Created:** 2026-06-03
**Repo:** `KenosaConsulting/fpds-os-analytics`
**Principle:** Every new view includes contracting-office-level granularity.

---

## Architecture Decisions

### Office Granularity Is the Baseline

Every new materialized view groups at the contracting-office level at minimum.
Higher-level aggregations (agency, department) are handled by report views that
roll up from office-grain MVs. This means:

- The office dimension table is a prerequisite for all builds.
- All MVs include `contracting_office_id` in their GROUP BY.
- Report views expose agency and department rollups via GROUP BY on the MV.
- Facade views serve both levels — office-level with required filters and
  agency-level as a separate dataset.

### Schema Layout

| Schema | Purpose | Builds |
|---|---|---|
| `customer_intelligence` | **New.** Office profiles, customer rollups, funding mismatch. | #1, #8 |
| `naics_breakdown` | **Existing.** Add NAICS × agency × office cross-tab. | #2 |
| `vendor_concentration` | **Existing.** Add agency/office vendor leaders report views. | #4 |
| `psc_analysis` | **New.** PSC trends, agency/office PSC profiles, PSC × NAICS crosswalk. | #7 |
| `pipeline_intelligence` | **New.** Recompete watchlist, duration profiles. | #5, #10 |
| `competition_dynamics` | **Existing.** Add vehicle/acquisition path views. | #6 |
| `geographic_analysis` | **Existing.** Extend with city/ZIP/county drill-down. | #9 |

### MV Sizing Estimates

Source table: `public.fpds_actions` — 99M rows.

| MV | Grain | Estimated Rows | Build Time |
|---|---|---|---|
| Office profile | office × FY | 200K–500K | 30–60 min |
| NAICS × agency × office | agency × office × NAICS × FY | 2M–5M | 45–90 min |
| PSC × agency × office | agency × office × PSC × FY | 2M–5M | 45–90 min |
| Funding mismatch | funding_agency × contracting_agency × office × FY | 500K–1M | 30–60 min |
| Vendor × agency × office | vendor × agency × office × FY | 5M–15M | 60–120 min |
| Recompete candidates | contract family (grouped) | 1M–3M | 60–120 min |
| Geo drill-down | city/county × agency × FY | 1M–3M | 45–90 min |
| Vehicle mix | agency × office × vehicle family × FY | 500K–2M | 30–60 min |

---

## Prerequisites: Dimension Tables

Before building any MVs, create these dimension tables in `analytics_dims`.

### P1. `analytics_dims.fpds_department_map`

Maps department codes to stable names. Small table (~40 rows).

```
department_id         text PRIMARY KEY
department_name       text NOT NULL
department_short_name text
is_dod                boolean
is_civilian           boolean
is_active             boolean
sort_order            integer
notes                 text
```

**Population method:** Extract distinct `contracting_dept_id`,
`contracting_dept_name` from `fpds_actions`. Manually curate short names
and flags. One-time effort.

**Facade:** `analytics_api.dim_departments`

### P2. `analytics_dims.fpds_agency_map`

Maps agency codes to names and parent departments (~300-400 rows).

```
agency_id             text PRIMARY KEY
agency_name           text NOT NULL
agency_short_name     text
parent_department_id  text REFERENCES fpds_department_map(department_id)
is_active             boolean
sort_order            integer
notes                 text
```

**Population method:** Extract distinct `contracting_agency_id`,
`contracting_agency_name`, `contracting_dept_id` from `fpds_actions`.
Deduplicate names (same agency ID with different name strings over time).

**Facade:** `analytics_api.dim_agencies`

### P3. `analytics_dims.fpds_contracting_office_map`

Maps office codes to names, parent agency, and metadata (~15K-25K rows).

```
contracting_office_id   text PRIMARY KEY
contracting_office_name text
normalized_office_name  text
contracting_agency_id   text
contracting_dept_id     text
office_state_code       text
office_country_code     text
first_observed_fy       integer
last_observed_fy        integer
is_active_recent        boolean    -- active in last 3 FYs
name_confidence         text       -- 'high', 'medium', 'low'
notes                   text
```

**Population method:**
1. Extract distinct office IDs with most recent name from `fpds_actions`.
2. Set `first_observed_fy` / `last_observed_fy` from signed_date ranges.
3. Flag `is_active_recent` based on last 3 fiscal years.
4. `name_confidence = 'high'` when only one name observed, `'medium'` when
   multiple names converge, `'low'` when names conflict.
5. `normalized_office_name` = cleaned version for display (strip dept prefix,
   standardize abbreviations).

**Known data quality issues:**
- Same office ID can have different names across years.
- Same name can appear under different IDs (reorganizations).
- Some office names are just the department name repeated.
- Office ID `000RA` appears in multiple agencies — the combination of
  `(contracting_office_id, contracting_agency_id)` is the true key, but
  the dim uses office ID alone for simplicity. Document this caveat.

**Facade:** `analytics_api.dim_contracting_offices`
Requires narrowing filter (agency, department, or search term) for queries.

### P4. `analytics_dims.fpds_psc_map`

Maps PSC codes to labels, categories, and classification (~3,000-4,000 rows).

```
psc_code              text PRIMARY KEY
psc_description       text
psc_category_code     text       -- first 2 chars
psc_category_label    text
psc_group             text       -- 'Services', 'Products', 'R&D', 'Construction'
is_service            boolean
is_product            boolean
is_r_and_d            boolean
is_construction       boolean
sort_order            integer
notes                 text
```

**PSC category structure:**
- First character indicates broad type:
  - `A`–`B`: R&D
  - `C`: Architect & Engineering
  - `D`: IT Services (ADP)
  - `E`–`G`: Purchase of structures, communications
  - `H`: Quality control/testing
  - `J`: Maintenance/repair of equipment
  - `K`–`N`: Lease/rental of equipment
  - `Q`: Medical services
  - `R`: Professional/admin/management services
  - `S`: Utilities and housekeeping
  - `T`–`V`: Transportation and travel
  - `W`: Lease/rental of equipment (specific)
  - `X`–`Y`: Lease/rental of facilities, construction
  - `Z`: Maintenance/repair of real property
  - `1`–`9`: Products/supplies (FSC codes)

**Population method:**
1. Extract distinct `product_or_service_code`, `product_or_service_code_desc`
   from `fpds_actions`.
2. Deduplicate descriptions (same code, different descriptions over time —
   take the most recent).
3. Derive `psc_group` from first-character classification rules.
4. Set boolean flags based on group.

**Facade:** `analytics_api.dim_psc_codes`

### P5. `analytics_dims.fpds_referenced_type_map`

Maps vehicle/acquisition path codes to families (5 rows + UNKNOWN).

```
raw_code              text PRIMARY KEY
label                 text NOT NULL
vehicle_family        text NOT NULL
is_gwac               boolean
is_schedule           boolean
is_idiq               boolean
is_bpa                boolean
is_open_market        boolean
sort_order            integer
notes                 text
```

**Values:**
- `A` → GWAC
- `B` → IDC (IDIQ)
- `C` → FSS (GSA Schedule)
- `D` → BOA (Basic Ordering Agreement)
- `E` → BPA (Blanket Purchase Agreement)
- `NONE` → Open Market (no referenced IDV)
- `UNKNOWN` → NULL/blank

**Facade:** `analytics_api.dim_vehicle_type_codes`

---

## Builds

Each build below is self-contained and can be executed independently once its
prerequisite dims exist. Builds are ordered by dependency and impact.

---

### Build 1: Office Customer Profile

**Priority:** Highest
**Prerequisites:** P1, P2, P3 (all three org dims)
**Schema:** `customer_intelligence` (new)
**Effort:** ~3 hours (MV build + report views + facade + catalog)

#### MV: `customer_intelligence.mv_office_profile_fy`

**Grain:** `contracting_office_id × fiscal_year`

**Source:** `fpds_actions` joined to `fpds_action_type_map`,
`fpds_extent_competed_map`, `fpds_set_aside_code_map`

**Columns:**

```
contracting_office_id          text
contracting_agency_id          text
contracting_dept_id            text
fiscal_year                    integer

-- Volume
total_action_count             bigint
contract_scope_action_count    bigint
base_award_action_count        bigint
modification_action_count      bigint

-- Obligations
net_obligated_amount           numeric
positive_obligated_amount      numeric
negative_obligated_amount      numeric
base_and_all_options_value_sum numeric

-- Diversity
distinct_vendor_count          integer   -- COUNT(DISTINCT uei)
distinct_naics_count           integer   -- COUNT(DISTINCT principal_naics_code)
distinct_psc_count             integer   -- COUNT(DISTINCT product_or_service_code)

-- Competition
competed_action_count          bigint
not_competed_action_count      bigint
competed_obligated             numeric
not_competed_obligated         numeric
avg_offers_received            numeric

-- Small business
small_biz_action_count         bigint
small_biz_obligated            numeric
positive_setaside_count        bigint

-- Top categories (by obligation within office-year)
top_naics_code                 text
top_psc_code                   text
top_vendor_uei                 text
```

**Indexes:**
- `(contracting_office_id, fiscal_year)` — primary lookup
- `(contracting_agency_id, fiscal_year)` — agency rollup
- `(contracting_dept_id, fiscal_year)` — department rollup

#### Report Views

1. **`report_deck_office_profile_fy`** — direct from MV with dim JOINs for
   office name, agency name, department name, top NAICS description, top PSC
   description. Computes shares:
   - `competed_action_share`, `competed_obligation_share`
   - `small_biz_action_share`, `small_biz_obligation_share`
   - `setaside_share`
   - `is_current_fiscal_year_ytd`

2. **`report_deck_agency_customer_profile_fy`** — rolls up MV by
   `contracting_agency_id × fiscal_year`. Same metrics aggregated. Adds
   `distinct_office_count`.

3. **`report_deck_office_kpi_summary`** — three-scope summary (all, current FY,
   recent 3yr) aggregated across all offices.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `customer.office_profile_fy` | `analytics_api.customer_office_profile_fy` | office_id, agency_id, or dept_id |
| `customer.agency_profile_fy` | `analytics_api.customer_agency_profile_fy` | agency_id or dept_id |
| `customer.kpi_summary` | `analytics_api.customer_kpi_summary` | — |

#### Analyst Questions Answered

- Which office at Army buys IT?
- Is this office active recently or just historically?
- How many vendors does this office work with?
- Is this office open to competition?
- Which office should I research before outreach?

---

### Build 2: NAICS × Agency × Office Cross-Tab

**Priority:** Very high
**Prerequisites:** P1, P2, P3, P4 (org dims + NAICS dim already exists)
**Schema:** `naics_breakdown` (existing)
**Effort:** ~3 hours

#### MV: `naics_breakdown.mv_fpds_naics_agency_office_fy`

**Grain:** `contracting_agency_id × contracting_office_id × principal_naics_code × fiscal_year`

**Source:** `fpds_actions` joined to `fpds_action_type_map`,
`fpds_naics_hierarchy_map`, `fpds_extent_competed_map`

**Columns:**

```
contracting_dept_id            text
contracting_agency_id          text
contracting_office_id          text
principal_naics_code           text
sector_code                    text    -- derived: LEFT(naics, 2)
fiscal_year                    integer

-- Volume
total_action_count             bigint
contract_scope_action_count    bigint

-- Obligations
net_obligated_amount           numeric
contract_scope_obligated       numeric

-- Market structure
distinct_vendor_count          integer
competed_action_count          bigint
not_competed_action_count      bigint
small_biz_obligated            numeric
avg_offers_received            numeric

-- Top vendor in this market
top_vendor_uei                 text
top_vendor_obligated           numeric
```

**Indexes:**
- `(contracting_agency_id, principal_naics_code, fiscal_year)`
- `(contracting_office_id, principal_naics_code, fiscal_year)`
- `(principal_naics_code, fiscal_year)` — government-wide NAICS lookup
- `(contracting_dept_id, fiscal_year)`

#### Report Views

1. **`report_deck_naics_agency_office_fy`** — from MV with dim JOINs. Full
   office-level detail.

2. **`report_deck_naics_agency_fy`** — rolls up by `agency × NAICS × FY`
   (aggregates across offices). Computes:
   - `small_biz_obligation_share`
   - `not_competed_obligation_share`
   - `top_vendor_share = top_vendor_obligated / net_obligated_amount`
   - Year-over-year obligation change (via self-join on FY-1)

3. **`report_deck_naics_customer_leaders`** — for a given NAICS, ranks agencies
   by 3-year obligation. "Who are the top 10 customers for NAICS 541512?"

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `market.agency_naics_fy` | `analytics_api.market_agency_naics_fy` | agency/dept + NAICS, or NAICS + FY |
| `market.office_naics_fy` | `analytics_api.market_office_naics_fy` | office/agency/dept required |
| `market.naics_customer_leaders` | `analytics_api.market_naics_customer_leaders` | NAICS code required |

#### Analyst Questions Answered

- How much did DOC spend on NAICS 541512 specifically?
- Which sub-agency (NOAA vs Census vs NIST) drives that spending?
- Which office within NOAA is the buyer?
- Is this NAICS growing or shrinking at this customer?
- Who is the top vendor in this agency × NAICS market?

---

### Build 3: Vendor Leaders by Agency and Office

**Priority:** High
**Prerequisites:** P1, P2, P3
**Schema:** `vendor_concentration` (existing)
**Effort:** ~2 hours (mostly report views on existing MVs)

This build is **lightweight** because `mv_fpds_vendor_agency_year` and
`mv_fpds_vendor_naics_agency_year` already exist. We need report views
that slice them by agency and add office-level data.

#### New MV: `vendor_concentration.mv_fpds_vendor_office_year`

**Grain:** `uei × contracting_office_id × fiscal_year`

Same structure as `mv_fpds_vendor_agency_year` but grouped at office level.
This is the one new MV needed.

**Columns:** Same as `mv_fpds_vendor_agency_year` plus
`contracting_office_id`.

#### Report Views (on existing + new MVs)

1. **`report_deck_agency_vendor_leaders`** — from existing
   `mv_fpds_vendor_agency_year`. Groups by `contracting_agency_id × uei`,
   sums recent-3yr obligations, ranks. Top 50 per agency.

2. **`report_deck_office_vendor_leaders`** — from new
   `mv_fpds_vendor_office_year`. Same pattern at office level.

3. **`report_deck_agency_naics_vendor_leaders`** — from existing
   `mv_fpds_vendor_naics_agency_year`. Filters to specific agency × NAICS,
   ranks vendors. "Who wins Army 541512?"

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `incumbent.agency_vendor_leaders` | `analytics_api.incumbent_agency_vendor_leaders` | agency_id or dept_id |
| `incumbent.office_vendor_leaders` | `analytics_api.incumbent_office_vendor_leaders` | office_id or agency_id |
| `incumbent.agency_naics_vendor_leaders` | `analytics_api.incumbent_agency_naics_vendor_leaders` | agency_id + NAICS |

#### Analyst Questions Answered

- Who are the top 10 vendors at NOAA?
- Who holds the IT services incumbency at NIST?
- Who should I team with at this customer?
- Is the market locked up by one vendor or spread across several?

---

### Build 4: PSC Analysis

**Priority:** High
**Prerequisites:** P4 (PSC dim)
**Schema:** `psc_analysis` (new)
**Effort:** ~3 hours

#### MV: `psc_analysis.mv_fpds_psc_agency_office_fy`

**Grain:** `contracting_agency_id × contracting_office_id × psc_code × fiscal_year`

**Columns:**

```
contracting_dept_id            text
contracting_agency_id          text
contracting_office_id          text
product_or_service_code        text
psc_group                      text    -- from dim: Services/Products/R&D/Construction
fiscal_year                    integer

total_action_count             bigint
contract_scope_action_count    bigint
net_obligated_amount           numeric
contract_scope_obligated       numeric
distinct_vendor_count          integer
competed_action_count          bigint
not_competed_action_count      bigint
small_biz_obligated            numeric
top_vendor_uei                 text
top_naics_code                 text    -- most common NAICS paired with this PSC
```

**Indexes:**
- `(contracting_agency_id, product_or_service_code, fiscal_year)`
- `(contracting_office_id, product_or_service_code, fiscal_year)`
- `(product_or_service_code, fiscal_year)`

#### Report Views

1. **`report_deck_psc_trend_fy`** — government-wide PSC trends by fiscal year.
   Joined to `fpds_psc_map` for labels. Aggregated across all agencies.

2. **`report_deck_psc_agency_profile_fy`** — per-agency PSC profile.
   "What PSC codes does Army buy?" Rolls up from office-grain MV.

3. **`report_deck_psc_office_profile_fy`** — per-office PSC profile.

4. **`report_deck_psc_naics_crosswalk`** — shows which NAICS codes co-occur
   with which PSC codes. Built from a separate query on `fpds_actions` grouping
   by `(psc, naics, fiscal_year)`.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `psc.trend_fy` | `analytics_api.psc_trend_fy` | FY or PSC code |
| `psc.agency_profile_fy` | `analytics_api.psc_agency_profile_fy` | agency/dept + FY or PSC |
| `psc.office_profile_fy` | `analytics_api.psc_office_profile_fy` | office/agency/dept required |
| `psc.naics_crosswalk` | `analytics_api.psc_naics_crosswalk` | PSC or NAICS required |

#### Analyst Questions Answered

- Which PSC codes describe Army IT spending? (D307, D310, R408?)
- Is the PSC classification different from NAICS for this agency?
- Which agencies buy PSC R499 (Professional Support: Other)?
- Which PSC codes are growing fastest?

---

### Build 5: Vehicle / Acquisition Path Mix

**Priority:** Medium-high
**Prerequisites:** P5 (referenced_type dim)
**Schema:** `competition_dynamics` (existing)
**Effort:** ~3 hours

#### MV: `competition_dynamics.mv_fpds_vehicle_mix_agency_office_fy`

**Grain:** `contracting_agency_id × contracting_office_id × vehicle_family × fiscal_year`

**Source:** `fpds_actions` joined to `fpds_referenced_type_map`. Actions with
no `referenced_type` are classified as `'NONE'` → Open Market.

**Columns:**

```
contracting_dept_id            text
contracting_agency_id          text
contracting_office_id          text
vehicle_family                 text    -- GWAC, IDIQ, FSS, BPA, BOA, Open Market, Unknown
fiscal_year                    integer

total_action_count             bigint
contract_scope_action_count    bigint
net_obligated_amount           numeric
distinct_vendor_count          integer
competed_action_count          bigint
not_competed_action_count      bigint
small_biz_obligated            numeric
avg_offers_received            numeric
top_vendor_uei                 text
```

**Indexes:**
- `(contracting_agency_id, vehicle_family, fiscal_year)`
- `(contracting_office_id, vehicle_family, fiscal_year)`
- `(vehicle_family, fiscal_year)`

#### Report Views

1. **`report_deck_vehicle_mix_trend_fy`** — government-wide vehicle family
   trends. "Is GWAC usage growing?"

2. **`report_deck_vehicle_mix_agency_fy`** — per-agency vehicle mix.
   "Does Army buy through GWACs or open market?"

3. **`report_deck_vehicle_mix_office_fy`** — per-office vehicle mix.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `acquisition.vehicle_mix_trend_fy` | `analytics_api.acquisition_vehicle_mix_trend_fy` | FY |
| `acquisition.agency_vehicle_mix_fy` | `analytics_api.acquisition_agency_vehicle_mix_fy` | agency/dept |
| `acquisition.office_vehicle_mix_fy` | `analytics_api.acquisition_office_vehicle_mix_fy` | office/agency/dept |

#### Analyst Questions Answered

- Does this customer buy through GWACs, GSA Schedule, agency IDIQs, or open market?
- Do I need a vehicle to compete?
- Which vehicle families dominate at this office?
- Is open market opportunity growing or shrinking?

#### Future Enhancement: Named Vehicle Resolution

This build uses `vehicle_family` only (GWAC/IDIQ/FSS/BPA/open market). Named
vehicle resolution (mapping `ref_piid` to "SEWP V", "Alliant 2", "CIO-SP3")
is a curated data project that requires:
- Building `analytics_dims.fpds_vehicle_map` with match patterns
- Joining `ref_piid` to known vehicle PIIDs
- Confidence scoring for matches

This is a separate effort — queue it after the family-level analysis proves
valuable.

---

### Build 6: Funding vs. Contracting Mismatch

**Priority:** Medium
**Prerequisites:** P1, P2
**Schema:** `customer_intelligence` (created in Build 1)
**Effort:** ~2 hours

#### MV: `customer_intelligence.mv_funding_contracting_mismatch_fy`

**Grain:** `funding_agency_id × contracting_agency_id × contracting_office_id × fiscal_year`

**Source:** `fpds_actions` filtered to records where `funding_agency_id` is
populated and differs from `contracting_agency_id`.

**Columns:**

```
funding_dept_id                text
funding_agency_id              text
contracting_dept_id            text
contracting_agency_id          text
contracting_office_id          text
fiscal_year                    integer

total_action_count             bigint
net_obligated_amount           numeric
distinct_vendor_count          integer
distinct_naics_count           integer
top_naics_code                 text
top_vendor_uei                 text
```

Note: Include ALL records (including matched funding=contracting) so shares can
be computed. Flag `is_mismatch = (funding_agency_id != contracting_agency_id)`.

**Indexes:**
- `(funding_agency_id, fiscal_year)`
- `(contracting_agency_id, fiscal_year)`
- `(funding_agency_id, contracting_agency_id, fiscal_year)`

#### Report Views

1. **`report_deck_funding_mismatch_flows_fy`** — shows money flowing from
   funding agencies to contracting agencies. Filtered to mismatches only.
   Ranked by obligation volume.

2. **`report_deck_assisted_acquisition_agency_fy`** — per-contracting-agency
   view showing how much of their work is funded by someone else.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `customer.funding_mismatch_flows_fy` | `analytics_api.customer_funding_mismatch_flows_fy` | funding_agency, contracting_agency, or dept |
| `customer.assisted_acquisition_fy` | `analytics_api.customer_assisted_acquisition_fy` | agency or dept |

#### Analyst Questions Answered

- Who owns the mission demand versus who runs the procurement?
- Is GSA buying this on NOAA's behalf?
- Should outreach target the funding program office or the contracting shop?

---

### Build 7: Recompete Pipeline & Duration Profiles

**Priority:** High (most differentiated feature)
**Prerequisites:** P1, P2, P3
**Schema:** `pipeline_intelligence` (new)
**Effort:** ~6 hours (most complex build — award-family grouping + date logic)

This is the hardest build because it requires **award-family grouping**:
collapsing individual contract actions (base award + modifications) into a
single contract entity to determine current end date, total obligation, and
incumbent vendor.

#### Step 1: Contract Family Intermediate MV

**`pipeline_intelligence.mv_contract_family`**

Groups `fpds_actions` into contract families using
`(piid, contracting_agency_id)` as the family key. For each family:

```
piid                                    text
contracting_agency_id                   text
contracting_office_id                   text    -- from most recent action
contracting_dept_id                     text
vendor_uei                              text    -- from most recent action
vendor_name                             text    -- from most recent action

principal_naics_code                    text    -- from base award
product_or_service_code                 text    -- from base award
set_aside_code                          text    -- from base award
extent_competed                         text    -- from base award

effective_date                          date    -- MIN across family
current_completion_date                 date    -- MAX across family
ultimate_completion_date                date    -- MAX across family

base_award_date                         date    -- signed_date of mod_number = '0' or MIN
latest_action_date                      date    -- MAX signed_date

total_obligated                         numeric -- SUM obligated_amount
base_and_all_options_value              numeric -- MAX (ceiling)
action_count                            integer
modification_count                      integer

fiscal_year_of_base                     integer
fiscal_year_of_latest                   integer

-- Derived
duration_months                         integer  -- date_diff in months
remaining_months                        integer  -- from CURRENT_DATE
is_expired                              boolean
expiration_bucket                       text     -- 'expired', '0-6mo', '6-12mo', '12-18mo', '18-24mo', '24mo+'
```

**Build approach:**
1. GROUP BY `(piid, contracting_agency_id)` — this is the contract family key.
2. Use window functions or aggregation to pull base-award attributes (where
   `mod_number = '0'` or `reason_for_modification IS NULL`).
3. Use MAX for dates and latest-action attributes.
4. Compute `duration_months` and `remaining_months` from dates.
5. Filter out families with invalid dates (completion < effective).

**Size estimate:** 15M-25M contract families (rough estimate: 99M actions
/ ~4 avg mods per family).

**Build time:** 60-120 minutes.

#### Step 2: Recompete Watchlist Report View

**`pipeline_intelligence.report_deck_recompete_watchlist`**

Filters `mv_contract_family` to:
- `remaining_months BETWEEN -6 AND 24` (recently expired to 24 months out)
- `total_obligated > 25000` (filter out micro-purchases)
- `action_count >= 1`

Joined to dims for labels. Includes:

```
-- From contract family
piid, contracting_office_id, contracting_agency_id, contracting_dept_id
vendor_uei, vendor_name
principal_naics_code, product_or_service_code, set_aside_code
effective_date, current_completion_date
total_obligated, base_and_all_options_value
duration_months, remaining_months, expiration_bucket

-- From dims
office_name, agency_name, dept_name
naics_description, psc_description
set_aside_label

-- Derived
recompete_confidence    text    -- 'high', 'medium', 'low'
confidence_notes        text
```

**Recompete confidence logic:**
- `high`: base + options value > 2× obligated (room for recompete), competed
  originally, active in recent FY, duration > 12 months
- `medium`: meets some but not all high criteria
- `low`: single-action, very old, or unusual patterns

#### Step 3: Duration Profile Report View

**`pipeline_intelligence.report_deck_duration_profile`**

Aggregates `mv_contract_family` by `contracting_agency_id × principal_naics_code`:

```
contracting_dept_id
contracting_agency_id
contracting_office_id
principal_naics_code
fiscal_year_of_base            -- grouped by base award FY

contract_count                 integer
median_duration_months         numeric
avg_duration_months            numeric
p25_duration_months            numeric
p75_duration_months            numeric
share_under_12_months          numeric
share_12_to_36_months          numeric
share_over_36_months           numeric
avg_obligated                  numeric
total_obligated                numeric
```

Filters to contract families with valid durations only.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `pipeline.recompete_watchlist` | `analytics_api.pipeline_recompete_watchlist` | date window + (agency/office/NAICS/PSC/vendor) |
| `pipeline.agency_recompete_summary` | `analytics_api.pipeline_agency_recompete_summary` | agency or dept |
| `pipeline.duration_profile` | `analytics_api.pipeline_duration_profile` | agency + NAICS, or office |

#### Analyst Questions Answered

- Which contracts at NOAA are expiring in the next 12 months?
- Who is the incumbent?
- Is this likely to be competed or sole-sourced?
- Are Army IT contracts typically 1-year or 5-year?
- What's the revenue cadence for this market?

#### Caveats (surface in API responses)

- FPDS period-of-performance dates are not guaranteed recompete indicators.
- Modifications can extend performance periods beyond the original estimate.
- Award-family grouping uses `(piid, contracting_agency_id)` which may not
  perfectly capture all related actions.
- Confidence scoring is heuristic, not deterministic.

---

### Build 8: Geographic Drill-Down Below State

**Priority:** Medium
**Prerequisites:** P1, P2, P3
**Schema:** `geographic_analysis` (existing)
**Effort:** ~3 hours

#### MV: `geographic_analysis.mv_fpds_geo_place_agency_fy`

**Grain:** `pop_state_code × pop_zip_city × pop_zip_county × contracting_agency_id × contracting_office_id × fiscal_year`

**Source:** `fpds_actions` filtered to domestic records with non-empty
city/county fields (~80% coverage).

**Columns:**

```
pop_country_code               text
pop_state_code                 text
pop_zip_city                   text
pop_zip_county                 text
pop_zip                        text    -- first 5 chars only
contracting_dept_id            text
contracting_agency_id          text
contracting_office_id          text
fiscal_year                    integer

total_action_count             bigint
net_obligated_amount           numeric
distinct_vendor_count          integer
competed_action_count          bigint
small_biz_obligated            numeric
top_naics_code                 text
top_vendor_uei                 text
```

**Indexes:**
- `(pop_state_code, pop_zip_city, fiscal_year)`
- `(contracting_agency_id, pop_state_code, fiscal_year)`
- `(pop_zip, fiscal_year)`

#### Report Views

1. **`report_deck_geo_place_profile_fy`** — city/county detail with dim JOINs.
2. **`report_deck_geo_metro_summary_fy`** — roll up by metro area if metro
   mapping is available, otherwise by `(state, city)` pairs.

#### Known Data Quality Issues

- City names are messy: "FT LIBERTY", "FORT LIBERTY", "FAYETTEVILLE" may all
  mean the same installation area.
- County names can be blank even when city/ZIP are present.
- ZIP codes may be 5-digit or 9-digit (ZIP+4). Truncate to 5.
- ~20% of domestic records lack city/county data entirely.

Normalization (city name cleaning, metro area mapping, installation matching)
is a curated effort that follows the initial build. Start with raw values
and iterate.

#### Facade Views

| Dataset ID | Facade | Required Filters |
|---|---|---|
| `geography.place_profile_fy` | `analytics_api.geography_place_profile_fy` | state + (city or ZIP or agency) |
| `geography.city_leaders` | `analytics_api.geography_city_leaders` | state or agency |

---

## Build Order

```
Prerequisites (dims)
├── P1: fpds_department_map         ← ~30 min
├── P2: fpds_agency_map             ← ~30 min
├── P3: fpds_contracting_office_map ← ~1 hr (name normalization)
├── P4: fpds_psc_map                ← ~1 hr (category classification)
└── P5: fpds_referenced_type_map    ← ~15 min

Build 1: Office Customer Profile        ← depends on P1-P3
Build 2: NAICS × Agency × Office        ← depends on P1-P3
Build 3: Vendor Leaders by Agency/Office ← depends on P1-P3
Build 4: PSC Analysis                    ← depends on P4
Build 5: Vehicle / Acquisition Path      ← depends on P5
Build 6: Funding Mismatch               ← depends on P1-P2
Build 7: Recompete + Duration            ← depends on P1-P3 (most complex)
Build 8: Geo Below State                 ← depends on P1-P2 (independent)
```

**Recommended execution sequence:**
1. All prerequisite dims (P1-P5) in one batch
2. Builds 1, 2, 3 together (they share the same schema and dim dependencies)
3. Build 4 (PSC) independently
4. Build 5 (vehicle) independently
5. Build 6 (funding mismatch) independently
6. Build 7 (recompete + duration) — save for last, most complex
7. Build 8 (geo) independently, can slot in anywhere

**Estimated total effort:** ~25-30 hours across all builds.

**Estimated MV build time (wall clock):** ~6-10 hours total (can overlap if
run sequentially during off-peak).

---

## Final API Surface After Phase 2

| Package | Datasets | Source |
|---|---|---|
| Pricing Strategy | 5 | Existing |
| Vendor Concentration | 5 + 3 new = 8 | Existing + Build 3 |
| Competition Dynamics | 4 + 2 enrichment + 3 vehicle = 9 | Existing + Wins 3,5 + Build 5 |
| NAICS Demand | 4 + 3 new = 7 | Existing + Build 2 |
| Geography | 4 + 2 new = 6 | Existing + Build 8 |
| Set-Aside | 6 | Win 1 |
| Customer Intelligence | 0 + 5 new = 5 | Builds 1, 6 |
| PSC Analysis | 0 + 4 new = 4 | Build 4 |
| Pipeline Intelligence | 0 + 3 new = 3 | Build 7 |
| **Total** | **~55 datasets** | |

Plus ~15 public dimensions.

---

## Open Design Questions

1. **Contract family key:** Is `(piid, contracting_agency_id)` sufficient, or
   do some agencies reuse PIIDs across programs? Need to test.
2. **Office dim: compound key vs. simple key?** Office ID `000RA` appears in
   multiple agencies. Use `(office_id, agency_id)` as PK, or document the
   caveat and use office_id alone?
3. **PSC category hierarchy source:** Should we use the official GSA PSC manual
   for category labels, or derive from FPDS descriptions?
4. **Named vehicle resolution scope:** How many vehicles should we curate names
   for in the first pass? Top 20 by obligation? Top 50?
5. **Geo normalization:** Clean city names in the dim, or expose raw and let
   consumers handle it?
6. **Recompete confidence thresholds:** What constitutes high/medium/low? Need
   analyst input on what makes a signal actionable.
