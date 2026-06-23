#!/usr/bin/env python3
"""Admin CLI for managing FPDS Analytics API keys.

Usage:
    python scripts/manage_keys.py create --tier beta --email user@example.com --name "Jane Doe" --org "Acme Corp"
    python scripts/manage_keys.py create --tier partner --email partner@co.com --expires-days 90
    python scripts/manage_keys.py list
    python scripts/manage_keys.py list --include-revoked
    python scripts/manage_keys.py revoke KEY_ID
    python scripts/manage_keys.py usage [--days 7]

Requires DB_HOST + DB_PASS environment variables, or ANALYTICS_DATABASE_URL.
Connects as postgres (admin), NOT the readonly role.
"""

from __future__ import annotations

import argparse
import os
import sys
from contextlib import contextmanager
from datetime import datetime
from typing import Iterator

import psycopg2
import psycopg2.extras


def admin_dsn() -> str:
    """Build a DSN for admin access (postgres role, not readonly)."""
    dsn = os.environ.get("ADMIN_DATABASE_URL")
    if dsn:
        return dsn

    host = os.environ.get("DB_HOST")
    password = os.environ.get("DB_PASS")
    if not host or not password:
        print("ERROR: Set ADMIN_DATABASE_URL, or DB_HOST + DB_PASS.", file=sys.stderr)
        sys.exit(1)

    user = os.environ.get("DB_ADMIN_USER", "postgres")
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ.get("DB_NAME", "postgres")
    return f"host={host} port={port} dbname={name} user={user} password={password} connect_timeout=10"


@contextmanager
def admin_cursor() -> Iterator[psycopg2.extensions.cursor]:
    conn = psycopg2.connect(admin_dsn(), cursor_factory=psycopg2.extras.RealDictCursor)
    try:
        with conn:
            with conn.cursor() as cur:
                yield cur
    finally:
        conn.close()


def cmd_create(args: argparse.Namespace) -> None:
    with admin_cursor() as cur:
        cur.execute(
            "SELECT * FROM api_admin.create_api_key("
            "p_tier := %s, p_user_email := %s, p_user_name := %s, "
            "p_organization := %s, p_notes := %s, p_expires_in_days := %s"
            ")",
            (args.tier, args.email, args.name, args.org, args.notes, args.expires_days),
        )
        row = cur.fetchone()

    print()
    print("=" * 60)
    print("  NEW API KEY CREATED")
    print("=" * 60)
    print()
    print(f"  Key ID:     {row['api_key_id']}")
    print(f"  Tier:       {row['tier']}")
    print(f"  Prefix:     {row['key_prefix']}")
    print(f"  Expires:    {row['expires_at'] or 'never'}")
    print()
    print(f"  API Key:    {row['plaintext_key']}")
    print()
    print("  ⚠️  COPY THIS KEY NOW — it will never be shown again.")
    print("=" * 60)
    print()


def cmd_list(args: argparse.Namespace) -> None:
    with admin_cursor() as cur:
        cur.execute(
            "SELECT * FROM api_admin.list_api_keys(p_include_revoked := %s)",
            (args.include_revoked,),
        )
        rows = cur.fetchall()

    if not rows:
        print("No API keys found.")
        return

    # Header
    print(f"{'Prefix':<16} {'Tier':<10} {'Email':<30} {'Org':<20} {'Active':<8} {'Requests':<10} {'Last Used':<20}")
    print("-" * 114)
    for r in rows:
        last_used = r["last_used_at"].strftime("%Y-%m-%d %H:%M") if r["last_used_at"] else "never"
        print(
            f"{r['key_prefix']:<16} {r['tier']:<10} {(r['user_email'] or '-'):<30} "
            f"{(r['organization'] or '-'):<20} {'✓' if r['is_active'] else '✗':<8} "
            f"{r['total_requests']:<10} {last_used:<20}"
        )
    print(f"\nTotal: {len(rows)} key(s)")


def cmd_revoke(args: argparse.Namespace) -> None:
    with admin_cursor() as cur:
        cur.execute("SELECT api_admin.revoke_api_key(%s::uuid)", (args.key_id,))
        result = cur.fetchone()

    if result and result["revoke_api_key"]:
        print(f"✓ Key {args.key_id} revoked.")
    else:
        print(f"✗ Key {args.key_id} not found or already revoked.", file=sys.stderr)
        sys.exit(1)


def cmd_usage(args: argparse.Namespace) -> None:
    with admin_cursor() as cur:
        cur.execute(
            """
            SELECT usage_date, key_prefix, tier, organization,
                   request_count, datasets_accessed, total_rows_returned,
                   avg_duration_ms, error_count
            FROM api_admin.usage_summary_daily
            WHERE usage_date >= current_date - %s * interval '1 day'
            ORDER BY usage_date DESC, request_count DESC
            """,
            (args.days,),
        )
        rows = cur.fetchall()

    if not rows:
        print(f"No usage in the last {args.days} day(s).")
        return

    print(f"{'Date':<12} {'Prefix':<16} {'Tier':<10} {'Org':<20} {'Requests':<10} {'Datasets':<10} {'Rows':<12} {'Avg ms':<8} {'Errors':<8}")
    print("-" * 106)
    for r in rows:
        print(
            f"{r['usage_date']!s:<12} {r['key_prefix']:<16} {r['tier']:<10} "
            f"{(r['organization'] or '-'):<20} {r['request_count']:<10} "
            f"{r['datasets_accessed']:<10} {r['total_rows_returned'] or 0:<12} "
            f"{r['avg_duration_ms'] or 0:<8} {r['error_count']:<8}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage FPDS Analytics API keys")
    sub = parser.add_subparsers(dest="command", required=True)

    # create
    p_create = sub.add_parser("create", help="Create a new API key")
    p_create.add_argument("--tier", choices=["beta", "partner", "internal"], default="beta")
    p_create.add_argument("--email", help="Contact email")
    p_create.add_argument("--name", help="User name")
    p_create.add_argument("--org", help="Organization")
    p_create.add_argument("--notes", help="Internal notes")
    p_create.add_argument("--expires-days", type=int, help="Days until expiry (default: never)")

    # list
    p_list = sub.add_parser("list", help="List API keys")
    p_list.add_argument("--include-revoked", action="store_true")

    # revoke
    p_revoke = sub.add_parser("revoke", help="Revoke an API key")
    p_revoke.add_argument("key_id", help="API key UUID to revoke")

    # usage
    p_usage = sub.add_parser("usage", help="Show usage summary")
    p_usage.add_argument("--days", type=int, default=7, help="Lookback days (default: 7)")

    args = parser.parse_args()

    if args.command == "create":
        cmd_create(args)
    elif args.command == "list":
        cmd_list(args)
    elif args.command == "revoke":
        cmd_revoke(args)
    elif args.command == "usage":
        cmd_usage(args)


if __name__ == "__main__":
    main()
