---
name: vendor-market-analysis
description: "Analyze vendor market share and competitive landscape for a target agency and NAICS code."
metadata:
  openclaw:
    emoji: "📊"
    requires:
      env: ["FPDS_API_KEY"]
---

# Vendor Market Analysis

## When to Use

You need to understand the competitive landscape for a specific federal market:
- "Who are the top vendors in Army IT services?"
- "How concentrated is the DHS cybersecurity market?"
- "What's the incumbent's market share in Navy logistics?"
- "Which vendors are expanding in this NAICS code?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Agency or department** | The federal customer (e.g., Army, DHS, Navy) | Use `fpds_resolve` to find the department code |
| **NAICS code** | The industry classification (e.g., 541512 for IT services) | Use `fpds_list_dimensions` → NAICS lookup, or the user provides it |
| **Time range** | Fiscal years to analyze (default: last 5 complete FYs) | User specifies, or default to current FY - 5 |

## Workflow

### Step 1: Resolve the customer

Call `fpds_resolve` with the department or agency name. You need the
`contracting_dept_id` for filtering.

If the user says "Army," resolve it. If they say "DHS Office of Procurement
Operations," resolve the office too — you'll get tighter data.

### Step 2: Get the market leaders

Call `fpds_query_dataset` on `concentration.vendor_market_leaders` with:

- `contracting_dept_id` = resolved department code
- `principal_naics_code` = the NAICS code
- `fiscal_year_min` = start of the time range
- `limit` = 20 (top 20 vendors)

This gives you vendor name, UEI, total obligations, action count, and market
share percentage.

### Step 3: Check concentration

Look at the top 5 vendors' combined market share:
- **> 60%** — Highly concentrated. Hard market to enter. Incumbent advantage is strong.
- **30–60%** — Moderately concentrated. Room for competition but established players dominate.
- **< 30%** — Fragmented market. Many small players, easier entry but harder to scale.

### Step 4: Drill into office × vendor × NAICS

If the market looks interesting, call `fpds_query_dataset` on
`concentration.vendor_office_naics_year` to see which offices within the
department are awarding to which vendors. This reveals:

- Which offices the incumbent is strongest in
- Which offices are more open to new vendors
- Whether the market is spread across many offices or concentrated in a few

### Step 5: Summarize

Present the findings in this structure:

```
## Vendor Market Analysis: [Department] — NAICS [code] ([description])

### Market Size (last [N] fiscal years)
- Total obligations: $X.XB
- Total actions: N,NNN
- Distinct vendors: NNN

### Top 10 Vendors
| Rank | Vendor | Obligations | Market Share | Actions |
|------|--------|-------------|--------------|---------|
| 1 | ... | ... | ...% | ... |
...

### Market Concentration
- Top 5 share: NN% ([high/moderate/low] concentration)
- Top 10 share: NN%
- HHI: NNNN ([concentrated/moderate/competitive])

### Office-Level Insights
- [N] offices awarded in this NAICS in the time range
- Largest office: [office name] ($X.XB, NN% of market)
- Most fragmented office: [office name] (NN vendors, top vendor NN% share)

### Key Findings
1. [Most important insight]
2. [Second most important]
3. [Third]

### Recommendations
- [Actionable recommendation based on the data]
```

## Caveats

- Market share is based on obligated amounts, not ceiling values. A vendor may
  have a large ceiling but low actual obligations.
- FPDS data has a known coverage gap for pre-2010 records. Use FY 2010+ for
  reliable comparisons.
- "Vendor" is identified by UEI. Companies with multiple UEIs (e.g., due to
  mergers or re-registration) will appear as separate entries. Flag this if
  you notice it.
- Some departments (notably DoD) have office code reuse across sub-agencies.
  The data accounts for this, but always check the department context.

## Example Conversation

**User:** "Who dominates Army IT services?"

**Agent:**
1. Resolves "Army" → `contracting_dept_id: 9700`
2. Resolves "IT services" → `principal_naics_code: 541512`
3. Queries `concentration.vendor_market_leaders` with dept=9700, naics=541512, FY 2020-2024
4. Queries `concentration.vendor_office_naics_year` for office-level detail
5. Presents the summary with top vendors, concentration metrics, and office insights
