# Changelog

All notable changes to the FPDS Analytics API are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses task-based versioning (FPDS-NNN) within development sprints.

---

## [Sprint 5] — 2026-06-17 — Contracting Officer Analytics (FPDS-022)

Procurement contact analytics: who handles the contracts at each agency, office, and NAICS code.

### Added

- **FPDS-022 · CO Analytics** — Six new datasets in the `contacts` domain:
  `contacts.detail` (rich per-contact profiles), `contacts.office_roster` (who buys at each office),
  `contacts.profile_fy` (CO year-over-year activity), `contacts.naics_buyers` (who buys your NAICS),
  `contacts.recompete_handlers` (who handled expiring contracts), and `contacts.office_coverage`
  (human attribution share per office). Backed by three new materialized views:
  `mv_fpds_contact_office_fy` (1.6M rows), `mv_fpds_contact_naics_agency_fy` (12M rows),
  and `mv_fpds_contract_contacts` (69.3M rows).

- **Enhanced Recompete Watchlist** — `pipeline.recompete_watchlist` now includes 7 contact columns:
  `contact_creator_user_id`, `contact_creator_name`, `contact_creator_class`,
  `contact_creator_award_date`, `contact_approver_user_id`, `contact_approver_name`,
  `contact_approver_last_seen_fy`. Every expiring contract now shows who handled it.

- **Contact Directory** — `analytics_dims.fpds_procurement_contact` (189,784 entries:
  133,881 human, 468 system, 55,435 unknown). Classification via 42 pattern-matching rules.

---

## [Sprint 4] — 2026-06-12 — Vehicle-Level Analytics (partial)

Vehicle-program packaging work for FPDS-021 continued in repo and on the live
Supabase project. The catalog, resolver, docs, and dimension surface landed.
The main dataset/report-view migration is still blocked on missing normalized
Step-4 materialized views in production.

### Added

- **FPDS-021f · Vehicle Program View Template** — Added
  [sql/034_vehicle_program_views.sql](sql/034_vehicle_program_views.sql) with a
  program-summary view, report-deck views, three `analytics_api` facades, and
  reader grants. The template correctly targets the `_norm` Step-4 MVs only and
  intentionally fails rather than reading the stale non-`_norm` objects.

- **FPDS-021g · Catalog Metadata** — Added three dataset catalog entries:
  `acquisition.vehicle_program_usage_fy`,
  `acquisition.vehicle_program_summary`, and
  `acquisition.vehicle_program_vendors`, including example queries,
  required-filter discipline, recent-program defaults, and caveats for
  one-level referencing, MAS undercounting, and order-activity-vs-seat-holder
  interpretation.

- **FPDS-021h · Vehicle Programs Dimension** — Added
  [sql/035_vehicle_program_dimension.sql](sql/035_vehicle_program_dimension.sql),
  `catalog/dimensions.yaml` exposure for `vehicle_programs`, and MCP resolver
  support so `fpds_resolve` can search curated vehicle-program names.

### Verified

- `./.venv/bin/python -m pytest tests -q` green with **75 passing tests**.
- Supabase migration `035_vehicle_program_dimension` applied successfully to
  project `tfrhforjvaafmqmxmtrt`; verified `analytics_api.dim_vehicle_programs`
  columns, reader grant, and a bounded `LIMIT 5` smoke select.

### Blocked

- Supabase migration `034_vehicle_program_views` failed on project
  `tfrhforjvaafmqmxmtrt` with `ERROR: relation
  customer_intelligence.mv_fpds_vehicle_program_agency_fy_norm does not exist`.
  The repo now reflects the intended `_norm`-only surface, but the live dataset
  facades cannot deploy until the external refresh/build path creates the two
  normalized Step-4 materialized views.

## [Sprint 3] — 2026-06-10 — Distribution & New Analytics

The analytics platform grows from query tool to intelligence engine: four new
analytical datasets, an MCP server for AI assistants, a Customer 360 composite
endpoint, and CSV export support.

### Added

- **FPDS-014 · CSV Export** — `?format=csv` on any row query. Same bounded
  result, streamed as `text/csv` with `Content-Disposition`. JSON remains the
  default. ([app/routes/datasets.py](app/routes/datasets.py))

- **FPDS-015 · MCP Server** — Standalone stdio Model Context Protocol server
  with 7 tools: `fpds_list_datasets`, `fpds_describe_dataset`,
  `fpds_query_dataset`, `fpds_list_dimensions`, `fpds_lookup_dimension`,
  `fpds_resolve`, and `fpds_customer_profile`. Delegates all guardrails to the
  REST API. Works with Claude Desktop, Cursor, VS Code, and any MCP client.
  ([mcp/](mcp/))

- **FPDS-016 · Customer 360 Profile** —
  `GET /v1/profiles/customer?contracting_dept_id=` assembles spend trend, top
  NAICS, competition posture, pricing posture, set-aside mix, top incumbents,
  vehicle mix, and recompete signals from existing datasets. Orchestration only
  — no new SQL. Partial-failure tolerant with section-level status and
  narrative hints. ([app/routes/profiles.py](app/routes/profiles.py))

- **FPDS-017 · Fiscal Seasonality** — Two new materialized views
  (`mv_fpds_agency_month_seasonality` at 31,966 rows,
  `mv_fpds_office_quarter_seasonality` at 191,651 rows) showing when agencies
  and offices obligate funds across the fiscal year. Includes Q4 obligation
  share with NULL policy for deobligation-heavy entity-years. Build time:
  ~32 min per MV. ([sql/026_fiscal_seasonality.sql](sql/026_fiscal_seasonality.sql))

- **FPDS-018 · New-Entrant Cohorts** — First-award year per vendor × agency,
  new-vendor counts per FY, first-win size, set-aside and vehicle of first win,
  and 2-fiscal-year survival rates.
  ([sql/023_new_entrant_cohorts.sql](sql/023_new_entrant_cohorts.sql))

- **FPDS-019 · Market Entry Difficulty Score** — Composite score per
  agency × NAICS blending HHI concentration, not-competed share, vehicle
  dependence, average offers received, and incumbent tenure. All component
  values exposed alongside the composite. Methodology documented.
  ([sql/025_market_entry_difficulty_score.sql](sql/025_market_entry_difficulty_score.sql))

- **FPDS-020 · Award-Size Distribution** — Median, P25, and P75 award sizes
  per agency × NAICS with under-SAT (simplified acquisition threshold) share.
  ([sql/024_award_size_distribution.sql](sql/024_award_size_distribution.sql))

### Stats

- **7 tasks completed** in Sprint 3
- **4 new analytical datasets** (seasonality, entrants, difficulty, award size)
- **1 MCP server** (7 tools for AI integration)
- **1 composite endpoint** (Customer 360)
- **1 new export format** (CSV)

---

## [Sprint 2] — 2026-06-10 — Speak Human

The API stops speaking in codes and starts speaking in names. Every dataset
gets human-readable labels, descriptions, example queries, and self-documenting
error messages.

### Added

- **FPDS-008 · Label Enrichment** — Human-readable `*_name` and
  `*_short_name` columns added alongside coded IDs on pricing, competition,
  concentration, and NAICS datasets. No more guessing what `9700` means.
  ([sql/020_v1_label_enrichment_append.sql](sql/020_v1_label_enrichment_append.sql))

- **FPDS-009 · Name Search / Resolver** — `q=` substring search on
  departments, agencies, contracting offices, NAICS, and PSC dimensions.
  Office search defaults to active-recent high/medium confidence records.
  Parameterized `ILIKE` only.

- **FPDS-010 · Catalog Descriptions & Examples** — Every dataset now has a
  2–3 sentence description, at least one working example query with
  explanation, and field descriptions for non-obvious fields (HHI, shares,
  ranks). Surfaced in `/v1/catalog` and `/v1/datasets/{id}`.

- **FPDS-013 · Freshness Metadata** — Per-dataset `meta.data_as_of` in row
  responses, sourced from a refresh-log table with graceful null fallback.
  ([sql/022_dataset_refresh_log.sql](sql/022_dataset_refresh_log.sql))

### Changed

- **FPDS-011 · Growth Leaders Rewrite** — Now compares the two most recent
  *complete* fiscal years (no more YTD-vs-full-year bias). Default $10M
  prior-year floor with a documented filter to lower it. Zero/negative base
  rows handled explicitly.
  ([sql/021_rewrite_naics_growth_leaders_complete_fy.sql](sql/021_rewrite_naics_growth_leaders_complete_fy.sql))

- **FPDS-012 · Self-Healing Errors** — `invalid_filter` errors now include
  `allowed_filters`; `invalid_sort` includes `sortable`; `missing_required_filter`
  includes an `example_query`. Error schema documented in OpenAPI.

### Stats

- **6 tasks completed** in Sprint 2
- **All 58 datasets** now have descriptions and example queries
- **Name search** works across 5 dimension types
- **Every error** tells you how to fix it

---

## [Sprint 1] — 2026-06-10 — Restore the API Contract

Foundation work: fix broken filters, add contract tests, align catalog metadata
with what the database actually has, and make the first unfiltered page of
every dataset show useful recent data.

### Fixed

- **FPDS-001 · Dynamic Filter Allowlist** — Replaced static `KNOWN_FILTERS`
  with a catalog-derived union allowlist. All 24 previously rejected filters
  now accepted on their datasets.

- **FPDS-002 · Boolean Filter Coercion** — Any `is_*` filter now correctly
  coerces `true/false/1/0/yes/no` inputs to boolean. Non-boolean filters
  unaffected.

- **FPDS-003 · NAICS Customer Leaders `sector_code`** — Added missing
  `sector_code` column to the backing view (was declared in catalog but absent
  from SQL). Applied as Supabase migration.
  ([sql/018_fix_naics_customer_leaders_sector_code.sql](sql/018_fix_naics_customer_leaders_sector_code.sql))

- **FPDS-006 · Default Sort Order** — All trend datasets now default to
  `-fiscal_year` (most recent first). No dataset's first unfiltered page leads
  with pre-2010 rows anymore.

### Added

- **FPDS-004 · Contract Tests** — New test suite validates catalog ↔ runtime
  parity: every catalog filter builds valid SQL, every `required_filters_any`
  member is accepted, every `default_sort` field is in `sortable`, every
  filter/sortable maps to a declared field. Catches FPDS-003-class bugs
  automatically. ([tests/test_catalog_contract.py](tests/test_catalog_contract.py))

- **FPDS-005 · Recompete Watchlist Defaults** — Default sort is ascending
  `remaining_months` (soonest expiration first). Excludes `recently_expired`
  rows by default (40% of rows) unless `expiration_bucket` filter is
  explicitly supplied.

- **FPDS-007 · MV Index Templates** — Index templates for newly enabled
  filters on vendor concentration, NAICS, pricing, and competition MVs.
  ([sql/019_new_filter_mv_indexes.sql](sql/019_new_filter_mv_indexes.sql))

### Stats

- **7 tasks completed** in Sprint 1
- **24 broken filters** restored
- **67 contract tests** guarding catalog ↔ runtime alignment
- **5 MV indexes** added for query performance

---

## [Pre-Sprint] — 2026-06-02 — Initial Release

- Core API with 44 datasets across 9 analysis packages
- Catalog-driven query builder with allowlisted filters, sorts, and fields
- Parameterized queries only — no arbitrary SQL surface
- Read-only `fpds_analytics_api_readonly` role, facade schema separation
- OpenAPI 3.1 specification
- AI assistant guide endpoint
- Analyst workflow documentation
- 67-test guardrail suite
- Dockerized deployment
- MIT License

## [Sprint 7] — 2026-06-24 — API User Management + Usability (in progress)

### S7-014 — API Limitation Quick Wins (done, 2026-06-24)

Resolved 9 backlog items from the S7-012b cross-cutting test findings. 10 new
tests added (88 total, all passing). 3 commits: `50c129e`, `82728b6`, `d43ff6c`.

**Critical fix:**

- **BL-014 — Public row limit raised 25 → 100.** `APIAccess.max_rows_per_request`
  was hardcoded to 25, ignoring the existing `public_row_limit()` function (which
  returns 100 via `FPDS_ANALYTICS_PUBLIC_ROW_LIMIT` env var). The catalog declares
  `max_limit: 500–1000`, but the override mechanism clamped to 25 before the query
  builder saw it. Fixed in `app/auth.py` (uses `field(default_factory=public_row_limit)`)
  and `app/routes/health.py` (calls `public_row_limit()` instead of hardcoded 25).
  This was the root cause of 6 of 12 S7-012b test query failures.

**Misattributions (were BL-014, not real bugs):**

- **BL-015 — Documented filters rejected.** All 9 flagged filters (`is_in_state`,
  `fiscal_year_min/max`, `is_cross_department`, `user_class`) and 3 sort params
  work correctly. The 400 errors were `limit_too_large` from BL-014, misattributed
  to the filter. Regression tests added.

- **BL-017 — `fields` projection rejected.** The `fields` parameter works correctly
  with sort + filter. Same root cause as BL-015. Regression test added.

**Data quality fixes:**

- **BL-024 — `sector_label` null.** All 1,722 rows in `fpds_naics_hierarchy_map`
  had `sector_code` populated but `sector_label` NULL. Fixed via SQL migration
  [sql/060_bl024_populate_sector_labels.sql](sql/060_bl024_populate_sector_labels.sql).
  Affects `psc.naics_crosswalk`, `market.naics_customer_leaders`, `naics.growth_leaders`.

- **BL-013 — `agency_short_name` null.** 120 of 371 agencies (up from 59) and 17
  departments now have short names. Major civilian agencies (USDA, EPA, GSA, NASA,
  DOE, HHS, HUD, DOJ, State, DOT, DHS, ED, USAID, SBA, NSF, NRC, etc.) all populated.
  Via SQL migration [sql/061_bl013_populate_agency_short_names.sql](sql/061_bl013_populate_agency_short_names.sql).

- **BL-021 — `data_as_of` timestamp.** 79 `dataset_refresh_log` entries populated
  (table existed but was empty). `data_as_of` now returns real timestamps in API
  responses.

- **BL-022 — Negative obligations.** Rows with negative obligation values
  (de-obligations) are now flagged with `_negative_obligation: true`. Response
  meta includes `negative_obligation_count` when any negative rows are present.
  Prevents misleading share calculations.

- **BL-023 — `source_fiscal_years` hardcoded.** Was `[1958, 2026]` on every
  response. Now computed from actual returned rows. `null` when the dataset has
  no `fiscal_year` column.

**Resolver fix:**

- **BL-016/BL-012 — `fpds_resolve` fails for numeric codes.** Code columns
  (`naics_code`, `psc_code`, `department_id`, `agency_id`) added to
  `searchable_columns` in `catalog/dimensions.yaml`. Resolver now matches
  numeric/alphanumeric codes, not just description text.

### S7-011 — MCP Inspector Validation (done)

Validated all 8 MCP tools via direct JSON-RPC stdio protocol test (14 checks).
13/14 passed; 1 apparent failure was a test-harness key mismatch, not a server
bug — the `fpds_customer_profile` response wraps sections under `data.*`
(9 sections: spend_trend, top_naics, competition_posture, pricing_posture,
set_aside_mix, top_incumbents, vehicle_mix, recompete_signals, narrative_hints),
not top-level `sections`. Server returns correct structure.

**Tools validated:**
- `fpds_list_datasets` (79 datasets, domain filter works)
- `fpds_describe_dataset` (returns filters, fields, examples, caveats)
- `fpds_query_dataset` (rows + filters + pagination params)
- `fpds_list_dimensions` (17 dimensions)
- `fpds_lookup_dimension` (q=search works)
- `fpds_resolve` (7-type cross-dimension search)
- `fpds_customer_profile` (9 sections for VA dept 3600)
- `fpds_topic_search` (cybersecurity → 5 matches across 2 sections)

**Protocol checks:**
- `initialize` handshake → server info returned
- `notifications/initialized` → no response (correct)
- `ping` → pong
- `tools/list` → 8 tools
- Unknown tool → JSON-RPC error -32601
- Missing required param → error surfaced

**Test harness:** `/tmp/mcp-s7-011-test.py` (re-runnable)

### S7-013 — UEI→vendor name audit (done)

Audited all 79 datasets for UEI exposure. 7 views expose UEI variants; 6 already
had `vendor_name`. 1 gap: `incumbent.agency_naics_vendor_leaders`.

Fix: sql/059 creates `analytics_dims.vendor_name_by_uei` (materialized lookup,
561,261 rows, 4 source tables unioned). Facade view recreated with LEFT JOIN.

Performance: v1 inline UNION made queries 66+ seconds; v2 materialized lookup
brings latency to 216ms (309× speedup).

Coverage: 99.998% (476,487 of 476,496 rows have vendor_name; 9 rows with
unresolved UEIs).

Catalog updated: `vendor_name` added to `incumbent.agency_naics_vendor_leaders`
fields list.

Pending: Render redeploy for live API to expose `vendor_name` in responses.
