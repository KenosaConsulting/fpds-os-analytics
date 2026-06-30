---
name: account-plan-builder
description: "Build a structured account plan for a federal customer using FPDS analytics data."
metadata:
  openclaw:
    emoji: "📋"
    requires:
      env: ["FPDS_API_KEY"]
---

# Account Plan Builder

## When to Use

You need a structured account plan for a target federal customer — the kind of
document a capture manager or business development lead uses to prioritize
pursuits and guide engagement strategy:

- "Build me an account plan for the Army."
- "I need an account plan for DHS focused on cybersecurity."
- "Create an account plan for the Navy's IT services market."

This skill synthesizes data from the other skills (market analysis, recompete
pipeline, contracting officer patterns) into a single coherent document.

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Department or agency** | The target customer | Use `fpds_resolve` |
| **Focus NAICS** (optional) | The industry you're pursuing | User provides or NAICS lookup |
| **Time horizon** (optional) | How far forward to plan | Default: 12-18 months |
| **Your company info** (optional) | Your UEI, NAICS codes, socio-economic status | User provides — used for competitive positioning |

## Workflow

### Step 1: Resolve the customer

Call `fpds_resolve` with the department or agency name. Get the
`contracting_dept_id` and `contracting_agency_id`.

### Step 2: Customer profile

Call `fpds_customer_profile` with the department code. This returns a
high-level summary: total obligations, top NAICS, top offices, vendor diversity,
socio-economic breakdown.

### Step 3: Market analysis (for focus NAICS, if specified)

Run the [vendor-market-analysis](../vendor-market-analysis/SKILL.md) workflow:
- Top vendors and market share
- Concentration metrics
- Office-level breakdown

### Step 3b: Entry difficulty assessment

Query `market.entry_difficulty_score` with `principal_naics_code=<focus NAICS>` and
optionally `contracting_agency_id=<resolved>`. Returns a 0-100 entry difficulty score
with component breakdown (concentration, competition rate, incumbent stickiness, etc.).

### Step 3c: Pricing risk assessment

Query `pricing.risk_scorecard` with `contracting_dept_id=<resolved>`. Shows the
agency's cost-type exposure and T&M exposure — high cost-type share means higher
risk for fixed-price vendors.

### Step 3d: New entrant viability

Query `entrants.agency_cohort_fy` with `contracting_agency_id=<resolved>` for the
last 5 fiscal years. Shows new vendor count, median first-year foothold, and 2-year
survival rate — critical for gauging whether new entrants succeed at this agency.

### Step 4: Recompete pipeline

Run the [recompete-pipeline](../recompete-pipeline/SKILL.md) workflow:
- Expiring contracts in the next 12-18 months
- Prioritized by value and timing
- Enriched with office buying patterns

### Step 5: Contracting office patterns

For the top 3-5 offices (by obligation volume in the target NAICS):
- Query `contacts.office_roster` (filters: `contracting_office_id`, `contracting_agency_id`, `contracting_dept_id`) for the top 3-5 offices to get office-level contacts and buying profiles.
- Query `contacts.naics_buyers` with `principal_naics_code=<focus NAICS>` and `contracting_agency_id=<resolved>` to find COs who specifically buy in the target NAICS.
- Use these results to identify key relationships and office-level buying patterns.

### Step 6: Competitive positioning (if company info provided)

If the user provides their company's UEI, check whether they already have
a footprint in this department:
- Query `concentration.vendor_market_leaders` with `uei=<your_uei>` to see market share within the target.
- Query `concentration.vendor_cross_agency_rank` with `uei=<your_uei>` to see the vendor's rank across ALL agencies — this provides competitive positioning context beyond a single department.
- Query `incumbent.agency_vendor_leaders` with `uei=<your_uei>` and `contracting_agency_id=<resolved>` to check if your company already has a ranked position at this agency.
- Identify which offices they've won in
- Identify which NAICS they're strongest in
- Compare against the target department's top vendors

### Step 7: Synthesize the account plan

```
# Account Plan: [Department/Agency Name]

## 1. Executive Summary
- Target customer: [name] (dept code: [code])
- Focus area: [NAICS code] ([description])
- Planning horizon: [N] months (through [YYYY-MM])
- Account size: $X.XB annual obligations ([N] actions/year)
- Your current footprint: [existing relationship summary]

## 2. Customer Overview
### Budget & Spending
- Total FY [YYYY] obligations: $X.XB
- 5-year trend: [growing/stable/declining] ([% change])
- Top 5 NAICS (by obligation volume):
  1. [code] — [description] — $X.XB (NN%)
  2. ...

### Organization
- Top 5 contracting offices (by obligation volume):
  1. [office name] — $X.XB (NN%)
  2. ...

### Buying Style
- Competition profile: [open / set-aside heavy / mixed]
- Socio-economic preferences: [8(a) / SDVOSB / WOSB / HUBZone usage]
- Q4 spending pattern: [NN% of annual obligations in Q4]

### Risk Profile
- Entry difficulty score: [0-100] — [rationale from component breakdown]
- Cost-type exposure: [N]% (H/M/L risk for fixed-price)
- T&M exposure: [N]%
- New entrant 2-year survival rate: [N]%

## 3. Market Landscape (Focus NAICS)
### Market Size
- Total obligations (last 5 FY): $X.XB
- Annual average: $X.XM
- Trend: [growing/stable/declining]

### Top Competitors
| Rank | Vendor | Market Share | 5-Yr Obligations | Trend |
|------|--------|-------------|------------------|-------|
| 1 | [name] | NN% | $X.XM | ↑/↓/→ |
| ... | | | | |

### Concentration
- Top 5 share: NN% ([high/moderate/low])
- Your position: [not present / rank N / NN% share]

## 4. Opportunity Pipeline (Next 18 Months)
### Summary
- Total recompete opportunities: N ($X.XB total value)
- Imminent (0-3 months): N ($X.XM)
- Near-term (3-6 months): N ($X.XM)
- Pipeline (6-12 months): N ($X.XM)
- Long-range (12-18 months): N ($X.XM)

### Priority Pursuits
#### Priority 1: [PIID] — [Incumbent Vendor]
- **Value:** $X.XM
- **Expires:** [date] ([N] months)
- **Office:** [name]
- **Why pursue:** [rationale]
- **Competition:** [assessment]
- **Your advantage:** [teaming/tech/cost basis]
- **Next action:** [specific step + date]

#### Priority 2: ...

## 5. Key Relationships to Develop
| Office | CO Name | Title | Awards/Yr | Engagement Priority |
|--------|---------|-------|-----------|-------------------|
| [name] | [name] | [title] | NN | High |
| ... | | | | |

## 6. Strategy & Recommendations
### Market Entry / Expansion Strategy
- [Recommendation based on concentration analysis]
- [Recommendation based on competition profile]
- [Recommendation based on seasonality]

### Teaming Strategy
- [Potential teaming partners based on complementary NAICS]
- [Set-aside partners needed if office prefers set-asides]
- [Incumbent weakness to exploit]

### 90-Day Action Plan
1. [Specific action + owner + date]
2. [Specific action + owner + date]
3. [Specific action + owner + date]

### Risks & Mitigations
| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| [risk] | H/M/L | H/M/L | [action] |
| ... | | | |

## 7. Business Case Summary

### Addressable Pipeline
- Active expiring contracts (next 18 months): [N] contracts, $[X]M total value
- Average contract size: $[X]M
- Recompete rate (from duration profile): [N]% of contracts recompeted
- Estimated addressable pipeline: $[X]M

### Win Probability Assessment
- Entry difficulty score: [score]/100 ([rationale from components])
- Average offers per action: [N] (higher = more competitive)
- New entrant 2-year survival rate: [N]%
- Estimated win probability range: [X]% - [Y]%

### Investment Required
- Recommended B&P budget (next 12 months): $[X]K - $[Y]K
- Teaming partner investment: [yes/no], estimated [cost]
- Vehicle access cost (if high vehicle dependence): [estimate]

### Projected Return
- Conservative (Pwin low end): $[X]M pipeline x [X]% win rate = $[Y]M
- Expected (Pwin mid): $[X]M pipeline x [X]% win rate = $[Y]M
- ROI ratio (expected return / investment): [X]:1
```

## Caveats

- An account plan is only as good as the data behind it. FPDS data is
  comprehensive but not perfect — coverage gaps, reporting delays, and
  coding inconsistencies exist. Use the plan as a starting point, not gospel.
- The plan doesn't include information about solicitations currently open on
  SAM.gov. Cross-reference with SAM.gov for active opportunities.
- Contracting officer contact information is from FPDS award records. For
  current contact information, verify through the agency's website or direct
  outreach.
- The competitive analysis assumes the user's company info is accurate. If
  the UEI is wrong or the company has multiple registrations, the analysis
  will be incomplete.

## Example Conversation

**User:** "Build me an account plan for the Army, focused on IT services. My company is [name], UEI [code]."

**Agent:**
1. Resolves "Army" → dept code 9700
2. Gets customer profile for dept 9700
3. Runs market analysis for NAICS 541512 at Army
4. Runs recompete pipeline for Army, NAICS 541512, 18-month window
5. Runs contracting office patterns for top 5 Army IT offices
6. Checks the user's company footprint at Army
7. Synthesizes everything into the account plan template
