---
name: recompete-pipeline
description: "Identify upcoming recompete opportunities and build a recompete watchlist."
metadata:
  openclaw:
    emoji: "🔄"
    requires:
      env: ["FPDS_API_KEY"]
---

# Recompete Pipeline

## When to Use

You need to find contracts that are coming up for recompete — expiring
indefinite delivery vehicles (IDVs), sole-source contracts ending, or
incumbent positions that will be open for competition:

- "What's expiring in DHS in the next 12 months?"
- "Show me recompete opportunities in NAICS 541512 for the Army."
- "Which incumbent contracts in my target agency expire this fiscal year?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Agency or department** | The federal customer | Use `fpds_resolve` |
| **Time window** | How far out to look (default: 12 months) | User specifies |
| **NAICS code** (optional) | Filter to a specific industry | User provides or use NAICS lookup |
| **Minimum contract value** (optional) | Filter out small contracts | User specifies (default: $1M) |

## Workflow

### Step 1: Resolve the customer

Call `fpds_resolve` with the department or agency name to get the
`contracting_dept_id`.

### Step 2: Query the recompete watchlist

Call `fpds_query_dataset` on `pipeline.recompete_watchlist` with:

- `contracting_dept_id` = resolved code
- `expiration_bucket` = your time window (values: `0-6 months`, `6-12 months`, `12-18 months`, `18-24 months`, `recently_expired`)
- `principal_naics_code` = NAICS code (if specified)
- `limit` = 50
- `sort` = `remaining_months` (soonest expiring first)

This returns contracts with:
- PIID (contract number)
- Vendor name + UEI (the incumbent)
- Expiration date
- Remaining months
- Total obligated amount
- Contract description (if available)

### Step 3: Link contracts to contracting officers

Call `fpds_query_dataset` on `contacts.recompete_handlers` with:

- `contracting_agency_id` = resolved agency code

Sort by `remaining_months`. This returns the contracting officer who created
each contract and the most recent human approver — the most actionable data
for capture teams building outreach lists.

### Step 4: Get modification history for top contracts

For the top 3-5 highest-value contracts, use the `fpds_contract_history` MCP
tool to pull the full modification trail: scope changes, option exercises,
funding increments, and de-obligations. This tells the real story of each
contract — whether the incumbent is executing steadily or the requirement is
being restructured.

### Step 5: Group and prioritize

Organize the results by:

1. **Imminent (0-3 months)** — These are already in the acquisition pipeline.
   The RFP may already be out. Check SAM.gov for the solicitation.
2. **Near-term (3-6 months)** — The contracting office is likely preparing the
   solicitation. Good window to start teaming discussions.
3. **Pipeline (6-12 months)** — Early enough to influence the requirement.
   This is where capture work adds the most value.
4. **Long-range (12+ months)** — Strategic visibility. Monitor for changes.

### Step 6: Enrich with duration context

For each opportunity worth tracking, call `fpds_query_dataset` on
`pipeline.duration_profile` with:

- `contracting_dept_id` = resolved code
- `contracting_agency_id` = agency code (if available)
- `principal_naics_code` = NAICS code (if specified)
- `naics_prefix` = NAICS prefix (optional broader lookup)

This shows typical contract durations at this office/agency for this NAICS —
answering whether contracts are typically 1-year or 5-year here, and whether
they tend to recompete or have long durations that lock in incumbents.

### Step 7: Present the watchlist

```
## Recompete Watchlist: [Department] — Next [N] Months

### Summary
- Total opportunities: N
- Total estimated value: $X.XB
- Imminent (0-3 months): N opportunities ($X.XB)
- Near-term (3-6 months): N opportunities ($X.XB)
- Pipeline (6-12 months): N opportunities ($X.XB)

### Duration Context
This agency typically awards [N]-year contracts in this NAICS, with median
duration of [X] months. [Assessment of recompete likelihood based on profile.]

### Top Opportunities (by value, expiring soonest)

#### 1. [PIID] — [Vendor Name] (Incumbent)
- **Expires:** YYYY-MM-DD ([N] months remaining)
- **Value:** $X.XM (total obligated)
- **Office:** [Office name] ([office ID])
- **NAICS:** [code] ([description])
- **Contracting Officer:** [Name] ([email]) — from recompete handlers
- **Description:** [contract description]
- **Modification history:** [Summary: N mods issued, X option exercises exercised, Y% funding change, last action date]
- **Action:** [Recommended next step based on timing]

#### 2. [PIID] — ...

### By NAICS
| NAICS | Description | Opportunities | Total Value |
|-------|-------------|---------------|-------------|
| ... | ... | N | $X.XM |

### Recommendations
1. [Highest-priority opportunity and why]
2. [Teaming target based on incumbent weakness]
3. [Next action for the capture team]
```

## Caveats

- The recompete watchlist is based on IDV expiration dates and contract
  periods of performance. Some contracts get extended or modified — treat
  dates as estimates, not guarantees.
- "Remaining months" is calculated from the current date. If the data hasn't
  been refreshed recently, dates may be slightly off.
- Not all expiring contracts will be recompeted — some are one-time buys,
  some get cancelled, some transition to other vehicles. Use the office
  buying pattern data to assess recompete likelihood.
- The dataset's default predicates already filter to contracts with $25K+
  total obligated amount. Contracts with high ceilings but low actual spending
  may appear lower in value rankings.

## Example Conversation

**User:** "What recompete opportunities are coming up in DHS in the next 12 months?"

**Agent:**
1. Resolves "DHS" → `contracting_dept_id`
2. Queries `pipeline.recompete_watchlist` with expiration_bucket filter
3. Links contracts to contracting officers via `contacts.recompete_handlers`
4. Pulls modification history for top-value contracts via `fpds_contract_history`
5. Groups results by timing (imminent / near-term / pipeline)
6. Enriches with contract duration context from `pipeline.duration_profile`
7. Presents the watchlist with recommendations
