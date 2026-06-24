# S7-012b Consolidated Findings — API Limitations & Data Quality

*Generated 2026-06-24 from 12 cross-cutting queries against the FPDS Analytics API.*

---

## Q4 — State Vendor-Performance Mismatch & Market Concentration

**Query:** Which states have the highest vendor-state vs. performance-state obligation mismatch, top out-of-state vendors, and HHI for those states?

### Limitations
- **`is_in_state` filter broken** — both boolean (`true`/`false`) and string equivalents return HTTP 400. Had to compute in-state/out-of-state client-side from returned rows.
- **`limit` capped at 25** for `geography.mismatch_leaders` despite documentation claiming max 500. Anything >25 returns HTTP 400.
- **Sort by `-total_obligated` fails at higher limits** (same 25-row cap issue).
- **No individual vendor data tied to performance state** — mismatch dataset grain is state-pair only. Datasets that name vendors (`incumbent.*`, `concentration.vendor_market_leaders`) don't expose `pop_state_code` as a filter. Cannot name individual out-of-state vendors.
- **No state-scoped HHI dataset** — concentration views are scoped by agency or fiscal_year only.
- **Small federal-heavy states (AK, WV, WY, VT, MS) returned only in-state rows** — "Mismatch Leaders" view filters out flows below a materiality threshold.

### Data Quality
- **"Mismatch Leaders" undercounts total state obligations** — only large-dollar pairs surfaced, so out-of-state ratios are likely overstated (tail in-state vendors missing).
- **NM's OH→NM flow ($14.98B / 115 vendors) and TN's MD→TN flow ($10.89B / 179 vendors)** — almost certainly national-lab M&O contracts (Sandia/Los Alamos/ORNL) where vendor state = HQ, not work location. Known FPDS artifact.
- **VA "in-state" $158.9B plausibly inflated** by federal contractors headquartered in VA near DC.
- **`source_fiscal_years: [1958, 2026]`** on every response — metadata reports full corpus span, not actual row years.
- **Pagination cursors return `null` after 1–8 rows** for per-state queries — confirms pre-filtered "leaders" dataset with no tail.

---

## Q5 — DHS Monthly Award Patterns & Q4 Spike Analysis

**Query:** For DHS and components, which months have highest award volume in FY2024–FY2025? Q4 spike patterns? Top NAICS for Q4-heavy offices?

### Limitations
- **STRUCTURAL FAILURE: Max turns (30) exceeded.** Query required >30 tool calls to enumerate DHS component offices, pull monthly data per office, and cross-reference NAICS. The multi-step fan-out (dept → offices → monthly → NAICS) is too deep for a single agent session.
- This is a **query complexity issue**, not a data issue — the API likely has the data, but the exploration → filter → aggregate loop exceeds the agent's turn budget.

### Data Quality
- No data quality observations (query did not complete).

---

## Q6 — Top Vehicle Programs & Cross-Program Vendor Overlap

**Query:** Top 10 vehicle programs by obligated amount, vendors appearing across multiple programs, recompete watchlist exposure for 3+ program vendors.

### Limitations
- **`acquisition.vehicle_program_vendors` limit capped at 25** despite `max_limit: 1000` in metadata. `limit=50` returns HTTP 400.
- **`fields` projection parameter rejected (400)** on same dataset.
- **`sort=-obligated_amount` rejected (400)** despite being listed as sortable.
- **No multi-year aggregation** — used FY2025 snapshot only. Vendors active in earlier years but not FY2025 are missed.
- **Vendor UEI unstable across subsidiaries/years** — same legal entity appears under different UEIs (Leidos: 3 UEIs, SAIC: 2, CACI: 2, IBM: 2). Hand-collapsed via name matching; UEI-strict counting would understate overlap.
- **Recompete watchlist pagination not exhausted** — counts are lower bounds.
- **No vehicle filter on recompete watchlist** — can't confirm watchlist PIIDs are tied to specific vehicle programs.
- **`expiration_bucket` filter only offers `0_to_6_months`** — no `remaining_months <= 12` filter exists.

### Data Quality
- **GSA Alliant FY2025 = -$103.7M** (all de-obligations). Still flagged `is_active_recent=true` — no wind-down state indicator.
- **NASA JPL FFRDC: Caltech appears under two UEIs** (YC1YP79BFD19, U2JMKHNS5TG4) — same legal entity, duplicate record.
- **VA PPV: 62 vendors listed but McKesson holds 99.78% share** — 61 vendors have ~0.2% combined, many with `obligated_amount = 0.00` and `vendor_obligation_share = 0E-28`. Vendor count inflated by placeholder records.
- **Recompete watchlist `remaining_months=0`** for contracts ending months in the future — bucket label unreliable, date math required.
- **`set_aside_code = "UNKNOWN"`** on vast majority of watchlist rows for large vendors — socioeconomic signal absent.
- **Negative `obligated_amount` entries** on VA CCN (NetSmart Technologies, -$662.44) produce negative `vendor_obligation_share`.

---

## Q7 — PSC R425 (Engineering Services) NAICS Crosswalk & Competition

**Query:** Which NAICS codes R425 contracts are classified under, top agencies per NAICS, competition posture for top agency-NAICS combo.

### Limitations
- **No agency × PSC × NAICS dataset exists** — crosswalk is PSC↔NAICS govwide; `market.naics_customer_leaders` gives agencies per NAICS but not PSC-filtered. Cannot isolate "R425 work under NAICS 541330 at Navy."
- **`market.entry_difficulty_score` timed out (504) on every attempt** — would have provided HHI, avg offers, incumbent tenure.
- **`fpds_resolve` returned 0 hits for PSC code "R425"** — resolver doesn't index PSC codes by literal code, only by description.
- **`recent_3yr_obligated` window undocumented** — values don't match FY22+23+24 sums from other datasets. Window endpoint unclear.
- **Average award size is per-action, not per-contract** — each action is a mod/option/base, not a full contract.

### Data Quality
- **`sector_label` null on every row** of `psc.naics_crosswalk` and `market.naics_customer_leaders` — `sector_code` (54) populated but label join missing.
- **`agency_short_name` null for non-DoD agencies** (NASA, DOE, USAID, VA, GSA FAS) but populated for Navy/Army/Air Force.
- **R425 → manufacturing NAICS (336411 Aircraft $766M, 336992 Armored Vehicle $185M)** — PSC R425 "engineering services" classified under manufacturing NAICS, reflecting underlying program rather than labor category. Pure NAICS filters miss R425 work hiding under manufacturing codes.
- **Navy 541330 small-biz share declining: 5.9% → 5.4% → 4.2%** (FY22–24) — unexpected directional trend.

---

## Q8 — Set-Aside Family Trends & New-Entrant Survival

**Query:** 8(a)/HUBZone/SDVOSB/WOSB obligation share trends FY2022–FY2025, top agencies per family, correlation with new-entrant survival.

### Limitations
- **`fiscal_year_min`/`fiscal_year_max` filters return 400** on `set_aside.family_trend_fy` despite being documented. Had to call each FY separately.
- **`sort=-new_vendor_count` returns 400** on `entrants.agency_cohort_fy` despite being listed as sortable.
- **No direct set-aside × entrant join** — can't answer "do 8(a) entrants specifically survive at higher rates than HUBZone entrants?" Only per-agency aggregate available.
- **`set_aside.agency_mix_fy` returns duplicate (agency, family) rows** when family contains multiple `set_aside_code` values. Family-level totals require manual summing.
- **FY2025 data suspect** — `is_current_fiscal_year_ytd=false` claims FY25 closed, but positive set-aside actions drop from ~950K (FY23) to ~351K (FY25) while overall obligations rose. Likely materialized view refresh lag.

### Data Quality
- **`set_aside_first_year_obligated` exceeds `first_year_obligated_total`** for several agencies (NASA FY23: $611M set-aside vs $354M total; TSA FY23: $140M vs $87M). Different bases — `set_aside_first_year_obligation_share` is a derived proxy, not a straight percentage.
- **`agency_short_name` inconsistently populated** — filled for Army/Navy/Air Force/TSA/NIH, null for VA/State/NASA/EPA/DHS-OPO/DLA/GSA.
- **FY25 set-aside obligation totals collapse** out of proportion — strongly suggests refresh lag, not real policy shift. No `data_as_of` field to confirm (null on every response).
- **HBCU/MI family has negative obligations** (–$10K FY22, –$9K FY23) — pure de-obligation rows with no positive baseline.
- **Entrants dataset set-aside attribution is explicitly not direct** — "not a direct transaction-level entrant aggregation." Directional only.

---

## Q9 — Cross-Department Funding Flows & Small-Business Proportion

**Query:** Which agencies receive funding from different departments, total flow by funding department, small-business proportion of assisted acquisitions for top 3 funders.

### Limitations
- **No funding-side small-business cut exists** — set-aside and pricing datasets key on `contracting_dept/agency_id`; funding-flow datasets have no set-aside/small-biz columns. Question cannot be answered cleanly from exposed datasets.
- **`is_cross_department: true` (boolean) rejected (400)** — must use string `"true"`.
- **`limit ≥ 50` with `sort` returns 400** on `funding.mismatch_flows_fy`. Default `limit=100` also fails. Had to page in batches of 25.
- **Sort by `-net_obligated_amount` inconsistently fails** — first attempt for FY2024 failed at limit=25; later identical requests succeeded. Not reproducible.
- **`fiscal_year=2024` (int) initially errored** while `"2024"` (string) and int `2023` worked on the same dataset minutes apart. Transient backend issue.

### Data Quality
- **46.4% unknown set-aside status on GSA-FAS FY2024** — set-aside share computed on ~54% coverage subset.
- **Phantom department code "1027"** — $759M cross-dept obligations but `funding_dept_name` and `funding_agency_name` both null. Not a recognized USASpending department code. Likely coding artifact.
- **DHS sub-agency names null** (7040, 7050, 7055, 7057, 7058, 7061) — department populated but agency-level names not resolved.
- **`net_obligated_amount` returned as string**, not number — requires manual conversion.
- **`funding_agency_short_name` sometimes set while `funding_agency_name` is null** — short name resolution more reliable than long name.

---

## Q10 — Top Contracting Officers in NAICS 541712 & Recompete Watchlist

**Query:** Top 5 human contracting officers by action count in NAICS 541712 (FY2024–FY2025), their watchlist contracts, and duration profile for the NAICS.

### Limitations
- **`user_class="human"` filter rejected (400)** despite documented example using exactly that value. Had to filter client-side.
- **`limit > 25` returns 400** on `contacts.naics_buyers` despite `max_limit: 500` in metadata.
- **`fields` whitelist parameter rejected (400)** — every call returns all fields.
- **`fpds_resolve` returned 0 rows for NAICS** on every query — resolver broken for NAICS codes.
- **Cannot filter `pipeline.recompete_watchlist` by FY** — only by expiration bucket/remaining months. Can't tie watchlist hits to "FY24–25 award activity" timeframe.
- **`fiscal_year_min`/`fiscal_year_max` not supported** on `contacts.naics_buyers` — only single `fiscal_year`. Two queries required for FY24+FY25.
- **`recompete` domain returns 0 datasets** — recompete data lives under `pipeline` domain. Misleading taxonomy.
- **Pagination shallow** — only top 50 rows per FY sampled. Additional humans beyond top 50 not surfaced.

### Data Quality
- **Grain non-uniqueness in `contacts.naics_buyers`** — same `(user_id, naics, agency, fiscal_year)` tuple appears on multiple rows with different `action_count`/`obligated_amount`. Cannot reliably aggregate without client-side dedup; dedup approach (max vs sum) undefined.
- **Many `user_class: "unknown"` rows are clearly humans** (HHSTBROWN4, MUNSON, MLAURY, MATTEVANS, JGOODWIN, MAOCONNE, CNCAREY) — classifier is conservative and undercounts real COs.
- **`name_confidence: "high"` on system accounts** (PADDS rows get display_name "Padds W56kgu") — name-confidence heuristic fooled by email parsing.
- **Negative obligations for several "buyers"** — action counts weighted toward modifications/de-obligations, not new awards. Action count alone isn't a clean "buying volume" signal.
- **`set_aside_pct` and `sole_source_pct` null when obligated_amount is negative** — division-by-negative silently suppressed.
- **`first_seen_fy=1958` on system admin account** — implausible for a person account; placeholder.
- **Trujillo's 5 recompete contracts all sole-source to UT Austin** with `set_aside_code: "UNKNOWN"` — clearly non-competed academic R&D awards left blank rather than coded as "no set-aside used."

---

## Q11 — Cloud Computing Topic Catalog & Competitive Landscape

**Query:** Topics related to "cloud computing" or "cloud migration," agency alignment, competitive landscape (vendors, share, concentration).

### Limitations
- **Department code mismatch** — `fpds_lookup_dimension` uses `department_id` but topic catalog uses `department_code` (USASpending CGAC, e.g. "019" / "075" / "97AK"). These don't match dim_departments keys ("1900" / "7500"). Required cross-walking via `topics.agency_profile`.
- **`fpds_resolve` returned 0 results for `97AK` and `9761`** — valid codes in topic catalog not resolvable.
- **No fiscal year filter on `topics.competitive_landscape`** — vendor totals cumulative back to FY1958 per `source_fiscal_years`. Can't isolate current market share.
- **No total-market-size field** on competitive_landscape — can't compute true HHI. Used top-3 cumulative share as proxy.
- **`canonical_topic_id` not a filter** on `topics.competitive_landscape` — only per-dept `topic_id` + `model_id`.

### Data Quality
- **Topic mislabeling / NAICS contamination at State (Topic 267)** — labeled "Web Hosting and Data Processing Services" (NAICS 518210) but top vendors are travel agencies (ADTRAV, Cherokee Nation Travel, Alamo Travel, Royal Jordanian Airlines). NAICS 518210 covers both data hosting AND computerized reservation systems; BERTopic lumped embassy travel-booking contracts into a "cloud" topic.
- **Null `vendor_name` despite valid `vendor_uei`** — repeated across HHS, DOL, DISA topics. At HHS, 3 of top-9 vendors (~19% share, ~$830M) are unnamed. Likely missing join to vendor-name dimension.
- **"MISCELLANEOUS FOREIGN AWARDEES" as ranked vendor** — FPDS placeholder catch-all (UEI LN9PU5M2YZN5) with 1,826 contracts at State Topic 267. Treated as real vendor in rankings, inflating concentration.
- **`total_obligated` returned as string** ("35385378.78") not number.
- **`source_fiscal_years: [1958, 2026]`** suspicious for cloud computing — likely metadata reflects full dataset coverage, not topic history.
- **`topic_share` field misleading** — shows share of office's total topic activity, not share of the topic. Easy to misread.

---

## Q12 — Pricing Risk vs. Sole-Source Concentration Correlation

**Query:** Top agencies by pricing risk score and sole-source share, correlation between the two, top 5 in both top quartiles.

### Limitations
- **`required_filters: []` is wrong in catalog** — both `pricing.risk_scorecard` and `competition.sole_source_hotspots` return 400 on unfiltered calls. Must supply `contracting_dept_id`. Had to enumerate ~26 departments individually.
- **No bureau-level grain** — only `contracting_dept_id` (~98 departments). Army vs Navy vs Air Force differences invisible within DoD.
- **Rate limit at ~25 parallel calls** (HTTP 429) — 7 calls dropped, had to re-run sequentially. No `Retry-After` header.
- **Small universe for quartile math** — 26 departments; top quartile ≈ 6–7 agencies. Adding ~70 tiny commissions not attempted.
- **No `data_as_of` timestamp** on any response — reproducibility/audit impaired.

### Data Quality
- **HUD returned negative shares** — risk_score = −0.7848, cost-type share = −0.017, sole-source share = −0.2539. De-obligations exceeded positive obligations over 3-yr window. No flag in data.
- **NARA and MCC: cost-type dollar amount negative but share silently zero-floored** — `cost_type_obligated_3yr = -$8,960` but `cost_type_obligation_share = "0.0000"`. Share field positive-clipped while underlying dollars aren't.
- **`department_short_name` null** for MCC, NRC, SEC, Smithsonian, NARA, and others.
- **SBA `cost_type_obligated_3yr = "0"`** — string "0" not "0.00". Type inconsistency vs other rows.

---

## Q13 — VA Office Profiles, Incumbent Vendors & Cross-Agency Market Leadership

**Query:** VA top 3 offices by obligated amount, office profiles, top 5 incumbent vendors per office, and what other agencies those vendors lead.

### Limitations
- **STRUCTURAL FAILURE: TIMEOUT (600s).** Query involves deep fan-out: VA dept → top 3 offices → office profiles → top 5 vendors per office (15 vendors) → market leader lookups per vendor across all agencies. Multi-level fan-out exceeds the 600-second session budget.
- Like Q5, this is a **query complexity issue** — the API likely has the data, but the 4-level drill-down can't complete in one session.

### Data Quality
- No data quality observations (query did not complete).

---

## Q14 — NAICS Growth Leaders & Geographic Concentration

**Query:** Top 10 NAICS by FY2024→FY2025 obligation growth rate, state concentration per NAICS, regional vs. national distribution.

### Limitations
- **No state × NAICS × FY dataset exists** — biggest limitation. `naics.growth_leaders` is national-only; `geography.state_trend_fy` has no NAICS dimension; `geography.place_profile_fy` has place + single `top_naics_code` per cell with no NAICS filter. Cannot directly query "FY24 & FY25 obligations for NAICS 336414 by state."
- **Proxy approach systematically undercounts** — `place_profile_fy` top-25 per state only captures NAICS that are #1 in each cell. Diffuse NAICS missed entirely.
- **`limit` effectively capped at 25** for `place_profile_fy` — `limit=50/100/200/500/1000` all return 400 despite `max_limit: 1000` in catalog.
- **`naics.trend_fy` with `fiscal_year_min`/`fiscal_year_max` returns 400** — couldn't get clean total-federal growth baseline.
- **`city_leaders` with no state/region filter returns 400** despite no required filter documented.
- **`geography.place_profile_fy` ~80% coverage** of domestic records — obligations with no city/county don't appear.
- **"Growth leaders" silently uses two most recent complete FYs** — comparison window shifts over time without notice.
- **Only 14 states sampled** — smaller states may host meaningful concentrations of smaller-dollar growth NAICS.

### Data Quality
- **`sector_label` null on every row** of `naics.growth_leaders` — `sector_code` populated correctly.
- **`agency_short_name` null** in many `place_profile_fy` rows.
- **Massive single-cell concentration: VA Fredericksburg ($29.4B health insurance, NAICS 524114)** — ~26% of all Virginia's $111.7B. Passthrough that skews state-level "top NAICS" readings.
- **NAICS 562119 (Waste Collection) +662% growth is a wildfire-response event** (Pacific Palisades/Eaton, FY2025) — not a sustained market trend.
- **`top_naics_code` is derived "biggest within cell"** — summing `net_obligated_amount` by `top_naics_code` overstates that NAICS's actual share when cells are mixed.
- **`pop_state_name` casing inconsistent** — uppercase in `state_trend_fy`, mixed-case in `place_profile_fy` and `city_leaders`.

---

## Q15 — Expiring Contracts >$10M: Duration Distribution & Agency Comparison

**Query:** Distribution of contract durations for expiring >$10M contracts, duration vs. award size correlation, top 5 agencies' median duration vs. historical averages.

### Limitations
- **`limit > ~25` errors (400) with `sort=-total_obligated` + filter** on `pipeline.recompete_watchlist` despite `max_limit: 500`. Full enumeration of ~3,000–5,000 contracts >$10M per agency would take 100+ paginated calls. Sampled top-25 per (agency, bucket).
- **`fields` parameter incompatible with `sort` + `filter`** — any query combining all three returns 400. Could not narrow payload.
- **No `min_total_obligated` filter** on `pipeline.recompete_watchlist` — >$10M floor enforced by sorting desc and watching the tail.
- **`expiration_bucket` enum values not documented** — had to guess; `0_6_months` failed; correct value is `0_to_6_months`.
- **No agency-level duration baseline filtered to >$10M tier** — compared top-tier expiring sample to agency-wide population, making "4–14× longer" finding partly mechanical.
- **`pipeline.duration_profile` caps `duration_months > 600`** but `recompete_watchlist` contains 400–520 month contracts — inconsistent population definitions.
- **DOE M&O/GOCO contracts in "0_to_6_months" bucket** have been continuously extended for 20+ years — not true recompete signals. ~$80B of DOE's "expiring 0-6 mo" is mechanical rollover.

### Data Quality
- **`agency_short_name` null for most non-DoD agencies** — DOE, NASA, GSA, VA, Treasury, USAID, State all null. HHS-NIH populated as "NIH" but HHS-CMS null. Inconsistent.
- **NULL `principal_naics_code` on legacy DoD records** — pre-FPDS-NG migrated records (PIIDs like `0006`, `0009`, `0011`) missing NAICS entirely. ~5–8% of high-value Navy expiring rows.
- **NULL `duration_months`** on Air Force `FA861123F0002` ($240M, F-22 SLM) — `effective_date == current_completion_date`.
- **`base_and_all_options_value = 0.00` on active high-value contracts** — e.g., Army `DAAA0996C0081` ($704M obligated, $0 base). Option value field unreliable for legacy/IDIQ instruments.
- **`total_obligated` >> `base_and_all_options_value` on DOE M&O contracts** — Savannah River $26.3B obligated vs $11.1B base. "Base + all options" appears to be original NTE ceiling, not refreshed with later modifications.
- **Vendor UEI fragmentation: Boeing appears under 13+ distinct UEIs** in this sample alone. Same for Lockheed Martin and Raytheon. UEI-based vendor concentration analysis severely undercounts primes.
- **`contact_creator_class = "unknown"` common** on DOE/NASA records (legacy contact-system migrations).

---

## Cross-Cutting Patterns

### Recurring API Limitations (appear in 3+ queries)
| Issue | Queries Affected |
|---|---|
| **`limit` capped at 25 despite `max_limit` documentation claiming 500–1000** | Q4, Q6, Q7, Q10, Q14, Q15 |
| **`fields` projection parameter rejected (400)** | Q6, Q10, Q15 |
| **Documented filters rejected as 400** (`is_in_state`, `user_class`, `fiscal_year_min/max`, `is_cross_department`) | Q4, Q8, Q9, Q10, Q14 |
| **`fpds_resolve` fails for valid codes** (PSC, NAICS, department codes) | Q7, Q10, Q11 |
| **`agency_short_name` inconsistently populated** (null for non-DoD) | Q7, Q8, Q9, Q12, Q14, Q15 |
| **`source_fiscal_years: [1958, 2026]` on every response** (misleading metadata) | Q4, Q6, Q7, Q11 |
| **No `data_as_of` timestamp** on responses | Q8, Q12 |
| **Sort parameters documented but rejected (400)** | Q6, Q8, Q9 |
| **String vs boolean filter value inconsistency** (`"true"` works, `true` doesn't) | Q9 |

### Recurring Data Quality Issues
| Issue | Queries Affected |
|---|---|
| **Vendor UEI fragmentation** (same legal entity under multiple UEIs) | Q6, Q15 |
| **Null vendor_name despite valid UEI** | Q11, Q15 |
| **Negative obligations producing misleading metrics** (negative shares, zero-floored percentages) | Q6, Q8, Q10, Q12 |
| **`sector_label` null while `sector_code` populated** | Q7, Q14 |
| **Legacy/migrated records missing NAICS** | Q15 |
| **Placeholder/vendor catch-all entries ranked as real vendors** ("MISCELLANEOUS FOREIGN AWARDEES") | Q11 |

### Structural Query Failures
| Query | Failure | Root Cause |
|---|---|---|
| **Q5** | Max turns (30) exceeded | 4-level fan-out: dept → offices → monthly → NAICS |
| **Q13** | Timeout (600s) | 4-level fan-out: dept → offices → vendors → cross-agency market leaders |

Both failures involve **multi-level drill-down queries** where each level requires multiple API calls. The agent turn/time budget cannot accommodate queries that require >30 tool calls or >600s of execution.

### Missing Datasets / Cross-Cuts (Gap Analysis)
| Needed Cross-Cut | Queries That Needed It |
|---|---|
| Agency × PSC × NAICS | Q7 |
| State × NAICS × FY | Q14 |
| Funding department × small-business indicator | Q9 |
| Set-aside family × entrant cohort | Q8 |
| State-scoped HHI / concentration | Q4 |
| Vendor-level data tied to performance state | Q4 |
| Vehicle filter on recompete watchlist | Q6 |
| FY filter on recompete watchlist | Q10 |
| FY filter on topics.competitive_landscape | Q11 |
| Bureau-level grain on risk scorecards | Q12 |
| Agency-level duration baseline filtered to >$10M tier | Q15 |
