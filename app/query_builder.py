"""Safe SQL construction from the dataset registry."""

from __future__ import annotations

import base64
import json
import re
from decimal import Decimal
from typing import Any

from .errors import APIError


IDENT_RE = re.compile(r"^[a-z][a-z0-9_]*$")
CONTROL_PARAMS = {"fields", "sort", "limit", "cursor"}
KNOWN_FILTERS = {
    "fiscal_year",
    "fiscal_year_min",
    "fiscal_year_max",
    "contracting_dept_id",
    "contracting_agency_id",
    "principal_naics_code",
    "sector_code",
    "pop_state_code",
    "vendor_state_code",
    "census_region",
    "census_division",
    "is_state",
    "uei",
    "is_small_business_ever",
    "is_in_state",
    "scope_name",
    "metric_period",
}


def quote_ident(identifier: str) -> str:
    if not IDENT_RE.match(identifier):
        raise ValueError(f"Unsafe SQL identifier: {identifier}")
    return f'"{identifier}"'


def quote_relation(relation: str) -> str:
    parts = relation.split(".")
    if len(parts) != 2:
        raise ValueError(f"Expected schema-qualified relation, got: {relation}")
    return ".".join(quote_ident(part) for part in parts)


def decode_cursor(cursor: str | None) -> int:
    if not cursor:
        return 0
    try:
        payload = json.loads(base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8"))
        return int(payload.get("offset", 0))
    except Exception as exc:
        raise APIError(400, "invalid_cursor", "Cursor is not valid.", param="cursor") from exc


def encode_cursor(offset: int) -> str:
    payload = json.dumps({"offset": offset}, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(payload).decode("ascii")


def parse_limit(raw_limit: str | None, max_limit: int, default_limit: int) -> int:
    if raw_limit is None:
        return default_limit
    try:
        limit = int(raw_limit)
    except ValueError as exc:
        raise APIError(400, "invalid_limit", "Limit must be an integer.", param="limit") from exc
    if limit < 1:
        raise APIError(400, "invalid_limit", "Limit must be greater than zero.", param="limit")
    if limit > max_limit:
        raise APIError(400, "limit_too_large", f"Limit exceeds dataset maximum of {max_limit}.", param="limit")
    return limit


def selected_fields(dataset: dict[str, Any], raw_fields: str | None) -> list[str]:
    allowed = list(dataset.get("fields", []))
    if not raw_fields:
        return allowed
    requested = [field.strip() for field in raw_fields.split(",") if field.strip()]
    unknown = [field for field in requested if field not in allowed]
    if unknown:
        raise APIError(400, "invalid_field", f"Field '{unknown[0]}' is not available for this dataset.", param="fields")
    return requested


def validate_required_filters(dataset: dict[str, Any], params: dict[str, str]) -> None:
    required_any = dataset.get("required_filters_any") or []
    if not required_any:
        return
    if not any(params.get(name) not in (None, "") for name in required_any):
        joined = ", ".join(required_any)
        raise APIError(400, "missing_required_filter", f"Dataset requires at least one of: {joined}.")


def build_where(dataset: dict[str, Any], params: dict[str, str]) -> tuple[list[str], list[Any]]:
    allowed_filters = set(dataset.get("filters", []))
    clauses: list[str] = []
    values: list[Any] = []

    for name, value in params.items():
        if value in (None, "") or name in CONTROL_PARAMS:
            continue
        if name not in KNOWN_FILTERS:
            raise APIError(400, "invalid_filter", f"Filter '{name}' is not supported by the API.", param=name)
        if name not in allowed_filters:
            raise APIError(400, "invalid_filter", f"Filter '{name}' is not supported for dataset '{dataset['id']}'.", param=name)

        if name == "fiscal_year_min":
            clauses.append(f"{quote_ident('fiscal_year')} >= %s")
            values.append(int(value))
        elif name == "fiscal_year_max":
            clauses.append(f"{quote_ident('fiscal_year')} <= %s")
            values.append(int(value))
        elif name in {"is_state", "is_small_business_ever", "is_in_state"}:
            clauses.append(f"{quote_ident(name)} = %s")
            values.append(str(value).lower() in {"1", "true", "t", "yes", "y"})
        else:
            clauses.append(f"{quote_ident(name)} = %s")
            values.append(value)
    return clauses, values


def build_rows_query(dataset: dict[str, Any], params: dict[str, str]) -> tuple[str, list[Any], int, int]:
    validate_required_filters(dataset, params)
    max_limit = int(dataset.get("max_limit") or 1000)
    default_limit = int(dataset.get("limit") or 100)
    limit = parse_limit(params.get("limit"), max_limit, default_limit)
    offset = decode_cursor(params.get("cursor"))
    fields = selected_fields(dataset, params.get("fields"))
    where_clauses, values = build_where(dataset, params)

    sort = params.get("sort") or dataset.get("default_sort") or fields[0]
    direction = "desc" if sort.startswith("-") else "asc"
    sort_field = sort[1:] if sort.startswith("-") else sort
    if sort_field not in dataset.get("sortable", []):
        raise APIError(400, "invalid_sort", f"Sort field '{sort_field}' is not supported for dataset '{dataset['id']}'.", param="sort")

    select_sql = ", ".join(quote_ident(field) for field in fields)
    relation_sql = quote_relation(dataset["backing_view"])
    sql = f"select {select_sql} from {relation_sql}"
    if where_clauses:
        sql += " where " + " and ".join(where_clauses)
    sql += f" order by {quote_ident(sort_field)} {direction} nulls last limit %s offset %s"
    values.extend([limit + 1, offset])
    return sql, values, limit, offset


def serialize_row(row: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in row.items():
        if isinstance(value, Decimal):
            result[key] = str(value)
        else:
            result[key] = value
    return result


def page_rows(rows: list[dict[str, Any]], *, limit: int, offset: int) -> tuple[list[dict[str, Any]], str | None]:
    has_next = len(rows) > limit
    data = [serialize_row(dict(row)) for row in rows[:limit]]
    next_cursor = encode_cursor(offset + limit) if has_next else None
    return data, next_cursor
