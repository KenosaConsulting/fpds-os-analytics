# Analytics Schema Design Notes

This document sketches the database design needed to support the analyst-facing
view roadmap in `docs/ANALYST_VIEW_IMPROVEMENTS.md`.

This is a design note, not a migration. The live API boundary should remain:

- Raw or source FPDS data stays private.
- Enriched dimensions live in `analytics_dims`.
- Domain-specific aggregates live in private analytics schemas.
- Public API relations are exposed only through curated `analytics_api` facade
  views.
- The API role receives `USAGE` and `SELECT` only on `analytics_api`.

Supabase/Postgres note: views created by privileged roles can bypass underlying
RLS unless they are security-invoker views or protected by schema grants. The
current repository protects the API by keeping source schemas ungranted and
exposing only the `analytics_api` facade. Continue that pattern. If any facade
view is placed in an exposed Supabase schema, prefer `security_invoker = true`
where compatible and continue revoking direct grants from `anon` and
`authenticated`.

## Current Pattern

The existing API uses this shape:

```text
internal analytics schema
  -> report_deck_* view or materialized view
  -> analytics_api.* facade view
  -> FastAPI catalog entry
  -> bounded API response
```

Dimensions use:

```text
analytics_dims.fpds_*_map
  -> analytics_api.dim_*
  -> catalog/dimensions.yaml
```

The next schema work should keep those two paths separate:

- `analytics_dims` stores code maps, labels, hierarchies, normalized names, and
  confidence-scored crosswalks.
- Domain schemas store aggregate facts and analyst-ready materialized views.

## Proposed Private Schemas

Keep schemas coarse enough to be navigable, but separated by analyst domain.

| Schema | Purpose |
|---|---|
| `customer_intelligence` | Contracting offices, agency/office profiles, funding vs contracting flows. |
| `market_demand` | Agency x NAICS and office x NAICS market sizing. |
| `small_business` | Set-aside and socioeconomic program mix. |
| `incumbent_analysis` | Vendor leaders, incumbency indicators, customer/vendor tenure. |
| `pipeline_intelligence` | Recompete candidates, expiration windows, duration profiles. |
| `acquisition_path` | Vehicle, IDV, BPA, schedule, and open-market access path mix. |
| `psc_analysis` | PSC trend, customer profiles, and PSC x NAICS overlap. |
| `geo_drilldown` | City, ZIP, county, metro, and installation candidate rollups. |

Do not grant the API role access to these schemas. They should feed facade
views only.

## V1 Schema Consolidation Recommendation

The full schema map above is useful for thinking through the product domains,
but it is too many new schemas for the first implementation. Start with fewer
private schemas and integrate related work into the existing analytics domains
until the logic is large enough to justify a split.

| Proposed schema | What it does | V1 recommendation |
|---|---|---|
| `customer_intelligence` | Holds agency, bureau, contracting-office, and funding-vs-contracting customer views. | **Create new.** There is no current customer/office schema, and office-level intelligence is a core analyst domain. |
| `market_demand` | Holds agency x NAICS, office x NAICS, and broader market-sizing cross-tabs. | **Do not create yet.** Put NAICS-heavy cross-tabs in existing `naics_breakdown`; split later only if market sizing expands across NAICS, PSC, offices, geography, and composite pages. |
| `small_business` | Holds set-aside mix and socioeconomic program analysis. | **Probably do not create yet.** Start in `competition_dynamics` or `vendor_concentration`; split only if small-business strategy becomes a major product surface. |
| `incumbent_analysis` | Holds customer-specific vendor leaders, tenure, concentration, and likely-incumbent signals. | **Do not create yet.** Start in existing `vendor_concentration`; split only if incumbency becomes award-family based and substantially more complex. |
| `pipeline_intelligence` | Holds recompete candidates, expiration windows, duration profiles, and renewal cadence. | **Create new.** Recompete timing is a distinct lifecycle domain and does not fit the current schemas cleanly. |
| `acquisition_path` | Holds vehicle, IDV, GWAC, BPA, GSA Schedule, and open-market access-path mix. | **Maybe later.** Start in `competition_dynamics` if the first version is simple; split once vehicle normalization and curated vehicle mapping become substantial. |
| `psc_analysis` | Holds PSC trends, agency PSC profiles, and PSC x NAICS overlap. | **Create only if PSC becomes first-class.** PSC is parallel to NAICS and deserves a clear home if it becomes a formal API package. |
| `geo_drilldown` | Holds city, ZIP, county, metro, installation, and place-of-performance drilldowns. | **Do not create yet.** Extend existing `geographic_analysis`; split only if installation normalization becomes a large curated layer. |

The cleaner initial schema set is:

```text
analytics_dims
analytics_api

contract_pricing
vendor_concentration
competition_dynamics
naics_breakdown
geographic_analysis

customer_intelligence      -- new
pipeline_intelligence      -- new
psc_analysis               -- optional new schema if PSC becomes first-class
```

Near-term placement:

- `naics_breakdown`: `market.agency_naics_fy`, `market.office_naics_fy`,
  `market.naics_customer_leaders`.
- `vendor_concentration`: `incumbent.agency_vendor_leaders`,
  `incumbent.office_vendor_leaders`, `incumbent.agency_naics_vendor_leaders`.
- `competition_dynamics`: set-aside mix and simple acquisition-path views.
- `geographic_analysis`: city, metro, ZIP, and place-of-performance drilldowns.
- `customer_intelligence`: office profiles, customer rollups, and
  funding-vs-contracting mismatch views.
- `pipeline_intelligence`: recompete watchlists and duration/cadence profiles.
- `psc_analysis`: PSC views only if PSC is promoted to a full analysis package.

This approach avoids schema sprawl while still creating homes for genuinely new
concepts: office/customer intelligence and recompete timing. `analytics_dims`
remains the shared semantic layer for all of them.

## `analytics_dims` Additions

`analytics_dims` should become the shared semantic layer. It should not contain
large fact tables. It should contain small to medium mapping tables that make
the analyst views interpretable.

### Agency And Office Dimensions

#### `analytics_dims.fpds_department_map`

Purpose: stable labels and rollups for FPDS contracting and funding department
codes.

Suggested columns:

- `department_id text primary key`
- `department_name text not null`
- `department_short_name text`
- `cabinet_level_group text`
- `is_dod boolean`
- `is_active boolean`
- `sort_order integer`
- `notes text`
- `source_updated_at timestamptz`

#### `analytics_dims.fpds_agency_map`

Purpose: agency/bureau labels and parent department mapping.

Suggested columns:

- `agency_id text primary key`
- `agency_name text not null`
- `agency_short_name text`
- `parent_department_id text`
- `agency_family text`
- `is_active boolean`
- `sort_order integer`
- `notes text`
- `source_updated_at timestamptz`

#### `analytics_dims.fpds_contracting_office_map`

Purpose: normalized contracting-office labels and parent agency context.

Suggested columns:

- `contracting_office_id text primary key`
- `contracting_office_name text`
- `normalized_office_name text`
- `contracting_agency_id text`
- `contracting_dept_id text`
- `office_family text`
- `office_type text`
- `city text`
- `state_code text`
- `country_code text`
- `first_observed_fy integer`
- `last_observed_fy integer`
- `is_active_recent boolean`
- `name_confidence text`
- `notes text`
- `source_updated_at timestamptz`

Design notes:

- Office names drift. Treat code as the stable key and name as descriptive.
- Keep `name_confidence` because office normalization will be imperfect.
- Do not hide offices with unknown names; expose code-first rows.

### Work Classification Dimensions

#### `analytics_dims.fpds_psc_map`

Purpose: PSC labels, category rollups, and service/product classification.

Suggested columns:

- `psc_code text primary key`
- `psc_description text`
- `psc_group_code text`
- `psc_group_label text`
- `psc_category text`
- `is_service boolean`
- `is_product boolean`
- `is_r_and_d boolean`
- `sort_order integer`
- `notes text`
- `source_updated_at timestamptz`

#### `analytics_dims.fpds_set_aside_map`

Purpose: set-aside and socioeconomic labels.

Suggested columns:

- `set_aside_code text primary key`
- `set_aside_description text`
- `set_aside_family text`
- `socioeconomic_program text`
- `is_small_business boolean`
- `is_8a boolean`
- `is_wosb boolean`
- `is_edwosb boolean`
- `is_hubzone boolean`
- `is_sdvosb boolean`
- `is_vosb boolean`
- `is_unrestricted boolean`
- `sort_order integer`
- `notes text`
- `source_updated_at timestamptz`

Design notes:

- Keep both code and description.
- Preserve unknown, blank, and not-applicable values as explicit rows.
- Do not infer socioeconomic status solely from vendor attributes; distinguish
  award set-aside coding from vendor eligibility.

#### `analytics_dims.fpds_award_type_map`

Purpose: human-readable labels for award, modification, and contract-action
types used in duration and recompete logic.

Suggested columns:

- `award_type_code text primary key`
- `award_type_description text`
- `award_type_family text`
- `is_idv boolean`
- `is_order boolean`
- `is_definitive_contract boolean`
- `is_modification boolean`
- `is_grant_like boolean`
- `sort_order integer`
- `notes text`

### Acquisition Path Dimensions

#### `analytics_dims.fpds_idv_type_map`

Purpose: normalize IDV/GWAC/BPA/schedule/open-market categories.

Suggested columns:

- `idv_type_code text primary key`
- `idv_type_description text`
- `vehicle_family text`
- `is_gwac boolean`
- `is_bpa boolean`
- `is_idiq boolean`
- `is_gsa_schedule boolean`
- `is_open_market boolean`
- `sort_order integer`
- `notes text`

#### `analytics_dims.fpds_vehicle_map`

Purpose: curated vehicle names and aliases for major contract vehicles.

Suggested columns:

- `vehicle_key text primary key`
- `vehicle_name text not null`
- `vehicle_family text`
- `managing_agency_id text`
- `common_aliases text[]`
- `match_pattern text`
- `match_confidence text`
- `is_active boolean`
- `notes text`
- `source_updated_at timestamptz`

Design notes:

- Vehicle mapping will be partly heuristic. Store confidence and notes.
- Start with reliable IDV fields; add curated aliases only where they are
  defensible.

### Vendor And Entity Dimensions

#### `analytics_dims.fpds_vendor_identity_map`

Purpose: normalized vendor display names and durable UEI-centered identity.

Suggested columns:

- `vendor_uei text primary key`
- `vendor_name text`
- `normalized_vendor_name text`
- `parent_vendor_key text`
- `is_small_business_ever boolean`
- `first_observed_fy integer`
- `last_observed_fy integer`
- `is_active_recent boolean`
- `name_confidence text`
- `notes text`
- `source_updated_at timestamptz`

Design notes:

- UEI should remain the public key where possible.
- Parent-company rollups should be confidence-scored and optional. Do not merge
  vendors silently.

### Geography Dimensions

#### `analytics_dims.fpds_place_map`

Purpose: normalize place-of-performance city/state/ZIP/country strings into
analyst-friendly geography labels.

Suggested columns:

- `place_key text primary key`
- `pop_country_code text`
- `pop_state_code text`
- `pop_city text`
- `pop_zip text`
- `county_name text`
- `metro_area text`
- `is_domestic boolean`
- `is_military_postal boolean`
- `geo_confidence text`
- `notes text`

#### `analytics_dims.installation_candidate_map`

Purpose: optional curated map from place fields to likely military/base or
installation names.

Suggested columns:

- `installation_key text primary key`
- `installation_name text`
- `service_branch text`
- `pop_state_code text`
- `pop_city text`
- `pop_zip text`
- `match_pattern text`
- `match_confidence text`
- `notes text`

Design notes:

- Installation mapping should never be presented as ground truth.
- Expose confidence labels in any API view that uses this table.

## First-Pass Aggregate Objects

The first build should favor materialized views for repeatability and API
performance. Names below are suggestions; final names should reflect the live
source schema conventions.

### `market_demand.mv_agency_naics_fy`

Grain:

- `contracting_dept_id`
- `contracting_agency_id`
- `principal_naics_code`
- `fiscal_year`

Metrics:

- `total_action_count`
- `total_obligated`
- `contract_scope_obligated`
- `distinct_vendor_count`
- `small_business_obligated`
- `small_business_obligation_share`
- `not_competed_obligated`
- `not_competed_obligation_share`
- `avg_offers_received`
- `avg_award_obligated`

Recommended indexes:

- `(contracting_agency_id, principal_naics_code, fiscal_year)`
- `(principal_naics_code, fiscal_year)`
- `(contracting_dept_id, fiscal_year)`

Facade view:

- `analytics_api.market_agency_naics_fy`

### `customer_intelligence.mv_office_profile_fy`

Grain:

- `contracting_office_id`
- `fiscal_year`

Metrics:

- Office and parent agency labels from `analytics_dims`
- `total_action_count`
- `total_obligated`
- `distinct_vendor_count`
- `distinct_naics_count`
- `distinct_psc_count`
- `small_business_obligation_share`
- `not_competed_obligation_share`
- `avg_offers_received`
- `top_naics_code_by_obligation`
- `top_psc_code_by_obligation`
- `top_vendor_uei_by_obligation`

Recommended indexes:

- `(contracting_office_id, fiscal_year)`
- `(contracting_agency_id, fiscal_year)`
- `(contracting_dept_id, fiscal_year)`

Facade view:

- `analytics_api.customer_office_profile_fy`

### `small_business.mv_set_aside_mix_fy`

Grain:

- `contracting_agency_id`
- `principal_naics_code`
- `set_aside_code`
- `fiscal_year`

Metrics:

- `total_action_count`
- `total_obligated`
- `distinct_vendor_count`
- `new_vendor_count`
- `avg_offers_received`
- `set_aside_obligation_share_of_agency_naics`
- `top_vendor_uei`
- `top_vendor_obligation_share`

Recommended indexes:

- `(contracting_agency_id, principal_naics_code, fiscal_year)`
- `(set_aside_code, fiscal_year)`

Facade view:

- `analytics_api.small_business_set_aside_mix_fy`

### `incumbent_analysis.mv_agency_vendor_leaders`

Grain:

- `contracting_agency_id`
- `principal_naics_code`
- `vendor_uei`

Metrics:

- `vendor_name`
- `total_obligated`
- `total_action_count`
- `recent_3yr_obligated`
- `first_active_fy`
- `last_active_fy`
- `active_fy_count`
- `estimated_tenure_years`
- `market_obligation_share`
- `top_contracting_office_id`
- `top_psc_code`
- `likely_incumbent_score`

Recommended indexes:

- `(contracting_agency_id, principal_naics_code, recent_3yr_obligated desc)`
- `(vendor_uei)`
- `(last_active_fy)`

Facade view:

- `analytics_api.incumbent_agency_vendor_leaders`

### `pipeline_intelligence.mv_recompete_candidates`

Grain:

- Contract-family or award-level key.

Candidate fields:

- `contract_family_key`
- `award_id_piid`
- `parent_award_id_piid`
- `contracting_agency_id`
- `contracting_office_id`
- `vendor_uei`
- `principal_naics_code`
- `psc_code`
- `set_aside_code`
- `period_of_performance_start_date`
- `period_of_performance_current_end_date`
- `last_obligation_date`
- `total_obligated`
- `recent_12mo_obligated`
- `remaining_months`
- `expiration_bucket`
- `recompete_confidence`
- `confidence_notes`

Recommended indexes:

- `(period_of_performance_current_end_date)`
- `(contracting_agency_id, period_of_performance_current_end_date)`
- `(principal_naics_code, period_of_performance_current_end_date)`
- `(vendor_uei)`

Facade view:

- `analytics_api.pipeline_recompete_watchlist`

Design notes:

- Treat expiration as a signal, not a promised recompete date.
- Use confidence buckets such as `high`, `medium`, `low`, and `insufficient`.
- Avoid exposing raw modification noise; group by contract family where
  possible.

### `acquisition_path.mv_agency_vehicle_mix_fy`

Grain:

- `contracting_agency_id`
- `principal_naics_code`
- `vehicle_key` or `vehicle_family`
- `fiscal_year`

Metrics:

- `total_action_count`
- `total_obligated`
- `vehicle_obligation_share`
- `distinct_vendor_count`
- `top_vendor_uei`
- `not_competed_obligation_share`
- `small_business_obligation_share`

Recommended indexes:

- `(contracting_agency_id, principal_naics_code, fiscal_year)`
- `(vehicle_key, fiscal_year)`
- `(vehicle_family, fiscal_year)`

Facade view:

- `analytics_api.acquisition_agency_vehicle_mix_fy`

### `psc_analysis.mv_agency_psc_fy`

Grain:

- `contracting_agency_id`
- `psc_code`
- `fiscal_year`

Metrics:

- `total_action_count`
- `total_obligated`
- `distinct_vendor_count`
- `top_vendor_uei`
- `top_naics_code`
- `not_competed_obligation_share`
- `small_business_obligation_share`

Recommended indexes:

- `(contracting_agency_id, psc_code, fiscal_year)`
- `(psc_code, fiscal_year)`

Facade view:

- `analytics_api.psc_agency_profile_fy`

## Facade View Conventions

Facade views should:

- Live in `analytics_api`.
- Select explicit columns rather than `SELECT *` once schemas stabilize.
- Use stable public names even if internal materialized views change.
- Include only analyst-safe fields.
- Avoid raw descriptions if they contain sensitive, low-value, or noisy text.
- Carry confidence and caveat fields for derived signals.

Example pattern:

```sql
CREATE OR REPLACE VIEW analytics_api.market_agency_naics_fy
WITH (security_barrier = true) AS
SELECT
    contracting_dept_id,
    contracting_agency_id,
    principal_naics_code,
    fiscal_year,
    total_action_count,
    total_obligated,
    distinct_vendor_count,
    small_business_obligation_share,
    not_competed_obligation_share,
    avg_offers_received
FROM market_demand.mv_agency_naics_fy;
```

If these views are ever exposed directly through Supabase APIs using `anon` or
`authenticated`, revisit the view security posture and use `security_invoker`
where appropriate.

## Catalog Additions

Every new facade view needs two catalog updates:

1. `catalog/datasets.yaml` for row datasets.
2. `catalog/dimensions.yaml` for dimensions.

Initial dataset catalog entries should require narrowing filters for
high-cardinality views:

- Office-level views: require `contracting_office_id`,
  `contracting_agency_id`, `contracting_dept_id`, or a fiscal-year range.
- Vendor-leader views: require customer, NAICS, or vendor filters.
- Recompete views: require date window plus at least one market/customer filter.
- Place-level views: require geography, customer, NAICS, PSC, or fiscal-year
  filters.

## Public Dimension Facade Additions

Add these public dimension views after the backing `analytics_dims` tables
exist:

| Dimension ID | Facade View | Backing Table |
|---|---|---|
| `departments` | `analytics_api.dim_departments` | `analytics_dims.fpds_department_map` |
| `agencies` | `analytics_api.dim_agencies` | `analytics_dims.fpds_agency_map` |
| `contracting_offices` | `analytics_api.dim_contracting_offices` | `analytics_dims.fpds_contracting_office_map` |
| `psc_codes` | `analytics_api.dim_psc_codes` | `analytics_dims.fpds_psc_map` |
| `set_aside_codes` | `analytics_api.dim_set_aside_codes` | `analytics_dims.fpds_set_aside_map` |
| `award_type_codes` | `analytics_api.dim_award_type_codes` | `analytics_dims.fpds_award_type_map` |
| `idv_type_codes` | `analytics_api.dim_idv_type_codes` | `analytics_dims.fpds_idv_type_map` |
| `vehicles` | `analytics_api.dim_vehicles` | `analytics_dims.fpds_vehicle_map` |
| `vendors` | `analytics_api.dim_vendors` | `analytics_dims.fpds_vendor_identity_map` |
| `places` | `analytics_api.dim_places` | `analytics_dims.fpds_place_map` |
| `installation_candidates` | `analytics_api.dim_installation_candidates` | `analytics_dims.installation_candidate_map` |

Dimension endpoints should stay bounded and filterable. For large dimensions
such as vendors and contracting offices, require a code, search term, parent
agency, or recent-activity filter before returning broad results.

## Recommended Build Order

### Step 1: Semantic Dimensions

Create or backfill these first:

1. `fpds_department_map`
2. `fpds_agency_map`
3. `fpds_contracting_office_map`
4. `fpds_psc_map`
5. `fpds_set_aside_map`
6. `fpds_vendor_identity_map`

These unlock most Tier 1 analyst views.

### Step 2: Market And Customer Aggregates

Build:

1. `market_demand.mv_agency_naics_fy`
2. `customer_intelligence.mv_office_profile_fy`
3. `small_business.mv_set_aside_mix_fy`
4. `incumbent_analysis.mv_agency_vendor_leaders`

### Step 3: Public Facade And Catalog

For each aggregate:

1. Create `analytics_api` facade view.
2. Add `catalog/datasets.yaml` entry.
3. Add tests for catalog count, OpenAPI enum, required filters, and generated
   SQL relation names.
4. Add documentation in `docs/DATASETS.md` and `docs/API_FUNCTIONS.md`.

### Step 4: Timing And Access Path

Build:

1. `pipeline_intelligence.mv_recompete_candidates`
2. `acquisition_path.mv_agency_vehicle_mix_fy`
3. `psc_analysis.mv_agency_psc_fy`
4. Duration profile views.

## Open Design Questions

- What is the canonical award-family key for recompete grouping?
- Which FPDS fields should determine open market vs. vehicle-driven awards?
- How should we normalize common vehicle names without overfitting to known
  examples?
- Should vendor parent-company rollups be included in public views, or kept as a
  private enrichment until confidence improves?
- Which office hierarchy is reliable enough to expose: office to agency only,
  or office to bureau/command/subcomponent?
- What minimum row counts should be required before displaying office-level and
  installation-level metrics?
- Should high-cardinality dimensions support text search in this API, or should
  search live in a separate product surface?

## Guardrails

- Keep `analytics_dims` private to the API role; expose only `analytics_api.dim_*`.
- Keep source and domain schemas private to the API role.
- Use explicit grants and smoke-test failed access to raw schemas after each
  migration.
- Use confidence labels for derived dimensions and pipeline signals.
- Do not present expiration dates as guaranteed recompetes.
- Do not expose arbitrary raw award rows as a substitute for analyst views.
- Keep row limits and required filters stricter for high-cardinality views.
