# FPDS OS Analytics — Usability & Analytics Expansion Review

**Session type:** Read-only audit of github.com/KenosaConsulting/fpds-os-analytics, verified against the live deployment at analytics-api.kenosaconsulting.com (catalog version 2026-06-04, 53 datasets, 15 dimensions).
**Purpose:** Prioritized findings for delegation to coding agents. Part 1 = usability for non-technical users. Part 2 = creative/additive analytics. Part 3 = delegation task list with file pointers.

---

## PART 1 — USABILITY FINDINGS (PRIORITIZED)

### P0-1: The catalog advertises 24 filters the query builder rejects — 20 of 53 datasets are partially or fully broken (CONFIRMED IN PRODUCTION)

`app/query_builder.py` has a hardcoded `KNOWN_FILTERS` allowlist (17 names) that is checked **before** the per-dataset filter list. Every filter introduced in the Phase 2 builds is missing from it. Any user — or any AI assistant faithfully following `/v1/datasets/{id}` metadata — who applies a documented filter gets a 400.

Live reproduction (2026-06-10):

```
GET /v1/datasets/psc.trend_fy/rows?psc_group=services
→ {"error":{"code":"invalid_filter","message":"Filter 'psc_group' is not supported by the API."}}

GET /v1/datasets/customer.office_profile_fy/rows?contracting_office_id=W912DY
→ {"error":{"code":"invalid_filter","message":"Filter 'contracting_office_id' is not supported by the API."}}

GET /v1/datasets/pipeline.recompete_watchlist/rows?contracting_dept_id=7000&expiration_bucket=next_12_months
→ {"error":{"code":"invalid_filter","message":"Filter 'expiration_bucket' is not supported by the API."}}
```

Missing filters (all documented in `catalog/datasets.yaml`):
`contracting_office_id, expiration_bucket, funding_agency_id, funding_dept_id, is_8a, is_cross_department, is_hubzone, is_sdvosb, is_small_business, is_sole_source, is_statutory, metric_scope, pop_city, pop_county, pop_zip5, product_or_service_code, psc_group, reason_code, reason_family, recompete_confidence, set_aside_code, set_aside_family, vehicle_family, vendor_uei`

Affected datasets (20): customer.office_profile_fy, market.office_naics_fy, incumbent.agency_vendor_leaders, incumbent.office_vendor_leaders, incumbent.agency_naics_vendor_leaders, competition.not_competed_reasons_fy, set_aside.family_trend_fy, set_aside.agency_mix_fy, set_aside.office_profile_fy, set_aside.kpi_summary, psc.trend_fy, psc.agency_profile_fy, psc.office_profile_fy, psc.naics_crosswalk, acquisition.vehicle_trend_fy, acquisition.agency_vehicle_mix_fy, acquisition.office_vehicle_mix_fy, funding.mismatch_flows_fy, pipeline.recompete_watchlist, geography.place_profile_fy.

Practical impact: **all office-level analysis, all PSC filtering, all set-aside-code filtering, all vehicle-family filtering, funding-flow filtering, and the entire point of the recompete watchlist (filter by expiration window/confidence) are dead in production.**

Fix specification for the coding agent:

1. In `app/query_builder.py`, replace the static `KNOWN_FILTERS` check with a check derived from the catalog: the union of all `filters` lists across `catalog/datasets.yaml` and `catalog/dimensions.yaml` (build once at catalog load in `app/catalog.py`). Keep the per-dataset check as the real gate. The two-level check currently exists only to distinguish "not supported by the API" vs "not supported for this dataset" in error messages — preserve that distinction but source it from the catalog.
2. Extend boolean coercion. `build_where` only coerces `is_state, is_small_business_ever, is_in_state` to booleans. Generalize: treat any filter named `is_*` as boolean (or add a `filter_types` map to the catalog YAML — better long-term). Without this, `is_8a=true` will throw `operator does not exist: boolean = text` from Postgres even after the allowlist fix.
3. Verify each new filter maps to an actual column on its backing view (the filter name is used directly as the column identifier). `expiration_bucket` and `recompete_confidence` appear as fields on `pipeline.recompete_watchlist`, so direct equality works; spot-check the rest against the `sql/0XX_*.sql` view definitions.
4. **Add the missing contract test** in `tests/test_catalog_contract.py`: every filter declared in the catalog must be accepted by `build_rows_query` (i.e., produce SQL, not raise `invalid_filter`). This single test would have caught the entire P0. A second test: every `required_filters_any` entry must itself be an accepted filter.

### P0-2: Recompete watchlist surfaces expired contracts first

Live default query for DHS returned a contract with `remaining_months: -6`, `expiration_bucket: "recently_expired"` as the top row. The marquee "find expiring contracts before SAM.gov" dataset, queried naively, leads with already-expired awards — and the filter that would fix it (`expiration_bucket`) is rejected per P0-1. Fix: after P0-1, also change `default_sort` to ascending `remaining_months` (or add a default predicate `remaining_months >= 0` documented in the dataset entry, with `recently_expired` available opt-in). Non-technical users judge the product on the first unfiltered query.

### P1-1: Most datasets return bare FPDS codes with no names

`pricing.agency_profile_fy` returns `contracting_dept_id: "9700"` and nothing else identifying the customer. Same for all v1-era datasets (pricing, competition, concentration trend/profile, naics, geography). A non-technical user does not know 9700 = DoD, 3600 = VA, 7000 = DHS, and an AI assistant must make a second `/v1/dimensions/departments` call and join client-side — many won't.

The Phase 2 views already solve this (recompete_watchlist returns `contracting_dept_name`, `department_short_name`, `agency_short_name`, `naics_desc`, `psc_description`, `set_aside_label` — excellent). The fix is to backfill labels into the v1 views, which `sql/006_label_enrichment.sql` already establishes the pattern for. Two implementation options for the agent:

- **Option A (preferred):** Update each `analytics_api.*` facade view to LEFT JOIN the dim tables and add `*_name` / `*_short_name` columns; add those columns to `fields` in `catalog/datasets.yaml`.
- **Option B (API-layer):** A `labels=true` query param that joins dims in the API. More code, slower, less cacheable. Don't do this.

### P1-2: No name-to-code resolution ("Homeland Security" → 7000)

The dimensions support only exact-code and boolean filters — there is no `q=` / name-contains search on `departments`, `agencies`, `contracting_offices`, `naics`, or `psc_codes`. The contracting_offices dimension is ~14K rows; an assistant cannot reasonably page through it to find "CECOM." This is the single biggest barrier in the AI-mediated workflow your docs promote: every real user question starts with a name, and the API only speaks codes.

Recommendation: add a `q` parameter to dimension queries (`ILIKE '%' || q || '%'` against name columns, allowlisted per dimension in `catalog/dimensions.yaml`), or better, a single resolver endpoint:

```
GET /v1/resolve?q=homeland&types=departments,agencies,offices
→ ranked matches with id, name, type, parent
```

This requires extending the dimension query path (`app/routes/dimensions.py`) with one safe pattern-match clause — same parameterized approach as `build_where`, no SQL surface expansion. Also worth a `naics`/`psc` description search ("cybersecurity" → candidate NAICS/PSC codes), which converts capability statements directly into queryable codes.

### P1-3: Dataset metadata has no descriptions — QUICKSTART overpromises

QUICKSTART says describing a dataset "tells you what the dataset measures." It doesn't — the live describe response is id, title, filters, sortable, fields, caveats. No prose description, no field definitions, no example queries. Field names like `avg_hhi`, `not_competed_obligation_share_3yr`, `friendliness_rank` are opaque to non-specialists, and AI assistants produce noticeably better tool calls when given `description` + `use_when` + worked examples.

This is a pure-metadata fix — no DB work:

1. Add to each entry in `catalog/datasets.yaml`: `description` (2–3 sentences, what it measures and the analyst question it answers — the README package blurbs already contain this language), `example_queries` (1–2 fully-formed query strings with explanation), and optionally `field_descriptions` (map of field → one-liner; can start with only non-obvious fields like HHI, shares, ranks).
2. Pass them through `app/catalog.py:public_dataset` and the describe route.
3. Surface `description` in `/v1/catalog` list output so an assistant can pick the right dataset in one fetch instead of N describe calls.

### P1-4: Bad default sorts produce nonsense first pages

Confirmed live: `pricing.trend_fy` default sort is ascending `fiscal_year`, so the first page is 1958–196x rows including `total_obligated: "0.00"`. `geography.state_trend_fy` default (`-total_obligated`, no FY requirement) returns Virginia four times (2022–2025) — a mixed-year leaderboard that looks like duplicate data to a layperson. Fixes: flip trend datasets to `-fiscal_year`; for cross-year leaderboard datasets either add `required_filters_any: [fiscal_year, ...]` or define a documented default window (e.g., apply `fiscal_year_min = current - 10` when no FY filter supplied, and state it in `meta`). The catalog `defaults.order` is already `-fiscal_year` but individual datasets override it to ascending — likely unintentional.

### P1-5: `naics.growth_leaders` is dominated by tiny-base noise

Live top results: "PAGING" with growth from $9.90 → $110K (+11,158x) and "TREE NUT FARMING." A non-technical user asking "which industries are growing" gets statistical artifacts. Fix in the view (or as a default predicate): require a minimum prior-FY base (e.g., ≥ $10M) and/or rank by a blended score (growth rate × log of obligation change). Keep a `min_base` filter so power users can lower it. This is the kind of result that quietly destroys trust in the whole product.

### P2-1: Error messages should teach, not just reject

Current errors are good (clear code, param, request_id). Make them self-healing for AI assistants: on `invalid_filter`, include `allowed_filters` for that dataset in the error body; on `invalid_sort`, include `sortable`; on `missing_required_filter`, include an example query string. An LLM that receives the allowlist in the error recovers in one turn instead of giving up.

### P2-2: Ship the MCP server — it is the actual non-technical UX

`docs/LLM_INTEGRATIONS.md` already specifies the design (5 thin tools wrapping the safe endpoints). For your audience — capture and BD people living in Claude/ChatGPT — a one-click connector beats every documentation improvement on this list. Recommended additions to the planned design: bake the dataset descriptions (P1-3) into tool descriptions; include the resolver tool (P1-2) so the model can go name → code → query without manual dimension paging; return `meta.notices` so caveats propagate. A static `/.well-known/llms.txt` (flat-text catalog + usage rules) is a near-zero-cost complement for assistants that only fetch URLs.

### P2-3: Human-friendly output formats

`format=csv` on `/rows` (same bounds, `Content-Disposition` header) lets a non-technical user open results in Excel directly — currently the path from API to spreadsheet requires jq or code, which is exactly what this audience can't do. Cheap to add in `app/routes/datasets.py`. The Phase-2 `POST /v1/exports` plan can stay for large bounded exports; `format=csv` covers the everyday case.

### P2-4: Documentation drift guards

Beyond the P0 contract test: README/QUICKSTART claims and `openapi.yaml` should be generated or tested from the catalog. The existing `test_openapi_dataset_enum_matches_catalog` is the right pattern — extend it to filters and sort fields so the OpenAPI spec (which the ChatGPT Action will import) never advertises parameters the runtime rejects.

---

## PART 2 — ADDITIVE & OVERLAPPING ANALYTICS (EXPLORATORY)

Ordered roughly by (analyst value ÷ build cost), with notes on what each reuses.

### A. Composite profile endpoints (Customer 360 / Market 360 as API objects)

Your roadmap (`docs/ANALYST_VIEW_IMPROVEMENTS.md`) defines Customer 360 / Market 360 / Recompete Watch as composite *views*. Implement them instead as composite *endpoints* that fan out to existing datasets server-side:

```
GET /v1/profiles/customer?contracting_dept_id=7000
→ { spend_trend: [...], top_naics: [...], competition_posture: {...},
    pricing_posture: {...}, set_aside_mix: [...], top_incumbents: [...],
    vehicle_mix: [...], recompete_signals: [...], narrative_hints: [...] }
```

Zero new SQL — it's an orchestration layer over views you already have. For an AI assistant this collapses a 10-call workflow into 1 call, which is the difference between a usable and unusable agent experience under rate limits. Add a small `narrative_hints` array of rule-based plain-English findings ("87% of FY25 obligations were competed — above the federal average — this customer is accessible to new entrants") so even the no-AI user gets interpretation.

### B. Derived strategic scores (your differentiator vs. raw USAspending)

You already compute one composite (`pricing.risk_scorecard.risk_score`, `set_aside.agency_profile_fy.friendliness_rank`). Extend the pattern — each is a single new view over existing aggregates:

1. **Market Entry Difficulty Score** per agency×NAICS: weighted blend of HHI, not-competed obligation share, vehicle-dependence share (IDIQ/GWAC vs open market), avg offers received, and incumbent tenure. Answers the README's own question ("how hard will entry be?") with one number plus visible components.
2. **Incumbent Vulnerability Score** on the recompete watchlist: short tenure, declining obligations over the contract life, high mod count, small share of the agency's portfolio, expiring set-aside eligibility. Turns the watchlist from "what's expiring" into "what's *winnable*."
3. **New-Entrant Friendliness**: share of obligations going to vendors in their first 3 years at that agency (see C).

### C. Vendor cohort / new-entrant analytics (genuinely missing today)

Nothing in the current 53 datasets answers "can a newcomer actually break in?" with evidence. Using first-award detection per (agency, vendor) — first_active_year already exists in `concentration.vendor_market_leaders` — build:

- `entrants.agency_cohort_fy`: new vendors per agency per FY, their first-award sizes, and survival (still active +2 FYs).
- `entrants.naics_entry_paths`: what set-aside types, vehicles, and award sizes new entrants' first wins came through. This is directly actionable BD doctrine: "at CMS in 541511, first wins are overwhelmingly 8(a) sole-source under $1M via specific offices."

### D. Vendor momentum & displacement events

Year-over-year share change per vendor within agency×NAICS markets: who is gaining, who is bleeding. A specialized "displacement events" view — contract families where the follow-on went to a different vendor — is the strongest possible evidence that a market is contestable, and pairs naturally with the recompete watchlist (historical base rate of incumbent loss per agency/office/NAICS → empirical recompete-win odds).

### E. Fiscal seasonality / Q4 spike index

There is currently **no sub-year time grain anywhere in the API**. FPDS signed dates support obligation-by-fiscal-quarter (or month) per agency/office. The "use-it-or-lose-it" September spike is among the most tactically useful signals in GovCon — it tells a BD team *when* to be in front of which office, and which offices do disproportionate Q4 simplified-acquisition spending (fast-award opportunity windows). One new MV grain, big perceived sophistication gain.

### F. Award-size distribution & micro-purchase/SAT bands

Median/P25/P75 award size per agency×NAICS, plus share of actions under the simplified acquisition threshold and under micro-purchase. Tells a small business whether a customer is reachable through low-friction awards or only through large procurements. Complements the existing duration profile (size × duration = pipeline shape).

### G. Lookalike customers

Cosine similarity over agency (or office) NAICS/PSC spend vectors: "offices that buy like CMS OAGM." Pure derivation from the `market.agency_naics_fy` cross-tab you already have. For BD prospecting, this answers "where else should we run this play?" — the natural next question after every successful capture.

### H. Co-incumbency / teaming graph

Vendors that repeatedly co-occur at the same offices and NAICS markets. Prime-only data limits true teaming inference (no subcontract edges), so frame it honestly as "co-presence," but it still produces a credible teaming-target shortlist for any market a user is entering.

### I. `/v1/ask` — natural-language routing (long-horizon)

The LLM_INTEGRATIONS plan assumes the user brings their own assistant. A hosted `POST /v1/ask` that runs a small model to (1) resolve entities, (2) pick a dataset, (3) build a guarded query, (4) return rows + plain-English interpretation would make the product self-contained for non-technical users — and the strict catalog/allowlist design means the routing problem is unusually tractable (closed action space, no SQL generation). Natural place to make the API key tier worth paying for.

---

## PART 3 — DELEGATION TASK LIST FOR CODING AGENTS

### Sprint 1 — Restore the contract (P0)
1. `app/query_builder.py`: derive filter allowlist from catalog; generalize boolean coercion (`is_*` or typed catalog). Files: `app/query_builder.py`, `app/catalog.py`.
2. Verify each newly-enabled filter against its backing view's columns in `sql/004–017`.
3. `tests/test_catalog_contract.py`: add (a) every catalog filter builds valid SQL, (b) every `required_filters_any` member is an accepted filter, (c) every `default_sort` field is in `sortable`.
4. `catalog/datasets.yaml`: fix recompete watchlist default sort/predicate (P0-2); flip ascending-FY trend defaults to `-fiscal_year`; review all mixed-year leaderboard defaults (P1-4).

### Sprint 2 — Speak human (P1)
5. Label enrichment backfill into v1 facade views (names alongside codes), following the `sql/006` pattern; update `fields` lists. Files: new `sql/018_*.sql`, `catalog/datasets.yaml`.
6. Name search: `q=` on name-bearing dimensions or a `/v1/resolve` endpoint. Files: `app/routes/dimensions.py`, `catalog/dimensions.yaml`, query builder.
7. Catalog metadata: `description`, `example_queries`, `field_descriptions` per dataset; surface in catalog + describe responses; reuse README package prose. Files: `catalog/datasets.yaml`, `app/catalog.py`, `app/routes/catalog.py`.
8. `naics.growth_leaders` minimum-base threshold + optional `min_base` filter (view change or default predicate).
9. Self-healing errors: include allowed filters/sorts and an example query in 400 bodies. File: `app/query_builder.py` / `app/errors.py`.

### Sprint 3 — Distribution & product (P2 + analytics)
10. MCP server per `docs/LLM_INTEGRATIONS.md`, with resolver tool and metadata-rich tool descriptions.
11. `format=csv` on `/rows`.
12. Composite endpoint `GET /v1/profiles/customer` (orchestration only; no new SQL) — Customer 360 first, Market 360 second.
13. First new analytics builds, in value order: fiscal-quarter seasonality grain (E), new-entrant cohorts (C), market-entry difficulty score (B1), award-size distribution (F).
14. Exploratory spikes: lookalike-customer similarity (G); co-incumbency teaming graph (H).

### Notes for the agents
- Preserve the security boundary exactly as documented: allowlisted identifiers, parameterized values, bounded limits, facade-schema-only, read-only role. Every recommendation above fits inside it.
- The catalog YAML is the single source of truth — anything added to runtime behavior should be declared there and contract-tested, since the P0 in this report was precisely a runtime/catalog divergence with no test coverage.
- All live observations in this report were taken 2026-06-10 against catalog version 2026-06-04.
