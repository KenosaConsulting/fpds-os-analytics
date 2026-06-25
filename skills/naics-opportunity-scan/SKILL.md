---
name: naics-opportunity-scan
description: "Scan a NAICS code across agencies to find growth opportunities and emerging markets."
metadata:
  openclaw:
    emoji: "🔍"
    requires:
      env: ["FPDS_API_KEY"]
---

# NAICS Opportunity Scan

## When to Use

You have a NAICS code (your company's industry classification) and want to
find which federal agencies are the best targets for growth:

- "Where are the growth opportunities in NAICS 541512?"
- "Which agencies are increasing spending in cybersecurity (541512)?"
- "Scan NAICS 236220 for state-level geographic opportunities."
- "What's the growth trend for my NAICS across the federal government?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **NAICS code** | The industry classification to scan | User provides or NAICS lookup |
| **Time range** (optional) | Fiscal years to analyze | Default: last 5 complete FYs |
| **Geographic focus** (optional) | Filter to specific states or regions | User specifies |
| **Minimum spend** (optional) | Filter out agencies with trivial spend | Default: $1M annual average |

## Workflow

### Step 1: Get the national growth picture

Call `fpds_query_dataset` on `naics.growth_leaders` with:

- `principal_naics_code` = the NAICS code
- `fiscal_year_min` = start of time range
- `limit` = 30
- `sort` = `growth_rate_desc`

This returns agencies ranked by growth rate — which agencies are increasing
spending in your NAICS the fastest.

### Step 2: Get the market leaders by agency

Call `fpds_query_dataset` on `concentration.vendor_market_leaders` with:

- `principal_naics_code` = the NAICS code
- `fiscal_year_min` = start of time range
- `limit` = 50
- `sort` = `net_obligated_amount_desc`

This shows where the money is going — which agencies spend the most in this
NAICS, regardless of growth rate. Cross-reference with Step 1 to find the
sweet spot: agencies with both high spend AND high growth.

### Step 3: Geographic breakdown (if geographic focus specified)

Call `fpds_query_dataset` on `geography.state_naics_fy` with:

- `principal_naics_code` = the NAICS code
- `fiscal_year_min` = start of time range
- `limit` = 50
- `sort` = `net_obligated_amount_desc`

This shows which states have the most contract activity in this NAICS — useful
for identifying where the work is being performed (not just where it's being
bought). A DC-area buying office may fund work performed nationwide.

### Step 4: Identify the sweet spot agencies

Cross-reference the growth leaders (Step 1) with the market leaders (Step 2):

- **High spend + High growth** → Prime targets. Active market, growing budget.
- **Low spend + High growth** → Emerging markets. Getting in early could pay off.
- **High spend + Low/negative growth** → Declining markets. May still be worth
  pursuing for recompetes, but the long-term trend is unfavorable.
- **Low spend + Low growth** → Skip. Not enough market to justify the effort.

### Step 5: Drill into the top 3-5 agencies

For each sweet-spot agency, call `fpds_query_dataset` on
`concentration.vendor_market_leaders` filtered to that department to see:
- Who the incumbents are
- Market concentration
- Whether there's room for a new entrant

### Step 6: Present the scan

```
## NAICS Opportunity Scan: [code] ([description])

### National Overview (FY [range])
- Total federal obligations: $X.XB
- 5-year trend: [growing/stable/declining] ([% change])
- Agencies awarding in this NAICS: NNN
- Distinct vendors: N,NNN

### Growth Leaders (Top 10 by growth rate)
| Rank | Department | FY[YYYY] Obligations | 5-Yr Growth | Trend |
|------|-----------|---------------------|-------------|-------|
| 1 | [name] | $X.XM | +NN% | ↑ |
| ... | | | | |

### Market Leaders (Top 10 by obligation volume)
| Rank | Department | 5-Yr Obligations | Annual Avg | Growth |
|------|-----------|------------------|------------|--------|
| 1 | [name] | $X.XB | $X.XM | +NN% |
| ... | | | | |

### Sweet Spot Agencies (high spend + high growth)
| Department | 5-Yr Obligations | Growth | Concentration | Opportunity |
|-----------|------------------|--------|---------------|-------------|
| [name] | $X.XM | +NN% | [H/M/L] | [assessment] |

### Geographic Distribution (top 10 states by performance location)
| State | 5-Yr Obligations | % of National | Trend |
|-------|-----------------|---------------|-------|
| ... | | | |

### Top Agencies — Competitive Detail

#### [Department Name] — [Growth Rate]% growth, $[X.XM] annual
- **Top 5 vendors:**
  1. [name] — NN% share
  2. ...
- **Concentration:** [high/moderate/low] (top 5 = NN%)
- **Set-aside usage:** NN% of actions
- **Recompete pipeline:** [N] contracts expiring in next 12 months ($X.XM)
- **Assessment:** [why this is or isn't a good target for your company]

### Recommendations
1. [Best agency to target and why]
2. [Secondary target]
3. [Geographic concentration to consider]
4. [Set-aside program that aligns with this NAICS]
```

## Caveats

- Growth rate is calculated over the time range specified. A single large
  award in one year can distort the rate. Check absolute numbers, not just
  percentages.
- "Growth" means growing obligated spending. It doesn't necessarily mean more
  opportunities — a single large IDV can inflate spending while the number of
  discrete opportunities stays flat.
- Geographic data reflects where work is *performed*, not where it's *bought*.
  A contract awarded by a DC office may fund work in 20 states. Use this to
  identify where the actual work happens, not where to focus business
  development.
- Some NAICS codes are broad (e.g., 541512 "Computer Systems Design Services"
  covers everything from cloud migration to cybersecurity to software dev).
  The scan gives you the macro picture — drill into specific offices for
  tighter intelligence.

## Example Conversation

**User:** "Where should I focus my business development for NAICS 541512?"

**Agent:**
1. Queries `naics.growth_leaders` for NAICS 541512, last 5 FYs
2. Queries `concentration.vendor_market_leaders` for the same NAICS
3. Identifies sweet-spot agencies (high spend + high growth)
4. Drills into top 3 agencies for competitive detail
5. Optionally checks geographic distribution
6. Presents scan with prioritized recommendations
