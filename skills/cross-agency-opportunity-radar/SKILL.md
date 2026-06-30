---
name: cross-agency-opportunity-radar
description: "Collaborative-filtering engine that finds agencies a vendor should target based on NAICS similarity to agencies where they already win."
metadata:
  openclaw:
    emoji: "🎯"
    requires:
      env: ["FPDS_API_KEY"]
---

# Cross-Agency Opportunity Radar

## When to Use

You want to find new agency targets where a vendor has zero presence but the buying patterns match their existing customer base:
- "Which agencies should I be selling to that I'm not?"
- "What agencies buy similar things to my existing customers?"
- "Where are the hidden opportunities my competitors haven't found?"
- "My vendor does IT services for Army and Navy — who else buys that same mix of NAICS?"
- "I'm a small business with three agency customers — where should I expand next?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Vendor UEI** | The vendor's Unique Entity Identifier | User provides it directly, or use `fpds_resolve` to find it |
| **Small business filter** | Limit to small-business vendors only | Set `vendor_is_small_business=true` |
| **Score threshold** | Minimum recommendation score (0-100) | Set `recommendation_score_min` to filter weaker signals |

## Workflow

### Step 1: Resolve the vendor UEI

If the user provides a company name instead of a UEI, call `fpds_resolve`
with the vendor name. You need the UEI for the dataset query.

If the user doesn't specify a vendor, ask them which vendor they want to
analyze. This dataset requires a vendor_uei filter.

### Step 2: Query the Opportunity Radar

Call `fpds_query_dataset` on `opportunity.radar` with:

- `vendor_uei` = the resolved UEI
- `sort` = `-recommendation_score`
- `limit` = 20

This returns agencies the vendor doesn't currently sell to, ranked by
a composite score combining NAICS similarity (40%), agency spend size (30%),
and entry accessibility (30%).

If the result is empty, the vendor either:
- Has fewer than 2 agency footprints (not enough data for collaborative filtering)
- Has no overlapping NAICS profiles with any other agency

In that case, fall back to `market.agency_naics_fy` to manually identify
agencies that buy the vendor's known NAICS codes.

### Step 3: Validate accessibility for top 5 recommendations

For the top 5 recommendations from Step 2, cross-reference the shared
NAICS codes with `market.entry_difficulty_score`:

- `contracting_agency_id` = recommended agency's ID
- `principal_naics_code` = each shared NAICS code (query separately or batch)

This returns the 0-100 entry difficulty score and its component breakdown
(HHI, not-competed share, vehicle dependence, offer intensity, incumbent
tenure). Compare against the `avg_entry_difficulty` field from the radar
output to validate the scoring.

### Step 4: Check competition posture for top 5

For the top 5 recommended agencies, call `fpds_query_dataset` on
`competition.agency_profile_fy` with:

- `contracting_agency_id` = recommended agency's ID
- `fiscal_year_min` = current FY minus 3

This returns competed/not-competed shares, bundled action share, and
average offers received. High not-competed share (>50%) combined with
low offer counts (<2) suggests structural barriers even if entry
difficulty scores appear moderate.

### Step 5: Check immediate opportunities for top 5

For the top 5 recommended agencies, call `fpds_query_dataset` on
`pipeline.agency_recompete_summary` with:

- `contracting_agency_id` = recommended agency's ID

This returns the count and obligation value of contracts expiring in
0-6 months, 6-12 months, 12-18 months, and 18-24 months. Agencies with
high expiring obligation in the next 6 months represent urgent
opportunities to pursue immediately.

### Step 6: Present findings

Present the results in a structured format that gives the vendor a
clear expansion roadmap.

## Output Template

```
## Cross-Agency Opportunity Radar: [Vendor Name] ([UEI])

### Current Footprint
- Active at [N] agencies
- Existing agencies: [comma-separated list]

### Top Agency Recommendations
| Rank | Agency | Score | Jaccard | Shared NAICS | Entry Difficulty | Spend |
|------|--------|-------|---------|-------------|-----------------|-------|
| 1 | [name] | [score] | [similarity] | [codes] | [0-100] | $[amount] |
| 2 | ... | | | | | |
...

### Deep Dive: Top 3 Recommendations

**1. [Agency Name]** — Score: [score]/100
- Shared capabilities: [list NAICS codes and what they mean]
- Entry accessibility: [difficulty score]/100 — [assessment: easy/moderate/challenging]
- Competition posture: [X]% competed, [Y] avg offers, [Z]% bundled
- Agency spend: $[total obligated]
- Immediate opportunities: [N] contracts expiring in 0-6 months ($[X]M)
- Key insight: [most important finding about this agency]

**2. [Agency Name]** ...

**3. [Agency Name]** ...

### Immediate Opportunities (Expiring Contracts)
| Agency | Expiring 0-6mo | Obligated 0-6mo | Expiring 6-12mo | Obligated 6-12mo |
|--------|---------------|-----------------|-----------------|-------------------|
| [name] | [N] | $[X] | [N] | $[X] |
...

### Action Plan
1. **Priority target**: [top agency] — [rationale based on score + immediate expirations]
2. **Pipeline development**: [2nd agency] — [rationale]
3. **Watch and prepare**: [3rd agency] — [rationale]
4. **Vehicle requirements**: [if entry difficulty flags vehicle dependence, note it]
5. **Teaming consideration**: [if market is concentrated, suggest teaming partners]
```

## Example Conversation

**User:** "My UEI is JF1HN11D8NU5. What new agencies should I target?"

**Agent:**
1. Queries `opportunity.radar` with `vendor_uei=JF1HN11D8NU5`, sorted by `-recommendation_score`, limit 20
2. For top 5 results, queries `market.entry_difficulty_score` for the shared NAICS codes
3. For top 5 results, queries `competition.agency_profile_fy` for competition posture
4. For top 5 results, queries `pipeline.agency_recompete_summary` for expiring contracts
5. Presents the opportunity radar with deep dives and action plan

## Caveats

- **Similarity ≠ win probability.** The radar identifies agencies that buy
  similar things to your existing customers — it does not predict whether you
  will win. Always cross-reference with entry difficulty, competition, and
  vehicle data before committing capture resources.
- **Two-agency minimum.** The collaborative filtering engine requires a vendor
  to have a footprint at 2+ agencies (where vendor_rank ≤ 50 at each). Vendors
  with only one agency relationship will not receive recommendations.
- **Refresh cadence.** The underlying materialized view refreshes with the
  analytics refresh cycle. New vendor wins, changes in NAICS profiles, or
  updated entry difficulty scores may not be reflected immediately.
- **NAICS-based similarity only.** The Jaccard similarity is computed on top-5
  NAICS code sets per agency. It does not consider PSC codes, contract size,
  vehicle types, or set-aside patterns — factors that can be equally important
  for targeting decisions.
- **Entry difficulty is a screening heuristic.** The entry difficulty score
  components are agency-level or agency-NAICS level signals. Treat them as
  directional indicators, not as precise win-probability estimates.
- **Cross-reference with pipeline data.** Agencies with high recommendation
  scores but few expiring contracts may require more lead time. Prioritize
  agencies with both high scores and near-term expirations.
