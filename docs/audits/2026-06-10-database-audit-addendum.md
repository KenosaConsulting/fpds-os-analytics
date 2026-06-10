# ADDENDUM — Read-Only Database Audit (2026-06-10)

Companion to `2026-06-10-usability-analytics-review.md`. All findings below were verified directly against the production analytics database (catalog version 2026-06-04). Scope was strictly the analytics schemas used by the open-source toolset (`analytics_api`, `analytics_dims`, `contract_pricing`, `vendor_concentration`, `competition_dynamics`, `naics_breakdown`, `geographic_analysis`, `customer_intelligence`, `pipeline_intelligence`, `psc_analysis`, `set_aside_breakdown`) plus the FPDS source table they derive from. Methods were metadata queries and bounded aggregates only — no raw-table scans, no writes.

---

## 1. Filter contract verification (closes the open question on P0-1)

Every catalog-declared filter and sortable field was cross-checked against the actual columns of its `analytics_api` backing view — 340 (view, column) pairs.

**Result: 339 of 340 pairs are valid.** The P0-1 fix (catalog-derived allowlist) is safe to ship for every dataset except one:

- **NEW BUG (P0-3): `market.naics_customer_leaders` declares `sector_code` as a filter — and includes it in `required_filters_any` — but the column does not exist on `analytics_api.market_naics_customer_leaders`.** After the allowlist fix, `?sector_code=54` on this dataset would raise `UndefinedColumn` → the API's 500 `dataset_contract_mismatch`. Fix either side: add `sector_code` to the view (preferred — it exists on the underlying NAICS MVs and is genuinely useful here) or remove it from the catalog entry's `filters` and `required_filters_any`.

**Boolean coercion spec is now exact.** The complete set of boolean-typed filter columns in production, all matching `is_*`:

| View | Boolean columns |
|---|---|
| competition_not_competed_reasons_fy | is_sole_source, is_statutory |
| concentration_vendor_market_leaders | is_small_business_ever |
| customer_funding_mismatch_flows_fy | is_cross_department |
| geography_mismatch_leaders | is_in_state |
| geography_state_trend_fy | is_state |
| incumbent_agency_vendor_leaders / incumbent_agency_naics_vendor_leaders | is_small_business |
| incumbent_office_vendor_leaders | is_small_business, is_8a, is_hubzone, is_sdvosb |

The "coerce any `is_*` filter to boolean" rule in the main doc is empirically complete for the current catalog. All other filter columns are text/integer/numeric/date and work with the existing equality path.

## 2. Architecture confirmation and performance posture

All 70 `analytics_api` relations are plain pass-through views over `report_deck_*` views, which sit on materialized views. API query cost therefore equals the report-view plan at request time.

**The recompete watchlist is well-protected.** `report_deck_recompete_watchlist` sits on `pipeline_intelligence.mv_contract_family` (69.3M rows, 18 GB) but pre-filters to `remaining_months BETWEEN -6 AND 24 AND total_obligated > 25000 AND current_completion_date IS NOT NULL`, which rides the existing `remaining_months` index. Verified working set: **~501K rows** — grouped aggregates over the full view return quickly.

**`expiration_bucket` and `recompete_confidence` are CASE expressions computed in the view, not MV columns.** Once P0-1 enables them as filters, equality predicates on them will be applied after the index-range scan — acceptable at the current working-set size. If the watchlist becomes a hot path, either translate bucket filters into `remaining_months` ranges in the API layer, or materialize the two columns into the MV with indexes at next rebuild. Confidence logic for reference: `high` = duration ≥ 12mo AND obligated > $100K AND ≥ 2 actions AND competed; `medium` = duration ≥ 6mo AND obligated > $25K; else `low`.

**Index gaps (create before enabling new filters):**

| MV | Rows | Size | Indexes |
|---|---|---|---|
| vendor_concentration.mv_fpds_vendor_naics_agency_year | 9.1M | 978 MB | **none** |
| naics_breakdown.mv_fpds_naics_agency_year | 712K | 134 MB | none |
| contract_pricing.mv_fpds_pricing_agency_year | 132K | 18 MB | none |
| competition_dynamics.mv_fpds_competition_agency_year | 74K | 12 MB | none |

The 9.1M-row vendor×NAICS×agency MV is the priority — it backs `incumbent.agency_naics_vendor_leaders`, whose filters become reachable after the P0-1 fix. Suggested: `(contracting_agency_id, fiscal_year)` and `(principal_naics_code, fiscal_year)`. The office-grain MVs (psc, geo place, vehicle mix, setaside office) already have strong composite coverage and need nothing.

## 3. Watchlist composition (quantifies P0-2)

Verified distribution of the production watchlist (~501K rows):

| Bucket | Contracts | Obligated |
|---|---:|---:|
| recently_expired | 198,445 | $446B |
| 0_to_6_months | 217,672 | $708B |
| 6_to_12_months | 57,157 | $407B |
| 12_to_18_months | 19,190 | $298B |
| 18_to_24_months | 9,170 | $177B |

**40% of the watchlist is already-expired contracts.** Forward-looking 0–24-month pipeline: ~303K contracts / ~$1.59T, of which high-confidence ≈ 72K contracts / ~$975B. This confirms the P0-2 default-sort fix and supports adding a default predicate excluding `recently_expired` (keep it opt-in via the bucket filter once enabled).

## 4. Growth-leaders root cause (sharpens P1-5)

The view definition compares **current-FY year-to-date (FY2026, ~8 months elapsed) against the full prior FY** — a structural downward bias. Verified consequences across the 1,150 NAICS rows:

- **918 codes (80%) show "negative growth"** — mostly the YTD artifact, not real contraction.
- Of 46 codes showing >100% growth, **42 have a prior-FY base under $1M** (tiny-base artifacts); only 4 have a $10M+ base.
- 119 codes have a zero-or-negative base (division produces null/garbage rates).
- Median base is $7.8M; **549 codes have a $10M+ base**, so a $10M floor retains roughly half the universe and nearly all credible signals.

Revised fix spec for the agent: rewrite the view to compare the **two most recent complete fiscal years** (or trailing-12-months vs. the prior 12 using monthly data once available), add a minimum-base predicate (default $10M, exposed as a `min_base`-style filter), and consider ranking by blended score rather than raw rate. The current `is_current_fiscal_year_ytd` caveat machinery elsewhere in the catalog shows the team already handles YTD flags — this view just predates that discipline.

## 5. Freshness and refresh cadence

No `pg_cron` jobs exist — MV refreshes are driven externally. Observed analyze timestamps (refresh proxy): the large MVs (contract_family, geo place, vendor office, psc) refreshed June 3–5; mid-tier MVs May 26–28; the set-aside package May 22. **Cross-package skew of up to ~2 weeks.**

Recommendation (new task): surface per-dataset freshness in API responses — a `meta.data_as_of` populated from a small refresh-log table written by the refresh process (or, interim, a nightly snapshot of `pg_stat_all_tables` analyze times mapped through `source_view`). Non-technical users assume live data; an honest as-of date is cheap trust insurance and pairs with the existing `is_current_fiscal_year_ytd` flags.

## 6. Office dimension quality (informs the P1-2 resolver)

`name_confidence` distribution across 13,885 offices: 13,011 high / 701 medium / 173 low. Active-recent: 2,946 high-confidence, 153 medium, 3 low. Resolver guidance: default name search to `is_active_recent = true` and confidence in (high, medium) — that's a ~3,100-office search space instead of 14K, with the full set available behind explicit flags.

## 7. Feasibility verdicts for Part 2 analytics

- **Fiscal seasonality (E): feasible.** The transaction-grain source `public.fpds_actions` (98.7M rows, 406 GB) carries the dates; build it as a new monthly/quarterly MV during the refresh cycle, exactly like the existing dept-year summaries. Never query the source at request time.
- **New-entrant cohorts (C): feasible from existing MVs.** First-active-year per (vendor, agency) already exists in the vendor_concentration layer; cohort views are a derivation, not new source aggregation.
- **Displacement events (D): feasible.** `mv_contract_family` carries per-family vendor, base/completion dates, and obligations — follow-on detection (same office+NAICS+PSC, adjacent windows, different UEI) is a self-join over the family MV, best built at refresh time given its size.
- **Duration/award-size profiles (F): trivially feasible** — duration_months and obligation amounts are already family-level columns.

## 8. Task-list deltas (merge into Part 3)

Sprint 1 additions:
- 1a. Fix `market.naics_customer_leaders` ↔ `sector_code` mismatch (view column or catalog removal) and extend the new contract test to assert every filter column exists on its backing view with a coercible type — that test now has a known-bug fixture to validate against.
- 1b. Create the four missing MV index sets (Section 2) before or with the filter enablement; the 9.1M-row vendor×NAICS MV first.

Sprint 2 additions:
- 2a. Growth-leaders rewrite per Section 4 (complete-FY comparison + $10M default floor).
- 2b. `meta.data_as_of` freshness surfacing per Section 5.
- 2c. Resolver defaults per Section 6.

Sprint 3 notes:
- Watchlist default predicate: exclude `recently_expired` by default per Section 3; revisit materializing bucket/confidence into the MV only if latency demands it.
- Seasonality MV build belongs in the refresh pipeline, sourced from the FPDS actions table at aggregation time only.
