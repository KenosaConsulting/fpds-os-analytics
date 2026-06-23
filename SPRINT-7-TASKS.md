# Sprint 7 — API User Management + Usability

**Started:** 2026-06-22
**Goal:** Beta testers can sign up, get API keys, and use the API successfully with AI assistants this week.
**Source repo:** `fpds-os-analytics` (production source of truth, deployed to Render)

---

## Phase A: Supabase Auth + API Key Management

| ID | Status | Task | Acceptance Criteria |
|---|---|---|---|
| S7-001 | done | Design + deploy `private.api_keys` schema on Supabase | Tables: `api_keys`, `api_key_usage_log`, `rate_limits`. RPC: `validate_api_key()`. pgcrypto enabled. Grants to analytics readonly role. SQL template committed to `sql/`. Smoke tested: create→validate→revoke→reject cycle passed. Applied to kenosa-federal-intel `tfrhforjvaafmqmxmtrt`. |
| S7-002 | done | Modify `app/auth.py` to validate keys against Supabase | `optional_api_access` checks Supabase RPC when key is supplied. Env-var fallback for backward compat during migration. Per-tier row limits enforced. 429 for rate-limited keys. Public default raised 25→100. 78/78 tests green. |
| S7-003 | todo | Admin key provisioning script | `scripts/manage_keys.py`: create, revoke, list, set-tier. Outputs plaintext key once on creation (never stored). |
| S7-004 | todo | Define tier system in catalog/config | Tiers: public (25 rows, 60/min), beta (250 rows, 300/min), partner (1000 rows, 1000/min), internal (10000 rows, no limit). Tier metadata in `api_keys` table. |
| S7-005 | todo | Issue beta keys for this week's testers | At least 2 beta keys generated and ready to distribute. |
| S7-006 | todo | Deploy auth changes to Render | Render env vars updated. Live validation confirmed. |

## Phase B: API Usability Fixes (backlog items blocking AI consumers)

| ID | Status | Task | Acceptance Criteria |
|---|---|---|---|
| S7-007 | todo | BL-002: NAICS prefix filter | `naics_prefix=5415` works on all datasets accepting `principal_naics_code`. Server-side `LEFT()` match. SQL template + catalog + tests. |
| S7-008 | todo | BL-003: Pre-aggregated NAICS group dataset | New MV at 4-digit NAICS group × dept × agency × FY grain. Catalog entry `market.naics_group_agency_fy`. |
| S7-009 | todo | BL-004: Raise public row limit + pagination metadata | Public limit 25→100. Add `has_more` and `total_count` (or estimate) to pagination response. Authenticated tiers get their configured limit. |
| S7-010 | todo | Update MCP tool descriptions for new capabilities | `fpds_query_dataset` description updated with NAICS prefix, new dataset, tier info. |

## Phase C: Testing + Validation

| ID | Status | Task | Acceptance Criteria |
|---|---|---|---|
| S7-011 | todo | MCP Inspector validation | All 8 MCP tools tested via `npx @modelcontextprotocol/inspector`. Zero protocol errors. |
| S7-012 | todo | AI end-to-end smoke test | 3 realistic procurement analyst queries (multi-dataset, cross-filter) executed by an AI model against the live API. All complete successfully. |
| S7-013 | todo | BL-001 audit: UEI→vendor name across all 78 datasets | Audit every dataset exposing `uei` — confirm `vendor_name` is present. List any gaps. |

---

## Build Order

```
S7-001 (schema)
  → S7-002 (auth integration)
  → S7-003 (admin script) + S7-004 (tiers)
  → S7-005 (issue keys) + S7-006 (deploy)
  → S7-007 (NAICS prefix) + S7-009 (row limits)
  → S7-008 (NAICS group MV)
  → S7-010 (MCP update)
  → S7-011 + S7-012 + S7-013 (testing)
```

## Test Queries for S7-012

These are realistic procurement analyst questions that exercise multi-dataset reasoning:

1. **Cross-filter competitive displacement:** "Which agencies show >$500M in NAICS 5415xx obligations with declining competition rates (year-over-year sole-source share increasing) and at least 3 incumbent vendors holding >15% market share — indicating a concentrated but contestable market for an SDVOSB offering cloud migration services under an existing GWAC vehicle?"

2. **Recompete pipeline with contact intelligence:** "For the top 5 agencies by recompete value expiring in the next 18 months in NAICS 541512, who are the contracting officers with the highest volume of recent awards in that code, what vehicles were used on the expiring contracts, and what is the pricing posture (fixed-price vs cost-type mix) for each agency?"

3. **Market entry scoring with topic alignment:** "Across all agencies with a market entry difficulty score below 60 for NAICS 541519, which have the strongest topic alignment with 'zero trust' or 'identity management', what is the small business set-aside share trend over the last 3 fiscal years, and which new entrant cohorts (first-award vendors in FY2024-2026) survived to a second award?"

---

**Rules:** Same as TASKS.md — one task at a time in ID order, set status before/after, commit with task changes, never weaken security boundary.
