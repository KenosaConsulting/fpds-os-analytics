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

## Completed

_(none yet)_
