"""Interpretation notices returned with API data."""

from __future__ import annotations

from typing import Any


GLOBAL_DATA_NOTICES = [
    (
        "FPDS analytics are decision-support indicators, not a complete procurement universe. "
        "They are derived from prime contract-action records and can exclude or underrepresent "
        "classified/sensitive activity, subcontracts, grants, assistance, micro-purchases, and records "
        "not represented in these curated analytics views."
    ),
    (
        "Department code 9700 represents Department of Defense records as coded in FPDS. "
        "DoD-related work can also appear under other contracting departments, funding departments, "
        "interagency vehicles, or government-wide acquisition channels, so 9700 should not be treated "
        "as the complete universe of defense or Army-relevant opportunity."
    ),
    (
        "Current fiscal year values are year-to-date and may be incomplete. FPDS records can be "
        "corrected, modified, or de-obligated after initial reporting."
    ),
]

GEOGRAPHY_NOTICES = [
    (
        "Place-of-performance fields are reporting fields, not perfect location truth. Overseas or "
        "OCONUS work can be recorded to military postal codes, foreign locations, CONUS district "
        "offices, vendor/admin locations, or other reporting conventions; use geography results as "
        "directional signals and verify against solicitations and source records."
    ),
]

AGENCY_CODE_NOTICES = [
    (
        "Agency and department codes describe how FPDS records were coded for contracting/reporting. "
        "They do not always map cleanly to the operational customer, installation, funding source, "
        "or end user of the work."
    ),
]


def _dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def data_notices(dataset: dict[str, Any]) -> list[str]:
    """Return interpretation notices for dataset row responses."""
    notices = list(GLOBAL_DATA_NOTICES)
    domain = dataset.get("domain")
    fields_and_filters = set(dataset.get("fields", [])) | set(dataset.get("filters", []))
    if domain == "geography":
        notices.extend(GEOGRAPHY_NOTICES)
    if {"contracting_dept_id", "contracting_agency_id"} & fields_and_filters:
        notices.extend(AGENCY_CODE_NOTICES)
    return _dedupe(notices)


def dimension_notices(dimension: dict[str, Any]) -> list[str]:
    """Return interpretation notices for dimension lookup responses."""
    notices = list(GLOBAL_DATA_NOTICES)
    if dimension.get("id") == "states":
        notices.extend(GEOGRAPHY_NOTICES)
    return _dedupe(notices)
