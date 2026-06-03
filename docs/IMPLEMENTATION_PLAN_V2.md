# Implementation Plan: Analytics API V2 — Quick Wins

**Created:** 2026-06-03
**Scope:** Strengthen existing schemas with data already materialized in the database.
**Repo:** `KenosaConsulting/fpds-os-analytics`

All work below targets the open-source analytics API. Nothing from the `v2`
schema is exposed — that data is proprietary and stays behind the paywall.

---

## Summary

Three categories of quick wins, ordered by effort-to-impact ratio:

| # | Win | New SQL | New Code | Effort | Impact |
|---|---|---|---|---|---|
| 1 | Promote set-aside breakdown to API | Facade views only | Catalog + docs | ~2 hrs | Entire new package (Package 6) |
| 2 | Expose the set-aside dimension publicly | 1 facade view | Catalog entry | ~15 min | Users can decode set-aside codes |
| 3 | Add `reason_not_competed` to competition dynamics | 1 new report view + 1 facade | Catalog entry | ~1 hr | Answers WHY contracts aren't competed |
| 4 | Wire existing dim labels into existing views | Update facade views | Docs | ~1 hr | Human-readable dept/state/NAICS names in responses |
| 5 | Add `commercial_item_acquisition_procedures` to competition | 1 MV column + report view | Catalog | ~2 hrs | Commercial vs. non-commercial buying (99.5% populated) |
| 6 | Add `parent_uei` to vendor concentration | MV rebuild | Catalog field additions | ~3 hrs | Parent-company rollups (100% populated) |

**Estimated total: ~10 hours for all 6 wins.**

---

## Win 1: Promote Set-Aside Breakdown (Package 6)

### What Already Exists in the Database

The `set_aside_breakdown` schema contains 11 materialized views (1.2M+ total
rows, 1 GB, fully indexed) and 8 report views. This was built for the chatbot
but never wired to the public analytics API.

**MVs (private, already materialized):**

| MV | Rows | Size | Grain |
|---|---|---|---|
| `mv_fpds_setaside_agency_year_summary` | 9,106 | 6 MB | dept × agency × FY |
| `mv_fpds_setaside_agency_year_award_type` | 125,541 | 96 MB | dept × agency × FY × award type × set-aside code |
| `mv_fpds_setaside_office_year_summary` | 137,770 | 86 MB | dept × agency × office × FY |
| `mv_fpds_setaside_office_year_award_type` | 887,208 | 735 MB | dept × agency × office × FY × award type × set-aside code |
| `mv_fpds_setaside_contact_year_award_type` | (large) | 34 MB | contact × office × FY × award type × set-aside |
| `mv_fpds_setaside_contact_3yr_summary` | 19,203 | 16 MB | contact × office (3-year rollup) |
| `mv_fpds_setaside_contact_3yr_setaside_type` | 22,132 | 17 MB | contact × office × set-aside family (3-year) |
| `mv_fpds_setaside_contact_3yr_summary_named` | (named) | 17 MB | Named version of 3yr summary |
| `mv_fpds_setaside_contact_3yr_setaside_type_named` | (named) | 19 MB | Named version of 3yr by type |
| `mv_fpds_contact_name_enrichment` | 14,599 | 5 MB | Contact name normalization |
| `mv_fpds_setaside_distincts_office_year_award_type` | (empty) | 8 KB | Appears unused |

**Report views (private, already built):**

| View | Columns | Purpose |
|---|---|---|
| `report_deck_overall_trend_fy` | 39 | Government-wide set-aside trends |
| `report_deck_setaside_family_trend_fy` | 19 | Trends by set-aside family (8(a), WOSB, HUBZone, etc.) |
| `report_deck_agency_friendly_fy` | 22 | Per-agency small-biz friendliness ranking |
| `report_deck_agency_setaside_mix_fy` | 16 | Agency × set-aside code mix |
| `report_deck_office_friendly_fy` | 24 | Per-office small-biz friendliness ranking |
| `report_deck_kpi_summary` | 11 | Three-scope KPI summary |
| `report_deck_contact_inbox_leaders_3yr` | 22 | **EXCLUDE — contains PII (names, emails)** |
| `report_deck_named_contact_leaders_3yr` | 20 | **EXCLUDE — contains PII (names, emails)** |

### What to Expose via the API

**6 datasets (excluding 2 contact/PII views):**

| Dataset ID | Facade View | Backing View |
|---|---|---|
| `set_aside.trend_fy` | `analytics_api.set_aside_trend_fy` | `report_deck_overall_trend_fy` |
| `set_aside.family_trend_fy` | `analytics_api.set_aside_family_trend_fy` | `report_deck_setaside_family_trend_fy` |
| `set_aside.agency_profile_fy` | `analytics_api.set_aside_agency_profile_fy` | `report_deck_agency_friendly_fy` |
| `set_aside.agency_mix_fy` | `analytics_api.set_aside_agency_mix_fy` | `report_deck_agency_setaside_mix_fy` |
| `set_aside.office_profile_fy` | `analytics_api.set_aside_office_profile_fy` | `report_deck_office_friendly_fy` |
| `set_aside.kpi_summary` | `analytics_api.set_aside_kpi_summary` | `report_deck_kpi_summary` |

### Implementation Steps

1. **SQL: `sql/004_set_aside_facade.sql`**
   - Create 6 facade views in `analytics_api` with `security_barrier = true`
   - Grant `SELECT` on all 6 to the API role
   - Explicit column lists (no `SELECT *`) — filter out any internal audit columns

2. **Catalog: `catalog/datasets.yaml`**
   - Add 6 dataset entries with filters, sortable fields, field allowlists
   - `set_aside.office_profile_fy` requires `contracting_office_id`,
     `contracting_agency_id`, `contracting_dept_id`, or `fiscal_year` filter
     (high cardinality — 137K rows)

3. **Docs: `docs/DATASETS.md`**
   - Add set-aside package section with field definitions
   - Document `friendliness_rank` computation (set-aside share ranking)
   - Note that ~49% of actions have unknown set-aside status (not missing —
     FPDS coding changed over time)

4. **Docs: `docs/METHODOLOGY.md`**
   - Add Package 6 section explaining the set-aside computation chain

5. **README: update Analysis Packages section**
   - Add Package 6: Set-Aside & Socioeconomic Programs

6. **Tests: `tests/`**
   - Add catalog contract test for 6 new datasets
   - Add required-filter test for office-level view

### Analyst Questions Answered

- Does this agency use small-business set-asides?
- Which set-aside programs does this customer actually use (8(a), WOSB, HUBZone, SDVOSB)?
- Which offices are most friendly to small businesses?
- Is the set-aside market concentrated in one program or spread across several?
- How has small-business participation changed year over year?

---

## Win 2: Expose Set-Aside Dimension

### What Exists

`analytics_dims.fpds_set_aside_code_map` — 20 rows, already populated with
codes, labels, families, validity dates, and boolean flags.

### Implementation

1. **SQL: add to `sql/004_set_aside_facade.sql`**

```sql
CREATE OR REPLACE VIEW analytics_api.dim_set_aside_codes
WITH (security_barrier = true) AS
SELECT raw_code, normalized_code, label, family, status,
       is_positive_set_aside, is_known_status,
       valid_from, valid_to, sort_order, notes
FROM analytics_dims.fpds_set_aside_code_map;
```

2. **Catalog: `catalog/dimensions.yaml`** — add `set_aside_codes` entry

---

## Win 3: Add `reason_not_competed` to Competition Dynamics

### Data Profile

`reason_not_competed` is populated on ~16.6% of actions — specifically those
that are not competed. Currently competition_dynamics tells you WHETHER something
was competed but not WHY it wasn't. The reason codes include:

| Code | Description | Sample Rate |
|---|---|---|
| `OTH` | Authorized by Statute (FAR 6.302-5) | ~24% of non-competed |
| `ONE` | Only One Source (FAR 6.302-1) | ~29% of non-competed |
| `SP2` | SAP Non-Competition (FAR 13) | ~18% of non-competed |
| `UNQ` | Unique Source | ~5% |
| `FOC` | Follow-On Contract | ~3% |
| `URG` | Urgency | ~3% |

### Implementation

1. **SQL: `sql/005_competition_enrichment.sql`**
   - Create new report view `competition_dynamics.report_deck_not_competed_reasons_fy`
     aggregating `reason_not_competed` × `contracting_dept_id` × `fiscal_year`
   - Create facade view `analytics_api.competition_not_competed_reasons_fy`

2. **Dim table: `analytics_dims.fpds_reason_not_competed_map`**
   - ~12 distinct codes → human-readable labels and reason families
   - Facade: `analytics_api.dim_reason_not_competed_codes`

3. **Catalog + docs updates**

### Analyst Questions Answered

- Why isn't this customer competing their work?
- Is the sole-source pattern statutory or market-driven?
- Is the non-competition concentrated in follow-on contracts (incumbent advantage)?

---

## Win 4: Wire Existing Dim Labels Into Views

### Problem

Current API responses return raw codes: `contracting_dept_id = "9700"`,
`pop_state_code = "VA"`, `principal_naics_code = "541512"`. Users must call
the dimension endpoints separately to decode them.

We already have the dim tables:
- `fpds_naics_hierarchy_map` (1,722 rows) — NAICS labels, sectors, subsectors
- `fpds_us_state_map` (65 rows) — state names, census regions
- `fpds_contract_pricing_map` (16 rows) — pricing family labels

These are exposed as API dimensions but NOT joined into the data views.

### Implementation

Update facade views to JOIN dim tables and include labels alongside codes.
This does NOT require rebuilding MVs — the facade views already sit on top.

Example for `naics.trend_fy`:

```sql
CREATE OR REPLACE VIEW analytics_api.naics_trend_fy
WITH (security_barrier = true) AS
SELECT r.*, 
       n.naics_desc, n.sector_code, n.sector_label, n.subsector_label
FROM naics_breakdown.report_deck_naics_trend_fy r
LEFT JOIN analytics_dims.fpds_naics_hierarchy_map n 
  ON r.principal_naics_code = n.naics_code;
```

Apply the same pattern to:
- All `naics_breakdown` report views → add NAICS labels
- All `geographic_analysis` report views → add state names, census regions
- All views with `contracting_dept_id` → add department names (requires
  creating `fpds_department_map` dim or using a lightweight CTE)

### Effort

~1 hour. No MV rebuilds. Only facade view updates + catalog field additions.

### Impact

Every API response becomes self-describing. Users no longer need two API calls
to understand a row.

---

## Win 5: Add Commercial Item Classification to Competition

### Data Profile

`commercial_item_acquisition_procedures` — 99.5% populated. Two primary values:

| Code | Description | Sample Share |
|---|---|---|
| `A` | Commercial Product/Service | ~47% |
| `D` | Commercial Procedures Not Used | ~48% |
| `B` | Products/Services under FAR 12.102(f) | ~1% |
| `C` | Services under FAR 12.102(g) | <1% |

### Why This Matters

Commercial vs. non-commercial buying is one of the most important strategic
distinctions in federal procurement. Commercial items use simplified
acquisition, lower barriers to entry, and different pricing dynamics. This is
currently invisible in the API.

### Implementation

1. **Dim table: `analytics_dims.fpds_commercial_item_map`** — 7 codes
2. **Option A (lightweight):** New report view in `competition_dynamics` that
   cross-tabs competition × commercial status × dept × FY. No MV rebuild needed
   — the view can read from `fpds_actions` directly with aggregation, or we add
   the column to the existing competition MV during the next refresh cycle.
3. **Option B (richer):** Add `commercial_item_acquisition_procedures` to the
   next `mv_fpds_competition_dept_year_summary` rebuild. This gives
   commercial/non-commercial splits on every competition metric.
4. **Facade + catalog + docs**

### Analyst Questions Answered

- Does this customer buy commercially or through traditional acquisition?
- Is the commercial market competed or sole-sourced?
- Which agencies are most open to commercial products?

---

## Win 6: Add Parent Company to Vendor Concentration

### Data Profile

`ultimate_parent_uei` — 100% populated. This enables parent-company rollups
that transform vendor concentration analysis from "which specific entity wins"
to "which corporate family controls the market."

### Implementation

This requires a `REFRESH MATERIALIZED VIEW` cycle because
`ultimate_parent_uei` must be added to the vendor MVs:

1. Add `ultimate_parent_uei` and `ultimate_parent_uei_name` to
   `mv_fpds_vendor_agency_year` definition
2. Rebuild the MV (this is the expensive step — 99M row scan)
3. Add parent-company grouping to `mv_fpds_vendor_incumbent_analysis`
4. Create new report view: `vendor_concentration.report_deck_parent_company_leaders`
   that groups by parent UEI and sums child obligations
5. Facade + catalog + docs

### Impact

High. Currently Guidehouse and its subsidiaries appear as separate vendors.
With parent rollup, analysts see the true corporate market share.

### Risk

MV rebuild on 99M rows takes ~30-60 minutes. Plan for a maintenance window.

---

## Build Order

| Order | Win | Blocks Others? | Deploy Risk |
|---|---|---|---|
| **1** | Win 1 + Win 2: Set-aside facade + dim | No | None — read-only facade on existing MVs |
| **2** | Win 4: Wire dim labels into existing views | No | Low — facade view updates only |
| **3** | Win 3: Reason not competed | No | Low — new view + dim table only |
| **4** | Win 5: Commercial item classification | No | Low if view-only; medium if MV rebuild |
| **5** | Win 6: Parent company rollup | No | Medium — requires MV rebuild |

Wins 1-4 can all be deployed as a single migration with zero downtime.
Win 5 is independent. Win 6 needs a maintenance window for the MV refresh.

---

## Files to Create/Modify

### New Files

| File | Purpose |
|---|---|
| `sql/004_set_aside_facade.sql` | Set-aside facade views + dim |
| `sql/005_competition_enrichment.sql` | Reason not competed view + dim |
| `sql/006_label_enrichment.sql` | Updated facade views with dim JOINs |
| `sql/007_commercial_item.sql` | Commercial item dim + view |
| `sql/008_parent_company.sql` | Parent UEI MV rebuild + facade |

### Modified Files

| File | Changes |
|---|---|
| `catalog/datasets.yaml` | Add 8+ new dataset entries |
| `catalog/dimensions.yaml` | Add set_aside_codes, reason_not_competed, commercial_item |
| `docs/DATASETS.md` | Field definitions for new datasets |
| `docs/METHODOLOGY.md` | Package 6 section + enrichment notes |
| `docs/API_FUNCTIONS.md` | New package descriptions |
| `README.md` | Analysis Packages table + documentation links |

---

## What This Does NOT Include

- **Nothing from `v2` schema** — proprietary, stays behind the paywall
- **No contact-level PII** — contracting officer names/emails are excluded
- **No new MV builds from scratch** (except Win 6 rebuild) — we use what's
  already materialized
- **No new private schemas** — everything integrates into existing schemas or
  uses facade-only patterns
- **No PSC, office drill-down, duration, or recompete views** — those are
  Phase 2 and require new MVs built from scratch

---

## Success Criteria

After implementing all 6 wins:

- API goes from 5 packages / 22 datasets to **6 packages / 30+ datasets**
- Set-aside analysis becomes a first-class product surface
- Every API response includes human-readable labels alongside codes
- Competition dynamics explains WHY (not just whether) contracts are non-competed
- Commercial vs. traditional acquisition becomes visible
- Parent-company market share replaces fragmented subsidiary analysis

All of this uses data that is already in the database. No new data loads, no
new pipelines, no new infrastructure.
