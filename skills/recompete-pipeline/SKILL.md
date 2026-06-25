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
- `remaining_months_max` = your time window (e.g., 12)
- `principal_naics_code` = NAICS code (if specified)
- `min_obligated_amount` = minimum value (if specified)
- `limit` = 50
- `sort` = `expiration_date_asc` (soonest expiring first)

This returns contracts with:
- PIID (contract number)
- Vendor name + UEI (the incumbent)
- Expiration date
- Remaining months
- Total obligated amount
- Contract description (if available)

### Step 3: Group and prioritize

Organize the results by:

1. **Imminent (0-3 months)** — These are already in the acquisition pipeline.
   The RFP may already be out. Check SAM.gov for the solicitation.
2. **Near-term (3-6 months)** — The contracting office is likely preparing the
   solicitation. Good window to start teaming discussions.
3. **Pipeline (6-12 months)** — Early enough to influence the requirement.
   This is where capture work adds the most value.
4. **Long-range (12+ months)** — Strategic visibility. Monitor for changes.

### Step 4: Enrich with office-level context

For each opportunity worth tracking, call `fpds_query_dataset` on
`customer.office_month_naics_fy` with the contracting office ID and NAICS code.
This shows the office's historical buying pattern in that NAICS — useful for
understanding whether they typically recompete or extend.

### Step 5: Present the watchlist

```
## Recompete Watchlist: [Department] — Next [N] Months

### Summary
- Total opportunities: N
- Total estimated value: $X.XB
- Imminent (0-3 months): N opportunities ($X.XB)
- Near-term (3-6 months): N opportunities ($X.XB)
- Pipeline (6-12 months): N opportunities ($X.XB)

### Top Opportunities (by value, expiring soonest)

#### 1. [PIID] — [Vendor Name] (Incumbent)
- **Expires:** YYYY-MM-DD ([N] months remaining)
- **Value:** $X.XM (total obligated)
- **Office:** [Office name] ([office ID])
- **NAICS:** [code] ([description])
- **Description:** [contract description]
- **Historical pattern:** This office has recompeted N of N similar contracts in the past 5 FYs.
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
- The `min_obligated_amount` filter uses total obligated amount, not ceiling
  value. A contract with a high ceiling but low actual spending may not appear.

## Example Conversation

**User:** "What recompete opportunities are coming up in DHS in the next 12 months?"

**Agent:**
1. Resolves "DHS" → `contracting_dept_id`
2. Queries `pipeline.recompete_watchlist` with remaining_months_max=12
3. Groups results by timing (imminent / near-term / pipeline)
4. Enriches top 5 opportunities with office buying patterns
5. Presents the watchlist with recommendations
