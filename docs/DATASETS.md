# Dataset Reference

This reference lists every dataset currently packaged in the FPDS Analytics API.

Use `GET /v1/datasets/{dataset_id}` for machine-readable metadata, including field allowlists and supported filters.

## Pricing

| Dataset ID | Plain-English purpose | Grain | Common filters | Default sort |
|---|---|---|---|---|
| `pricing.trend_fy` | Pricing Trend By Fiscal Year | fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max | `fiscal_year` |
| `pricing.agency_profile_fy` | Pricing Agency Profile By Fiscal Year | contracting_dept_id x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, contracting_dept_id | `-total_obligated_amount` |
| `pricing.kpi_summary` | Pricing KPI Summary | scope | scope_name | `scope_name` |
| `pricing.risk_scorecard` | Pricing Risk Scorecard | contracting_dept_id over recent three fiscal years | contracting_dept_id | `-risk_score` |
| `pricing.dept_year_summary` | Pricing Department-Year Summary | contracting_dept_id x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, contracting_dept_id | `-total_obligated` |

## Concentration

| Dataset ID | Plain-English purpose | Grain | Common filters | Default sort |
|---|---|---|---|---|
| `concentration.trend_fy` | Market Concentration Trend By Fiscal Year | fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max | `fiscal_year` |
| `concentration.agency_profile` | Concentration Agency Profile | contracting_agency_id | contracting_agency_id | `-total_market_obligation` |
| `concentration.vendor_market_leaders` | Vendor Market Leaders | uei | uei, is_small_business_ever | `-lifetime_total_obligated` |
| `concentration.small_biz_health_fy` | Small Business Health By Fiscal Year | fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max | `fiscal_year` |
| `concentration.kpi_summary` | Concentration KPI Summary | scope | metric_period | `metric_period` |

## Competition

| Dataset ID | Plain-English purpose | Grain | Common filters | Default sort |
|---|---|---|---|---|
| `competition.trend_fy` | Competition Trend By Fiscal Year | fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max | `fiscal_year` |
| `competition.agency_profile_fy` | Competition Agency Profile By Fiscal Year | contracting_dept_id x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, contracting_dept_id | `-total_obligated` |
| `competition.kpi_summary` | Competition KPI Summary | scope | scope_name | `scope_name` |
| `competition.sole_source_hotspots` | Sole Source Hotspots | contracting_dept_id over recent three fiscal years | contracting_dept_id | `-not_competed_obligation_share_3yr` |

## Naics

| Dataset ID | Plain-English purpose | Grain | Common filters | Default sort |
|---|---|---|---|---|
| `naics.trend_fy` | NAICS Sector Trend By Fiscal Year | sector_code x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, sector_code | `-total_obligated` |
| `naics.agency_profile_fy` | NAICS Agency Profile By Fiscal Year | contracting_dept_id x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, contracting_dept_id | `-total_obligated` |
| `naics.growth_leaders` | NAICS Growth Leaders | principal_naics_code | principal_naics_code, sector_code | `-obligation_growth_rate` |
| `naics.kpi_summary` | NAICS KPI Summary | scope | scope_name | `scope_name` |

## Geography

| Dataset ID | Plain-English purpose | Grain | Common filters | Default sort |
|---|---|---|---|---|
| `geography.state_trend_fy` | Geographic State Trend By Fiscal Year | pop_state_code x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, pop_state_code, census_region, census_division, is_state | `-total_obligated` |
| `geography.regional_summary_fy` | Geographic Regional Summary By Fiscal Year | census_region x fiscal_year | fiscal_year, fiscal_year_min, fiscal_year_max, census_region | `-total_obligated` |
| `geography.mismatch_leaders` | Vendor-State To Performance-State Mismatch Leaders | vendor_state_code x pop_state_code over recent three fiscal years | vendor_state_code, pop_state_code, is_in_state | `-total_obligated` |
| `geography.kpi_summary` | Geographic KPI Summary | scope | scope_name | `scope_name` |

## Field Details

### `pricing.trend_fy`

- Title: Pricing Trend By Fiscal Year
- Grain: fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- Sortable fields: `fiscal_year`, `total_obligated`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`
- Fields: `fiscal_year`, `is_current_fiscal_year_ytd`, `fixed_price_action_count`, `fixed_price_obligated`, `cost_type_action_count`, `cost_type_obligated`, `tm_action_count`, `tm_obligated`, `other_action_count`, `other_obligated`, `total_action_count`, `total_obligated`, `fixed_price_action_share`, `cost_type_action_share`, `tm_action_share`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`

### `pricing.agency_profile_fy`

- Title: Pricing Agency Profile By Fiscal Year
- Grain: contracting_dept_id x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `contracting_dept_id`
- Sortable fields: `fiscal_year`, `contracting_dept_id`, `total_obligated_amount`, `cost_type_obligation_share`, `tm_obligation_share`
- Fields: `contracting_dept_id`, `fiscal_year`, `is_current_fiscal_year_ytd`, `total_action_count`, `total_obligated_amount`, `fixed_price_action_count`, `fixed_price_obligated`, `cost_type_action_count`, `cost_type_obligated`, `tm_action_count`, `tm_obligated`, `other_action_count`, `other_obligated`, `fixed_price_action_share`, `cost_type_action_share`, `tm_action_share`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`

### `pricing.kpi_summary`

- Title: Pricing KPI Summary
- Grain: scope
- Filters: `scope_name`
- Sortable fields: `scope_name`, `total_obligated`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`
- Fields: `scope_name`, `total_actions`, `total_obligated`, `fixed_price_actions`, `cost_type_actions`, `tm_actions`, `fixed_price_action_share`, `cost_type_action_share`, `tm_action_share`, `fixed_price_obligated`, `cost_type_obligated`, `tm_obligated`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`

### `pricing.risk_scorecard`

- Title: Pricing Risk Scorecard
- Grain: contracting_dept_id over recent three fiscal years
- Filters: `contracting_dept_id`
- Sortable fields: `risk_score`, `total_obligated_3yr`, `cost_type_obligation_share`, `tm_obligation_share`
- Fields: `contracting_dept_id`, `cost_type_obligation_share`, `tm_obligation_share`, `risk_score`, `total_obligated_3yr`, `cost_type_obligated_3yr`, `tm_obligated_3yr`, `total_action_count_3yr`

### `pricing.dept_year_summary`

- Title: Pricing Department-Year Summary
- Grain: contracting_dept_id x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `contracting_dept_id`
- Sortable fields: `fiscal_year`, `contracting_dept_id`, `total_obligated`, `cost_type_obligation_share`, `tm_obligation_share`
- Fields: `contracting_dept_id`, `fiscal_year`, `fixed_price_action_count`, `fixed_price_obligated`, `cost_type_action_count`, `cost_type_obligated`, `tm_action_count`, `tm_obligated`, `other_action_count`, `other_obligated`, `total_action_count`, `total_obligated`, `multi_year_action_count`, `pbc_action_count`, `fixed_price_action_share`, `cost_type_action_share`, `tm_action_share`, `fixed_price_obligation_share`, `cost_type_obligation_share`, `tm_obligation_share`

### `concentration.trend_fy`

- Title: Market Concentration Trend By Fiscal Year
- Grain: fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- Sortable fields: `fiscal_year`, `avg_hhi`, `highly_concentrated_markets`, `competitive_markets`
- Fields: `fiscal_year`, `is_current_fiscal_year_ytd`, `analyzed_markets`, `highly_concentrated_markets`, `moderately_concentrated_markets`, `competitive_markets`, `highly_concentrated_pct`, `avg_hhi`, `avg_top_vendor_share_pct`, `avg_top_3_vendor_share_pct`, `avg_vendors_per_market`, `small_biz_obligation_share_pct`, `avg_small_biz_vendors_per_market`, `total_market_obligation`
- Caveats: Concentration markets require at least two distinct vendors and positive total obligation.

### `concentration.agency_profile`

- Title: Concentration Agency Profile
- Grain: contracting_agency_id
- Filters: `contracting_agency_id`
- Sortable fields: `contracting_agency_id`, `analyzed_markets`, `avg_hhi`, `monopoly_market_pct`, `total_market_obligation`
- Fields: `contracting_agency_id`, `analyzed_markets`, `monopoly_markets`, `monopoly_market_pct`, `avg_hhi`, `avg_top_vendor_share_pct`, `avg_vendors_per_market`, `small_biz_obligation_share_pct`, `total_market_obligation`, `avg_market_size`, `latest_fiscal_year`

### `concentration.vendor_market_leaders`

- Title: Vendor Market Leaders
- Grain: uei
- Filters: `uei`, `is_small_business_ever`
- Sortable fields: `lifetime_total_obligated`, `agencies_served`, `avg_tenure_years`, `avg_annual_obligated`
- Fields: `uei`, `vendor_name`, `is_small_business_ever`, `agencies_served`, `lifetime_total_obligated`, `avg_annual_obligated`, `avg_tenure_years`, `avg_year_span`, `long_incumbent_agencies`, `last_active_year`, `first_active_year`
- Caveats: Vendor datasets exclude rows with missing UEI, agency, or signed_date.

### `concentration.small_biz_health_fy`

- Title: Small Business Health By Fiscal Year
- Grain: fiscal_year
- Required filters: at least one of `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- Sortable fields: `fiscal_year`, `small_biz_obligation_share_pct`, `small_biz_vendor_share_pct`, `new_small_biz_entrants`
- Fields: `fiscal_year`, `is_current_fiscal_year_ytd`, `small_biz_vendor_count`, `total_vendor_count`, `small_biz_vendor_share_pct`, `small_biz_obligation_total`, `total_obligation`, `small_biz_obligation_share_pct`, `small_biz_action_count`, `total_action_count`, `small_biz_action_share_pct`, `new_small_biz_entrants`
- Caveats: Small-business flags reflect FPDS award records, not necessarily current SAM registration status.

### `concentration.kpi_summary`

- Title: Concentration KPI Summary
- Grain: scope
- Filters: `metric_period`
- Sortable fields: `metric_period`, `current_fy_avg_hhi`, `current_fy_highly_concentrated_pct`, `current_fy_small_biz_share_pct`
- Fields: `metric_period`, `current_fiscal_year`, `current_fy_markets_analyzed`, `current_fy_avg_hhi`, `current_fy_highly_concentrated_pct`, `three_year_avg_hhi`, `current_fy_avg_vendors_per_market`, `current_fy_small_biz_share_pct`

### `competition.trend_fy`

- Title: Competition Trend By Fiscal Year
- Grain: fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`
- Sortable fields: `fiscal_year`, `total_obligated`, `competed_action_share`, `not_competed_action_share`, `bundled_action_share`, `avg_offers_received`
- Fields: `fiscal_year`, `is_current_fiscal_year_ytd`, `competed_action_count`, `competed_obligated`, `not_competed_action_count`, `not_competed_obligated`, `full_competition_action_count`, `full_competition_obligated`, `limited_competition_action_count`, `limited_competition_obligated`, `bundled_action_count`, `bundled_obligated`, `consolidated_action_count`, `consolidated_obligated`, `total_action_count`, `total_obligated`, `competed_action_share`, `not_competed_action_share`, `full_competition_action_share`, `limited_competition_action_share`, `competed_obligation_share`, `not_competed_obligation_share`, `bundled_action_share`, `bundled_obligation_share`, `consolidated_action_share`, `consolidated_obligation_share`, `avg_offers_received`

### `competition.agency_profile_fy`

- Title: Competition Agency Profile By Fiscal Year
- Grain: contracting_dept_id x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `contracting_dept_id`
- Sortable fields: `fiscal_year`, `total_obligated`, `competed_action_share`, `not_competed_action_share`, `bundled_action_share`, `avg_offers_received`
- Fields: `contracting_dept_id`, `fiscal_year`, `is_current_fiscal_year_ytd`, `competed_action_count`, `competed_obligated`, `not_competed_action_count`, `not_competed_obligated`, `full_competition_action_count`, `full_competition_obligated`, `limited_competition_action_count`, `limited_competition_obligated`, `bundled_action_count`, `bundled_obligated`, `consolidated_action_count`, `consolidated_obligated`, `total_action_count`, `total_obligated`, `competed_action_share`, `not_competed_action_share`, `bundled_action_share`, `competed_obligation_share`, `not_competed_obligation_share`, `bundled_obligation_share`, `consolidated_obligation_share`, `avg_offers_received`

### `competition.kpi_summary`

- Title: Competition KPI Summary
- Grain: scope
- Filters: `scope_name`
- Sortable fields: `scope_name`, `competed_action_share`, `not_competed_action_share`, `bundled_action_share`, `avg_offers_received`
- Fields: `scope_name`, `total_actions`, `total_obligated`, `competed_actions`, `not_competed_actions`, `full_competition_actions`, `limited_competition_actions`, `competed_action_share`, `not_competed_action_share`, `full_competition_action_share`, `limited_competition_action_share`, `competed_obligated`, `not_competed_obligated`, `competed_obligation_share`, `not_competed_obligation_share`, `bundled_actions`, `consolidated_actions`, `bundled_obligated`, `consolidated_obligated`, `bundled_action_share`, `consolidated_action_share`, `bundled_obligation_share`, `consolidated_obligation_share`, `avg_offers_received`

### `competition.sole_source_hotspots`

- Title: Sole Source Hotspots
- Grain: contracting_dept_id over recent three fiscal years
- Filters: `contracting_dept_id`
- Sortable fields: `not_competed_obligation_share_3yr`, `not_competed_obligated_3yr`, `total_obligated_3yr`
- Fields: `contracting_dept_id`, `not_competed_action_count_3yr`, `not_competed_obligated_3yr`, `total_action_count_3yr`, `total_obligated_3yr`, `not_competed_action_share_3yr`, `not_competed_obligation_share_3yr`, `avg_offers_received_3yr`, `bundled_action_count_3yr`, `bundled_action_share_3yr`

### `naics.trend_fy`

- Title: NAICS Sector Trend By Fiscal Year
- Grain: sector_code x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `sector_code`
- Sortable fields: `fiscal_year`, `sector_code`, `total_obligated`, `sector_obligation_share_of_total`, `total_distinct_vendors`
- Fields: `fiscal_year`, `sector_code`, `sector_label`, `is_current_fiscal_year_ytd`, `total_action_count`, `total_obligated`, `contract_scope_action_count`, `contract_scope_obligated`, `total_distinct_naics`, `total_distinct_vendors`, `sector_obligation_share_of_total`

### `naics.agency_profile_fy`

- Title: NAICS Agency Profile By Fiscal Year
- Grain: contracting_dept_id x fiscal_year
- Required filters: at least one of `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `contracting_dept_id`
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `contracting_dept_id`
- Sortable fields: `fiscal_year`, `contracting_dept_id`, `total_obligated`, `distinct_naics_count`, `top_naics_obligation_share`, `top_sector_obligation_share`
- Fields: `contracting_dept_id`, `fiscal_year`, `is_current_fiscal_year_ytd`, `total_action_count`, `total_obligated`, `distinct_naics_count`, `distinct_sector_count`, `distinct_subsector_count`, `distinct_vendor_count`, `top_naics_code_by_obligation`, `top_naics_obligation_share`, `naics_diversity_ratio`, `top_sector_code`, `top_sector_obligation_share`

### `naics.growth_leaders`

- Title: NAICS Growth Leaders
- Grain: principal_naics_code
- Filters: `principal_naics_code`, `sector_code`
- Sortable fields: `obligation_growth_rate`, `obligation_change`, `current_fy_obligated`, `prior_fy_obligated`
- Fields: `principal_naics_code`, `naics_desc`, `sector_code`, `current_fy_obligated`, `prior_fy_obligated`, `obligation_change`, `obligation_growth_rate`, `current_fy_actions`, `prior_fy_actions`

### `naics.kpi_summary`

- Title: NAICS KPI Summary
- Grain: scope
- Filters: `scope_name`
- Sortable fields: `scope_name`, `distinct_naics_count`, `distinct_sector_count`, `avg_vendors_per_naics`, `avg_obligation_per_naics`
- Fields: `scope_name`, `distinct_naics_count`, `distinct_sector_count`, `total_obligated`, `dept_count`, `vendor_interactions`, `avg_vendors_per_naics`, `avg_obligation_per_naics`

### `geography.state_trend_fy`

- Title: Geographic State Trend By Fiscal Year
- Grain: pop_state_code x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `pop_state_code`, `census_region`, `census_division`, `is_state`
- Sortable fields: `fiscal_year`, `pop_state_code`, `total_obligated`, `total_distinct_vendor_count`, `distinct_agency_count`
- Fields: `pop_state_code`, `pop_state_name`, `fiscal_year`, `is_current_fiscal_year_ytd`, `total_action_count`, `total_obligated`, `contract_scope_obligated`, `distinct_agency_count`, `total_distinct_vendor_count`, `is_domestic`, `census_region`, `census_division`, `is_state`

### `geography.regional_summary_fy`

- Title: Geographic Regional Summary By Fiscal Year
- Grain: census_region x fiscal_year
- Filters: `fiscal_year`, `fiscal_year_min`, `fiscal_year_max`, `census_region`
- Sortable fields: `fiscal_year`, `census_region`, `total_obligated`, `state_count`, `total_distinct_vendor_count`
- Fields: `census_region`, `fiscal_year`, `is_current_fiscal_year_ytd`, `state_count`, `total_action_count`, `total_obligated`, `contract_scope_obligated`, `total_distinct_vendor_count`, `total_distinct_agency_count`

### `geography.mismatch_leaders`

- Title: Vendor-State To Performance-State Mismatch Leaders
- Grain: vendor_state_code x pop_state_code over recent three fiscal years
- Filters: `vendor_state_code`, `pop_state_code`, `is_in_state`
- Sortable fields: `total_obligated`, `total_action_count`, `total_distinct_vendor_count`
- Fields: `vendor_state_code`, `pop_state_code`, `vendor_state_name`, `pop_state_name`, `total_action_count`, `total_obligated`, `total_distinct_vendor_count`, `is_in_state`, `vendor_census_region`, `pop_census_region`

### `geography.kpi_summary`

- Title: Geographic KPI Summary
- Grain: scope
- Filters: `scope_name`
- Sortable fields: `scope_name`, `domestic_obligated_share`, `international_obligated_share`, `in_state_obligated_share`
- Fields: `scope_name`, `state_count`, `total_actions`, `total_obligated`, `domestic_obligated`, `international_obligated`, `domestic_obligated_share`, `international_obligated_share`, `in_state_obligated`, `in_state_obligated_share`
