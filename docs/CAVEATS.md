# Data Caveats

The FPDS Analytics API is built for market analysis and planning. It should help users ask better questions, identify customer patterns, and prioritize outreach. It should not replace source-record due diligence.

## Source

The analytics are derived from FPDS contract-action records and pre-aggregated into curated analytics views.

## Fiscal Years

Fiscal years use the federal October-September convention:

- October 2025 is FY 2026.
- September 2025 is FY 2025.

## Obligations

FPDS obligation amounts can include:

- Positive obligations.
- Negative de-obligations.
- Corrections.
- Modifications.

For this reason, totals can move down as well as up.

## Vendor Concentration

Vendor concentration datasets require usable vendor and agency keys. Records missing UEI, agency, or signed date are excluded from those vendor-specific aggregates.

## Department And Agency Codes

Department and agency codes reflect how records were coded in FPDS. They do not always map cleanly to the operational customer, installation, funding source, or end user of the work.

Department code `9700` represents Department of Defense records as coded in FPDS. DoD-related work can also appear under other contracting departments, funding departments, interagency vehicles, or government-wide acquisition channels. Do not treat `9700` as the complete universe of defense, Army, or military-base opportunity.

## Geography And Overseas Work

Place-of-performance fields are reporting fields, not perfect location truth. Overseas or OCONUS work can be recorded to military postal codes, foreign locations, CONUS district offices, vendor/admin locations, or other reporting conventions.

Use geography results as directional signals and verify against solicitations, award files, and source records before making customer-entry decisions.

## IDV And Contract Scope

Some FPDS records contain indefinite-delivery vehicle ceiling values that can overstate actual obligated dollars. Where available, contract-scope measures should be used for real-money analysis.

## Current Fiscal Year

Current fiscal year values are year-to-date and may be incomplete.

## Use As Decision Support

The API can indicate patterns such as:

- High sole-source exposure.
- Concentrated vendor markets.
- Growing NAICS demand.
- Regional work flows.
- Pricing-risk exposure.

These are analytical indicators, not final procurement judgments.
