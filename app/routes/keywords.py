"""Keyword-level procurement analytics endpoints.

Integrates the fpds-keywords data (v2 schema) into the FPDS Analytics API,
providing capability-level search, analytics, topic bridging, comparison,
and vendor profiles.
"""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Query, Request

from app.db import db_cursor
from app.errors import APIError
from app.notices import BRIEF_DATA_NOTICE

router = APIRouter(prefix="/v1")

DEFAULT_CATEGORIES = ["product_vendor", "method_service", "system_program"]


def _keyword_by_text_or_id(
    cur: Any, keyword_text: str | None, keyword_id: int | None
) -> dict[str, Any] | None:
    """Resolve a keyword by exact text or id. Returns None if not found."""
    if keyword_id is not None:
        cur.execute(
            "SELECT id, keyword, keyword_type, category "
            "FROM v2.keywords WHERE id = %s",
            (keyword_id,),
        )
    elif keyword_text is not None:
        cur.execute(
            "SELECT id, keyword, keyword_type, category "
            "FROM v2.keywords WHERE lower(keyword) = lower(%s) LIMIT 1",
            (keyword_text,),
        )
    else:
        return None
    row = cur.fetchone()
    return dict(row) if row else None


def _keyword_link_count(cur: Any, keyword_id: int, department_code: str | None = None) -> int:
    clauses = ["keyword_id = %s"]
    params: list[Any] = [keyword_id]
    if department_code:
        clauses.append("department_code = %s")
        params.append(department_code)
    cur.execute(
        f"SELECT count(*) as cnt FROM v2.keyword_links WHERE {' AND '.join(clauses)}",
        params,
    )
    row = cur.fetchone()
    return row["cnt"] if row else 0


# ── Search ───────────────────────────────────────────────────────────────


@router.get("/keywords/search")
def keyword_search(
    q: str = Query(..., description="Search query — substring match on keyword text."),
    keyword_type: list[str] | None = Query(
        default=None, description="Filter by keyword type (e.g. phrase, term)."
    ),
    category: list[str] | None = Query(
        default=None, description="Filter by category (product_vendor, method_service, system_program)."
    ),
    department_code: str | None = Query(
        default=None, description="USASpending department code filter."
    ),
    min_link_count: int = Query(default=2, description="Minimum total link count (popularity filter)."),
    limit: int = Query(default=25, ge=1, le=100, description="Max results."),
) -> dict[str, Any]:
    categories = category or DEFAULT_CATEGORIES
    types = keyword_type or ["phrase", "term"]

    with db_cursor() as cur:
        cur.execute(
            """
            SELECT k.id as keyword_id, k.keyword, k.keyword_type, k.category,
                   k.n_words, k.classification_confidence, k.suggested_subcategory,
                   (SELECT count(*) FROM v2.keyword_links kl WHERE kl.keyword_id = k.id) as total_link_count,
                   (SELECT count(*) FROM v2.keyword_links kl
                    WHERE kl.keyword_id = k.id AND kl.department_code = %s) as department_link_count
            FROM v2.keywords k
            WHERE k.keyword ILIKE %s
              AND k.category = ANY(%s)
              AND k.keyword_type = ANY(%s)
            ORDER BY total_link_count DESC
            LIMIT %s
            """,
            (department_code or "", f"%{q}%", categories, types, limit + 1),
        )
        rows = cur.fetchall()

    keywords_list = []
    for row in rows[:limit]:
        kw = dict(row)
        if kw.get("total_link_count", 0) < min_link_count:
            continue
        # Get top departments
        with db_cursor() as cur2:
            cur2.execute(
                """
                SELECT department_code as code, count(*) as cnt
                FROM v2.keyword_links
                WHERE keyword_id = %s
                GROUP BY department_code
                ORDER BY cnt DESC LIMIT 5
                """,
                (kw["keyword_id"],),
            )
            kw["top_departments"] = cur2.fetchall()
        keywords_list.append(kw)

    return {
        "notice": BRIEF_DATA_NOTICE,
        "query": q,
        "department_code": department_code,
        "result_count": len(keywords_list),
        "keywords": keywords_list,
    }


# ── Analytics ────────────────────────────────────────────────────────────


@router.get("/keywords/analytics")
def keyword_analytics(
    keyword_id: int | None = Query(default=None, description="Keyword ID from keyword_search results."),
    keyword_text: str | None = Query(default=None, description="Exact keyword text (case-insensitive match)."),
    department_code: str | None = Query(default=None, description="USASpending department code filter."),
    fy_start: int = Query(default=2018, description="Start fiscal year."),
    fy_end: int = Query(default=2026, description="End fiscal year."),
    group_by: str = Query(default="agency", description="Breakdown: agency, vendor, fy, naics, set_aside."),
    limit: int = Query(default=25, ge=1, le=100, description="Max rows in breakdown."),
) -> dict[str, Any]:
    if keyword_id is None and keyword_text is None:
        raise APIError(400, "missing_param", "Provide keyword_id or keyword_text.", param="keyword_id")

    with db_cursor() as cur:
        kw = _keyword_by_text_or_id(cur, keyword_text, keyword_id)
        if not kw:
            raise APIError(404, "keyword_not_found", "Keyword not found.", param="keyword_id")

    kid = kw["keyword_id"]
    link_count = _keyword_link_count(cur, kid, department_code)

    # Main obligation stats
    with db_cursor() as cur:
        dept_clause = "AND klm.department_code = %s" if department_code else ""
        dept_params: list[Any] = [kid]
        if department_code:
            dept_params.append(department_code)
        dept_params.extend([fy_start, fy_end])
        cur.execute(
            f"""
            SELECT
                COALESCE(SUM(klm.obligated_amount), 0) as total_obligated_amount,
                COUNT(DISTINCT klm.award_number) FILTER (WHERE klm.award_number IS NOT NULL) as total_award_count
            FROM v2.keyword_link_metadata klm
            WHERE klm.keyword_id = %s
              {dept_clause}
              AND klm.fiscal_year BETWEEN %s AND %s
            """,
            dept_params,
        )
        stats = dict(cur.fetchone() or {})

    # FY trend
    with db_cursor() as cur:
        cur.execute(
            f"""
            SELECT klm.fiscal_year as fy,
                   COALESCE(SUM(klm.obligated_amount), 0) as obligation,
                   COUNT(DISTINCT klm.award_number) FILTER (WHERE klm.award_number IS NOT NULL) as award_count
            FROM v2.keyword_link_metadata klm
            WHERE klm.keyword_id = %s
              {dept_clause}
              AND klm.fiscal_year BETWEEN %s AND %s
            GROUP BY klm.fiscal_year
            ORDER BY klm.fiscal_year
            """,
            dept_params,
        )
        fy_trend = [dict(row) for row in cur.fetchall()]

    # Breakdown
    breakdown: list[dict[str, Any]] = []
    group_map: dict[str, tuple[str, str]] = {
        "agency": ("klm.department_code", "agency_code"),
        "vendor": ("klm.recipient_uei", "vendor_uei"),
        "fy": ("klm.fiscal_year", "fy"),
        "naics": ("klm.naics_code", "naics_code"),
        "set_aside": ("klm.set_aside_code", "set_aside_code"),
    }
    group_spec = group_map.get(group_by)
    if group_spec:
        group_col, label = group_spec
        with db_cursor() as cur:
            cur.execute(
                f"""
                SELECT {group_col} as {label},
                       COALESCE(SUM(klm.obligated_amount), 0) as obligation,
                       COUNT(DISTINCT klm.award_number) FILTER (WHERE klm.award_number IS NOT NULL) as award_count
                FROM v2.keyword_link_metadata klm
                WHERE klm.keyword_id = %s
                  {dept_clause}
                  AND klm.fiscal_year BETWEEN %s AND %s
                  AND {group_col} IS NOT NULL
                GROUP BY {group_col}
                ORDER BY obligation DESC
                LIMIT %s
                """,
                dept_params + [limit],
            )
            breakdown = [dict(row) for row in cur.fetchall()]

    return {
        "notice": BRIEF_DATA_NOTICE,
        "keyword": kw["keyword"],
        "keyword_id": kid,
        "keyword_type": kw["keyword_type"],
        "category": kw["category"],
        "keyword_link_count": link_count,
        "total_award_count": stats.get("total_award_count", 0),
        "total_obligated_amount": float(stats.get("total_obligated_amount", 0) or 0),
        "fy_trend": fy_trend,
        "breakdown": breakdown,
    }


# ── Topic Bridge ─────────────────────────────────────────────────────────


@router.get("/keywords/vs-topic")
def keyword_vs_topic(
    keyword_id: int | None = Query(default=None, description="Keyword ID for keyword→topics mode."),
    keyword_text: str | None = Query(default=None, description="Exact keyword text for keyword→topics mode."),
    topic_id: int | None = Query(default=None, description="Topic ID for topic→keywords mode."),
    department_code: str | None = Query(default=None, description="Department filter."),
    limit: int = Query(default=15, ge=1, le=100, description="Max results."),
) -> dict[str, Any]:
    if topic_id is not None:
        # Topic → Keywords mode
        with db_cursor() as cur:
            dept_clause = "AND ktm.department_code = %s" if department_code else ""
            params: list[Any] = [topic_id]
            if department_code:
                params.append(department_code)
            params.append(limit)
            cur.execute(
                f"""
                SELECT k.id as keyword_id, k.keyword, k.keyword_type, k.category,
                       ktm.link_count, ktm.topic_share, ktm.topic_rank, ktm.department_code
                FROM v2.keyword_topic_map ktm
                JOIN v2.keywords k ON k.id = ktm.keyword_id
                WHERE ktm.topic_id = %s
                  {dept_clause}
                ORDER BY ktm.link_count DESC
                LIMIT %s
                """,
                params,
            )
            keywords = [dict(row) for row in cur.fetchall()]
        return {
            "notice": BRIEF_DATA_NOTICE,
            "topic_id": topic_id,
            "keywords": keywords,
        }

    # Keyword → Topics mode
    if keyword_id is None and keyword_text is None:
        raise APIError(400, "missing_param", "Provide keyword_id, keyword_text, or topic_id.")

    with db_cursor() as cur:
        kw = _keyword_by_text_or_id(cur, keyword_text, keyword_id)
        if not kw:
            raise APIError(404, "keyword_not_found", "Keyword not found.")

    with db_cursor() as cur:
        dept_clause = "AND ktm.department_code = %s" if department_code else ""
        params = [kw["keyword_id"]]
        if department_code:
            params.append(department_code)
        params.append(limit)
        cur.execute(
            f"""
            SELECT ktm.topic_id, ktm.topic_label, ktm.link_count,
                   ktm.topic_share, ktm.topic_rank, ktm.department_code
            FROM v2.keyword_topic_map ktm
            WHERE ktm.keyword_id = %s
              {dept_clause}
            ORDER BY ktm.link_count DESC
            LIMIT %s
            """,
            params,
        )
        topics = [dict(row) for row in cur.fetchall()]

    return {
        "notice": BRIEF_DATA_NOTICE,
        "keyword": kw["keyword"],
        "keyword_id": kw["keyword_id"],
        "keyword_type": kw["keyword_type"],
        "category": kw["category"],
        "topics": topics,
    }


# ── Compare ──────────────────────────────────────────────────────────────


@router.get("/keywords/compare")
def keyword_compare(
    keywords: list[str] | None = Query(default=None, description="List of keyword texts to compare."),
    keyword_ids: list[int] | None = Query(default=None, description="List of keyword IDs to compare."),
    department_code: str | None = Query(default=None, description="USASpending department code filter."),
    fy_start: int = Query(default=2018, description="Start fiscal year."),
    fy_end: int = Query(default=2026, description="End fiscal year."),
) -> dict[str, Any]:
    if not keywords and not keyword_ids:
        raise APIError(400, "missing_param", "Provide keywords or keyword_ids.")

    with db_cursor() as cur:
        if keywords:
            cur.execute(
                "SELECT id, keyword, keyword_type, category FROM v2.keywords WHERE lower(keyword) = ANY(%s)",
                ([kw.lower() for kw in keywords],),
            )
        else:
            cur.execute(
                "SELECT id, keyword, keyword_type, category FROM v2.keywords WHERE id = ANY(%s)",
                (keyword_ids,),
            )
        kw_rows = cur.fetchall()

    comparison: list[dict[str, Any]] = []
    for kw_row in kw_rows:
        kw = dict(kw_row)
        kid = kw["id"]
        dept_clause = "AND klm.department_code = %s" if department_code else ""
        dept_params: list[Any] = [kid]
        if department_code:
            dept_params.append(department_code)
        dept_params.extend([fy_start, fy_end])

        with db_cursor() as cur:
            # Stats
            cur.execute(
                f"""
                SELECT
                    COALESCE(SUM(klm.obligated_amount), 0) as total_obligation,
                    COUNT(DISTINCT klm.award_number) FILTER (WHERE klm.award_number IS NOT NULL) as award_count,
                    COUNT(DISTINCT klm.recipient_uei) FILTER (WHERE klm.recipient_uei IS NOT NULL) as unique_vendors,
                    COUNT(DISTINCT klm.department_code) as unique_agencies
                FROM v2.keyword_link_metadata klm
                WHERE klm.keyword_id = %s
                  {dept_clause}
                  AND klm.fiscal_year BETWEEN %s AND %s
                """,
                dept_params,
            )
            stats = dict(cur.fetchone() or {})

            # FY trend
            cur.execute(
                f"""
                SELECT klm.fiscal_year as fy,
                       COALESCE(SUM(klm.obligated_amount), 0) as obligation,
                       COUNT(DISTINCT klm.award_number) FILTER (WHERE klm.award_number IS NOT NULL) as awards
                FROM v2.keyword_link_metadata klm
                WHERE klm.keyword_id = %s
                  {dept_clause}
                  AND klm.fiscal_year BETWEEN %s AND %s
                GROUP BY klm.fiscal_year
                ORDER BY klm.fiscal_year
                """,
                dept_params,
            )
            fy_trend = [dict(row) for row in cur.fetchall()]

            # Top 3 agencies
            cur.execute(
                f"""
                SELECT klm.department_code as agency_code,
                       COALESCE(SUM(klm.obligated_amount), 0) as obligation
                FROM v2.keyword_link_metadata klm
                WHERE klm.keyword_id = %s
                  {dept_clause}
                  AND klm.fiscal_year BETWEEN %s AND %s
                  AND klm.department_code IS NOT NULL
                GROUP BY klm.department_code
                ORDER BY obligation DESC LIMIT 3
                """,
                dept_params,
            )
            top_agencies = [dict(row) for row in cur.fetchall()]

        comparison.append({
            "keyword": kw["keyword"],
            "keyword_type": kw["keyword_type"],
            "category": kw["category"],
            "total_obligation": float(stats.get("total_obligation", 0) or 0),
            "award_count": stats.get("award_count", 0),
            "unique_vendors": stats.get("unique_vendors", 0),
            "unique_agencies": stats.get("unique_agencies", 0),
            "fy_trend": fy_trend,
            "top_agencies": top_agencies,
        })

    return {
        "notice": BRIEF_DATA_NOTICE,
        "department_code": department_code,
        "fy_range": {"start": fy_start, "end": fy_end},
        "comparison": comparison,
    }


# ── Vendor Profile ───────────────────────────────────────────────────────


@router.get("/keywords/vendor/{uei}")
def keyword_vendor_profile(
    uei: str,
    department_code: str | None = Query(default=None, description="USASpending department code filter."),
    category: list[str] | None = Query(
        default=None, description="Keyword categories to include."
    ),
    fy_start: int = Query(default=2018, description="Start fiscal year."),
    fy_end: int = Query(default=2026, description="End fiscal year."),
    limit: int = Query(default=50, ge=1, le=200, description="Max keywords."),
) -> dict[str, Any]:
    categories = category or DEFAULT_CATEGORIES

    with db_cursor() as cur:
        dept_clause = "AND kl.department_code = %s" if department_code else ""
        dept_params: list[Any] = [uei, categories]
        if department_code:
            dept_params.append(department_code)

        cur.execute(
            f"""
            SELECT k.id as keyword_id, k.keyword, k.keyword_type, k.category,
                   COUNT(DISTINCT kl.id) as link_count,
                   COALESCE(SUM(klm.obligated_amount) FILTER (
                       WHERE klm.fiscal_year BETWEEN %s AND %s
                   ), 0) as total_obligated_amount,
                   COUNT(DISTINCT klm.award_number) FILTER (
                       WHERE klm.award_number IS NOT NULL
                         AND klm.fiscal_year BETWEEN %s AND %s
                   ) as award_count,
                   COUNT(DISTINCT kl.department_code) as agency_count
            FROM v2.keywords k
            JOIN v2.keyword_links kl ON kl.keyword_id = k.id AND kl.entity_uei = %s
            LEFT JOIN v2.keyword_link_metadata klm ON klm.link_id = kl.id
            WHERE k.category = ANY(%s)
              {dept_clause}
            GROUP BY k.id, k.keyword, k.keyword_type, k.category
            ORDER BY link_count DESC
            LIMIT %s
            """,
            [fy_start, fy_end, fy_start, fy_end, uei, categories]
            + ([department_code] if department_code else [])
            + [limit],
        )
        keywords_list = [dict(row) for row in cur.fetchall()]

    # Summary: department coverage
    with db_cursor() as cur:
        dept_where = "AND kl.department_code = %s" if department_code else ""
        dept_params2: list[Any] = [uei, categories]
        if department_code:
            dept_params2.append(department_code)
        cur.execute(
            f"""
            SELECT kl.department_code,
                   COUNT(DISTINCT kl.keyword_id) as keyword_count,
                   COUNT(DISTINCT kl.id) as link_count,
                   COALESCE(SUM(klm.obligated_amount) FILTER (
                       WHERE klm.fiscal_year BETWEEN %s AND %s
                   ), 0) as total_obligated_amount
            FROM v2.keyword_links kl
            JOIN v2.keywords k ON k.id = kl.keyword_id AND k.category = ANY(%s)
            LEFT JOIN v2.keyword_link_metadata klm ON klm.link_id = kl.id
            WHERE kl.entity_uei = %s
              {dept_where}
            GROUP BY kl.department_code
            ORDER BY total_obligated_amount DESC
            """,
            [fy_start, fy_end, categories, uei]
            + ([department_code] if department_code else []),
        )
        dept_summary = [dict(row) for row in cur.fetchall()]

    return {
        "notice": BRIEF_DATA_NOTICE,
        "uei": uei,
        "department_code": department_code,
        "fy_range": {"start": fy_start, "end": fy_end},
        "keywords": keywords_list,
        "keyword_count": len(keywords_list),
        "department_summary": dept_summary,
    }
