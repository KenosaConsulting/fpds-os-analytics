# FPDS Analytics Utility Audit

**Date:** 2026-07-13
**Scope:** Code, database, MCP server, catalog, documentation
**Lens:** LLM ease of use, user friendliness, sophistication of insights, interconnectivity

---

## Session Progress

### Session 1: 2026-07-13 — Audit + Code Integration (COMPLETE)

**Completed:**
- Full codebase and database audit → 35 findings across 9 themes
- Keyword graph integrated natively (5 tools: search, analytics, vs-topic, compare, vendor_profile)
- Catalog YAML enriched: `query_pattern`, `grain_keys`, `department_code_format`, `joins_to` on all 90 datasets
- Department code auto-crosswalk (3-digit ↔ 4-digit) in query builder
- Vendor profile + topic profile composite tools (API endpoints + MCP)
- JSON-RPC dispatch consolidated (stdio delegates to FPDSServer)
- MCP tool updates: `q` param on list_datasets, dynamic catalog resources, keyword guidance
- User testing findings documented (Theme 8)
- Keywords graph reassessment documented (Theme 9)

**Deploy:** `7beb953` + hotfix `e18e735` (removed stale chat import)

### Session 2: 2026-07-14 — Code-Only + Light Data Items (COMPLETE)

**Completed:**
- `_trend_classification` (growing/stable/declining/baseline) on dataset rows with FY data
- YTD notice when current FY appears in results + `source_fiscal_years` metadata in describe_dataset
- `filter_name` and `field_name` params on `list_datasets` for targeted discovery
- `related` datasets field on 10 key catalog entries (drill-down siblings, cross-domain complements)
- `canonical_topic_mapping` dimension (9,313 rows) — bridges canonical ↔ local topic IDs
- `fpds_health` MCP tool (no auth)
- `fpds_vendor_compare` MCP tool + `/v1/profiles/vendors/compare` endpoint (auth required)
- 8 skills from `skills/` exposed as MCP prompts
- Inline dataset listing trimmed from `fpds_query_dataset` tool description
- `parent_department_id` caveat added to agencies dimension
- Pre-existing YAML indentation bug fixed in dimensions.yaml

**Blocked:**
- `contacts.recompete_handlers` UEI column — source MV `mv_fpds_contract_contacts` has no UEI column. Requires MV modification (medium data work).

**Deploy:** `1a9a110`

### Remaining Work (for future sessions)

**Medium Data Work (view alters, MV rebuilds):**
- D.2 Obligation field naming — 50+ view ALTER statements, 3-phase approach
- D.3 / BL-007 FY/NAICS filters — modify 7 source views, 1 MV redesign
- D.4 / BL-010 SDVOSB flags — rebuild 2 MVs, update 4 views
- 8.1.2 Topic crosswalk — done (canonical_topic_mapping dimension created), but `topics.lineage` view still broken

**Heavy Data Work (new MVs):**
- 8.1.4 Vendor-level PSC dataset — new MV: vendor × PSC × agency × FY
- 8.1.3 Parent-company rollup — curate parent-UEI lookup (sql/008 migration exists)

---

## Executive Summary

FPDS Analytics is a mature, well-architected procurement intelligence platform. The MCP server works correctly, the data pipeline is sound, and the catalog-driven API design is forward-thinking. This audit identifies **7 themes** with **29 findings** prioritized by impact on the LLM+user experience.

Top-line: The platform excels at *vertical* analysis (deep dive into one domain) but struggles with *horizontal* analysis (cross-domain joins, multi-hop queries). The biggest opportunities are (1) exposing dataset relationships, (2) aligning code/naming conventions across domains, and (3) reducing context overhead for LLM navigation.

---

## Theme 1: Discovery & Navigation

How well can an LLM find the right dataset and understand what it does?

### 1.1 Domain-only dataset filtering is too coarse

**Finding:** `fpds_list_datasets` only accepts a `domain` filter. If the LLM wants "all datasets with `principal_naics_code` as a filter" or "all datasets at `contracting_dept_id × fiscal_year` grain", it must iterate through all 88+ datasets. There is no ability to filter by filter name, field name, grain, or access tier.

**Impact:** LLMs waste context scanning irrelevant datasets. A simple query like "show me everything at the NAICS grain" requires tool-call loops or catalog pre-loading.

**Recommendation:** Add optional filters `filter_name`, `field_name`, `grain_field`, `access_tier` to `fpds_list_datasets`. This is a catalog-only change — no DB work needed.

---

### 1.2 Tool descriptions bloat LLM context

**Finding:** `fpds_query_dataset`'s description injects the domain summary AND the full dataset listing (~3KB+ of text). The LLM sees this every time `tools/list` is called. While the domain summary is useful, the full dataset listing is rarely actionable without first calling `fpds_list_datasets` or `fpds_describe_dataset`.

**Impact:** 3-5KB of context consumed on every tool list refresh. Over many turns, this crowds out actual data.

**Recommendation:** Keep the domain summary in the tool description. Move the dataset listing to `fpds_list_datasets`'s description only. Add a note: "Call `fpds_list_datasets` to see all dataset IDs and descriptions." This saves ~2KB per context refresh.

---

### 1.3 No semantic dataset search

**Finding:** The LLM must binary-search through domain categories. If a user asks "what dataset tells me about vendor diversity at an agency?", the LLM has to guess domain ("concentration"? "incumbent"? "competition"?) and iterate. There is no fuzzy/embedding-based dataset matching.

**Impact:** Users with non-technical questions hit a domain-guessing game. The LLM sometimes picks the wrong domain and wastes turns.

**Recommendation:** Add `q` parameter to `fpds_list_datasets` that does a substring match on `description` + `title` fields in the catalog. Simple, zero-infra, immediate improvement. Future: add embedding-based semantic search over dataset descriptions.

---

### 1.4 `fpds_describe_dataset` doesn't show related datasets

**Finding:** When the LLM inspects a dataset, it gets filters, fields, sort options, and caveats — but no hints about what datasets relate to this one. For example, when looking at `pipeline.recompete_watchlist`, the LLM should know `contacts.recompete_handlers` and `pipeline.duration_profile` are siblings, and that `pipeline.contract_transactions` is the drill-down.

**Impact:** The LLM must infer relationships from field names. It often misses the drill-down or cross-domain connection that would produce a better answer.

**Recommendation:** Add an optional `related` field to the catalog schema with related dataset IDs. Expose it in `fpds_describe_dataset` responses. Keep it curated — start with the obvious chains documented in the pre-built prompts.

---

### 1.5 `fpds_onboarding` is a static text block

**Finding:** The onboarding guide (`_onboarding_guide()`) is a hardcoded string with domain descriptions, workflow patterns, and dataset examples. It doesn't reflect live catalog data — if datasets are added, renamed, or removed, the guide goes stale.

**Impact:** Users get a polished but potentially inaccurate introduction. The guide also duplicates information from the catalog.

**Recommendation:** Generate the onboarding guide dynamically from the catalog (domain counts, dataset examples, filter counts). Keep the narrative framing static, but make data references live.

---

## Theme 2: Interoperability & Cross-Domain Joins

How well can datasets be combined to answer multi-hop questions?

### 2.1 No join metadata — the LLM must infer relationships from field names

**Finding:** The catalog doesn't declare foreign-key relationships between datasets. The LLM infers that `contracting_dept_id` in `pricing.agency_profile_fy` matches the same field in `competition.sole_source_hotspots`, but this is heuristic. There's no explicit join path, no hint about which column is the "primary key" of a dataset's grain.

**Impact:** Multi-hop queries (e.g., "find agencies with high pricing risk AND low competition") require the LLM to guess join columns. When field names differ across domains (e.g., `contracting_dept_id` vs `department_id` vs `department_code`), the join is structurally invisible.

**Recommendation:** Add a `grain_keys` field to each dataset catalog entry, listing the columns that form the dataset's unique key. Add a `joins_to` optional field listing related datasets and the join column mapping. This is metadata-only — no DB changes.

Example:
```yaml
grain_keys: [contracting_dept_id, fiscal_year]
joins_to:
  - dataset: pricing.risk_scorecard
    on: {contracting_dept_id: contracting_dept_id}
```

---

### 2.2 Department code format inconsistency across domains

**Finding:** Datasets use two different department code formats:
- **4-digit FPDS** (e.g., `9700` for DoD, `3600` for VA) — used in most analytics datasets
- **3-digit USASpending CGAC** (e.g., `097` for DoD, `036` for VA) — used in topic intelligence datasets and some dimension lookups

The `fpds_resolve` tool can find both, but `fpds_lookup_dimension` on `departments` returns 4-digit codes. When the LLM gets a 4-digit code and passes it to `topics.catalog` (which expects 3-digit), the query silently returns empty or no results.

**Impact:** THE most common LLM failure mode observed in testing (BL-008). The LLM doesn't know which format each dataset expects, and the error is silent — no "invalid department code" message, just zero rows.

**Recommendation:** 
1. Add `department_code_format` to the catalog: `"fpds_4digit"` or `"usaspending_3digit"` per dataset.
2. Add automatic cross-walking in the query builder: when a filter value matches a known 4-digit code but the dataset expects 3-digit, auto-translate via `analytics_dims.usaspending_fpds_dept_crosswalk`.
3. Alternatively, normalize ALL datasets to accept both formats and resolve internally.

---

### 2.3 Obligation field naming is inconsistent across datasets

**Finding:** Money fields have different names depending on the dataset:
- `total_obligated`
- `total_obligated_amount`  
- `net_obligated_amount`
- `obligated_amount`
- `total_obligated_3yr`
- `not_competed_obligated_3yr`

The LLM must read field descriptions for each dataset to know which field to sum/sort on.

**Impact:** Cross-dataset comparisons ("was this 3-year obligation higher than last year's single-year obligation?") are error-prone. The LLM sometimes picks the wrong obligation field and produces incorrect comparisons.

**Recommendation:** Standardize obligation field naming across the catalog. Adopt a convention like:
- `obligated_amount` — single period (year, quarter, month)
- `obligated_amount_3yr` — rolling 3-year
- `lifetime_obligated` — all-time

This is a view-rename exercise, not a data change.

---

### 2.4 NAICS granularity varies across datasets

**Finding:** Some datasets expose `principal_naics_code` (6-digit), others expose `sector_code` (2-digit NAICS sector), `naics_group` (4-digit), or `subsector_code`. The LLM doesn't know which to use for a given question without trial and error.

**Impact:** A user asking "who buys in IT services?" might get 6-digit NAICS results from one dataset and 2-digit sector results from another, with no clear bridge.

**Recommendation:** Expose `naics_granularity` in the catalog per dataset: `"sector"`, `"subsector"`, `"group"`, `"code"`. This lets the LLM know when to use `naics_prefix` to bridge granularity gaps.

---

### 2.5 Missing FY filter on cross-temporal datasets blocks comparison

**Finding:** Several datasets (BL-008, `topics.competitive_landscape`, `topics.govwide_canonical`, etc.) lack a `fiscal_year` filter. Their data spans all time, making it impossible to isolate "current market share" vs "historic dominance."

**Impact:** Competitive analysis is mixed-signal — a vendor with massive FY2010 obligations looks dominant even if they haven't won anything since FY2020.

**Recommendation:** Add `fiscal_year` / `fiscal_year_min` / `fiscal_year_max` filters to every dataset where the underlying MV has a date or FY column. Audit the 100 analytics_api views for this gap.

---

## Theme 3: Tool Coverage & Parity

What MCP tools exist vs what the data could support?

### 3.1 No `fpds_vendor_profile` tool

**Finding:** The API has a vendor profile concept in the `orchestrate_capture` workflow, and the data to build one exists: vendor market leaders, incumbent tenure, cross-agency footprint, NAICS concentration, small business status. But there is no MCP tool to get a vendor profile by UEI in one call.

**Impact:** "Tell me about Lockheed" requires 4-6 separate tool calls across concentration, incumbent, and market datasets. Every LLM session reinvents this assembly.

**Recommendation:** Add `fpds_vendor_profile` tool (or a `/v1/profiles/vendor` endpoint) that aggregates the same value as `fpds_customer_profile` but for a vendor UEI. Sections: summary stats, agency footprint, NAICS concentration, competitive positioning, recent wins, recompete exposure.

---

### 3.2 No `fpds_topic_profile` tool

**Finding:** Topic intelligence is powerful but requires navigating 6 separate dataset queries (catalog → agency profile → trends → competitive → NAICS decomp → document links). The `discover_what_agency_actually_buys` prompt does this, but there's no single tool.

**Impact:** Topic analysis is the most context-intensive workflow — 6+ dataset queries with interleaved filtering. Most LLM sessions time out or hit context limits before completing the full chain.

**Recommendation:** Add `fpds_topic_profile` as a composite tool that runs the topic intelligence chain for a department code and returns the synthesized result. Build it as a server-side aggregation (like `fpds_customer_profile`).

---

### 3.3 Missing MCP tools for existing API endpoints

**Finding:** The following API endpoints exist but have no MCP tool exposure:
- `/v1/profiles/customer` (exposed as `fpds_customer_profile` — OK)
- No `/v1/profiles/vendor` endpoint exists
- No composite topic endpoint exists
- `/v1/dimensions/` — list endpoint exists but returns all 17 at once; no paginated browse
- `/v1/health` — not exposed as MCP tool (useful for LLM to verify connectivity)

**Recommendation:** Audit API route coverage against MCP tool coverage. Any API endpoint that returns analytics should have an MCP tool. The health endpoint as an MCP tool lets the LLM self-diagnose connectivity issues.

---

### 3.4 `fpds_resolve` is powerful but fragile

**Finding:** `fpds_resolve` searches 7+ dimensions in parallel and returns a large nested structure. But:
- It searches agencies AND departments, often returning the same entity under both types
- It doesn't weight results by relevance
- The LLM must parse a deeply nested JSON structure to extract codes

**Impact:** High context consumption. A resolve for "Army" returns 20+ results across departments, agencies, offices, and sometimes topics — the LLM must filter client-side.

**Recommendation:** Add a `top_k` parameter that limits results per type. Add a relevance score (simple substring match length ratio). Deduplicate results where the same ID appears in multiple types.

---

### 3.5 No tool for `fpds_contract_transactions` drill-down context

**Finding:** `fpds_contract_history` maps to `pipeline.contract_transactions` and returns raw transaction rows. But the LLM has no tool to get context about what modification reason codes mean, what contract action types imply, or how to interpret the obligation deltas.

**Impact:** The LLM gets raw modification data but can't interpret it without looking up the dimension codes separately.

**Recommendation:** Include dimension code labels inline in the contract history response (join `analytics_dims.fpds_modification_reason_map` and `analytics_dims.fpds_action_type_map` at query time), OR add a "show label" parameter.

---

## Theme 4: Context Efficiency

How efficiently do the MCP tools use the LLM's context window?

### 4.1 Dataset row responses are verbose

**Finding:** Every `fpds_query_dataset` response includes `notice`, `data`, `pagination`, and `meta` (with notices, caveats, version, data_as_of, row_count, access tier). For small queries (5-10 rows), the metadata wrapper can be larger than the actual data.

**Impact:** When the LLM queries multiple datasets, metadata accumulates. 10 dataset queries = 10 copies of the same global notices.

**Recommendation:** Move global notices to a session-level cache (return once per session, let the LLM know they're persistent). Optionally add a `compact=true` parameter that strips meta when the calling tool already has context.

---

### 4.2 Duplicate JSON-RPC dispatch logic

**Finding:** The MCP server has two JSON-RPC message handlers:
- `mcp/fpds_mcp_server.py::handle_message()` — used by the standalone stdio server
- `app/routes/mcp.py::_handle_message()` — used by the HTTP remote endpoint

Both handle `initialize`, `tools/list`, `tools/call`, `prompts/*`, `resources/*` with essentially the same logic. The standalone server also has its own `call_tool()` method on `FPDSServer`, while the HTTP route delegates to it.

**Impact:** Bug fixes must be applied in two places. The standalone server doesn't support lazy authentication (its `handle_message` has no auth check), meaning the stdio mode can query protected datasets without a key.

**Recommendation:** Consolidate both handlers to use `FPDSServer` exclusively. The stdio server's `handle_message` should delegate to `FPDSServer` methods the same way the HTTP route does. This also fixes the auth gap in stdio mode.

---

### 4.3 Prompt templates are static and don't reference live catalog data

**Finding:** The 8 pre-built prompts are hardcoded string templates in `_prompt_*` methods. They reference specific dataset names and filter patterns that may change.

**Impact:** If a dataset is renamed or a filter is added, the prompts don't reflect it. An LLM following a prompt may try a non-existent filter.

**Recommendation:** Generate prompt references to dataset IDs and filters from the catalog at runtime. Keep the narrative structure static, but resolve dataset references dynamically.

---

### 4.4 No tool output truncation or summary mode

**Finding:** The MCP tools return full JSON payloads. For a `fpds_query_dataset` with `limit=100` and 15 fields, the response can exceed 50KB. The LLM must process every field even if it only needs 3.

**Impact:** Context window consumption scales linearly with query size. Multi-dataset analyses become impossible within a single session.

**Recommendation:** Add a `fields` parameter to all MCP tools (already exists on `fpds_query_dataset` — but the LLM often forgets to use it). Add automatic truncation when response size exceeds a threshold, with a "show more" hint.

---

## Theme 5: Data Normalization & Consistency

How consistent is the data model across domains?

### 5.1 Agency vs Department vs Office hierarchy is unclear to the LLM

**Finding:** The data has a three-level hierarchy (department → agency → office), but:
- Some datasets use `contracting_dept_id`, others use `contracting_agency_id`
- The `fpds_customer_profile` tool accepts both, but the relationship isn't exposed
- There's no tool to "get all agencies under department X"

**Impact:** The LLM can't easily navigate the hierarchy. "Show me all Navy components" requires a separate dimension lookup.

**Recommendation:** Add a `parent` relationship to the dimensions catalog. Expose it via `fpds_lookup_dimension` with `filters={parent_department_id: "9700"}`. Add a `fpds_agency_tree` tool that returns the full parent-child hierarchy for a department.

---

### 5.2 UEI → vendor name join is opaque

**Finding:** S7-013 fixed the UEI → vendor name gap by creating `analytics_dims.vendor_name_by_uei` (561K rows) and joining it into 6 views. But the LLM doesn't know this join exists. When a dataset returns a `uei` without a `vendor_name`, the LLM assumes the name is unavailable.

**Impact:** The LLM can't self-serve vendor name enrichment for datasets that don't carry the name field.

**Recommendation:** Add a note in the catalog metadata: "Datasets exposing `uei` without `vendor_name` can be enriched via the vendor_name_by_uei lookup." Better: ensure ALL datasets that expose UEI also expose vendor_name.

---

### 5.3 Socioeconomic flag inconsistency

**Finding:** Some datasets carry `is_small_business`, others carry `is_sdvosb`, `is_wosb`, `is_8a`, `is_hubzone`. At the NAICS grain (`incumbent.agency_naics_vendor_leaders`), only `is_small_business` is available (BL-010). At the office grain, all flags are available.

**Impact:** "Show me 8(a) incumbents in my NAICS" produces incomplete results, making the platform look less capable than it is.

**Recommendation:** Audit all vendor-facing datasets for socioeconomic flag coverage. Add missing flags where the underlying MV supports them. Standardize flag naming across datasets.

---

### 5.4 Topic department codes don't match other dimensions

**Finding:** Topic intelligence datasets use `department_code` (USASpending 3-digit), while all other datasets use `contracting_dept_id` (FPDS 4-digit). The dimensions are in different formats, and the LLM can't translate between them.

**Impact:** A user who resolves "VA" → `3600` (FPDS) then tries `topics.agency_profile?department_code=3600` gets no results (BL-008). The LLM must discover the crosswalk through trial and error.

**Recommendation:** Add `department_code_format` metadata to topic datasets. In the query builder, auto-translate FPDS 4-digit → USASpending 3-digit using `analytics_dims.usaspending_fpds_dept_crosswalk` when the target dataset expects 3-digit codes.

---

## Theme 6: Insight Sophistication

How deep can the precomputed analytics go?

### 6.1 No compound scoring or composite metrics

**Finding:** Each dataset answers one question well: pricing risk, competition level, concentration, etc. But there is no precomputed "agency accessibility score" that combines competition openness + pricing risk + set-aside friendliness + vehicle accessibility + new-entrant survival.

**Impact:** The LLM must query 5+ datasets and hand-roll a composite score. This is the most valuable synthesis but the hardest to produce in a single session.

**Recommendation:** Build a `market.agency_accessibility_scorecard` dataset that collapses 8-10 dimensions into a single 0-100 score with component breakdowns. Precompute it, don't make the LLM derive it.

---

### 6.2 No trend direction classification

**Finding:** Most datasets return raw values. The LLM must compute YoY change, classify growth/decline, and detect inflection points client-side. `naics.growth_leaders` has `obligation_growth_rate` and `topics.trends` has `trend_classification`, but most other datasets don't.

**Impact:** "Is this agency's competition getting better or worse?" requires multiple queries across fiscal years and client-side math.

**Recommendation:** Add `trend_classification` (growing/stable/declining) and `yoy_change_pct` to all FY-grain datasets where it's computationally meaningful. The MVs already have the data — this is a view-level column addition.

---

### 6.3 No anomaly detection or outlier flagging

**Finding:** The datasets report aggregate values but don't flag outliers. A Q4 obligation spike at one office is just a number — the LLM must compute z-scores or compare to peer offices to identify it as unusual.

**Impact:** "What's unusual about this agency's buying patterns?" requires downloading all peer data and computing client-side.

**Recommendation:** Add `is_outlier` and `percentile_rank` columns to key datasets (seasonality, pricing, competition). Simple precomputation — compare against peer group, flag values outside 1.5× IQR.

---

### 6.4 Missing temporal comparison shortcuts

**Finding:** To compare "this year vs last year," the LLM must make two queries and join in memory. There's no `fiscal_year_compare` parameter that returns side-by-side FY columns.

**Impact:** Simple temporal comparisons consume 2× the queries and 2× the context.

**Recommendation:** Add a `compare_fy` parameter to FY-grain datasets that, when specified, returns the current year + comparison year as adjacent columns (`obligated_amount_fy2025`, `obligated_amount_fy2024`, `yoy_change`).

---

### 6.5 No vendor-vs-vendor head-to-head analysis

**Finding:** "Compare Booz Allen vs Leidos at DHS" requires querying concentration datasets for each vendor separately and merging. There's no side-by-side comparison tool.

**Impact:** Competitive analysis — the most common govcon question — requires the most manual assembly.

**Recommendation:** Add `fpds_vendor_compare` tool (or a `/v1/profiles/compare` endpoint) that takes two or more UEIs and returns a side-by-side comparison: agency footprint overlap, NAICS overlap, incumbent tenure, small business status, recompete exposure.

---

## Theme 7: Documentation & Resource Quality

How well do the MCP resources support the LLM?

### 7.1 Resources are static and may be stale

**Finding:** The 5 MCP documentation resources (`methodology`, `datasets`, `caveats`, `ai-assistant-guide`, `notices`) are loaded from markdown files at server startup. They don't reflect live catalog changes and must be manually updated.

**Impact:** The `DATASETS.md` reference lists fewer datasets than the catalog (88 vs what's in the YAML). LLMs reading the doc get an incomplete picture.

**Recommendation:** Generate the DATASETS resource dynamically from the catalog YAML. Keep METHODOLOGY and CAVEATS as manually curated. Notices should be generated from `app/notices.py` (already done).

---

### 7.2 No MCP resource for the complete catalog

**Finding:** There's no `fpds://catalog/datasets` resource that gives the LLM the full catalog as context. The LLM must discover datasets one domain at a time via `fpds_list_datasets`.

**Impact:** The LLM can't "preload" the full catalog for session-wide awareness. Discovery is incremental and turn-intensive.

**Recommendation:** Add `fpds://catalog/datasets` and `fpds://catalog/dimensions` as MCP resources, generated from the live catalog. This lets the LLM load the complete reference in one read.

---

### 7.3 Skills directory is disconnected from the MCP system

**Finding:** The `skills/` directory contains 8 well-written skill markdown files for common govcon workflows. But they're standalone files — not exposed as MCP resources, not referenced in tool descriptions, and not integrated into the prompt system. The `README.md` describes how to use them with OpenClaw or Claude Desktop, but there's no MCP-native access.

**Impact:** The skills represent significant thought work in workflow design but are invisible to most MCP users.

**Recommendation:** Expose each skill as an MCP prompt (they already follow a workflow pattern similar to the 8 built-in prompts). Alternatively, add them as MCP resources so the LLM can load them on demand.

---

### 7.4 No changelog or version history exposed to the LLM

**Finding:** The catalog has a single `version` string (`2026-06-27`), but individual datasets don't have versions. When a dataset changes (new filter, renamed field), the LLM has no way to know.

**Impact:** If the LLM cached a dataset's schema from a prior session, it may use stale assumptions.

**Recommendation:** Add a `catalog_changed_since` endpoint or tool. Return a list of dataset IDs that changed since the given version/date. Minimum: add `last_modified` timestamp per dataset.

---

## Theme 8: User Testing Findings (2026-07-13)

Results from two-pass LLM testing of the MCP system. Organized by the tester's own taxonomy.

### 8.1 Data I Didn't Have

#### 8.1.1 No AI/ML classification field on any contract

**Finding:** Nothing in FPDS — not a flag, keyword tag, or confidence score — marks a contract as AI/ML-related. Every answer must be proxied through broad NAICS codes (541511/541512) or PSC codes (DA01), both of which are "general IT services" — not AI/ML-specific. This ceiling is fixed regardless of tool usage quality.

**Impact:** "Who's winning AI/ML contracts?" is currently unanswerable. The topic intelligence system detects procurement sub-markets, but there's no bridge from topic → individual contract flagging. The data answers "who buys IT services" extremely well — but not "who buys AI."

**Recommendation:** Two paths:
1. **Short-term:** Expose the topic→contract mapping already present in `analytics_dims.contract_family_topics` (referenced in DRILL-DOWN-GAPS.md but status unclear). If a contract has been assigned to a topic, surface that as a filterable field.
2. **Long-term:** Use the existing BERTopic pipeline to tag individual contracts with canonical topic IDs, then expose `canonical_topic_id` as a filter on vendor and competitive landscape datasets.

**Overlaps with:** Finding 3.2 (no topic_profile tool) — if topics were bridgeable to contracts, the value of topic intelligence grows 10×.

---

#### 8.1.2 No crosswalk between canonical and local topic IDs

**Finding:** `topics.govwide_canonical` returns clean government-wide topics with labels like "Artificial Intelligence and Cognitive Computing Research" (id 2594), but carries zero obligation or vendor data (`total_assignments_govwide: null`). The datasets that *do* have vendor/dollar data (`topics.competitive_landscape`, `topics.naics_decomposition`) use department-local topic IDs. There is no visible join key connecting canonical id 2594 to a local id. The `topics.lineage` dataset — which should provide this bridge — returns empty for all tested combinations.

**Impact:** Topic intelligence is split into two disconnected halves: (a) a clean, human-readable govwide catalog with no analytics, and (b) per-department analytics with opaque local IDs that can't be cross-referenced. The "what's the government buying?" question gets a label; the "who's winning it?" question gets numbers you can't label.

**Recommendation:** Investigate `topic_intelligence.canonical_topic_mapping` (9,313 rows — the actual join table between canonical and local topic IDs). If this table is the missing bridge, expose it as a dimension (`canonical_topic_mapping`) and join it into the competitive landscape and NAICS decomposition views. If it's stale or incomplete, rebuild the mapping and create a view. This is the single highest-leverage topic fix — it unlocks every topic dataset for govwide analysis.

**Overlaps with:** Finding 2.1 (no join metadata) — this is the canonical example of a join path the LLM can't discover.

---

#### 8.1.3 No entity-resolution / parent-company rollup

**Finding:** Major vendors appear under multiple UEIs with no linking field. Examples: Booz Allen Hamilton (2+ UEIs), Leidos (3 UEIs), Peraton (2 UEIs). Every vendor ranking must be manually reassembled by matching names across UEIs. In one test, Leidos's three entities combined nearly closed the gap with Accenture — a structurally different ranking than what any single dataset produces.

**Impact:** "Largest vendor" rankings are systematically wrong for companies with multiple UEIs. The error direction is consistent: multi-UEI companies are undercounted, making single-UEI companies appear artificially dominant.

**Recommendation:** The `sql/008_parent_company_rollup.sql` migration exists — investigate whether it created a parent-company mapping table. If a `parent_company_id` or `ultimate_parent_uei` field exists in the data, expose it on all vendor-grain datasets and add it as a filter. If not, build a curated parent-company lookup from known M&A data (the UEI → vendor name mapping in `analytics_dims.vendor_name_by_uei` is a starting point). This is a data engineering problem, not an API problem — but the API is the right place to expose the fix.

**Overlaps with:** New finding — not in existing backlog.

---

#### 8.1.4 No vendor-level PSC dataset

**Finding:** PSC data exists only at agency/office grain (`psc.agency_profile_fy`, `psc.office_profile_fy`). There is no `incumbent`-style dataset that ranks vendors by PSC the way NAICS does (`incumbent.agency_naics_vendor_leaders`). A question like "rank vendors by PSC DA01 obligation" is structurally unanswerable — you can confirm DA01 is the right code, but never rank vendors by it.

**Impact:** Any competitive analysis framed around product/service codes (PSC) rather than industry codes (NAICS) hits a dead end. For capabilities best described by PSC (e.g., specific equipment types, research categories, construction codes), there is no vendor competitive intelligence.

**Recommendation:** Build a `psc.vendor_leaders` or `incumbent.psc_vendor_leaders` dataset at PSC × vendor × agency × FY grain. The underlying data exists in `fpds_actions` (every action has both `product_or_service_code` and a vendor UEI). The missing piece is a materialized view aggregating it.

**Overlaps with:** New finding — not in existing backlog. Related to finding 2.1 (dataset relationships) — NAICS and PSC are parallel classification dimensions but PSC lacks the vendor grain that NAICS has.

---

#### 8.1.5 No server-side aggregation

**Finding:** Every vendor total reported in testing was built by pulling up to 200 raw rows and summing client-side. There is no "sum obligations by vendor across all offices/years/NAICS" endpoint. Vendors whose business is spread thinly across many small offices are systematically undercounted — their rows fall below whatever cutoff the LLM pulls.

**Impact:** Multi-dimensional aggregations (vendor × agency, vendor × NAICS, vendor × FY) require the LLM to download raw data and compute. This is context-expensive, slow, and error-prone due to truncation at result limits. Rankings are biased toward concentration — vendors with one large office win appear higher than vendors with equivalent total volume spread across 20 small offices.

**Recommendation:** Two complementary fixes:
1. **Short-term:** Add server-side aggregation to `fpds_query_dataset` via a `group_by` parameter (e.g., `group_by=vendor_name` on office-grain datasets). The API already knows the view schema — it can generate `SELECT vendor_name, SUM(obligated) GROUP BY vendor_name` safely.
2. **Long-term:** Ensure all major analytical dimensions have a vendor-grain rollup dataset (vendor × NAICS exists; vendor × PSC, vendor × topic, vendor × agency are gaps).

**Overlaps with:** Finding 3.1 (no vendor_profile tool) — a vendor profile solves this for the most common case. Finding 6.5 (no vendor comparison) — comparison without server-side aggregation is twice as expensive.

---

### 8.2 Parameters/Behavior That Weren't Documented Upfront

#### 8.2.1 Required-filter logic is invisible until you fail

**Finding:** The dataset catalog (`fpds_list_datasets`) lists filter fields but never indicates which are required or in what combination. Each dataset enforces its own hidden rule (e.g., "at least one of fiscal_year, contracting_dept_id"). The only way to learn the rule is to submit a query and read the 400 error. In one test, this caused the wrong conclusion that `concentration.vendor_office_naics_year` required an agency filter — when actually `fiscal_year` alone (paired with NAICS) was sufficient and a better tool. This cost an entire first pass.

**Impact:** This is the #1 friction point identified in testing. The LLM selected suboptimal tools because it couldn't see filter requirements before attempting queries. The 400 errors carry the information but only after failure — wasted turns, wasted context, and eroded trust.

**Recommendation:** Expose `required_filters_any` (already in catalog YAML per dataset) in `fpds_describe_dataset` responses. Add a `required_filters` section that explains the filter logic in plain English. Example:
```json
"required_filters": {
  "mode": "any_of",
  "fields": ["fiscal_year", "contracting_dept_id"],
  "description": "At least one of fiscal_year or contracting_dept_id must be provided to avoid query timeout."
}
```
Also add a `usage_note` field per dataset that explains common non-obvious patterns (like "this dataset supports fiscal_year + principal_naics_code without an agency filter").

---

#### 8.2.2 No distinction between "lookup" and "discovery" datasets

**Finding:** `concentration.vendor_market_leaders` sounds like a leaderboard you can browse, but actually requires a UEI you already know — it's a lookup tool wearing a discovery-tool name. Nothing in the catalog signals this difference. The LLM must try to query without a UEI, fail, and re-interpret the dataset's purpose.

**Impact:** The catalog's domain taxonomy helps, but doesn't distinguish between "I want to browse" and "I already know what I'm looking for." This is especially confusing for vendor datasets where the same domain contains both patterns.

**Recommendation:** Add a `query_pattern` field to the catalog with values like `"browse"`, `"lookup"`, `"ranked"`, `"drill_down"`. This tells the LLM the intended usage before it tries to query. Example:
- `concentration.vendor_market_leaders` → `"lookup"` (requires known UEI)
- `incumbent.agency_vendor_leaders` → `"browse"` (ranked list, filterable by agency)
- `pipeline.recompete_watchlist` → `"browse"` (filterable, no entity required)

---

#### 8.2.3 Fiscal-year semantics not flagged as consequential

**Finding:** FY2026 being year-to-date/partial was not surfaced as meaningful. In testing, Palantir's entire dominant position in 541511 only became visible when isolating FY2026 — because its Army presence essentially didn't exist before FY2025. Nothing tells the user upfront that checking the partial current year separately (rather than defaulting to "most recent complete year") could flip the answer. The tester only checked it because the Army-specific numbers looked oddly concentrated in 2 fiscal years.

**Impact:** The default behavior (query `fiscal_year=2025` for "most recent") silently drops the most current data. For rapidly-changing markets (new entrant gains traction, surge funding events), the most important signal lives in the YTD year and is missed.

**Recommendation:** 
1. Add `is_current_fiscal_year_ytd` to the response metadata when the queried FY is the current partial year.
2. Add a catalog-level notice: "Some datasets include FY2026 year-to-date data which is incomplete. For complete-year analysis, use FY2025 or earlier. For emerging trends, check FY2026."
3. In `fpds_describe_dataset`, note the max and min FY available in the dataset's source data.

---

#### 8.2.4 Grain not obvious from dataset names

**Finding:** Several datasets with similar-sounding names differ critically in their required context:
- `incumbent.agency_naics_vendor_leaders` — requires agency context
- `concentration.vendor_office_naics_year` — can work without agency context (just FY + NAICS)
- `concentration.vendor_market_leaders` — requires known UEI

The names use consistent prefixes (`incumbent.*`, `concentration.*`) but the prefix doesn't encode grain/required-context information. The difference only surfaces in filter-requirement errors.

**Impact:** The LLM makes tool-selection errors based on name heuristics. With 88+ datasets, even a careful LLM can't memorize the grain of each one. Names that look interchangeable aren't.

**Recommendation:** Add `grain_keys` (already proposed in finding 2.1) to the catalog and expose it in `fpds_describe_dataset`. The LLM should see at a glance: "this dataset is at contracting_dept_id × fiscal_year grain" vs "this dataset is at uei × contracting_agency_id × fiscal_year grain." A structured grain description is more reliable than naming conventions.

---

## Theme 8 Summary: User Testing Priority

The tester identified the single highest-leverage fix as: **exposing required-filter combinations in the dataset catalog itself.**

Ranked by testing impact (with keywords graph reassessment noted):

| # | Finding | Tester's Assessment | Keywords Graph? |
|---|---------|---------------------|-----------------|
| 1 | 8.2.1 Required-filter visibility | "Would have gotten me to the right tool on the first pass" | ❌ |
| 2 | ~~8.1.2 Canonical→local topic crosswalk~~ | ~~"The most important missing join in the system"~~ | ⚠️ 3-hop keyword bridge exists; reduced to single-hop gap |
| 3 | 8.1.3 Parent-company rollup | "Changed rankings — multi-UEI companies systematically undercounted" | ⚠️ Heuristic via keyword overlap |
| 4 | 8.1.4 Vendor-level PSC dataset | "PSC leg of question was structurally unanswerable" | ❌ |
| 5 | 8.2.2 Lookup vs discovery distinction | "Wasted turns on datasets that looked like leaderboards" | ❌ |
| 6 | ~~8.1.5 Server-side aggregation~~ | ~~"Vendors spread across many small offices systematically undercounted"~~ | ✅ Solved by `keyword_analytics(group_by=...)` |
| 7 | ~~8.1.1 AI/ML contract classification~~ | ~~"Fixed ceiling regardless of tool usage quality"~~ | ✅ Solved — keywords ARE the classification |
| 8 | 8.2.3 FY semantics | "Partial year data flipped the answer but wasn't flagged" | ❌ |
| 9 | 8.2.4 Grain not obvious from names | "Names that look interchangeable aren't" | ❌ |

**Net effect of keywords graph:** 2 of 5 "data I didn't have" findings are already solved. 2 more are partially addressed. 1 (vendor PSC) and all 4 "parameters unclear" findings remain open.

---

## Theme 9: Keywords Graph — What It Already Solves

The `fpds-keywords` MCP server provides keyword-level procurement analytics sourced from `keyword_link_metadata` — contracts flagged with extracted phrases/terms from award descriptions. It operates in parallel to the FPDS analytics API and addresses several audit findings directly.

### 9.1 Data Model

Keywords are extracted phrases and terms from contract descriptions, categorized into:
- `product_vendor` — vendor/brand names (e.g., "Booz Allen Hamilton", "Microsoft")
- `method_service` — capability/service descriptions (e.g., "artificial intelligence", "cloud computing")
- `system_program` — named programs/systems (e.g., "joint artificial intelligence", "JAIC")

Each keyword carries:
- `total_link_count` — number of contract links (reliable, always populated)
- `total_obligated_amount` — summed from `keyword_link_metadata` (reliable)
- `total_award_count` — may be sparse (depends on award_number enrichment)
- `top_departments` — top 5 departments by link count
- `suggested_subcategory` — optional grouping label (e.g., "cloud_computing")
- `classification_confidence` — nullable confidence score

Department codes use USASpending sub-agency format (e.g., `'070'` = DHS, `'097'` = DoD, `'036'` = VA).

### 9.2 Tools Available

| Tool | What It Does |
|------|-------------|
| `keyword_search` | Substring search for keywords across all 3 categories |
| `keyword_analytics` | Award count, obligations, FY trend, `group_by` on agency/vendor/fy/naics/set_aside |
| `keyword_vs_topic` | Bidirectional: keyword → topics OR topic → keywords at specific departments |
| `keyword_compare` | Side-by-side comparison of multiple keywords (FY trends, vendors, agencies) |
| `keyword_vendor_profile` | All keywords a vendor appears in, with award counts, obligations, agency coverage |

### 9.3 Mapping to Audit Findings

#### Directly Solved

**8.1.1 — No AI/ML classification field: ✅ SOLVED**

Keywords ARE the capability classification that FPDS lacks. Example from live data:

| Metric | "artificial intelligence" |
|--------|--------------------------|
| Links | 4,249 |
| Total obligated | $1.43B |
| Unique vendors | 724 |
| Unique agencies | 26 |
| Top vendor | UEI `XYB4JU4PA6T4` — $165M |
| Top agency | `2100` (Army) — $481M |
| FY peak | FY2020 — $383M |

`keyword_compare(["artificial intelligence","machine learning","data science"])` produces a side-by-side capability comparison with FY trends, top agencies, vendor counts, and total obligations in a single call. This directly answers "who's winning AI/ML contracts?" without proxying through NAICS/PSC.

**8.1.5 — Server-side aggregation: ✅ SOLVED**

`keyword_analytics(keyword_text="artificial intelligence", group_by="vendor")` returns precomputed vendor rankings with obligation amounts. No client-side row summation needed. `group_by` supports: agency, vendor, FY, NAICS, set_aside. Obligation data comes from `keyword_link_metadata` (reliable), not from per-row aggregation.

#### Partially Solved

**8.1.2 — Canonical→local topic crosswalk: ⚠️ KEYWORD-MEDIATED**

`keyword_vs_topic` bridges keywords to per-department topic IDs bidirectionally. Example:

```
keyword "artificial intelligence"
  → topic_id 87 at dept "097" (Army)
    label: "Artificial Intelligence and Cognitive Computing Research"
    topic_share: 0.441 (44% of this topic's links are AI keyword)

topic_id 87 at dept "097" ← "artificial intelligence", "machine learning",
  "algorithms", "automated", "computational", "prototype", "exploration"
```

This works, but it's a keyword-mediated path — not a direct canonical_topic_id → local_topic_id join. To go from a canonical topic (like `topics.govwide_canonical` id 2594) to local analytics, the LLM must: canonical label → keyword_search → keyword_vs_topic → local topic_id → competitive_landscape. This is a 3-hop chain. A direct canonical_topic_mapping join would be a 1-hop chain.

**8.1.3 — Parent-company rollup: ⚠️ HEURISTIC**

`keyword_vendor_profile(uei="...")` returns all keywords for a vendor with obligation amounts and agency coverage. Two UEIs belonging to the same parent company should have highly overlapping keyword portfolios. This provides a heuristic for grouping, but is not a structural solution.

**3.2 — No topic_profile tool: ⚠️ INDIRECT**

The keyword graph provides analytics through the keyword lens rather than the topic lens. To get topic-level vendor rankings, the flow is: keyword search → keyword_vs_topic → find topic_id → keyword_vs_topic (reverse) → collect keywords → aggregate. This works but is more steps than a direct `fpds_topic_profile` tool would be.

#### Not Solved

| Finding | Status | Reason |
|---------|--------|--------|
| 8.1.4 Vendor-level PSC dataset | ❌ | Keywords don't expose PSC codes |
| 8.2.1 Required-filter visibility | ❌ | Metadata/UX issue, not data |
| 8.2.2 Lookup vs discovery | ❌ | Metadata/UX issue |
| 8.2.3 FY semantics | ❌ | Documentation issue |
| 8.2.4 Grain not obvious | ❌ | Metadata/UX issue |
| 6.1 Compound scoring | ❌ | Keywords scope is capability, not agency composite |
| All code-level findings (Theme 4) | ❌ | N/A |

### 9.4 The Integration Gap

The keywords graph and the FPDS analytics API are **separate MCP servers** with no explicit bridge tool. The LLM must discover both independently and manually compose multi-server workflows. The critical missing link:

```
keyword_analytics → vendor UEI → ??? → full vendor profile (tenure, cross-agency, competition)
```

There is no single tool that takes a UEI from the keywords graph and returns an analytics API vendor profile. The LLM must switch servers, resolve the UEI, and query multiple analytics datasets. This handoff is the highest-value integration point between the two systems.

Similarly, the keyword → topic bridge (`keyword_vs_topic`) returns local topic IDs, but the analytics API's topic datasets (`topics.competitive_landscape`, etc.) also use local topic IDs. Once the LLM has a (topic_id, department_code) pair from the keyword graph, it can query the analytics API topic datasets directly — but this requires the LLM to know that both servers use the same local topic ID space.

### 9.5 Keyword Graph vs Analytics API: When to Use Which

| Question Type | Best Tool |
|---------------|-----------|
| "Who wins AI/ML contracts?" | Keywords graph — `keyword_analytics(group_by="vendor")` |
| "How does Agency X buy?" | Analytics API — `fpds_customer_profile` |
| "What's the AI/ML market size?" | Keywords graph — `keyword_analytics` with FY trend |
| "Is Agency X competitive in NAICS Y?" | Analytics API — `competition.*` datasets |
| "Compare AI vs cloud vs cyber obligations" | Keywords graph — `keyword_compare` |
| "What contracts are expiring at Agency X?" | Analytics API — `pipeline.recompete_watchlist` |
| "What topics does Agency X's AI spend fall under?" | Keywords → Topics bridge — `keyword_vs_topic` |
| "Who's the incumbent for NAICS X at Agency Y?" | Analytics API — `incumbent.*` datasets |
| "What capabilities does Vendor Z compete in?" | Keywords graph — `keyword_vendor_profile` |

### 9.6 Keywords Graph Limitations

1. **Award counts may be sparse.** While obligation data is reliable (from `keyword_link_metadata`), award counts depend on `award_number` enrichment which is not always present. Rankings should use obligation, not count.

2. **Department codes use USASpending format.** Codes like `'070'` (DHS), `'097'` (DoD) must be cross-walked to/from the analytics API's FPDS 4-digit format (`7000`, `9700`). Both servers have the crosswalk but the LLM must discover it.

3. **No UEI-to-name resolution.** `keyword_analytics(group_by="vendor")` returns UEIs but not vendor names. The LLM must enrich names separately via the analytics API or `keyword_vendor_profile`.

4. **Topic bridge requires department context.** `keyword_vs_topic` returns per-department local topic IDs. Omitting `department_code` returns results defaulting to an arbitrary department, producing misleading matches (validated during testing: topic_id 87 without department_code returned "packing/carpet" keywords instead of "AI/ML").

---

## Impact Reassessment After Keywords Graph Analysis

The keywords graph changes the severity of several findings:

| Finding | Before Keywords | After Keywords | Delta |
|---------|----------------|----------------|-------|
| 8.1.1 AI/ML classification | Critical — "structurally unanswerable" | ✅ Solved by existing tool | **Resolved** |
| 8.1.5 Server-side aggregation | High — "systematically undercounted" | ✅ Solved by existing tool | **Resolved** |
| 8.1.2 Canonical→local topic crosswalk | Critical — "most important missing join" | ⚠️ Keyword-mediated bridge exists, 3-hop vs 1-hop | **Reduced severity** |
| 8.1.3 Parent-company rollup | High — "rankings changed by unmerged entities" | ⚠️ Heuristic via keyword overlap | **Reduced severity** |
| 8.1.4 Vendor-level PSC dataset | High — "structurally unanswerable" | ❌ Still unsolved | **Unchanged** |

The keywords graph was already solving 2 of the 5 "Data I Didn't Have" findings before testing even began — the LLM just wasn't guided to use it for those questions.

---

## Appendix A: Data Pipeline Health

Summary of the 3-layer pipeline discovered during the schema audit:

| Layer | Count | Status |
|-------|-------|--------|
| Materialized Views (10 schemas) | 63 MVs | Healthy. 6 documented drill-down gaps partially filled (3 of 6 have new MVs in `customer_intelligence`). |
| Report Deck Views (10 schemas) | ~85 views | Healthy. 1:1 facade over MVs. |
| Analytics API Views (1 schema) | 100 views | Healthy. Exposes the catalog datasets. |

### MV Gap Status (from DRILL-DOWN-GAPS.md)

| Gap | MV | Status |
|-----|-----|--------|
| 1: Office × month × NAICS × FY | `customer_intelligence.mv_fpds_office_month_naics_fy` | **Built** |
| 2: Vendor cross-agency rank | `vendor_concentration.vendor_cross_agency_rank` (view) | **Built** |
| 3: Vendor × office × NAICS | `vendor_concentration.mv_fpds_vendor_office_naics_year` | **Built** |
| 4: State × vendor × year | `geographic_analysis.mv_fpds_geo_state_vendor_year` | **Built** (BL-018 gap 4) |
| 5: Agency × month × NAICS × FY | `customer_intelligence.mv_fpds_agency_month_naics_fy` | **Built** |
| 6: PSC × NAICS × office × FY | `psc_analysis.mv_fpds_psc_naics_office_fy` | **Built** |

All 6 drill-down gaps appear to be filled based on MV presence. Verify catalog exposure.

---

## Appendix B: Backlog Alignment

Findings that overlap with or extend existing backlog items. Findings marked ✅ are already solved by the keywords graph and may not need analytics API work.

| Finding | Related BL | Status | Keywords Graph? |
|---------|-----------|--------|-----------------|
| 2.2 Department code format | BL-008 | Open — topic catalog specifically | ❌ |
| 5.3 Socioeconomic flags | BL-010 | Open — SDVOSB at NAICS grain | ❌ |
| 2.5 Missing FY filters | BL-007 (partial) | Open — 5 datasets identified | ❌ |
| 8.2.1 Required-filter visibility | New (extends BL-015) | Catalog YAML has it, not exposed to LLM | ❌ |
| 8.2.2 Lookup vs discovery distinction | New | Catalog metadata addition | ❌ |
| 8.1.4 Vendor-level PSC dataset | New (BL-022 suggested) | PSC has no vendor grain — data work needed | ❌ |
| 9.4 Keywords↔Analytics integration gap | New (BL-024 suggested) | No bridge tool between MCP servers | ❌ |
| 8.1.2 Canonical→local topic crosswalk | New (BL-020 suggested) | 9,313-row mapping table exists; keyword bridge is 3-hop workaround | ⚠️ Partial |
| 8.1.3 Parent-company rollup | New (BL-021 suggested) | sql/008 migration exists; keyword overlap is heuristic | ⚠️ Partial |
| 3.2 No topic_profile tool | New | Keyword graph provides indirect path | ⚠️ Partial |
| ~~8.1.1 AI/ML classification~~ | ~~New~~ | ✅ Keywords ARE the classification | ✅ Solved |
| ~~8.1.5 Server-side aggregation~~ | ~~BL-023~~ | ✅ `keyword_analytics(group_by=...)` | ✅ Solved |
| 3.1 No vendor_profile tool | New | Not in backlog — still needed for non-keyword flows | ❌ |
| 6.1 Compound scoring | New | Not in backlog | ❌ |
| 4.2 Duplicate dispatch | New | Not in backlog | ❌ |

---

## Appendix C: Priority Matrix (Revised After Keywords Graph Analysis)

Sorted by (User + LLM Impact × Implementation Effort), ascending effort.
Findings marked ~~strikethrough~~ are solved by the existing keywords graph.

| # | Finding | Impact | Effort | Category | Recommendation |
|---|---------|--------|--------|----------|----------------|
| 1 | **8.2.1 Required-filter visibility** | **Critical** | **Low** | Metadata | Expose `required_filters_any` in describe + list |
| 2 | **9.4 Keywords↔Analytics integration gap** | **Critical** | **Low** | Metadata | Add cross-server tool guidance, UEI→profile bridge |
| 3 | 2.2 Department code format | Critical | Low | Code | Auto-crosswalk in query builder |
| 4 | 8.2.2 Lookup vs discovery | High | Low | Metadata | Add `query_pattern` field to catalog |
| 5 | 1.3 Semantic dataset search | High | Low | Metadata | Add `q` param to `fpds_list_datasets` |
| 6 | 2.1 No join metadata | High | Low | Metadata | Add `grain_keys` + `joins_to` to catalog |
| 7 | 8.2.4 Grain not obvious from names | High | Low | Metadata | Expose `grain_keys` in describe_dataset |
| 8 | 8.2.3 FY semantics flagged | Medium | Low | Metadata | Add YTD notice + available FY range |
| 9 | 1.1 Domain-only filtering | Medium | Low | Metadata | Add `filter_name`, `field_name` params |
| 10 | 1.4 Related datasets | Medium | Low | Metadata | Add `related` field to catalog |
| 11 | 1.2 Tool description bloat | Medium | Low | Code | Trim dataset listing from tool desc |
| 12 | 6.2 No trend classification | Medium | Low | Data | Add `trend_classification` to FY views |
| 13 | 7.2 No catalog resource | Medium | Low | Code | Generate from catalog YAML |
| 14 | 5.1 Agency hierarchy | Medium | Low | Metadata | Expose parent-child in dimensions |
| 15 | 5.2 UEI → name join | Medium | Low | Data | Audit + complete vendor_name coverage |
| 16 | 2.3 Obligation naming | Medium | Medium | Data | Standardize field names in views |
| 17 | 3.3 Missing tool parity | Medium | Medium | Code | Audit API → MCP tool coverage |
| 18 | 7.3 Skills → prompts | Medium | Medium | Code | Expose skills as MCP prompts |
| 19 | 4.2 Duplicate dispatch | High | Medium | Code | Consolidate to FPDSServer |
| 20 | 3.1 No vendor_profile tool | High | Medium | Code | Build composite endpoint |
| 21 | 3.2 No topic_profile tool | High | Medium | Code | Build composite endpoint |
| 22 | **8.1.2 Canonical→local topic crosswalk** | **High¹** | **Medium** | Data | Expose canonical_topic_mapping, join into views |
| 23 | **8.1.4 Vendor-level PSC dataset** | **High** | **High** | Data | New MV: vendor × PSC × agency × FY |
| 24 | **8.1.3 Parent-company rollup** | **Medium²** | **High** | Data | Curate parent-UEI lookup, expose on vendor datasets |
| 25 | 6.1 Compound scoring | High | High | Data | New MV with multi-dimensional score |
| 26 | 6.5 Vendor comparison | High | High | Code | New composite endpoint |
| ~~27~~ | ~~8.1.1 AI/ML classification~~ | ~~N/A~~ | ~~N/A~~ | ~~Data~~ | ~~✅ Solved by keywords graph~~ |
| ~~28~~ | ~~8.1.5 Server-side aggregation~~ | ~~N/A~~ | ~~N/A~~ | ~~Code~~ | ~~✅ Solved by keywords graph~~ |

¹ Reduced from Critical — keyword_vs_topic provides a 3-hop workaround.
² Reduced from High — keyword_vendor_profile provides a heuristic for grouping.

---

## Appendix D: Data Work Investigation (2026-07-14)

Post-code-deploy investigation of the 4 "low effort" data items. All require view alters or MV rebuilds — none are catalog-only fixes.

### D.1 UEI → vendor_name (5.2): ✅ NO GAPS

S7-013 already resolved this. All 11 `analytics_api` views with UEI columns (`uei`, `vendor_uei`) already include `vendor_name`. All 13 catalog datasets listing a UEI field also list `vendor_name`. Zero work needed.

Minor unrelated finding: `contacts.recompete_handlers` has `vendor_name` but no UEI column — cannot filter/join by UEI.

### D.2 Obligation field naming (2.3): MEDIUM-HIGH EFFORT

93 unique obligation-related field names across the catalog. ~53 variants lack the `_amount` suffix convention (e.g., `total_obligated` → `total_obligated_amount`). Catalog field names are 1:1 identical to view column names — **every rename requires an ALTER VIEW**. 50+ views would need ALTER statements.

**Recommended phased approach:**
- Phase 1: Core totals (~30 views) — `total_obligated` → `total_obligated_amount`
- Phase 2: Subtype fields (~45 views) — `fixed_price_obligated` → `fixed_price_obligated_amount`, etc.
- Phase 3: Edge cases — `total_net_obligated_amount` → `net_obligated_amount`, etc.

**Deferred** — not low effort.

### D.3 Missing FY/NAICS filters (2.5 / BL-007): MEDIUM EFFORT

7 datasets identified. All 7 need **source view/MV modifications** — the columns don't exist in the underlying views. Zero catalog-only fixes.

| Dataset | FY | NAICS | Fix |
|---------|-----|-------|-----|
| `pipeline.agency_recompete_summary` | Missing | Missing | View rebuild (grain change: agency → agency × FY × NAICS) |
| `acquisition.agency_vehicle_mix_fy` | OK | Missing | Add NAICS to source view |
| `acquisition.vehicle_program_vendors` | OK | Missing | Add NAICS to source view |
| `set_aside.agency_profile_fy` | OK | Missing | Add NAICS to source view |
| `set_aside.trend_fy` | OK | Missing | Add NAICS to source view (changes grain to FY × NAICS) |
| `entrants.agency_cohort_fy` | OK | Missing | Add NAICS to source view |
| `topics.competitive_landscape` | Missing | Missing | MV redesign (add FY accumulation) |
| `topics.govwide_canonical` | N/A | N/A | Static vocabulary — no action |

**Deferred** — requires source view modifications.

### D.4 SDVOSB flags on NAICS-grain incumbent (5.3 / BL-010): MEDIUM EFFORT

Root cause: 2 MVs were never updated when the office-grain MV was enhanced with full socioeconomic flags:

| Flag | Office MV | Agency MV | NAICS MV |
|------|-----------|-----------|----------|
| `is_small_business` | ✓ | ✓ | ✓ |
| `is_veteran_owned` | ✓ | ✓ | ✗ |
| `is_women_owned` | ✓ | ✓ | ✗ |
| `is_minority_owned` | ✓ | ✓ | ✗ |
| `is_8a` | ✓ | ✗ | ✗ |
| `is_hubzone` | ✓ | ✗ | ✗ |
| `is_sdvosb` | ✓ | ✗ | ✗ |

**Fix requires:**
1. Rebuild `mv_fpds_vendor_agency_year` — add 3 `BOOL_OR` columns (is_8a, is_hubzone, is_sdvosb)
2. Rebuild `mv_fpds_vendor_naics_agency_year` — add 6 `BOOL_OR` columns (all missing flags)
3. Update 4 views (2 report_deck + 2 analytics_api)
4. Update catalog YAML (fields + filters)

**Deferred** — requires MV rebuilds.
