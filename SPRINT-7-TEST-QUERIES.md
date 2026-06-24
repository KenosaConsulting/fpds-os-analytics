# S7-012b: 12 Cross-Cutting Test Queries

**Purpose:** Stress-test the API across different dataset combinations, filter patterns, and analytical shapes that real users would attempt. Each query is designed to surface different limitations.

**Method:** Run each through Claude Sonnet via MCP tools. Record: (1) did the AI succeed, (2) what limitations were hit, (3) what data quality issues surfaced.

---

## Q4: Geographic vendor mismatch + concentration
"Which states have the highest ratio of vendor-state-to-performance-state obligation mismatch (vendors headquartered elsewhere performing work in-state), and for the top 3 states, who are the top 5 out-of-state vendors by obligated amount? Also, what is the market concentration (HHI) for contracts performed in those states?"

**Stresses:** geography.mismatch_leaders + geography.place_profile_fy + concentration datasets. Cross-domain join (geography → concentration). State-level filtering.

## Q5: Seasonality-driven capture timing
"For DHS (dept 7000) and its component agencies, which months have the highest award obligation volume in FY2024 and FY2025? Are there offices with a consistent Q4 spike pattern? For the top 3 offices by Q4 volume, what NAICS codes dominate their Q4 awards?"

**Stresses:** seasonality.agency_month_fy + seasonality.office_quarter_fy + market.office_naics_fy. Time-bucket filtering. Office-level drill-down.

## Q6: Vehicle program vendor concentration + recompete overlap
"For the top 10 vehicle programs by total obligated amount, which vendors appear across multiple programs and what is their combined market share? For vendors that appear in 3+ vehicle programs, how many have contracts in the recompete watchlist expiring in the next 12 months?"

**Stresses:** acquisition.vehicle_program_vendors + acquisition.vehicle_program_summary + pipeline.recompete_watchlist. Cross-dataset vendor linkage. Set intersection (vendors in programs ∩ vendors in watchlist).

## Q7: PSC-NAICS crosswalk analysis for capability mapping
"A company that provides 'Engineering Services' (PSC R425) wants to know which NAICS codes those contracts are classified under, and which agencies buy the most under each NAICS. For the top agency-NAICS combination, what is the competition posture and average award size?"

**Stresses:** psc.naics_crosswalk + psc.office_profile_fy + competition datasets. PSC→NAICS mapping. Multi-hop: PSC → NAICS → agency → competition.

## Q8: Small business set-aside family trends + entrant survival
"How has the share of 8(a) vs HUBZone vs SDVOSB vs WOSB set-aside obligations changed over FY2022-FY2025? For each family, which agencies have the highest share, and do those agencies also show higher new-entrant survival rates (FY2023 cohort surviving to FY2025)?"

**Stresses:** set_aside.family_trend_fy + set_aside.agency_mix_fy + entrants.agency_cohort_fy. Socio-economic category filtering. Correlation across datasets (set-aside share vs entrant survival).

## Q9: Funding mismatch + assisted acquisition flows
"Which agencies receive funding from a different department than their contracting department, and what is the total obligated flow from each funding department? For the top 3 funding-source departments, what proportion of their assisted acquisitions go to small businesses?"

**Stresses:** funding.mismatch_flows_fy + funding.assisted_acquisition_fy. Cross-departmental fund flow analysis. Joining funding data with set-aside or small-business metrics.

## Q10: Contact intelligence — CO NAICS specialization + recompete pipeline
"Which contracting officers (human, not system) have the highest award action count in NAICS 541712 (Research and Development in the Physical, Engineering, and Life Sciences) over FY2024-FY2025? For the top 5 COs, what contracts in their NAICS are in the recompete watchlist, and what is the average duration profile for awards in that NAICS?"

**Stresses:** contacts.naics_buyers + contacts.profile_fy + pipeline.recompete_watchlist + pipeline.duration_profile. Contact → NAICS → pipeline linkage. Duration analysis.

## Q11: Topic-driven competitive landscape for a specific capability
"Using the topic catalog, find topics related to 'cloud computing' or 'cloud migration.' For each topic, which agencies have the strongest alignment, and what does the competitive landscape look like (top vendors, their market share, and whether the market is concentrated or competitive)?"

**Stresses:** topics.catalog + topics.agency_profile + topics.competitive_landscape + topics.naics_decomposition. Topic discovery → agency alignment → competitive analysis chain.

## Q12: Pricing risk scorecard + competition posture correlation
"Which agencies have the highest pricing risk scores (high cost-type or T&M exposure), and do those same agencies also show low competition rates (high sole-source share)? Is there a correlation between pricing risk and low competition at the agency level? List the top 5 agencies that appear in both risk scorecard top quartile and sole-source hotspot top quartile."

**Stresses:** pricing.risk_scorecard + competition.sole_source_hotspots + pricing.agency_profile_fy. Cross-domain risk correlation. Quartile analysis.

## Q13: Office-level depth drill — customer profile to office to vendor
"Start with the VA (dept 3600) customer profile. Identify the top 3 offices by obligated amount. For each office, pull the office profile, then identify the top 5 incumbent vendors and their market share. For each of those vendors, what other agencies do they serve as market leaders?"

**Stresses:** customer.agency_profile_fy + customer.office_profile_fy + incumbent.office_vendor_leaders + concentration.vendor_market_leaders. Deep drill-down chain: agency → office → vendor → cross-agency.

## Q14: NAICS growth leaders + geographic distribution
"For the top 10 NAICS codes by obligation growth rate (FY2024 to FY2025), which states have the highest obligation in those NAICS codes? Are growth leaders concentrated in specific geographic regions, or distributed nationally? Identify any NAICS-state combinations that are growing faster than the national average."

**Stresses:** naics.growth_leaders + geography.state_trend_fy + naics.trend_fy. Growth analysis + geographic cross-cut. Multi-dimensional ranking.

## Q15: Pipeline duration + award size distribution for capture planning
"For contracts expiring in the next 12 months with a total value over $10M, what is the distribution of contract durations? Do longer-duration contracts tend to have larger award sizes? For the top 5 agencies by expiring value, what is the median duration and median award size, and how do those compare to the agency's historical averages?"

**Stresses:** pipeline.recompete_watchlist + pipeline.duration_profile + pipeline.award_size_distribution. Statistical distribution analysis. Median/percentile calculations across datasets.

---

## What These Queries Stress (Coverage Matrix)

| Query | Domains hit | Key cross-cut | Filter pattern |
|---|---|---|---|
| Q4 | geography, concentration | state × vendor × HHI | state filter, vendor ranking |
| Q5 | seasonality, market | time-bucket × office × NAICS | month/quarter filter, office drill |
| Q6 | acquisition, pipeline | vehicle × vendor × recompete | set intersection |
| Q7 | psc, competition | PSC → NAICS → agency → competition | multi-hop mapping |
| Q8 | set_aside, entrants | socio-economic family × agency × survival | category filter, correlation |
| Q9 | funding | fund flow × assisted acquisition × small biz | cross-department |
| Q10 | contacts, pipeline | CO × NAICS × recompete × duration | contact specialization |
| Q11 | topics | topic discovery → agency → competitive | topic search chain |
| Q12 | pricing, competition | risk score × sole-source correlation | quartile analysis |
| Q13 | customer, incumbent, concentration | agency → office → vendor → cross-agency | deep drill-down |
| Q14 | naics, geography | growth × state distribution | growth ranking + geo |
| Q15 | pipeline | duration × award size × agency stats | statistical distribution |
