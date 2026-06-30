---
name: teaming-partner-finder
description: "Find primes to team with at a target agency — set-aside compatibility, NAICS alignment, and cross-agency reach."
metadata:
  openclaw:
    emoji: "🤝"
    requires:
      env: ["FPDS_API_KEY"]
---

# Teaming Partner Finder

## When to Use

You are a small business trying to enter or expand in a federal agency market
and need to know which primes to partner with:

- "I'm an 8(a) IT services company targeting the VA — who should I team with?"
- "I'm an SDVOSB in NAICS 236220. Which primes at the Army need my set-aside status?"
- "I'm a WOSB in management consulting. Can I compete direct at DHS or do I need a prime?"
- "I'm an 8(a) in NAICS 541330 targeting the Navy. Which primes have complementary NAICS codes and strong positions there?"
- "Is teaming necessary at this agency or can I compete directly as a small business?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Agency or department** | The federal customer you are targeting | Use `fpds_resolve` |
| **NAICS code** | Your primary NAICS code | Use `fpds_list_dimensions` → NAICS lookup, or the user provides it |
| **Set-aside type** | Your socioeconomic designation (8a, sdvosb, wosb, hubzone, small_business) | User specifies (e.g., "I'm an 8(a)") |
| **Fiscal year** | Baseline year for analysis | Default: the latest complete fiscal year |

## Workflow

### Step 1: Resolve the agency and NAICS

Call `fpds_resolve` with the department or agency name to get the
`contracting_agency_id`. If the user says "VA," resolve it. If they say "Navy,"
resolve it.

If the user provides a NAICS description instead of a code (e.g., "IT services"),
use `fpds_list_dimensions` to resolve the description to a `principal_naics_code`.

### Step 2: Assess set-aside landscape

Call `fpds_query_dataset` on `set_aside.agency_profile_fy` with:

- `contracting_agency_id` = resolved agency code
- `fiscal_year` = latest complete fiscal year
- `sort` = `friendliness_rank`
- `limit` = 1

Check the key metrics:

- `contract_scope_setaside_obligation_share_known` — the share of known-status
  obligations that went to set-asides. High (>40%) means the agency actively
  uses set-asides. Low (<20%) means full-and-open dominates.
- `friendliness_rank` — how this agency ranks against peers on set-aside usage.

If the agency has high set-aside usage, you may not need a prime — you can
compete directly through your set-aside program. If low, teaming with a large
prime is more important for market entry.

### Step 3: Identify the top primes at the agency

Call `fpds_query_dataset` on `incumbent.agency_vendor_leaders` with:

- `contracting_agency_id` = resolved agency code
- `sort` = `vendor_rank`
- `limit` = 25

Filter the results to `is_small_business: false` — these are the large primes
you can potentially team with. Note their:

- `vendor_rank` — overall position at this agency
- `recent_3yr_obligated` — recent momentum (higher = more active)
- `tenure_years` — how long they have been working with this agency
- `active_fy_count` — consistency of activity
- Socioeconomic flags: `is_veteran_owned`, `is_women_owned`, `is_minority_owned`
  (even though these are not small businesses, their ownership flags indicate
  potential cultural alignment)

### Step 4: Find NAICS-specific leaders

Call `fpds_query_dataset` on `incumbent.agency_naics_vendor_leaders` with:

- `contracting_agency_id` = resolved agency code
- `principal_naics_code` = your NAICS code
- `sort` = `vendor_rank`
- `limit` = 25

This shows who wins specifically in your NAICS at this agency. Cross-reference
with the agency-wide leaders from Step 3. Primes that appear in both lists
(strong agency-wide AND strong in your NAICS) are the best teaming candidates.
Note `vendor_rank` and `recent_3yr_obligated` in this NAICS specifically.

### Step 5: Assess government-wide breadth

For the top 5-8 candidate primes identified in Steps 3-4, call
`fpds_query_dataset` on `concentration.vendor_cross_agency_rank` with:

- `uei` = each candidate vendor UEI
- `fiscal_year` = latest complete fiscal year
- `limit` = 250

Check `agency_count` — the number of agencies they serve. Government-wide primes
(many agencies) are better teaming partners: more stable, more resources, more
likely to have a formal small business liaison office. Agency-specialist primes
(few agencies) may offer deeper relationships at your specific target.

Sort by `-net_obligated_amount` to see their top agencies. Check whether your
target agency is a primary or secondary market for them — primes heavily
concentrated at your target are more motivated to win there.

### Step 6: Get lifetime context

For each candidate, call `fpds_query_dataset` on `concentration.vendor_market_leaders` with:

- `uei` = candidate vendor UEI
- `limit` = 1

This confirms their lifetime profile:

- `agencies_served` — total agencies across their entire history
- `avg_tenure_years` — average relationship length per agency
- `avg_annual_obligated` — consistent performance indicator
- `is_small_business_ever` — have they ever been small? Former small businesses
  may be more receptive to teaming.
- `long_incumbent_agencies` — agencies where they have 10+ year relationships
- `last_active_year` — are they still active?

### Step 7: Cross-reference with your set-aside type

Match the set-aside landscape to your business type:

| Your Status | What to Prioritize |
|-------------|-------------------|
| **8(a)** | Primes with strong positions at agencies that use 8(a) heavily. Check `set_aside.agency_profile_fy` across candidate primes' top agencies — strong 8(a) usage at other agencies suggests the prime knows how to work with 8(a) partners. |
| **SDVOSB** | Primes with veteran ownership flags (`is_veteran_owned: true`). These primes are more likely to value SDVOSB teaming. Also check SDVOSB set-aside usage at the target agency. |
| **WOSB** | Primes with women ownership flags (`is_women_owned: true`). Check WOSB set-aside usage at target. |
| **HUBZone** | This is the most underserved set-aside category. Few agencies have strong HUBZone usage. Prioritize primes that specifically win in HUBZone-preferred NAICS codes. |
| **General small** | If `contract_scope_setaside_obligation_share_known` is high at your target, you may be able to compete direct without a prime. |

### Step 8: Present the findings

```
## Teaming Partner Analysis: [Agency Name]

### Set-Aside Landscape
- Agency: [name] ([contracting_agency_id])
- Latest complete FY: [fiscal_year]
- Set-aside obligation share (known-status): [NN]%
- Friendliness rank: #[N]
- Assessment: [Can you compete direct, or is teaming necessary?]

### Top 10 Primes at [Agency]
| Rank | Vendor | 3-Yr Obligations | Tenure (yrs) | Active FYs | Vet | Women | Minority |
|------|--------|-----------------|-------------|-----------|-----|-------|----------|
| 1 | ... | $X.XM | N | N | - | - | - |
| ... |

### NAICS-Specific Leaders (NAICS [code]: [description])
| Rank | Vendor | 3-Yr Obligations | Agency-Wide Rank | Overlap? |
|------|--------|-----------------|-----------------|----------|
| 1 | ... | $X.XM | #N | ✓/✗ |
| ... |

### Recommended Teaming Partners
| Priority | Vendor | Agency Rank | NAICS Rank | Agencies Served | Avg Tenure | Set-Aside Fit | Rationale |
|----------|--------|------------|------------|----------------|-----------|--------------|-----------|
| 1 | ... | #N | #N | N | N yrs | High | ... |
| ... |

#### Scoring Logic
Each candidate is evaluated on:
- **Agency strength** (vendor_rank at target agency — lower is better)
- **NAICS alignment** (vendor_rank in your NAICS at target — lower is better)
- **Government-wide breadth** (agency_count and agencies_served — higher is better)
- **Set-aside compatibility** (based on your business type)

### Teaming Strategy

#### If you can compete direct:
- You do not strictly need a prime partner — focus on direct pursuits
- Still consider teaming if the specific opportunity is large or requires
  capabilities you lack

#### If you need a prime:
1. **First approach:** [Top recommended prime] — [rationale specific to your NAICS and set-aside type]
2. **Your value proposition:** As a [set-aside type] in NAICS [code], you help
   this prime meet subcontracting goals and access set-aside work
3. **Second approach:** [Second recommended prime] — [rationale]
4. **Backup option:** [Third recommended prime] — [rationale]

#### Set-Aside-Specific Notes
- [Specific note for your set-aside type at this agency]
```

## Caveats

- Set-aside obligation share is calculated only on contracts where the set-aside
  status is known. A significant share of obligations may have unknown status.
  Check `unknown_status_share` in the agency profile for context.
- Prime subcontracting data is not available in FPDS. The analysis identifies
  primes that are well-positioned for teaming based on spend patterns and
  set-aside usage, but it cannot confirm existing teaming relationships.
- `concentration.vendor_cross_agency_rank` is at the agency level, not
  department level. A vendor may show multiple entries across sub-agencies
  within the same department.
- Agency-specialist primes (serving few agencies) may have deeper relationships
  at your target but less formal teaming infrastructure than government-wide
  primes.
- The analysis is based on obligated amounts from FPDS. Some agencies have
  alternative contracting authorities (VA's FSS schedules, GSA's MAS) that
  may not be fully captured.

## Example Conversation

**User:** "I'm an 8(a) IT services company. Who should I team with to enter the VA?"

**Agent:**
1. Resolves "VA" to `contracting_agency_id`
2. Resolves "IT services" to `principal_naics_code: 541512`
3. Queries `set_aside.agency_profile_fy` — finds VA has high set-aside usage,
   meaning teaming is helpful but direct 8(a) pursuit is viable
4. Queries `incumbent.agency_vendor_leaders` for VA — identifies top large
   primes (is_small_business=false), noting veteran-owned flags
5. Queries `incumbent.agency_naics_vendor_leaders` for VA × NAICS 541512 —
   identifies primes winning IT services at VA specifically
6. Queries `concentration.vendor_cross_agency_rank` for top 5-8 primes to
   assess government-wide reach
7. Queries `concentration.vendor_market_leaders` for lifetime context on each
8. Cross-references with 8(a) status: prioritizes primes at agencies with
   strong 8(a) usage, veteran-owned primes (VA culture fit)
9. Presents ranked teaming recommendations with set-aside landscape, prime
   profiles, and a step-by-step teaming strategy
