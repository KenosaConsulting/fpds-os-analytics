# Scope: Vehicle-Level Analytics (FPDS-021) — REVISED

**Date:** 2026-06-10 (v2, supersedes v1)
**Status:** Pending approval
**Priority:** Critical — fills the "which vehicle" gap in capture strategy
**Revision driver:** Production cardinality check invalidated v1's core design assumption (see "What Changed and Why").

---

## What Changed and Why (v1 → v2)

v1 assumed ~13,700 distinct vehicles based on `pg_stats` n_distinct for `ref_piid`. A capped
exact count (loose index scan) against production found **>1,200,000 distinct ref_piids** —
the sampled estimate was off by ~100x, and the discrepancy reveals a structural fact:

**A `ref_piid` is not a vehicle. It is one vendor's individual contract under a program.**
Every GSA MAS holder has their own GS-35F schedule contract. OASIS comprises hundreds of
awardee contracts across pools. Every multiple-award IDIQ scatters into one PIID per awardee.

Consequences for v1's design:

1. A PIID-keyed "vehicle directory" would have 1.2M+ rows, almost none of which are what a
   human means by "vehicle."
2. v1's flagship example — search "OASIS" → `ref_piid = GS00Q14OADS128` → sum its spend —
   returns **one awardee's** OASIS contract and understates the program by ~100x.
3. MV A at ref_piid grain would be tens of millions of mostly-singleton rows, not 500K–2M.

**v2 therefore makes `vehicle_program` the primary analytical key, with `ref_piid` as the
child grain.** This produces smaller, faster MVs; answers the questions users actually ask
(program-level); and — because each child PIID belongs to exactly one vendor — the PIID-grain
table becomes a **vehicle seat-holder / order-winner asset**, which v1 did not attempt and
which is half the capture value.

---

## The Problem (unchanged)

The API answers "does this agency use GWACs, Schedules, or IDIQs?" but cannot answer **which
specific vehicles**. A contractor preparing capture strategy needs:

- "Do I need to be on OASIS to compete for this agency's IT work?"
- "What percentage of Navy engineering goes through SeaPort-NxG?"
- "Which agencies are the heaviest SEWP V users?"
- "Who actually holds and wins on this vehicle — and am I one of them?"  *(new in v2)*

## The Data We Have (corrected)

`public.fpds_actions` (98.7M rows) vehicle-identity columns:

| Column | Content | Notes |
|---|---|---|
| `ref_piid` | Parent contract number (vendor's contract under a program) | Indexed (`idx_fpds_actions_ref_piid`) |
| `ref_agency_id` / `ref_agency_id_name` | Agency that owns/administers the referenced contract | Dirty in places — derive per-PIID owner by majority vote, not first-seen |
| `referenced_type_desc` | `IDC` 42.9%, `BPA` 8.1%, `FSS` 7.2%, `BOA` 2.7%, `GWAC` 0.6%; ~38.5% null (open market / standalone) | |

**Verified:** >1.2M distinct ref_piids (exact census is Build Step 0). ~137 owning agencies.

**Known limitation to document as a caveat:** FPDS carries one level of referencing. A
delivery order against a BPA that itself sits under a Schedule shows only the immediate
parent. Also, FPDS reveals order *activity* — vehicle holders with a seat but zero orders are
invisible. For capture purposes the order-winner list is arguably the more useful one; the
caveat text must say which list this is.

---

## What We'd Build

### 1. Program Registry — the primary key of the package

**Table:** `analytics_dims.fpds_vehicle_program` (~100–300 rows, curated)

| Column | Notes |
|---|---|
| `program_id` | text PK, slug (e.g., `oasis_unrestricted`, `sewp_v`, `gsa_mas`, `seaport_nxg`) |
| `program_name` / `program_short_name` | Human names |
| `program_family` | GWAC / IDIQ / Schedule / BPA / BOA |
| `owning_agency_id` / `owning_agency_name` | Administrator |
| `is_governmentwide` | boolean |
| `successor_program_id` | nullable — links generations (OASIS → OASIS+, CIO-SP3 → CIO-SP4) |
| `notes`, `name_source` | provenance |

**Table:** `analytics_dims.fpds_vehicle_program_pattern` (curated match rules)

| Column | Notes |
|---|---|
| `program_id` | FK |
| `piid_pattern` | SQL LIKE / regex pattern (e.g., `GS00Q14OADS%`, `NNG15SD%`) |
| `ref_agency_id` | optional additional constraint to avoid false matches |
| `priority` | tie-break when patterns overlap |

Curation effort is the same 4–8 hours as v1's Tier 1, but produces pattern *rules* instead of
per-PIID names — easier to write and it scales to every awardee contract automatically.

### 2. Contract (PIID) Directory — the child grain and the seat-holder asset

**Table:** `analytics_dims.fpds_vehicle_contract` (~1.2M+ rows; office-dim pattern at scale)

| Column | Source |
|---|---|
| `ref_piid` | PK |
| `program_id` | nullable FK — pattern match where one applies |
| `vehicle_type` | majority `referenced_type_desc` across the PIID's actions |
| `owning_agency_id` / `owning_agency_name` | **majority vote** across actions |
| `primary_vendor_uei` / `vendor_name` | the awardee whose orders reference this PIID (majority; flag multi-vendor anomalies) |
| `derived_label` | `{owning_agency_short} {vehicle_type} ({ref_piid})` for unmatched PIIDs |
| `total_obligations`, `total_orders`, `distinct_using_agencies`, `first_order_fy`, `last_order_fy`, `is_active_recent` | aggregated |

Unmatched PIIDs roll up in analytics as pseudo-programs (`{owning_agency} {vehicle_type}`),
so 100% of referenced spend is always attributable to *something* — no silent gaps.

### 3. Materialized Views

**MV A: Program × Agency × FY** — `customer_intelligence.mv_fpds_vehicle_program_agency_fy`
Grain: `program_id` (or pseudo-program) × `contracting_dept_id` × `contracting_agency_id` ×
`fiscal_year`. Measures: obligated_amount, action_count, distinct_vendor_count,
competed/not_competed action counts, **avg_offers_received**, small_biz_obligated.
Estimated rows: low hundreds of thousands. Build: full source scan, ~30–45 min
(seasonality-proven pattern; nohup + session pooler, never MCP apply).

**MV B: Program × Vendor × FY** — `customer_intelligence.mv_fpds_vehicle_program_vendor_fy`
*(new in v2 — the seat/winner layer.)* Grain: program_id × vendor UEI × FY. Measures:
obligated_amount, order count, distinct customer agencies. Answers "who wins on OASIS, how
much, and is their share growing." Built in the same source pass as MV A if practical.

**MV C: Program Summary** — one row per program + pseudo-program: lifetime obligations,
orders, distinct using depts/agencies, distinct winning vendors, first/last FY,
is_active_recent. Derived from MV A/B; trivial.

### 4. API Datasets

| Dataset ID | Grain | Question answered |
|---|---|---|
| `acquisition.vehicle_program_usage_fy` | program × agency × FY | "Which vehicles does this agency use, how much, how competitive?" |
| `acquisition.vehicle_program_summary` | program | "Rank vehicles by spend, reach, vendor count" (default `is_active_recent=true`) |
| `acquisition.vehicle_program_vendors` | program × vendor × FY | "Who holds/wins on this vehicle?" |

Dimension exposure: `GET /v1/dimensions/vehicle_programs` with `q=` name search;
`GET /v1/dimensions/vehicle_contracts` filterable by `program_id`, `primary_vendor_uei`,
`ref_piid` (required-filter rule applies — never unfiltered at 1.2M rows).
`fpds_resolve` gains `types=["vehicle_programs"]`.

Required filters on `vehicle_program_usage_fy` and `vehicle_program_vendors`: at least one of
program_id / dept / agency. All defaults follow the post-audit discipline: recent-first,
active-first, no graveyard data on page one.

**Corrected example flow:**

```bash
GET /v1/dimensions/vehicle_programs?q=OASIS
# → program_id = oasis_small_business (the PROGRAM, not one awardee's PIID)
GET /v1/datasets/acquisition.vehicle_program_usage_fy/rows?program_id=oasis_small_business&fiscal_year=2025&sort=-obligated_amount
GET /v1/datasets/acquisition.vehicle_program_vendors/rows?program_id=oasis_small_business&fiscal_year=2025&sort=-obligated_amount&limit=25
```

### 5. Name Enrichment (revised tiers)

- **Tier 1 — pattern rules (curated):** ~100–300 programs covering the large majority of
  referenced dollars. Sources: GSA.gov, agency acquisition portals, BD community knowledge.
- **Tier 2 — FPDS ATOM harvest: ⚠️ SCHEDULE-CRITICAL.** The ATOM feed retires ~June 30, 2026
  — three weeks away. Harvest IDV records (`descriptionOfContractRequirement`) for the top
  ~2,000 ref_piids by obligations **this month, before anything else is built**; store raw XML
  so parsing/classification can happen later at leisure. SAM.gov Contract Awards v1 API is the
  degraded fallback. Tier-2 names carry `name_source='fpds_atom'` and never masquerade as
  curated.
- **Tier 3 — derived labels:** programmatic `{agency} {type} ({piid})` for the long tail.
  At 1.2M rows this is a column expression, not a backfill project.

### 6. Recompete Integration (phased honestly)

"3 OASIS task orders worth $45M expiring in 12 months" is the killer cross-feature. It
requires a vehicle reference on `pipeline_intelligence.mv_contract_family`. **Build Step 0
must check whether that MV already carries an IDV/ref PIID column.** If yes: add
`program_id` joins at the report-view level — cheap, in scope. If no: it requires rebuilding
a 69M-row / 18 GB MV — explicitly **Phase 2**, scheduled like the seasonality build, not
smuggled into this scope.

---

## Build Plan (resequenced)

| Step | What | Est. | Notes |
|---|---|---|---|
| 0 | Exact ref_piid census; check mv_contract_family for IDV column | 30 min | Sizing + Phase-2 decision |
| 1 | **ATOM Tier-2 raw harvest (top ~2,000 PIIDs)** | 2–3 hrs | **Run before June 30 — calendar-locked** |
| 2 | Curate program registry + pattern rules | 4–8 hrs | Parallel with 1 |
| 3 | SQL templates: program + pattern + contract tables | 2 hrs | Contract table is a heavy build (source scan) |
| 4 | MV A + MV B build (nohup/psql path, sequential) | ~35–60 min wall | Same protocol as FPDS-017 |
| 5 | MV C, report views, facades, grants, indexes | <10 min | |
| 6 | Catalog entries (descriptions, examples, caveats incl. one-level-referencing + activity-vs-seat) + contract tests | 1.5 hrs | |
| 7 | Dimension endpoints + resolver type | 1 hr | |
| 8 | Tier-2 parse/classify from harvested XML; Tier-3 label fill | 2–3 hrs | After launch is fine — raw data already saved by Step 1 |
| 9 | README + CHANGELOG | 30 min | |

**Total:** ~14–19 hrs development + ~1 hr MV build wall-clock. Heavy statements follow the
FPDS-017 lesson: direct/session-pooler psql with `statement_timeout=0`, never MCP
`apply_migration`.

## What This Unlocks

**Before:** "The Army uses GWACs for 12% of IT spending."
**After:** "Army IT flows $2.1B through OASIS, $890M through Alliant 2, $340M through SEWP V.
OASIS orders average 4.2 offers vs 2.1 on Alliant 2 — and here are the 25 vendors winning
OASIS work at this agency, with your absence from that list as the capture gap."

## Follow-on Ideas (recorded, not in scope)

1. Named-vehicle component in the FPDS-019 Market Entry Difficulty Score ("62% of this market
   flows through closed-on-ramp programs").
2. Vendor vehicle-whitespace profile (`/v1/profiles/vehicle-strategy?uei=`): programs a vendor
   wins on vs programs carrying the demand they chase — the gap is the teaming/on-ramp list.
3. Program migration tracking via `successor_program_id`: YoY share shifts catch
   OASIS→OASIS+ / CIO-SP3 transition turbulence while capture windows are open.
4. Competition-quality ranking per program (avg offers, not-competed share within program):
   competitive vehicles vs captive ones — whether a seat is worth the proposal cost.

## Risks & Mitigations (revised)

| Risk | Mitigation |
|---|---|
| ATOM feed retires before harvest | Step 1 is calendar-locked to this month; raw XML stored, parsing deferred |
| Pattern rules mis-assign PIIDs to programs | `ref_agency_id` constraint + priority on patterns; spot-check top 50 programs against known totals; `name_source` provenance everywhere |
| Contract-table build heavier than estimated | Same proven path as seasonality (nohup psql, sequential); 1.2M-row output is modest |
| Unmatched long tail looks like missing data | Pseudo-program rollups guarantee 100% attribution; caveats explain derived labels |
| mv_contract_family lacks IDV column | Recompete linkage explicitly Phase 2 — no scope creep |
| Multi-vendor anomalies on a single ref_piid | Flag in contract table; exclude from `primary_vendor_uei` confidence |

## Security (unchanged)

Same boundary: curated dims + MVs in existing schemas, `analytics_api` facades,
`fpds_analytics_api_readonly` SELECT grants, `public.fpds_actions` read at build time only,
no new roles, no PII.

---

*v2 awaiting Chairman approval. On approval: Step 1 (ATOM harvest) starts immediately given
the June 30 deadline; remaining steps enter TASKS.md as FPDS-021a–021i.*
