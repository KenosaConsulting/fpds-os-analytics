---
name: contracting-officer-patterns
description: "Analyze contracting office buying patterns and contract officer behavior."
metadata:
  openclaw:
    emoji: "👤"
    requires:
      env: ["FPDS_API_KEY"]
---

# Contracting Officer Patterns

## When to Use

You need to understand how a specific contracting office buys — what they buy,
when they buy it, and who does the buying:

- "How does the DHS Office of Procurement Operations buy IT services?"
- "What's the Army PEO STRI's monthly award pattern?"
- "Who are the contracting officers in GSA FAS Region 1 and what do they buy?"
- "Does this office compete its contracts or use sole source?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Office or agency** | The contracting office to analyze | Use `fpds_resolve` — can resolve at department, agency, or office level |
| **NAICS code** (optional) | Filter to a specific industry | User provides or NAICS lookup |
| **Time range** (optional) | Fiscal years to analyze | Default: last 5 complete FYs |

## Workflow

### Step 1: Resolve the office

Call `fpds_resolve` with the office name. This gives you the
`contracting_office_id`, `contracting_agency_id`, and `contracting_dept_id`.

If the user doesn't know the office name, resolve at the department level first,
then list offices within that department using `fpds_lookup_dimension`.

### Step 2: Get the monthly award pattern

Call `fpds_query_dataset` on `customer.office_month_naics_fy` with:

- `contracting_office_id` = resolved office code
- `principal_naics_code` = NAICS (if specified)
- `fiscal_year_min` = start of time range
- `limit` = 200
- `sort` = `fiscal_year_asc, fiscal_month_asc`

This gives you month-by-month award patterns: how many actions, how much
obligated, how many vendors, broken down by NAICS and set-aside code.

### Step 3: Analyze seasonality

Look for patterns in the monthly data:

- **Q4 spike (July-September):** Federal fiscal year ends September 30.
  Many offices have a Q4 spending surge. If the office consistently spikes in
  Q4, that's when opportunities appear.
- **Q1 lull (October-December):** New fiscal year, continuing resolutions,
  budget uncertainty. Often slower.
- **Mid-year steady state:** January-June is typically the most predictable.
- **Anomalous months:** A single month with 10x normal volume usually means
  a large IDV award or a contract modification. Flag these.

### Step 4: Check competition patterns

From the same dataset, look at the `set_aside_code` breakdown:

- **High "NONE" or "UNKNOWN"** → Many non-set-aside contracts. Open competition
  (or the set-aside data isn't populated, which is also worth knowing).
- **High "8A", "SDVOSB", "WOSB"** → This office prefers set-aside programs.
  Adjust your teaming strategy accordingly.
- **"8AN" (8(a))** → HUBZone or 8(a) set-asides. If you're not in the program,
  you need a teaming partner who is.

For more precise competition metrics, also call `fpds_query_dataset` on
`competition.agency_profile_fy` with `contracting_dept_id=<resolved>` and
`fiscal_year=<latest>` to get `competed_action_share`,
`not_competed_action_share`, `avg_offers_received`, and `bundled_action_share`.

### Step 5: Get contact information (if available)

Call `fpds_query_dataset` on `contacts.office_roster` with:

- `contracting_office_id` = resolved office code
- `contracting_agency_id` = resolved agency code
- `contracting_dept_id` = resolved department code
- `user_id` (optional)
- `user_class` (optional)
- `fiscal_year` (optional)
- `limit` = 50
- `sort` = `-action_count` or `-obligated_amount`

Returns the list of known human contracting officers in that office with their
buying statistics.

**Note:** Contact data comes from FPDS award records. Not all contracting
officers are listed. The data is most complete for offices that have made
recent awards.

### Step 6: Find NAICS-specific buyers

If the user provided a target NAICS code, call `fpds_query_dataset` on
`contacts.naics_buyers` with:

- `principal_naics_code` = target NAICS code
- `contracting_agency_id` = resolved agency code
- `limit` = 50
- `sort` = `-obligated_amount`

This returns the specific contracting officers who buy in that NAICS code,
which is more targeted than the office-level roster.

### Step 7: Present the analysis

```
## Contracting Office Analysis: [Office Name] ([Office ID])

### Office Overview
- Department: [name] (code)
- Agency: [name] (code)
- FY [YYYY] obligations: $X.XM across NNN actions
- Distinct vendors: NNN
- Primary NAICS: [code] ([description]) — NN% of obligations

### Monthly Award Pattern (FY [range])
| FY | Q1 | Q2 | Q3 | Q4 | Total |
|----|----|----|----|----|----|
| ... | $X | $X | $X | $X | $X |

**Seasonality:** [Q4-heavy / steady / irregular]
**Q4 surge:** NN% of annual obligations occur in Q4 (Jul-Sep)

### Competition Profile
| Set-Aside | Actions | Obligations | % of Total |
|-----------|---------|-------------|------------|
| NONE | NNN | $X.XM | NN% |
| 8A | NN | $X.XM | NN% |
| ... | | | |

**Department-Level Competition Metrics** (FY [year])
| Avg Offers Received | Competed % | Not Competed % | Bundled % |
|---------------------|------------|----------------|-----------|
| N.N | NN% | NN% | NN% |

**Assessment:** [Open competition / set-aside preferred / mixed]

### Known Contracting Officers (from office roster)
| Name | Role | FY Actions / Obligated | Primary NAICS |
|------|------|----------------------|---------------|
| ... | ... | NNN / $X.XM | [code] |

### NAICS-Specific Buyers (NAICS [code] at [agency])
| Name | Office | FY Actions / Obligated |
|------|--------|----------------------|
| ... | ... | NNN / $X.XM |

### Key Findings
1. [Most important pattern]
2. [Seasonality insight]
3. [Competition insight]

### Recommendations
- [Best time to engage this office: month/quarter]
- [Set-aside strategy based on their profile]
- [Key contacts to develop relationships with]
```

## Caveats

- Contracting officer contact information is derived from FPDS award records.
  It's not a complete directory — only officers who have signed awards that
  were reported to FPDS will appear. For a full office directory, check the
  agency's website or SAM.gov.
- Monthly patterns can be distorted by large single awards. If one month has
  10x the normal volume, check whether it's a single large IDV award rather
  than a true buying pattern.
- Set-aside data in FPDS is inconsistent. "NONE" may mean "open competition"
  or "set-aside not specified." Use the competition extent fields (available
  via `fpds_describe_dataset`) for a more reliable competition signal.
- Office codes can change over time (reorganizations, renumbering). If you
  see a sudden drop in activity, check whether the office got a new code.

## Example Conversation

**User:** "How does the GSA Federal Acquisition Service buy IT?"

**Agent:**
1. Resolves "GSA Federal Acquisition Service" → office ID
2. Queries `customer.office_month_naics_fy` for last 5 FYs
3. Analyzes monthly pattern → identifies Q4 surge
4. Checks set-aside breakdown → mostly open competition
5. Queries `contacts.office_roster` for known COs
6. Queries `contacts.naics_buyers` for NAICS-specific buyers
7. Presents analysis with seasonality, competition profile, and contacts
