---
name: vehicle-strategy-advisor
description: "Advise govcon companies on which contract vehicles (GWAC, Schedule, IDIQ, BPA) they need for a target agency, which specific programs the agency uses, and who is already winning on them."
metadata:
  openclaw:
    emoji: "🚛"
    requires:
      env: ["FPDS_API_KEY"]
---

# Vehicle Strategy Advisor

## When to Use

You need to determine the contract vehicle strategy for a specific federal agency:

- "Do I need a vehicle to sell to this agency?"
- "Which specific GWACs, Schedules, or IDIQs does this agency use?"
- "Who's winning on the vehicles I need to get on?"
- "Should I pursue a vehicle seat or find a prime with one?"
- "Is this agency's spending shifting toward vehicles or open market?"

## Inputs

| Input | What it is | How to get it |
|-------|-----------|---------------|
| **Agency or department** | The federal customer (e.g., VA, DHS, Army) | Use `fpds_resolve` to find the department or agency code |
| **Office (optional)** | A specific contracting office within the agency | Use `fpds_resolve` with the office name, or skip for agency-wide analysis |
| **Vehicle family filter (optional)** | Narrow to GWAC, Schedule, IDIQ, BPA, BOA, or Open Market | User specifies, or default to all vehicles |

## Workflow

### Step 1: Resolve the agency

Call `fpds_resolve` with the department or agency name. You need the
`contracting_dept_id` and `contracting_agency_id` for filtering.

If the user has a specific office in mind, resolve it as well — you will use it
in Step 7.

### Step 2: Get the agency's overall vehicle mix

Call `fpds_query_dataset` on `acquisition.agency_vehicle_mix_fy` with:

- `contracting_agency_id` = resolved agency code (use `contracting_dept_id` if agency-level is unavailable)
- `fiscal_year` = most recent complete fiscal year (e.g., 2025 if current is 2026)
- `limit` = 10 (covers all vehicle families)
- `sort` = `-net_obligated_amount`

This returns the breakdown by vehicle family: GWAC, Schedule, IDIQ, BPA, BOA,
and Open Market. Pay attention to:

- **Open Market share**: High open-market share means you can compete without a
  vehicle. Low open-market share means vehicle access is critical.
- **GWAC + IDIQ share**: If these dominate, the agency leans heavily on
  structured vehicle programs.
- **Schedule share**: A strong Schedule presence means GSA MAS is a viable path.
- **Competed vs. not-competed**: `competed_action_share` tells you how much of
  the vehicle spend is actually competed. High not-competed share on a vehicle
  family suggests incumbents have a lock.

### Step 3: Identify the named vehicle programs the agency uses

Call `fpds_query_dataset` on `acquisition.vehicle_program_usage_fy` with:

- `contracting_agency_id` = resolved agency code
- `fiscal_year` = most recent complete fiscal year
- `limit` = 25
- `sort` = `-obligated_amount`

This returns specific named programs (e.g., OASIS, Alliant 2, GSA MAS, SEWP V,
8(a) STARS III) that the agency actually obligates through. For each vehicle,
note:

- **`obligated_amount`**: How much the agency spent through this vehicle.
- **`avg_offers_received`**: Low averages (<3) suggest pre-wired task orders.
  High averages (>5) suggest genuinely competitive task order environments.
- **`small_biz_obligation_share`**: Above 50% means the vehicle is a strong
  small business pathway. Below 20% means the vehicle favors large primes.
- **`competed_action_share`**: Below 50% means most orders are not competed —
  incumbents likely have a strong hold.
- **`is_governmentwide`**: GWACs are open to all agencies. Agency-specific
  IDIQs only serve that agency.
- **`is_pseudo_program`**: True means this is a FPDS catch-all category, not a
  real vehicle program. Deprioritize these.

### Step 4: See who's winning on the top vehicles

For the top 3-5 vehicles from Step 3, call `fpds_query_dataset` on
`acquisition.vehicle_program_vendors` with:

- `vehicle_program_id` = the program ID from Step 3
- `fiscal_year` = most recent complete fiscal year
- `limit` = 15
- `sort` = `-obligated_amount`

This shows vendors winning orders on each vehicle, including their
`vendor_rank_in_program_fy` and `vendor_obligation_share`. Assess vendor
concentration:

- If the top 3 vendors control >80% of obligations, the vehicle is effectively
  gated — you will need to team with one of them rather than pursue your own
  seat.
- If the top 10 vendors split <50% of obligations, the vehicle has a broad
  holder base and is more accessible.
- Check `distinct_winning_vendors_fy` on the usage record — if only 5 vendors
  won orders in the entire FY, the vehicle is tightly held regardless of how
  many holders exist on paper.

### Step 5: Get vehicle program context

For the top vehicles from Step 3, call `fpds_query_dataset` on
`acquisition.vehicle_program_summary` with:

- `vehicle_program_id` = the program ID
- (Default `is_active_recent=true` predicate applies, so inactive vehicles are
  filtered out automatically. Pass `is_active_recent=false` explicitly if you
  want legacy vehicles too.)

This returns each vehicle's profile:

- **`lifetime_obligated_amount`**: Total spend through the vehicle across all
  agencies. High lifetime spend (> $5B) signals a mature, entrenched program.
- **`distinct_using_agencies` / `distinct_using_departments`**: How broad the
  vehicle's footprint is. A vehicle used by 50+ agencies is a strong credential.
- **`first_order_fy` / `last_order_fy`**: How long the vehicle has been active.
  Vehicles established >10 years ago with recent activity are deeply embedded.
- **`successor_program_id`**: If the vehicle has a successor, you need to know
  about it — pursuing the old vehicle may be a dead end.
- **`small_biz_obligation_share`**: Overall small business participation.
- **`is_governmentwide`**: Governmentwide vehicles (GWACs, GSA MAS) give you
  access to multiple agencies with one contract. Agency-specific vehicles only
  open that one customer.
- **`notes`**: May contain useful context about the vehicle's status,
  recompetes, or unique characteristics.

### Step 6 (Optional): Government-wide vehicle trends

Call `fpds_query_dataset` on `acquisition.vehicle_trend_fy` with:

- `fiscal_year_min` = current FY minus 5
- `fiscal_year_max` = most recent complete FY
- `limit` = 50

This returns year-over-year trends by vehicle family government-wide. Use this
to contextualize the agency's pattern:

- Is GWAC usage growing government-wide while this agency's GWAC share is flat?
  The agency may be a GWAC laggard — opportunity to propose GWAC-based
  solutions.
- Is Schedule usage declining nationally? GSA MAS may be losing relevance for
  this market.
- Is IDIQ usage growing? More agencies are consolidating spend into
  agency-specific IDIQs.

### Step 7 (Optional): Drill into specific offices

If the user has a specific office or wants to find where within the agency
vehicles are used, call `fpds_query_dataset` on `acquisition.office_vehicle_mix_fy`
with:

- `contracting_agency_id` = resolved agency code
- `fiscal_year` = most recent complete FY
- `limit` = 50
- `sort` = `-net_obligated_amount`

This shows which offices within the agency use which vehicle families. A single
office dominating vehicle spend may indicate a centralized procurement shop.
Multiple offices using the same vehicle family suggest broad adoption.

## Decision Framework

| Vehicle dependence | Strategy |
|---|---|
| <30% vehicle share | Compete open market — no vehicle needed. Register in SAM, respond to RFPs on SAM.gov or agency forecast. |
| 30-60% vehicle share | Get on 1-2 key vehicles OR team with a holder. Prioritize vehicles with high `avg_offers_received` (competitive) and strong `small_biz_obligation_share`. |
| >60% vehicle share | Vehicle access is mandatory. Pursue your own seat if the vendor base is broad (<50% top-3 concentration). Team with a prime holder if the vehicle is tightly held (>80% top-3 concentration). |

## Output Template

```
## Vehicle Strategy: [Agency Name]

### Vehicle Mix Overview (FY [year])
| Vehicle Family | Obligated | Actions | Vendors | Competed % | Small Biz % |
|---------------|-----------|---------|---------|------------|-------------|
| GWAC | $XXM | NNN | NN | NN% | NN% |
| Schedule | $XXM | NNN | NN | NN% | NN% |
| IDIQ | $XXM | NNN | NN | NN% | NN% |
| BPA | $XXM | NNN | NN | NN% | NN% |
| BOA | $XXM | NNN | NN | NN% | NN% |
| Open Market | $XXM | NNN | NN | NN% | NN% |

**Overall vehicle dependence: XX%** → [strategy from decision framework]

### Named Vehicle Programs Used (Top [N])
| Vehicle Program | FY Obligated | Actions | Vendors | Avg Offers | Competed % | Small Biz % | Govwide? |
|----------------|-------------|---------|---------|------------|------------|-------------|----------|
| [Program 1] | $XXM | NNN | NN | N.N | NN% | NN% | Yes/No |
| [Program 2] | $XXM | NNN | NN | N.N | NN% | NN% | Yes/No |
| ...

### Vendor Concentration on Key Vehicles

**[Vehicle 1]**
| Rank | Vendor | Obligated | Orders | Share | Customer Agencies |
|------|--------|-----------|--------|-------|-------------------|
| 1 | [Name] | $XXM | NN | NN% | NN |
| 2 | [Name] | $XXM | NN | NN% | NN |
| 3 | [Name] | $XXM | NN | NN% | NN |
| ...

**Top 3 concentration: XX%** → [gated/accessible/broad]

**[Vehicle 2]** (same format)

### Key Vehicle Details
| Vehicle | Lifetime Spend | Active Since | Last Order | Using Agencies | SB % | Successor? |
|---------|---------------|-------------|------------|----------------|------|------------|
| [Program 1] | $X.XB | FY20XX | FY20XX | NN | NN% | [name]/None |
| ...

### Government-Wide Trends (FY [range])
| Fiscal Year | GWAC | Schedule | IDIQ | BPA | BOA | Open Market |
|------------|------|----------|------|-----|-----|-------------|
| [year] | $XXB | $XXB | $XXB | $XXB | $XXB | $XXB |
| ...

### Your Strategy

**Vehicle Dependency Score: XX%**
- [Primary recommendation: pursue seat, team with holder, or compete open market]
- [Which specific vehicles to prioritize and why]
- [Estimated timeline: how long to get on each vehicle]
- [Fallback: what to do while pursuing a vehicle seat]

### Action Items
1. For [Vehicle A]: [specific action — e.g., contact program office, find teaming partners, check open season]
2. For [Vehicle B]: [specific action]
3. Open market opportunities: [agencies/offices with high open-market share]
```

## Example Conversation

**User:** "Does the VA use specific vehicles for IT services, or can I compete
open market?"

**Agent:**
1. Resolves "VA" → `contracting_dept_id: 3600`
2. Queries `acquisition.agency_vehicle_mix_fy` with agency=3600, fiscal_year=2025
   → sees 42% GWAC, 18% Schedule, 12% IDIQ, 28% Open Market for IT services
3. Queries `acquisition.vehicle_program_usage_fy` with agency=3600, fiscal_year=2025,
   limit=15, sort=-obligated_amount → top vehicles: T4NG ($2.1B), GSA MAS ($890M),
   VETS GWAC ($340M), NASA SEWP V ($210M)
4. Queries `acquisition.vehicle_program_vendors` for T4NG (top 3 hold 47%),
   GSA MAS (top 3 hold 12%), VETS GWAC (top 3 hold 38%), SEWP V (top 3 hold 22%)
5. Queries `acquisition.vehicle_program_summary` for T4NG, GSA MAS, VETS GWAC, SEWP V
   → T4NG: $22B lifetime, VA-specific, active. GSA MAS: $140B lifetime, governmentwide.
   VETS GWAC: $8B lifetime, governmentwide, SDVOSB set-aside. SEWP V: $18B lifetime,
   governmentwide.
6. Queries `acquisition.vehicle_trend_fy` for FY 2020-2025 → GWAC usage growing
   7% CAGR government-wide, VA above average at 11%
7. Presents the summary: VA is 72% vehicle-dependent for IT. T4NG is the dominant
   vehicle but is VA-specific and concentrated (top 3 hold 47%). VETS GWAC and
   SEWP V are accessible governmentwide alternatives. GSA MAS is the most open
   vehicle. Recommendation: pursue VETS GWAC (SDVOSB set-aside) or SEWP V for
   immediate access, team with a T4NG prime for VA-specific work while pursuing
   your own T4NG seat during the next open season.

## Caveats

- Vehicle mix percentages are based on obligated amounts, not ceiling values.
  A vehicle with a $50B ceiling may only have $200M in actual obligations through
  a given agency.
- `vendor_obligation_share` reflects actual task order wins, not the full holder
  base. Dozens of companies may hold the vehicle but only a handful may be actively
  winning orders. Focus on who is *winning*, not who is *holding*.
- `is_pseudo_program=true` vehicles are FPDS catch-all categories (e.g., "GSA
  SCHEDULE 70 GENERIC"), not real contract programs. Deprioritize these — the
  real programs are the non-pseudo ones.
- `is_active_recent=true` in `acquisition.vehicle_program_summary` filters to
  programs with orders in the last 2 fiscal years. Vehicles without recent
  activity are automatically excluded unless you override the filter.
- Agency-specific IDIQs (e.g., T4NG for VA) only serve that agency. Getting on
  them gives you access to one customer. Governmentwide vehicles (GWACs, GSA MAS)
  give you access to all federal agencies.
- FPDS data has a known coverage gap for pre-2010 records. Use FY 2010+ for
  reliable lifetime comparisons.
- Open season windows for vehicles are infrequent and unpredictable. Check the
  vehicle program office website for solicitation schedules. Many IDIQs only
  open for new holders every 5-10 years.
