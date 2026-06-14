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

## Completed

_(none yet)_
