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

### BL-008: Topic catalog gaps — zero trust, ICAM, identity management

**Priority:** Medium
**Reported:** 2026-06-23 (S7-012 Q3)
**Context:** `fpds_topic_search` returned 0 results for "zero trust," "zero trust architecture," "ICAM," "identity credential access," "access control authentication," "PIV HSPD-12," and "smart card." "Identity management" returned only 2 weak hits, neither aligned to NAICS 541519. The topic dimension only indexes generic "cybersecurity" topics aligned to 541512/541513.

**Impact:** Cannot rank agencies by topic alignment for zero-trust / identity-management work — a core capture intelligence question for any cybersecurity-focused vendor.

**Proposed fix:** Ingest zero-trust and ICAM topic definitions into the topic catalog. Likely requires curating keyword sets from CISA ZTMM reference documents and federal identity guidance (FICAM, HSPD-12, OMB M-22-09). Map to NAICS 541519 where appropriate.

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
**Context:** `fpds_resolve(q="541512")` and `fpds_resolve(q="541519")` returned 0 results. Only description-string queries ("Other Computer Related Services") resolved the code. Counter-intuitive — users naturally search by code, not description.

**Impact:** Minor friction. AI fell back to `fpds_lookup_dimension(dimension_id=naics, filters={naics_code:"541512"})` which works, but the resolve tool should handle both.

**Proposed fix:** Update `fpds_resolve` to check for numeric strings and match against `naics_code` in addition to description text.

---

### BL-013: `agency_short_name` null for many civilian agencies

**Priority:** Low
**Reported:** 2026-06-23 (S7-012 Q3)
**Context:** `agency_short_name` returned null for VA, State, IRS, NASA, and others in `market.entry_difficulty_score` and related datasets. AI had to fall back to `contracting_agency_name` for labeling.

**Impact:** Cosmetic — doesn't block queries but makes output uglier and harder to scan.

**Proposed fix:** Populate `agency_short_name` in the agency dimension table for all major civilian agencies. Likely a one-time UPDATE against `analytics_dims.agencies`.

---

## Completed

### BL-001: Resolve UEIs to vendor names across datasets
**Completed:** 2026-06-23 (S7-013). `sql/059` created `analytics_dims.vendor_name_by_uei` materialized lookup (561K rows). `incumbent.agency_naics_vendor_leaders` now returns `vendor_name`. 99.998% coverage.
