-- Set-aside analysis facade views for the public API.
--
-- Source: set_aside_breakdown schema (11 MVs, 8 report views).
-- Excludes: contact-level views (contain PII — officer names, emails).
--
-- Run after 001_analytics_api_facade.sql.

-- Set-aside trend: government-wide set-aside participation by fiscal year.
CREATE OR REPLACE VIEW analytics_api.set_aside_trend_fy
WITH (security_barrier = true) AS
SELECT
    fiscal_year,
    is_current_fiscal_year_ytd,
    action_count,
    contract_scope_action_count,
    base_award_action_count,
    modification_action_count,
    known_setaside_status_count,
    unknown_setaside_status_count,
    no_setaside_action_count,
    positive_setaside_action_count,
    net_obligated_amount,
    known_status_net_obligated_amount,
    positive_setaside_net_obligated_amount,
    contract_scope_net_obligated_amount,
    contract_scope_positive_setaside_net_obligated_amount,
    setaside_action_share_all,
    setaside_action_share_known,
    contract_scope_setaside_action_share_known,
    setaside_obligation_share_known,
    contract_scope_setaside_obligation_share_known,
    unknown_status_share,
    modification_share,
    base_award_setaside_share_known
FROM set_aside_breakdown.report_deck_overall_trend_fy;

COMMENT ON VIEW analytics_api.set_aside_trend_fy IS
'Government-wide set-aside participation trends by fiscal year. Shows how small-business set-aside usage evolves over time, including the share of actions and obligations flowing through socioeconomic programs.';


-- Set-aside family trend: trends broken out by set-aside family (8(a), WOSB, HUBZone, SDVOSB, etc.).
CREATE OR REPLACE VIEW analytics_api.set_aside_family_trend_fy
WITH (security_barrier = true) AS
SELECT
    fiscal_year,
    is_current_fiscal_year_ytd,
    set_aside_family,
    action_count,
    contract_scope_action_count,
    positive_setaside_action_count,
    net_obligated_amount,
    contract_scope_net_obligated_amount,
    contract_scope_positive_setaside_net_obligated_amount,
    total_action_count,
    total_positive_setaside_action_count,
    total_net_obligated_amount,
    share_of_known_status_actions,
    share_of_positive_setaside_actions,
    share_of_net_obligations
FROM set_aside_breakdown.report_deck_setaside_family_trend_fy;

COMMENT ON VIEW analytics_api.set_aside_family_trend_fy IS
'Set-aside participation trends broken out by socioeconomic program family: 8(a), Small Business, WOSB, HUBZone, SDVOSB, Veteran-Owned, and others. Shows each program''s share of total set-aside activity over time.';


-- Agency set-aside profile: per-agency small-business friendliness by fiscal year.
CREATE OR REPLACE VIEW analytics_api.set_aside_agency_profile_fy
WITH (security_barrier = true) AS
SELECT
    fiscal_year,
    is_current_fiscal_year_ytd,
    contracting_dept_id,
    contracting_dept_name,
    contracting_agency_id,
    contracting_agency_name,
    action_count,
    contract_scope_total_action_count,
    contract_scope_known_setaside_status_count,
    contract_scope_positive_setaside_action_count,
    net_obligated_amount,
    contract_scope_net_obligated_amount,
    contract_scope_known_status_net_obligated_amount,
    contract_scope_positive_setaside_net_obligated_amount,
    setaside_action_share_known,
    contract_scope_setaside_action_share_known,
    contract_scope_setaside_obligation_share_known,
    unknown_status_share,
    modification_share,
    friendliness_rank
FROM set_aside_breakdown.report_deck_agency_friendly_fy;

COMMENT ON VIEW analytics_api.set_aside_agency_profile_fy IS
'Per-agency small-business set-aside profile by fiscal year. Includes a friendliness rank based on the share of contract-scope actions and obligations flowing through set-aside programs. Higher rank means more small-business-friendly.';


-- Agency set-aside mix: which specific set-aside programs each agency uses.
CREATE OR REPLACE VIEW analytics_api.set_aside_agency_mix_fy
WITH (security_barrier = true) AS
SELECT
    fiscal_year,
    is_current_fiscal_year_ytd,
    contracting_dept_id,
    contracting_dept_name,
    contracting_agency_id,
    contracting_agency_name,
    set_aside_code,
    set_aside_label,
    set_aside_family,
    positive_setaside_action_count,
    net_obligated_amount,
    base_and_all_options_value_sum,
    total_estimated_order_value_sum,
    contract_scope_action_count,
    known_setaside_status_count,
    agency_setaside_rank
FROM set_aside_breakdown.report_deck_agency_setaside_mix_fy;

COMMENT ON VIEW analytics_api.set_aside_agency_mix_fy IS
'Per-agency breakdown of set-aside usage by specific program (8(a) Competed, 8(a) Sole Source, SBA Total, WOSB, HUBZone, SDVOSB, etc.) and fiscal year. Shows which socioeconomic programs each customer actually uses and how much flows through each.';


-- Office set-aside profile: per-contracting-office small-business friendliness.
CREATE OR REPLACE VIEW analytics_api.set_aside_office_profile_fy
WITH (security_barrier = true) AS
SELECT
    fiscal_year,
    is_current_fiscal_year_ytd,
    contracting_dept_id,
    contracting_dept_name,
    contracting_agency_id,
    contracting_agency_name,
    contracting_office_id,
    contracting_office_name,
    action_count,
    contract_scope_total_action_count,
    contract_scope_known_setaside_status_count,
    contract_scope_positive_setaside_action_count,
    net_obligated_amount,
    contract_scope_net_obligated_amount,
    contract_scope_known_status_net_obligated_amount,
    contract_scope_positive_setaside_net_obligated_amount,
    setaside_action_share_known,
    contract_scope_setaside_action_share_known,
    contract_scope_setaside_obligation_share_known,
    unknown_status_share,
    modification_share,
    friendliness_rank
FROM set_aside_breakdown.report_deck_office_friendly_fy;

COMMENT ON VIEW analytics_api.set_aside_office_profile_fy IS
'Per-contracting-office small-business set-aside profile by fiscal year. Office-level granularity reveals which buying organizations within an agency are actually friendly to small businesses. Includes friendliness rank.';


-- Set-aside KPI summary: top-level metrics across three time scopes.
CREATE OR REPLACE VIEW analytics_api.set_aside_kpi_summary
WITH (security_barrier = true) AS
SELECT
    metric_scope,
    min_fiscal_year,
    max_fiscal_year,
    action_count,
    known_setaside_status_count,
    unknown_setaside_status_count,
    no_setaside_action_count,
    positive_setaside_action_count,
    net_obligated_amount,
    setaside_action_share_known,
    unknown_status_share
FROM set_aside_breakdown.report_deck_kpi_summary;

COMMENT ON VIEW analytics_api.set_aside_kpi_summary IS
'Top-level set-aside KPIs across three scopes: all years, current fiscal year, and recent 3-year contact activity. Shows government-wide small-business participation rates and data quality (unknown status share).';


-- Public dimension: set-aside code lookup.
CREATE OR REPLACE VIEW analytics_api.dim_set_aside_codes
WITH (security_barrier = true) AS
SELECT
    raw_code,
    normalized_code,
    label,
    family,
    status,
    is_positive_set_aside,
    is_known_status,
    valid_from,
    valid_to,
    sort_order,
    notes
FROM analytics_dims.fpds_set_aside_code_map;

COMMENT ON VIEW analytics_api.dim_set_aside_codes IS
'Set-aside code lookup table. Maps FPDS type_of_set_aside codes to human-readable labels, socioeconomic program families, and classification flags. Includes historical validity dates for retired codes.';
