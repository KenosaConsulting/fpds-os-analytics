# Analyst View Improvements

This document turns user feedback into a build roadmap for more analyst-facing
procurement intelligence views.

See `docs/ANALYTICS_SCHEMA_DESIGN.md` for the companion database design notes.

The current API is strongest at market characterization: pricing risk,
competition posture, concentration, NAICS demand, and state-level geography.
Those datasets help an analyst understand how a customer buys at a macro level.

The next layer should focus on capture intelligence: who buys, who wins, what
is expiring, which access paths matter, and where an analyst can act.

## Product Direction

The most useful analyst workflow is not a longer list of datasets. It is a
progressive path from market context to capture action:

1. Pick a customer, office, industry, place, or vendor.
2. Size the relevant market.
3. Identify the dominant incumbents and access barriers.
4. Find the likely acquisition channel.
5. Surface timing signals for recompetes or recurring work.
6. Explain the capture implication in plain English.

The existing API handles step 2 at the department level. The proposed views
expand steps 1, 3, 4, and 5.

## Priority Tiers

| Tier | Theme | Why It Matters |
|---|---|---|
| 1 | Customer and office specificity | Analysts do not sell to departments; they target offices, bureaus, and buying commands. |
| 1 | Agency x industry market sizing | Market entry starts with "who buys my thing?" for a specific customer and NAICS/PSC. |
| 1 | Incumbent and vendor maps | Capture strategy depends on who already owns the work. |
| 1 | Set-aside and socioeconomic mix | Small-business strategy changes completely by 8(a), WOSB, HUBZone, SDVOSB, and open competition. |
| 1 | Recompete and expiration signals | Timing is the difference between market research and pipeline. |
| 2 | Contract vehicle and acquisition method | Analysts need to know whether they can compete now or need vehicle access first. |
| 2 | PSC coverage | PSCs often describe the work more accurately than NAICS for services and defense. |
| 2 | Funding vs contracting agency split | Operational customers and buying offices are often different. |
| 2 | Location below state | State-level geography is useful for strategy, but installations and metros drive action. |
| 2 | Contract duration profile | Average contract length shapes pipeline cadence and revenue stability. |
| 3 | Composite analyst pages | Bundle datasets into "Customer 360", "Market 360", and "Recompete Watch" views. |

## Proposed Views

### 1. Contracting Office Profile

**Problem:** Department-level aggregation hides the real buying organization.
"Army" and "DOC" are not actionable customers. Analysts need CECOM, NOAA AGO,
NIST acquisitions, regional contracting centers, and comparable buying offices.

**Proposed dataset IDs:**

- `customer.office_profile_fy`
- `customer.office_trend_fy`
- `customer.office_lookup`

**Grain:**

- `contracting_office_id x fiscal_year`
- Optional rollups by `contracting_agency_id`, `contracting_dept_id`, and bureau
  or command when a reliable hierarchy exists.

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `psc_code`
- `vendor_uei`
- `set_aside_type`

**Core fields:**

- Office name and code
- Parent agency and department
- Total obligations and action count
- Top NAICS and PSC codes
- Top vendors
- Small-business and socioeconomic shares
- Competed vs. not-competed shares
- Average offers received
- Median and average award size
- Last active fiscal year

**Analyst questions answered:**

- Which office actually buys this work?
- Is the office active recently or only historically?
- Does this office use small businesses?
- Is this office open to new vendors or incumbent-heavy?
- Which office should I research before outreach?

**Build notes:**

- Normalize office names aggressively; office names can be noisy.
- Include stable office codes even when names change.
- Suppress or flag offices with very low action counts to avoid false precision.

### 2. Agency x NAICS Market Sizing

**Problem:** The current NAICS views show government-wide growth and department
summary profiles, but analysts need direct cross-tabs: "How much did this
agency spend on this NAICS?"

**Proposed dataset IDs:**

- `market.agency_naics_fy`
- `market.office_naics_fy`
- `market.naics_customer_leaders`

**Grain:**

- `contracting_dept_id x contracting_agency_id x principal_naics_code x fiscal_year`
- Optional office-level version for high-value analyst workflows.

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `sector_code`

**Core fields:**

- Obligations and action count
- Year-over-year obligation change
- Three-year obligation total
- Three-year CAGR or growth rate
- Distinct vendor count
- Small-business obligation share
- Top vendor share
- Not-competed obligation share
- Average award size

**Analyst questions answered:**

- Which agencies buy NAICS 541512?
- Is this agency's demand growing or shrinking?
- Is the market large enough to pursue?
- Is the market competitive enough for a new entrant?

**Build notes:**

- This should be a Tier 1 build because it unlocks market sizing for almost
  every business-development use case.
- Require at least one customer or NAICS filter for row queries.

### 3. Set-Aside Mix

**Problem:** Small-business obligation share is useful, but it is not enough for
small-business capture. 8(a), WOSB, HUBZone, SDVOSB, total small business, and
unrestricted awards imply different strategies.

**Proposed dataset IDs:**

- `small_business.set_aside_mix_fy`
- `small_business.agency_set_aside_naics_fy`
- `small_business.office_set_aside_mix_fy`

**Grain:**

- `contracting_agency_id x set_aside_type x fiscal_year`
- `contracting_agency_id x principal_naics_code x set_aside_type x fiscal_year`

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `set_aside_type`

**Core fields:**

- Set-aside code and label
- Obligations and action count
- Share of agency or NAICS obligations
- Distinct vendor count
- New vendor count
- Average offers received
- Top vendor and top vendor share

**Analyst questions answered:**

- Does this customer actually use 8(a), WOSB, HUBZone, or SDVOSB awards?
- Is the set-aside market concentrated or open?
- Is the customer meeting small-business participation through one program or
  through broad competition?

**Build notes:**

- Include both raw FPDS code and human-readable label.
- Treat missing or uncoded set-aside values explicitly; do not bury them in
  "other."

### 4. Agency Vendor Leaders And Incumbency

**Problem:** Government-wide vendor leaders do not help a capture analyst target
DOC IT, NOAA professional services, or Army installation work. Analysts need
customer-specific incumbent maps.

**Proposed dataset IDs:**

- `incumbent.agency_vendor_leaders`
- `incumbent.office_vendor_leaders`
- `incumbent.agency_naics_vendor_leaders`

**Grain:**

- `contracting_agency_id x vendor_uei`
- `contracting_agency_id x principal_naics_code x vendor_uei`
- Optional `contracting_office_id x vendor_uei`

**Core filters:**

- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `psc_code`
- `vendor_uei`
- `is_small_business`

**Core fields:**

- Vendor UEI and name
- Total obligations and action count
- Three-year obligations
- Latest fiscal year active
- First fiscal year active
- Estimated tenure
- Top NAICS and PSC for the vendor at that customer
- Share of customer or market obligations
- Small-business indicator

**Analyst questions answered:**

- Who are the top incumbents at this customer?
- Who should I team with?
- Is the market locked up by one vendor or spread across several vendors?
- Which vendors are long-tenured enough to indicate entrenched incumbency?

**Build notes:**

- Keep UEI in the API response to avoid ambiguous vendor names.
- Consider a "likely incumbent" flag based on recent activity, tenure, and
  share, but keep the underlying metrics visible.

### 5. Recompete Watchlist

**Problem:** Market sizing is useful, but pipeline depends on timing. Analysts
need to know which awards are approaching the end of their current period of
performance and who holds them.

**Proposed dataset IDs:**

- `pipeline.recompete_watchlist`
- `pipeline.agency_recompete_summary`
- `pipeline.office_recompete_summary`

**Grain:**

- Award or contract-family level for watchlist rows.
- `contracting_agency_id x fiscal_quarter` for summaries.

**Core filters:**

- `ending_before`
- `ending_after`
- `fiscal_year`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `psc_code`
- `vendor_uei`
- `set_aside_type`

**Core fields:**

- Award identifier or safe contract-family key
- Award title or description when safe to expose
- Incumbent vendor
- Contracting office and agency
- NAICS and PSC
- Current period-of-performance end date
- Obligated amount
- Estimated remaining months
- Competition and set-aside attributes
- Recompete confidence level

**Analyst questions answered:**

- Which contracts may recompete in the next 6, 12, or 18 months?
- Who is the incumbent?
- Which customer and office owns the work?
- Is this likely to be competed, sole-sourced, or set aside?

**Build notes:**

- FPDS period-of-performance dates are not a perfect recompete indicator.
  Treat this as a signal, not a guarantee.
- Base-plus-option structure may require award-family grouping, not single
  action rows.
- Include confidence levels and caveats to prevent overclaiming.

### 6. Contract Vehicle And Acquisition Path Mix

**Problem:** Analysts need to know whether they can compete directly or must
first get onto a vehicle. Pricing type does not answer that.

**Proposed dataset IDs:**

- `acquisition.vehicle_mix_fy`
- `acquisition.agency_vehicle_mix_fy`
- `acquisition.naics_vehicle_mix_fy`

**Grain:**

- `contracting_agency_id x vehicle_or_idv_type x fiscal_year`
- Optional `contracting_agency_id x principal_naics_code x vehicle_or_idv_type x fiscal_year`

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `psc_code`
- `vehicle_name`
- `idv_type`

**Core fields:**

- Vehicle or acquisition path label
- Obligations and action count
- Share of agency or NAICS obligations
- Distinct vendor count
- Top vendors on that path
- Competed and not-competed shares
- Average award size

**Analyst questions answered:**

- Does this customer buy through GWACs, GSA Schedule, agency IDIQs, BPAs, or
  open market awards?
- Do I need a vehicle before I can pursue this customer?
- Which vehicles dominate this NAICS at this customer?

**Build notes:**

- Vehicle naming is hard. Start with reliable IDV and contract vehicle fields,
  then add curated normalization for common vehicles.
- Keep an "unknown/unclear" bucket visible.

### 7. PSC Demand And Crosswalk

**Problem:** NAICS is not enough. PSC often better describes services, R&D,
defense work, IT, and professional services. Many analysts and contracting
officers think in PSC terms.

**Proposed dataset IDs:**

- `psc.trend_fy`
- `psc.agency_profile_fy`
- `psc.agency_psc_naics_fy`
- `dimensions.psc_codes`

**Grain:**

- `psc_code x fiscal_year`
- `contracting_agency_id x psc_code x fiscal_year`
- Optional `psc_code x principal_naics_code x fiscal_year`

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `psc_code`
- `psc_category`
- `principal_naics_code`

**Core fields:**

- PSC code and label
- Obligations and action count
- Distinct vendors
- Top agency and top vendor
- Three-year trend
- NAICS overlap

**Analyst questions answered:**

- Which agencies buy this type of work by PSC?
- Which PSCs describe this customer's spending better than NAICS?
- Where do NAICS and PSC classification disagree?

**Build notes:**

- Add PSC as both a dimension endpoint and a filter surface for later views.
- Include PSC category rollups for easier analyst scanning.

### 8. Funding Agency vs. Contracting Agency Mismatch

**Problem:** The buyer and the beneficiary are often different. GSA, DISA, and
other agencies may contract on behalf of another operational customer.

**Proposed dataset IDs:**

- `customer.funding_contracting_mismatch_fy`
- `customer.assisted_acquisition_flows`

**Grain:**

- `funding_agency_id x contracting_agency_id x fiscal_year`
- Optional department-level rollup for sparse flows.

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `funding_dept_id`
- `funding_agency_id`
- `contracting_dept_id`
- `contracting_agency_id`
- `principal_naics_code`
- `psc_code`

**Core fields:**

- Funding agency and department
- Contracting agency and department
- Obligations and action count
- Share of funding agency spend executed by another agency
- Share of contracting agency spend funded by another agency
- Top NAICS and PSC
- Top vendors

**Analyst questions answered:**

- Who owns the mission demand versus who runs the procurement?
- Is an apparent customer actually buying through another agency?
- Should outreach target the funding program office, the contracting shop, or
  both?

**Build notes:**

- Surface both directions: money leaving a funding agency and money handled by a
  contracting agency for others.
- Add caveats because funding agency fields may be incomplete or inconsistently
  coded.

### 9. Location Drill-Down

**Problem:** State-level geography helps market mapping, but capture teams need
installations, cities, counties, metros, and overseas locations where possible.

**Proposed dataset IDs:**

- `geography.place_profile_fy`
- `geography.metro_profile_fy`
- `geography.installation_candidates`

**Grain:**

- `place_of_performance_city x state x fiscal_year`
- `metro_area x fiscal_year`
- Optional installation-normalized layer when reliable enough.

**Core filters:**

- `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- `pop_state_code`
- `pop_city`
- `pop_zip`
- `metro_area`
- `contracting_agency_id`
- `principal_naics_code`
- `psc_code`

**Core fields:**

- Place name, state, ZIP, county, or metro
- Domestic/foreign flag
- Obligations and action count
- Distinct vendor count
- Top agencies
- Top NAICS and PSC
- Vendor-state mismatch share

**Analyst questions answered:**

- Where does the work actually happen?
- Which local markets are growing?
- Which places have local vendors versus out-of-state delivery?
- Which installations or metros should drive teaming and staffing strategy?

**Build notes:**

- Place-of-performance data can be incomplete. Keep caveats prominent.
- Installation mapping should be curated and confidence-scored.

### 10. Contract Duration And Cadence

**Problem:** Contract length shapes pipeline timing and revenue stability. A
market of recurring one-year awards behaves differently than a market of
five-year IDIQs.

**Proposed dataset IDs:**

- `pipeline.duration_profile_fy`
- `pipeline.agency_naics_duration_profile`
- `pipeline.office_duration_profile`

**Grain:**

- `contracting_agency_id x principal_naics_code`
- Optional `contracting_office_id x principal_naics_code`

**Core filters:**

- `contracting_dept_id`
- `contracting_agency_id`
- `contracting_office_id`
- `principal_naics_code`
- `psc_code`
- `set_aside_type`
- `award_type`

**Core fields:**

- Median period-of-performance months
- Average period-of-performance months
- P25/P75 duration
- Share of awards under 12 months
- Share of awards over 36 months
- Recurring annual pattern indicator
- Average obligated amount by duration bucket

**Analyst questions answered:**

- How often does this market turn over?
- Is the pipeline cadence annual, multi-year, or episodic?
- Does this customer offer stable recurring revenue or short project work?

**Build notes:**

- Duration should be computed carefully from valid start and end dates only.
- Keep single-action corrections and administrative modifications from
  distorting duration metrics.

## Composite Analyst Views

After the Tier 1 datasets exist, create composite views that package multiple
signals into analyst-ready pages.

### Customer 360

**Input:** agency, department, or contracting office.

**Sections:**

- Spend trend
- Top NAICS and PSC
- Competition posture
- Pricing posture
- Small-business and set-aside mix
- Top incumbents
- Vehicle mix
- Upcoming recompete signals
- Geography footprint

**Output:** A concise customer profile that answers whether to pursue, how to
position, and what to research next.

### Market 360

**Input:** NAICS, PSC, customer, and optional geography.

**Sections:**

- Market size and growth
- Top customers
- Top offices
- Top incumbents
- Set-aside mix
- Vehicle barriers
- Competition openness
- Recompete timing

**Output:** A market-entry page for a specific capability.

### Recompete Watch

**Input:** agency, office, NAICS, PSC, vendor, or date window.

**Sections:**

- Upcoming expiration signals
- Incumbent vendor
- Customer and contracting office
- Contract size
- Competition and set-aside attributes
- Similar recurring awards
- Confidence and caveats

**Output:** A tactical pipeline screen for capture planning.

## Implementation Sequence

### Phase 1: High-Impact Cross-Tabs

Build views that reuse existing aggregation patterns and unlock immediate
analyst value.

1. `market.agency_naics_fy`
2. `incumbent.agency_vendor_leaders`
3. `small_business.set_aside_mix_fy`
4. `customer.office_profile_fy`

### Phase 2: Capture Timing And Access

Build views that require more careful normalization or award-family logic.

1. `pipeline.recompete_watchlist`
2. `acquisition.agency_vehicle_mix_fy`
3. `psc.agency_profile_fy`
4. `pipeline.duration_profile_fy`

### Phase 3: Drill-Down And Composite Products

Turn signals into analyst workflows.

1. `customer.funding_contracting_mismatch_fy`
2. `geography.place_profile_fy`
3. Customer 360
4. Market 360
5. Recompete Watch

## Data Quality And Guardrails

- Require narrowing filters for high-cardinality views such as office, vendor,
  award, and recompete datasets.
- Return confidence labels when deriving incumbency, vehicle, installation, or
  recompete signals.
- Keep raw codes and human-readable labels together.
- Do not hide unknown or missing classifications; expose them as explicit
  buckets.
- Avoid presenting period-of-performance end dates as guaranteed recompete
  dates.
- Keep the existing API boundary: documented datasets, allowlisted filters,
  bounded rows, no arbitrary SQL, no raw table access, and no write operations.

## Success Criteria

A new analyst-facing view should be considered successful if it helps answer at
least one of these questions without requiring raw FPDS analysis:

- Who buys this specific work?
- Which office should I research?
- Who is the incumbent?
- Is there room for a new entrant?
- Is the work likely set aside?
- Do I need a contract vehicle?
- When might the work come back around?
- Where is the work performed?
- Should I prime, subcontract, team, or avoid the market?

The strategic goal is to move from "this department is interesting" to "this is
the customer, office, incumbent, access path, and timing signal worth acting on."
