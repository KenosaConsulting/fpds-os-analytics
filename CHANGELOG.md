# Changelog

All notable changes to the FPDS Analytics API are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses task-based versioning (FPDS-NNN) within development sprints.

---

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
