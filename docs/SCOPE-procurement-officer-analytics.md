# Scope: Procurement Officer Analytics (FPDS-022)

**Date:** 2026-06-10
**Status:** Pending approval
**Priority:** High — answers the customer's last-mile question: "who do I actually talk to?"
**Data basis:** All source columns verified against production `public.fpds_actions` (98.7M rows) on 2026-06-10. No assumptions — every claim below was checked against `pg_attribute` and `pg_stats`.

---

## Start With the Customer

Every dataset we've shipped answers *what* and *where*: which agencies buy, which NAICS grow,
which vehicles carry the work, which contracts expire. Our customer — a small-business BD lead,
an 8(a) capture manager, a first-time federal entrant — gets to the end of that analysis and
hits the same wall every time:

> "Great. **Who do I call?**"

That question is currently answered by expensive subscriptions (GovTribe, HigherGov) or by
cold-emailing office mailboxes. The raw material to answer it sits unused in our own source
table. This component turns it into the warmest output the API can produce: **a named, active
procurement contact, with evidence of what they buy, how they buy it, and why you specifically
should be talking to them.**

### The questions the customer is actually asking

1. *"Who handles procurement at this office, and are they still active?"*
2. *"Which buyer at this agency does 8(a) sole-source awards in my NAICS?"* — the single
   highest-value query for set-aside-eligible firms.
3. *"Who administered this expiring contract on the recompete watchlist?"* — turns a watchlist
   row into a phone call.
4. *"What does this person typically award — size, competition level, set-aside types — so I
   approach them with the right offer?"*
5. *"Is this office's buying done by people I can build relationships with, or fed in by
   automated systems?"* — itself a market-accessibility signal.

### Before / After

**Before:** "USACE Huntsville obligated $890M in 541330 last year, 22% small-business."
**After:** "USACE Huntsville obligated $890M in 541330. Twelve procurement contacts were active
there in the last 18 months. JANE.DOE@USACE.ARMY.MIL created 41 awards in your NAICS, 60%
set-aside, median award $740K — and she created the QSS contract on your recompete watchlist
that expires in 9 months."

That is the difference between market research and a meeting.

---

## The Data We Have (verified, with eyes open)

`fpds_actions` carries four user-identity fields plus one contact field:

| Column | Verified null rate | Verified n_distinct (sampled floor) | What it actually is |
|---|---|---|---|
| `created_by` | 0% | ~8,200+ | FPDS account that entered the award record — typically the contract specialist or buyer |
| `approved_by` | 22% | ~7,100+ | Approving official — closest proxy to the warranted contracting officer |
| `last_modified_by` | 2.5% | ~5,100+ | **Polluted for our purpose**: dominated by closeout bots (`DOD_CLOSEOUT`, `FPDS_CLOSEOUT`, `IDV_CORRECT`) touching old records |
| `closed_by` | 60.5% | ~900 | Almost entirely closeout automation — exclude |
| `email_address` | 97.5% | ~1,100 | IDV ordering-contact mailboxes (`oasisplusmods@gsa.gov`, `VIPR@fs.fed.us`) — **not** people. Route this finding to FPDS-021 as program-POC enrichment; out of scope here |

**The defining data reality:** the *most common* values in every user field are system
accounts — `EBS.SYSADMIN.DLA.MIL`, `00.F.SYSTEMADMIN@GSA.GOV`, `MIGRATOR`, `FPDSADMIN`. Most
agencies push FPDS records from contract-writing systems under batch identities; the humans
live in the long tail (email-format IDs like `FIRST.LAST@AGENCY.GOV` and agency userids).

**Therefore this component is, first, a classification problem — human vs. system — and only
then a directory.** Getting that layer right is the whole product. Shipping it wrong (system
accounts presented as people) would be the trust-destroying failure mode, and the design below
treats it as such.

**Honesty requirement carried into every caveat:** `created_by` identifies who *entered the
record*, not necessarily a warranted KO. `approved_by` is closer to the CO but not guaranteed.
The product language is "procurement contacts" / "contracting activity personnel," never a
claim of warrant status. This is the same data basis the commercial tools use; we win by being
clearer about what it means, not by overclaiming.

---

## What We'd Build

### 1. Classification Layer — human vs. system (the foundation)

**Table:** `analytics_dims.fpds_user_classification_rule` (curated, ~50–150 rows)
Pattern rules: `%SYSADMIN%`, `%_CLOSEOUT`, `FPDSADMIN`, `MIGRATOR`, `IDV_CORRECT`, `%BATCH%`,
`%INTERFACE%`, `%CONVERSION%`, `%MIGRAT%`, `%SYSTEM%`, agency-specific feeders discovered in
Step 0. Plus **behavioral backstops** computed at build time: accounts exceeding plausible
human volume (e.g., >5,000 actions in a single FY, or activity spanning >10 departments) are
auto-classed `system` regardless of name shape; email-format IDs matching `first.last@*.gov/.mil`
are presumption-`human`.

Every user gets `user_class`: `human` / `system` / `unknown`, with `class_source`
(rule / behavioral / format) for transparency. `unknown` is a first-class value — never
force-classify.

### 2. Procurement Contact Directory

**Table:** `analytics_dims.fpds_procurement_contact` (one row per distinct user identity;
exact census is Build Step 0 — treat sampled n_distinct as a floor, the ref_piid lesson)

| Column | Notes |
|---|---|
| `user_id` | PK — normalized (upper, trimmed) identity string |
| `user_class`, `class_source` | from the classification layer |
| `display_name` | parsed from email-format IDs (`JANE.DOE@X` → `Jane Doe`); null when unparseable — never fabricate |
| `email` | the user_id itself when email-format, else null |
| `primary_dept_id` / `primary_agency_id` / `primary_office_id` (+names) | **majority vote** across their created/approved actions |
| `roles_seen` | array: creator / approver |
| `first_seen_fy`, `last_seen_fy`, `is_active_recent` | last_seen_fy >= current_fy − 1 |
| `lifetime_actions_created`, `lifetime_actions_approved`, `lifetime_obligated_created` | |
| `name_confidence` | high (email-format, parsed) / medium (consistent userid) / low |

Attribution rule baked into all aggregates: **use `created_by` and `approved_by` as recorded at
award time; never attribute via `last_modified_by`** (closeout-bot pollution, verified above).

### 3. Materialized Views

All builds follow the FPDS-017 protocol: full source scan via nohup/psql session-pooler with
`statement_timeout=0`, sequential, never MCP `apply_migration`. FY2010+.

**MV A — Contact × Office × FY:** `customer_intelligence.mv_fpds_contact_office_fy`
Grain: user_id × dept × agency × office × FY × role (creator/approver). Measures:
obligated_amount, action_count, distinct_vendor_count, small_biz obligated, set-aside action
count, not-competed action count, median award size. The workhorse.

**MV B — Contact × NAICS (trailing 3 FY):** `mv_fpds_contact_naics_3yr`
Grain: user_id × principal_naics_code (+ sector). Measures: obligated, actions, set-aside
share, sole-source share, distinct vendors. Powers the killer query: *"who buys my NAICS at
this agency, and how."* Restricted to `user_class='human'` rows at build for size; 3-year
window keeps it current.

**MV C — Contract → Contact bridge:** `mv_fpds_contract_contacts`
Grain: (piid, agency_id) → creator user_id at original award, most recent human approver,
their classes and last-seen dates. **This is the recompete watchlist's missing handshake** —
built directly from `fpds_actions`, requiring no rebuild of the 69M-row contract-family MV.
The watchlist report view LEFT JOINs it to add "who handled this contract."

**Office coverage stat (cheap derivative):** per office × FY, the share of obligations
attributable to human-classed users — published as `human_attribution_share` so users (and our
caveats) know exactly how much signal exists per office. DoD-heavy offices will score low;
that transparency is a feature.

### 4. API Datasets (end-user framing first)

| Dataset ID | The customer's question | Grain |
|---|---|---|
| `contacts.office_roster` | "Who's actively handling procurement at this office?" | contact × office, recent window; defaults: `user_class=human`, `is_active_recent=true`, sorted by recent obligated |
| `contacts.profile_fy` | "What does this person award, year by year?" | contact × FY |
| `contacts.naics_buyers` | "Who buys my NAICS at this agency — and do they set work aside?" | contact × NAICS (3yr); filters incl. min set-aside share |
| `contacts.recompete_handlers` | "Who handled the expiring contracts I'm chasing?" | via MV C join, exposed both as watchlist columns and standalone |

Required-filter rule applies everywhere (office, agency, NAICS, or user_id — never an
unfiltered roster). Dimension exposure: `GET /v1/dimensions/procurement_contacts` with `q=`
search on display_name/user_id, defaulting to human + active (the office-resolver lesson).
`fpds_resolve` gains `types=["contacts"]`. Every response carries the role-semantics caveat.

**Example customer flow (the whole point, end to end):**

```bash
# 1. My recompete target — who handled it?
GET /v1/datasets/pipeline.recompete_watchlist/rows?contracting_office_id=W912DY&expiration_bucket=6_to_12_months
#    → rows now include contact_user_id / contact_display_name / contact_last_seen_fy

# 2. What else does she buy?
GET /v1/datasets/contacts.profile_fy/rows?user_id=JANE.DOE@USACE.ARMY.MIL&sort=-fiscal_year

# 3. Who else at this agency buys 541330 with set-asides?
GET /v1/datasets/contacts.naics_buyers/rows?contracting_agency_id=2100&principal_naics_code=541330&sort=-setaside_obligated
```

### 5. AI-Assistant Integration

No new MCP tools — the existing seven cover the datasets via the catalog. Dataset descriptions
(FPDS-010 style) must teach the assistant the semantics: contacts are record creators/approvers,
not verified KOs; low `human_attribution_share` offices yield thin rosters; always pair a
contact suggestion with its evidence (actions, NAICS, recency). The Customer 360 profile
endpoint gains an optional `top_contacts` section.

---

## Responsible Use (in the doc because the customer-trust stakes are high)

These are federal employees identified in a public, legally mandated dataset, acting in their
official capacity — the same basis used industry-wide. Our obligations: present professional
context only (what they award, where, how); publish exactly what FPDS publishes — **no
enrichment of personal information** (no LinkedIn matching, no personal contact discovery —
that stays out of the open-source toolset permanently); parsed display names are clearly
provenance-marked; and the API includes a usage note that contacts should be approached through
official channels and that the data identifies record activity, not warrant authority. A
takedown/correction path (GitHub issue template) costs nothing and signals seriousness.

---

## Build Plan

| Step | What | Est. | Notes |
|---|---|---|---|
| 0 | **Census + coverage study**: exact distinct user counts (created_by, approved_by); human-pattern share of obligations by department; discover agency feeder accounts for the rule table | 1–2 hrs | Decides everything; sampled stats are floors |
| 1 | Classification rule table + behavioral thresholds (tuned with Step 0 output) | 3–4 hrs | The product's foundation |
| 2 | Contact directory build (full source scan) | ~35–60 min wall | FPDS-017 protocol |
| 3 | MV A + MV B (sequential) | ~60–90 min wall | Same protocol |
| 4 | MV C contract-contact bridge + watchlist report-view join | ~35 min + 1 hr | No contract-family MV rebuild needed |
| 5 | Report/facade views, grants, indexes, office coverage stat | <15 min | |
| 6 | Catalog entries (customer-question descriptions, role-semantics caveats, examples) + contract tests | 2 hrs | |
| 7 | Dimension endpoint + resolver type + Customer 360 `top_contacts` section | 2 hrs | |
| 8 | README/CHANGELOG + responsible-use note + issue template | 1 hr | |

**Total:** ~12–15 hrs development + ~2.5 hrs MV wall-clock.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| System accounts leak into rosters | Three-layer classing (rules + behavior + format), `unknown` never shown as human by default, Step-0 tuning, top-200-users manual review before launch |
| Coverage is thin at systemized agencies (much of DoD) | `human_attribution_share` published per office; caveats set expectations; civilians and many DoD activities still yield strong rosters |
| Stale contacts (people move) | `is_active_recent` default-on; `last_seen_fy` always displayed |
| Role overclaim ("this is the KO") | Locked product language + per-response caveat; `roles_seen` exposed |
| Closeout-bot misattribution | Hard rule: attribution from created/approved only — verified pollution in last_modified_by/closed_by |
| Perceived privacy concern | Responsible Use section, public-data-only policy, no personal enrichment, correction path |

## Security

Unchanged boundary: curated dims + MVs in existing schemas, `analytics_api` facades,
`fpds_analytics_api_readonly` grants, `public.fpds_actions` read at build time only, required
filters on all contact datasets, no new roles. Contact data is verbatim public FPDS content.

## Cross-Scope Notes

- `email_address` (IDV ordering mailboxes) → hand to **FPDS-021** as program-POC enrichment.
- MV C makes the recompete watchlist person-addressable — the two scopes together produce the
  flagship capability: *expiring contract → named handler → their buying pattern → your pitch.*
- Future (parking lot): contact-level Q4 behavior via the FPDS-017 seasonality grain ("when
  does this buyer spend"), and contact tenure/turnover as an office-stability signal.

---

*Awaiting Chairman approval. On approval, Step 0 runs first and its coverage findings are
reported before any build proceeds — if human attribution is materially weaker than expected,
we re-decide with data rather than ship a thin product.*
