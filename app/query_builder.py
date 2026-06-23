"""Safe SQL construction from the dataset registry."""

from __future__ import annotations

import base64
import json
import re
from decimal import Decimal
from typing import Any

from .errors import APIError


IDENT_RE = re.compile(r"^[a-z][a-z0-9_]*$")
CONTROL_PARAMS = {"fields", "sort", "limit", "cursor", "format", "_max_limit_override", "_search_q"}

# Synthetic prefix filters: map from filter name to the underlying column.
# These generate LEFT(column, len(value)) = value instead of equality.
PREFIX_FILTERS = {
    "naics_prefix": "principal_naics_code",
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


def first_example_query(dataset: dict[str, Any]) -> str | None:
    examples = dataset.get("example_queries") or []
    if not examples:
        return None
    first = examples[0]
    if isinstance(first, dict):
        return first.get("query")
    return None


def validate_required_filters(dataset: dict[str, Any], params: dict[str, str]) -> None:
    required_any = dataset.get("required_filters_any") or []
    if not required_any:
        return
    if not any(params.get(name) not in (None, "") for name in required_any):
        joined = ", ".join(required_any)
        extra = {"example_query": first_example_query(dataset)}
        raise APIError(400, "missing_required_filter", f"Dataset requires at least one of: {joined}.", extra=extra)


def coerce_filter_value(name: str, value: Any) -> Any:
    if name.startswith("is_"):
        return str(value).lower() in {"1", "true", "t", "yes", "y"}
    return value


def coerce_bound_value(value: Any) -> Any:
    try:
        return Decimal(str(value))
    except Exception as exc:
        raise APIError(400, "invalid_filter", "Bound filter values must be numeric.", param="filter") from exc


def build_default_where(dataset: dict[str, Any], params: dict[str, str]) -> tuple[list[str], list[Any]]:
    allowed_filters = set(dataset.get("filters", []))
    clauses: list[str] = []
    values: list[Any] = []
    for predicate in dataset.get("default_predicates", []):
        field = predicate.get("field")
        unless_filter = predicate.get("unless_filter", field)
        if not field:
            raise APIError(
                500,
                "dataset_contract_mismatch",
                f"Default predicate field is missing for dataset '{dataset['id']}'.",
            )
        if unless_filter and params.get(unless_filter) not in (None, ""):
            continue
        include_values = predicate.get("include_values")
        excluded_values = predicate.get("exclude_values")
        if include_values is not None:
            if field not in allowed_filters:
                raise APIError(
                    500,
                    "dataset_contract_mismatch",
                    f"Default predicate field '{field}' is not declared as a filter for dataset '{dataset['id']}'.",
                )
            coerced_values = [coerce_filter_value(field, value) for value in include_values]
            if len(coerced_values) == 1:
                clauses.append(f"{quote_ident(field)} = %s")
            else:
                placeholders = ", ".join("%s" for _ in coerced_values)
                clauses.append(f"{quote_ident(field)} in ({placeholders})")
            values.extend(coerced_values)
            continue
        min_value = predicate.get("min_value")
        if min_value is not None:
            if field not in set(dataset.get("fields", [])):
                raise APIError(
                    500,
                    "dataset_contract_mismatch",
                    f"Default predicate field '{field}' is not declared as a field for dataset '{dataset['id']}'.",
                )
            clauses.append(f"{quote_ident(field)} >= %s")
            values.append(coerce_bound_value(min_value))
            continue
        if excluded_values is None or len(excluded_values) != 1:
            raise APIError(
                500,
                "dataset_contract_mismatch",
                f"Default predicate for '{field}' must declare exactly one excluded value.",
            )
        if field not in allowed_filters:
            raise APIError(
                500,
                "dataset_contract_mismatch",
                f"Default predicate field '{field}' is not declared as a filter for dataset '{dataset['id']}'.",
            )
        clauses.append(f"{quote_ident(field)} <> %s")
        values.append(coerce_filter_value(field, excluded_values[0]))
    return clauses, values


def build_search_where(dataset: dict[str, Any], params: dict[str, str]) -> tuple[list[str], list[Any]]:
    raw_query = params.get("_search_q")
    if raw_query in (None, ""):
        return [], []
    searchable_columns = list(dataset.get("searchable_columns", []))
    fields = set(dataset.get("fields", []))
    if not searchable_columns:
        raise APIError(400, "invalid_filter", f"Search is not supported for dataset '{dataset['id']}'.", param="q")
    unknown_columns = [column for column in searchable_columns if column not in fields]
    if unknown_columns:
        raise APIError(
            500,
            "dataset_contract_mismatch",
            f"Search column '{unknown_columns[0]}' is not declared as a field for dataset '{dataset['id']}'.",
        )
    clauses = [f"{quote_ident(column)} ilike %s" for column in searchable_columns]
    return ["(" + " or ".join(clauses) + ")"], [f"%{raw_query}%"] * len(searchable_columns)


def build_where(dataset: dict[str, Any], params: dict[str, str]) -> tuple[list[str], list[Any]]:
    allowed_filters = set(dataset.get("filters", []))
    api_filter_allowlist = set(dataset.get("_api_filter_allowlist", allowed_filters))
    clauses: list[str] = []
    values: list[Any] = []

    for name, value in params.items():
        if value in (None, "") or name in CONTROL_PARAMS:
            continue
        if name not in api_filter_allowlist:
            raise APIError(
                400,
                "invalid_filter",
                f"Filter '{name}' is not supported by the API.",
                param=name,
                extra={"allowed_filters": sorted(allowed_filters)},
            )
        if name not in allowed_filters:
            raise APIError(
                400,
                "invalid_filter",
                f"Filter '{name}' is not supported for dataset '{dataset['id']}'.",
                param=name,
                extra={"allowed_filters": sorted(allowed_filters)},
            )

        if name in PREFIX_FILTERS:
            target_column = PREFIX_FILTERS[name]
            prefix_value = str(value).strip()
            if not prefix_value.isdigit() or not (2 <= len(prefix_value) <= 5):
                raise APIError(
                    400,
                    "invalid_filter",
                    f"Prefix filter '{name}' must be 2-5 digits (e.g. '5415' for Computer Systems Design group).",
                    param=name,
                )
            clauses.append(f"left({quote_ident(target_column)}, %s) = %s")
            values.extend([len(prefix_value), prefix_value])
        elif name == "fiscal_year_min":
            clauses.append(f"{quote_ident('fiscal_year')} >= %s")
            values.append(int(value))
        elif name == "fiscal_year_max":
            clauses.append(f"{quote_ident('fiscal_year')} <= %s")
            values.append(int(value))
        elif name.endswith("_min"):
            field_name = name.removesuffix("_min")
            if field_name not in set(dataset.get("fields", [])):
                raise APIError(
                    500,
                    "dataset_contract_mismatch",
                    f"Minimum filter '{name}' does not map to a field for dataset '{dataset['id']}'.",
                )
            clauses.append(f"{quote_ident(field_name)} >= %s")
            values.append(coerce_bound_value(value))
        elif name.endswith("_max"):
            field_name = name.removesuffix("_max")
            if field_name not in set(dataset.get("fields", [])):
                raise APIError(
                    500,
                    "dataset_contract_mismatch",
                    f"Maximum filter '{name}' does not map to a field for dataset '{dataset['id']}'.",
                )
            clauses.append(f"{quote_ident(field_name)} <= %s")
            values.append(coerce_bound_value(value))
        else:
            clauses.append(f"{quote_ident(name)} = %s")
            values.append(coerce_filter_value(name, value))
    return clauses, values


def build_rows_query(dataset: dict[str, Any], params: dict[str, str]) -> tuple[str, list[Any], int, int]:
    validate_required_filters(dataset, params)
    max_limit = int(dataset.get("max_limit") or 1000)
    default_limit = int(dataset.get("limit") or 100)
    if "_max_limit_override" in params:
        max_limit = min(max_limit, int(params["_max_limit_override"]))
        default_limit = min(default_limit, max_limit)
    limit = parse_limit(params.get("limit"), max_limit, default_limit)
    offset = decode_cursor(params.get("cursor"))
    fields = selected_fields(dataset, params.get("fields"))
    where_clauses, values = build_default_where(dataset, params)
    filter_clauses, filter_values = build_where(dataset, params)
    where_clauses.extend(filter_clauses)
    values.extend(filter_values)
    search_clauses, search_values = build_search_where(dataset, params)
    where_clauses.extend(search_clauses)
    values.extend(search_values)

    sort = params.get("sort") or dataset.get("default_sort") or fields[0]
    direction = "desc" if sort.startswith("-") else "asc"
    sort_field = sort[1:] if sort.startswith("-") else sort
    if sort_field not in dataset.get("sortable", []):
        raise APIError(
            400,
            "invalid_sort",
            f"Sort field '{sort_field}' is not supported for dataset '{dataset['id']}'.",
            param="sort",
            extra={"sortable": list(dataset.get("sortable", []))},
        )

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
