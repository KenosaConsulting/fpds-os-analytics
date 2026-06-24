# fpds-os-analytics — Backlog

Improvements and enhancements tracked for future sprints.

---

## Open

### BL-001: Resolve UEIs to vendor names across datasets

**Priority:** High
**Reported:** 2026-06-13
**Context:** Several datasets return `uei` but not `vendor_name` — the name field isn't populated in those views. Users need human-readable company names, not just UEI codes.

**Proposed fix:** The `vendor_market_leaders` dataset already carries `vendor_name` keyed by `uei`. Join against that lookup (or the underlying MV/table) in any view that exposes UEIs without names. Audit all datasets for this gap and patch consistently.

**Affected datasets:** TBD — audit needed across all 58 datasets for views that expose `uei` without a corresponding `vendor_name`.

---

### BL-002: NAICS group/prefix filter support

**Priority:** High
**Reported:** 2026-06-13
**Context:** Users ask questions at the 4-digit NAICS group level (e.g., "5415 — Computer Systems Design") but the API only accepts 6-digit codes. A simple question like "who spends most on 5415?" required 392 separate API calls, hit rate limits, and still produced incomplete results.

**Proposed fix:** Add a `naics_prefix` filter (or similar) that matches all 6-digit codes starting with the given prefix. Apply across all datasets that accept `principal_naics_code` as a filter. Server-side aggregation — don't force the client to discover and loop sub-codes.

---

### BL-003: Pre-aggregated NAICS group-level dataset

**Priority:** High
**Reported:** 2026-06-13
**Context:** Even with a prefix filter, querying at 6-digit grain and aggregating client-side is wasteful. A 4-digit NAICS group rollup dataset would answer "who buys in this industry?" in one call with far fewer rows.

**Proposed fix:** Build a new MV at the `naics_group` (4-digit) × dept × agency × FY grain. Expose as `market.naics_group_agency_fy` or similar. Carry the same measures as `market.agency_naics_fy` but pre-aggregated.

---

### BL-004: Row limit + pagination improvements

**Priority:** High
**Reported:** 2026-06-13
**Context:** Public tier caps at 25 rows per request with no cursor pagination. Analytical queries spanning multiple years/agencies/NAICS codes are silently truncated. The user never knows data was cut off.

**Proposed fix:**
- Increase public limit cap (100–250 minimum)
- Implement cursor-based pagination across all datasets
- Authenticated users get higher limits (500–1000)
- Return pagination metadata (total_count, next_cursor, has_more) in every response

---

### BL-005: Rate limit tuning for analytical patterns

**Priority:** Medium
**Reported:** 2026-06-13
**Context:** A scripted workaround for BL-002 (looping 98 depts × 4 NAICS codes) hit rate limits after ~120 requests, producing 274 errors. Major departments (DoD, DHS, HHS, VA, GSA) were completely missing from results.

**Proposed fix:** Increase burst tolerance for legitimate sequential access patterns. Consider authenticated tier with higher rate limits. Fixing BL-002 and BL-003 largely eliminates this issue at the source.

---

### BL-006: CSV export broken

**Priority:** Medium
**Reported:** 2026-06-13
**Context:** Adding `format=csv` to dataset row requests returned empty files for every request. Either the format parameter isn't implemented or it's gated behind auth without a clear error.

**Proposed fix:** Implement CSV export or return an explicit error if unsupported/auth-gated.

---

### BL-007: NAICS filters missing on key datasets

**Priority:** High
**Reported:** 2026-06-23 (S7-012 AI smoke test, Q2 + Q3)
**Context:** Four datasets that should support NAICS-scoped queries do not accept a NAICS filter, forcing the AI to query agency-wide and hand-filter or infer:
- `pipeline.agency_recompete_summary` — can't answer "top agencies by recompete value in NAICS X"
- `acquisition.agency_vehicle_mix_fy` — can't answer "what vehicles were used on expiring contracts in this NAICS"
- `acquisition.vehicle_program_vendors` — same; agency × vehicle_family × FY only
- `set_aside.agency_profile_fy` and `set_aside.trend_fy` — can't scope set-aside share to a NAICS
- `entrants.agency_cohort_fy` — new-entrant survival is agency-wide, not NAICS-scoped

**Impact:** The AI had to infer vehicles from PIID prefixes and substitute `small_biz_obligation_share` (dollar share from `market.agency_naics_fy`) for the set-aside question. Directionally useful but not authoritative.

**Proposed fix:** Add `principal_naics_code` (and/or `naics_prefix`) filter to each of these datasets. For `entrants.agency_cohort_fy`, this requires the underlying MV to carry NAICS — may need a rebuild.

---

### BL-008: Topic catalog — department code mismatch and missing FY filter

**Priority:** Medium
**Reported:** 2026-06-23 (S7-012 Q3), expanded 2026-06-24 (S7-012b Q11)
**Context:** Two real issues found (NOT the literal program-name matching — topics are derived from corpus text, so "zero trust" not appearing as a literal topic is expected behavior):
1. **Department code mismatch** — `fpds_lookup_dimension` uses `department_id` (FPDS format "1900"/"7500") but topic catalog uses `department_code` (USASpending CGAC format "019"/"075"/"97AK"). Required cross-walking via `topics.agency_profile`.
2. **No FY filter on `topics.competitive_landscape`** — vendor totals cumulative back to FY1958 per `source_fiscal_years`. Cannot isolate current market share.

**Note:** Literal program names ("zero trust," "ICAM," "cloud migration") not resolving as exact topic matches is **not a gap** — topic derivation works from corpus text, not a controlled vocabulary. The derived topics that *do* exist cover these capability areas under different labels.

**Proposed fix:** (1) Align department code format between dimensions and topic catalog, or add a crosswalk. (2) Add `fiscal_year` filter to `topics.competitive_landscape`.

---

### BL-009: Obligation-weighted competition share needed

**Priority:** Medium
**Reported:** 2026-06-23 (S7-012 Q1)
**Context:** `market.agency_naics_fy` exposes `not_competed_action_share` (action count share) but not an obligation-dollar-weighted share. For competitive displacement analysis, the dollar share matters more than action count — a single $500M sole-source action and a $5K competed micro-purchase both count as "1 action."

**Impact:** AI had to aggregate action counts across NAICS codes per agency-FY as a proxy. Obligation-weighted share could shift the trend direction for agencies with a few large sole-source awards.

**Proposed fix:** Add `not_competed_obligation_share` to `market.agency_naics_fy` (and the group-level rollup). Requires the underlying MV to carry `extent_competed` × `total_obligated` — verify column availability.

---

### BL-010: SDVOSB flag missing from NAICS-grain incumbent views

**Priority:** Medium
**Reported:** 2026-06-23 (S7-012 Q1)
**Context:** `incumbent.agency_naics_vendor_leaders` exposes `is_small_business` but not `is_sdvosb` (or other socio-economic flags). The `incumbent.office_vendor_leaders` view does carry SDVOSB, but at office-grain — not NAICS-scoped.

**Impact:** Cannot identify SDVOSB incumbents at the NAICS level — a direct question for SDVOSB firms doing market research under a GWAC vehicle.

**Proposed fix:** Add `is_sdvosb`, `is_wosb`, `is_8a`, `is_hubzone` to `incumbent.agency_naics_vendor_leaders`. Verify the underlying MV sources from `fpds_actions` socio-economic flags.

---

### BL-011: Pagination flaky at high limits

**Priority:** Medium
**Reported:** 2026-06-23 (S7-012 Q2)
**Context:** `pipeline.recompete_watchlist` returned HTTP 400 at `limit=100` and `limit=500`. Cursor pagination (`offset=25`) timed out on one call. AI worked around it by staying at `limit=25` and accepting undercoverage of the long tail.

**Impact:** Large dataset queries silently fail or time out. Users hitting this won't know to fall back to small limits.

**Proposed fix:** Investigate timeout root cause (likely a slow underlying query at high offset). Implement cursor-based pagination (BL-004) to replace offset pagination. Add explicit error messages with suggested limit values.

---

### BL-012: `fpds_resolve` doesn't accept numeric NAICS codes

**Priority:** Low
**Reported:** 2026-06-23 (S7-012 Q2, Q3)
**Status:** FIXED 2026-06-24 (commit `82728b6`). Folded into BL-016 fix — code columns added to searchable_columns.
**Context:** `fpds_resolve(q="541512")` and `fpds_resolve(q="541519")` returned 0 results. Only description-string queries ("Other Computer Related Services") resolved the code. Counter-intuitive — users naturally search by code, not description.

**Impact:** Minor friction. AI fell back to `fpds_lookup_dimension(dimension_id=naics, filters={naics_code:"541512"})` which works, but the resolve tool should handle both.

**Proposed fix:** Update `fpds_resolve` to check for numeric strings and match against `naics_code` in addition to description text.

---

### BL-013: `agency_short_name` null for many civilian agencies

**Priority:** Low
**Reported:** 2026-06-23 (S7-012 Q3)
**Status:** FIXED 2026-06-24 (commit `82728b6`). 120 agencies + 17 departments populated via SQL migration 061.
**Context:** `agency_short_name` returned null for VA, State, IRS, NASA, and others in `market.entry_difficulty_score` and related datasets. AI had to fall back to `contracting_agency_name` for labeling.

**Impact:** Cosmetic — doesn't block queries but makes output uglier and harder to scan.

**Proposed fix:** Populate `agency_short_name` in the agency dimension table for all major civilian agencies. Likely a one-time UPDATE against `analytics_dims.agencies`.

---

### BL-014: `limit` parameter universally capped at 25 despite docs claiming 500–1000

**Priority:** Critical
**Reported:** 2026-06-24 (S7-012b — 6 of 12 queries)
**Status:** FIXED 2026-06-24 (commit `50c129e`)
**Context:** The single most impactful finding. Catalog metadata declares `max_limit: 500` or `max_limit: 1000` on most datasets, but any `limit` value > 25 returns HTTP 400. Affected: `geography.mismatch_leaders`, `acquisition.vehicle_program_vendors`, `contacts.naics_buyers`, `geography.place_profile_fy`, `pipeline.recompete_watchlist`, and others. AI had to page in batches of 25, making large analyses impractical.

**Impact:** Any query needing >25 rows per call requires 4–40× more API calls than necessary. Rate limits compound the problem. This is the #1 blocker for real analytical use.

**Fix applied:** `APIAccess.max_rows_per_request` now uses `field(default_factory=public_row_limit)` (returns 100 via `FPDS_ANALYTICS_PUBLIC_ROW_LIMIT` env var, default 100). Was hardcoded 25. Health/ai_assistant_guide endpoint updated to call `public_row_limit()` instead of hardcoded 25. Authenticated tiers (beta=250, internal=10000) were already correct. Tests added: `test_bl014_public_default_limit_matches_public_row_limit`, `test_bl014_health_endpoint_reports_correct_public_limit`.

**Remaining:** Deploy to Render (auto-deploy triggered). Consider raising to 250 for public tier in future if rate limits tolerate it.

---

### BL-015: Documented filters rejected as 400

**Priority:** High
**Reported:** 2026-06-24 (S7-012b — Q4, Q8, Q9, Q10, Q14)
**Status:** FIXED 2026-06-24 (commit `82728b6`). Confirmed as BL-014 misattribution — all filters work correctly. Regression tests added.
**Context:** At least 6 filter parameters are documented in the catalog but rejected by the server:
- `is_in_state` (geography.mismatch_leaders) — both boolean and string
- `fiscal_year_min`/`fiscal_year_max` (set_aside.family_trend_fy, naics.trend_fy)
- `user_class` (contacts.naics_buyers) — documented example uses exactly this value
- `is_cross_department` (funding.mismatch_flows_fy) — boolean rejected, string "true" works
- `sort` params listed as sortable but rejected on multiple datasets

**Impact:** Users following documentation hit 400 errors and don't know why. Erodes trust in the API contract.

**Proposed fix:** Audit every documented filter against actual server behavior. Either implement the filter or remove it from the catalog. Add integration tests that validate catalog claims.

---

### BL-016: `fpds_resolve` fails for valid codes (PSC, NAICS, department)

**Priority:** High
**Reported:** 2026-06-24 (S7-012b — Q7, Q10, Q11)
**Status:** FIXED 2026-06-24 (commit `82728b6`). Code columns (naics_code, psc_code, department_id, agency_id) added to searchable_columns in dimensions.yaml.
**Context:** `fpds_resolve` returns 0 results for valid PSC codes ("R425"), NAICS codes ("541512", "541519"), and department codes ("97AK", "9761"). Only description-string queries resolve. This expands BL-012 (which only noted NAICS) — the resolver is broken across multiple dimension types.

**Impact:** AI had to fall back to `fpds_lookup_dimension` with filters, adding friction. Users naturally search by code.

**Proposed fix:** Update `fpds_resolve` to match numeric/code strings against all dimension ID fields, not just description text.

---

### BL-017: `fields` projection parameter rejected

**Priority:** Medium
**Reported:** 2026-06-24 (S7-012b — Q6, Q10, Q15)
**Status:** FIXED 2026-06-24 (commit `82728b6`). Confirmed as BL-014 misattribution — fields param works with sort+filter. Regression test added.
**Context:** The `fields` parameter (to select specific columns) returns 400 when combined with sort or filter. Every call returns all fields, bloating payloads.

**Proposed fix:** Implement `fields` projection or remove from documentation if unsupported.

---

### BL-018: Multi-level drill-down queries structurally fail

**Priority:** High
**Reported:** 2026-06-24 (S7-012b — Q5, Q13)
**Context:** Q5 (DHS → offices → monthly → NAICS) hit max turns (30). Q13 (VA → offices → vendors → cross-agency market leaders) timed out at 600s. Both involve 4-level fan-outs where each level requires multiple API calls. The agent turn/time budget cannot accommodate these patterns.

**Impact:** Real analytical questions that require deep drill-downs (agency → office → vendor → cross-agency) are unanswerable in a single agent session. Users would need to manually break these into sub-queries.

**Proposed fix:** Two approaches:
1. **Pre-aggregated datasets** — build cross-cut views that answer common drill-down patterns in one call (e.g., `customer.top_office_vendor_cross_agency`)
2. **Higher turn budget** — raise `--max-turns` for analytical use cases (band-aid, not a real fix)

---

### BL-019: Missing cross-cut datasets

**Priority:** Medium
**Reported:** 2026-06-24 (S7-012b — Q4, Q7, Q8, Q9, Q14)
**Context:** 11 cross-cut datasets would have unblocked specific queries:
- Agency × PSC × NAICS (Q7)
- State × NAICS × FY (Q14)
- Funding department × small-business indicator (Q9)
- Set-aside family × entrant cohort (Q8)
- State-scoped HHI / concentration (Q4)
- Vendor-level data tied to performance state (Q4)
- Vehicle filter on recompete watchlist (Q6)
- FY filter on recompete watchlist (Q10)
- FY filter on topics.competitive_landscape (Q11)
- Bureau-level grain on risk scorecards (Q12)
- Agency-level duration baseline filtered to >$10M tier (Q15)

**Proposed fix:** Triage by impact. State × NAICS × FY and Agency × PSC × NAICS are the highest-value gaps — they unblock the most common analytical questions.

---

### BL-020: Vendor UEI fragmentation

**Priority:** Medium
**Reported:** 2026-06-24 (S7-012b — Q6, Q15)
**Context:** Same legal entity appears under multiple UEIs (Boeing: 13+ UEIs, Leidos: 3, SAIC: 2, CACI: 2, IBM: 2, Lockheed Martin: multiple, Raytheon: multiple). UEI-based vendor concentration analysis severely undercounts primes. Same entity counted as separate vendors in market share calculations.

**Impact:** Vendor concentration, market share, and competitive landscape analyses are all unreliable at the UEI level. AI had to hand-collapse via name matching.

**Proposed fix:** Build a UEI→canonical-vendor mapping table (similar to `vendor_name_by_uei` but with parent-entity grouping). Consider using SAM.gov's ultimate-parent-UEI field if available.

---

### BL-021: No `data_as_of` timestamp on responses

**Priority:** Low
**Reported:** 2026-06-24 (S7-012b — Q8, Q12)
**Status:** FIXED 2026-06-24 (commit `82728b6`). 79 dataset_refresh_log entries populated. data_as_of now returns real timestamps.
**Context:** No response includes a `data_as_of` or `last_refreshed` timestamp. Users can't tell if FY2025 data is current or stale. Q8 found FY2025 set-aside totals that look like MV refresh lag, but couldn't confirm.

**Proposed fix:** Add `data_as_of` field to all responses, sourced from the underlying MV's last refresh timestamp.

---

### BL-022: Negative obligations producing misleading metrics

**Priority:** Medium
**Reported:** 2026-06-24 (S7-012b — Q6, Q8, Q10, Q12)
**Status:** FIXED 2026-06-24 (commit `82728b6`). Rows with negative obligations flagged with _negative_obligation. Response meta includes negative_obligation_count.
**Context:** De-obligations exceed positive obligations for some agencies/periods, producing negative shares and zero-floored percentages. Examples:
- HUD: risk_score = −0.7848, sole-source share = −0.2539
- NARA: cost-type dollars negative but share silently zero-floored
- GSA Alliant FY2025 = −$103.7M (all de-obligations)
- Multiple buyers with negative obligated amounts

**Impact:** Risk scores, share metrics, and rankings are misleading when de-obligations dominate. No flag in data to warn users.

**Proposed fix:** (1) Add a `net_obligation_sign` flag (`positive`/`negative`/`mixed`) to affected datasets. (2) Consider showing gross obligation + de-obligation separately rather than net. (3) Suppress share calculations when denominator is negative, with an explicit `null` + reason.

---

### BL-023: `source_fiscal_years: [1958, 2026]` on every response

**Priority:** Low
**Reported:** 2026-06-24 (S7-012b — Q4, Q6, Q7, Q11)
**Status:** FIXED 2026-06-24 (commit `82728b6`). source_fiscal_years now computed from actual returned rows. Null when no fiscal_year column.
**Context:** Every response includes `source_fiscal_years: [1958, 2026]` in metadata, reflecting the full corpus span rather than the actual rows returned. Misleading — suggests the data includes 68 years of records when it's typically a 3-year window.

**Proposed fix:** Set `source_fiscal_years` to the actual min/max FY of returned rows, not the corpus.

---

### BL-024: `sector_label` null while `sector_code` populated

**Priority:** Low
**Reported:** 2026-06-24 (S7-012b — Q7, Q14)
**Status:** FIXED 2026-06-24 (commit `82728b6`). 1,722 rows updated via SQL migration 060. sector_label + subsector_label populated.
**Context:** `sector_label` (e.g., "Manufacturing," "Professional, Scientific, and Technical Services") is null on every row of `psc.naics_crosswalk`, `market.naics_customer_leaders`, and `naics.growth_leaders`, while `sector_code` (e.g., 54) is populated.

**Proposed fix:** Join against the NAICS sector dimension to populate `sector_label` wherever `sector_code` is present.

---

## Completed

### BL-001: Resolve UEIs to vendor names across datasets
**Completed:** 2026-06-23 (S7-013). `sql/059` created `analytics_dims.vendor_name_by_uei` materialized lookup (561K rows). `incumbent.agency_naics_vendor_leaders` now returns `vendor_name`. 99.998% coverage.
