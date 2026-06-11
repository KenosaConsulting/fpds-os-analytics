#!/usr/bin/env python3
"""Harvest raw FPDS ATOM XML pages for a bounded PIID list.

This is the FPDS-021b capture step only:
- input: top-PIID CSV from Step 0
- output: raw Atom page XML under data/atom-harvest/raw/
- logging: append-only JSONL fetch log and a summary JSON

Parsing/classification is intentionally deferred to FPDS-021i.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any
from urllib.parse import quote_plus
from xml.etree import ElementTree as ET

import requests


ATOM_URL = "https://www.fpds.gov/ezsearch/FEEDS/ATOM"
ATOM_NS = {"atom": "http://www.w3.org/2005/Atom"}
PAGE_SIZE = 10
USER_AGENT = "fpds-os-analytics/FPDS-021b-atom-harvest"

_tls = threading.local()
_log_lock = threading.Lock()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-csv",
        type=Path,
        required=True,
        help="CSV from FPDS-021a containing the top ref_piid list.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("data/atom-harvest"),
        help="Harvest root directory inside the repo.",
    )
    parser.add_argument("--workers", type=int, default=6, help="Concurrent PIID workers.")
    parser.add_argument("--timeout", type=int, default=45, help="Per-request timeout in seconds.")
    parser.add_argument("--pause", type=float, default=0.3, help="Sleep between page requests per PIID.")
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Optional cap for debugging; default harvests all PIIDs in the input CSV.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-fetch PIIDs even if a success record already exists in the fetch log.",
    )
    return parser.parse_args()


def ensure_dirs(root: Path) -> dict[str, Path]:
    paths = {
        "root": root,
        "input": root / "input",
        "raw": root / "raw",
        "logs": root / "logs",
    }
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    return paths


def get_session(timeout: int) -> requests.Session:
    session = getattr(_tls, "session", None)
    if session is None:
        session = requests.Session()
        session.headers.update(
            {
                "User-Agent": USER_AGENT,
                "Accept": "application/atom+xml, application/xml, text/xml",
            }
        )
        _tls.session = session
    _tls.timeout = timeout
    return session


def safe_slug(text: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", text.strip())
    slug = slug.strip("._")
    return slug or "piid"


def piid_dir(raw_root: Path, piid: str) -> Path:
    digest = hashlib.sha1(piid.encode("utf-8")).hexdigest()[:12]
    path = raw_root / f"{safe_slug(piid)}__{digest}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def count_entries(xml_bytes: bytes) -> int:
    root = ET.fromstring(xml_bytes)
    return len(root.findall("atom:entry", ATOM_NS))


def read_existing_log(log_path: Path) -> dict[str, dict[str, Any]]:
    results: dict[str, dict[str, Any]] = {}
    if not log_path.exists():
        return results
    with log_path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            results[record["piid"]] = record
    return results


def append_log(log_path: Path, record: dict[str, Any]) -> None:
    with _log_lock:
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True) + "\n")


def fetch_one(
    piid: str,
    raw_root: Path,
    log_path: Path,
    timeout: int,
    pause: float,
) -> dict[str, Any]:
    session = get_session(timeout)
    start = 0
    pages_fetched = 0
    entries_found = 0
    page_files: list[str] = []
    piid_path = piid_dir(raw_root, piid)

    while True:
        params = {"FEEDNAME": "PUBLIC", "q": f'PIID:"{piid}"', "start": str(start)}
        response = session.get(ATOM_URL, params=params, timeout=timeout)
        response.raise_for_status()

        page_bytes = response.content
        entry_count = count_entries(page_bytes)
        page_name = f"page-{pages_fetched:04d}-start-{start}.xml"
        page_path = piid_path / page_name
        page_path.write_bytes(page_bytes)

        pages_fetched += 1
        entries_found += entry_count
        page_files.append(str(page_path.relative_to(raw_root.parent.parent)))

        if entry_count < PAGE_SIZE:
            break

        start += PAGE_SIZE
        if pause > 0:
            time.sleep(pause)

    record = {
        "piid": piid,
        "status": "ok",
        "pages_fetched": pages_fetched,
        "entries_found": entries_found,
        "page_files": page_files,
        "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    append_log(log_path, record)
    return record


def copy_input_manifest(src: Path, dst_root: Path) -> Path:
    dst = dst_root / src.name
    dst.write_bytes(src.read_bytes())
    return dst


def load_piids(csv_path: Path, limit: int | None) -> list[str]:
    piids: list[str] = []
    with csv_path.open("r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            piid = (row.get("ref_piid") or "").strip()
            if not piid:
                continue
            piids.append(piid)
            if limit is not None and len(piids) >= limit:
                break
    return piids


def main() -> int:
    args = parse_args()
    paths = ensure_dirs(args.output_dir)
    copied_manifest = copy_input_manifest(args.input_csv, paths["input"])
    log_path = paths["logs"] / "fetch-log.jsonl"
    summary_path = paths["logs"] / "summary.json"

    existing = read_existing_log(log_path)
    all_piids = load_piids(args.input_csv, args.limit)
    if args.force:
        work_piids = all_piids
    else:
        work_piids = [piid for piid in all_piids if existing.get(piid, {}).get("status") != "ok"]

    summary: dict[str, Any] = {
        "input_csv": str(copied_manifest.relative_to(paths["root"])),
        "requested_piids": len(all_piids),
        "skipped_existing": len(all_piids) - len(work_piids),
        "workers": args.workers,
        "timeout": args.timeout,
        "pause": args.pause,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "successes": 0,
        "failures": 0,
    }

    failures: list[dict[str, Any]] = []

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {
            pool.submit(fetch_one, piid, paths["raw"], log_path, args.timeout, args.pause): piid
            for piid in work_piids
        }
        completed = 0
        total = len(futures)
        for future in as_completed(futures):
            piid = futures[future]
            try:
                record = future.result()
                summary["successes"] += 1
                completed += 1
                if completed == total or completed % 25 == 0:
                    print(
                        f"[fpds-atom] completed={completed}/{total} "
                        f"successes={summary['successes']} failures={summary['failures']} "
                        f"last={piid} pages={record['pages_fetched']} entries={record['entries_found']}",
                        flush=True,
                    )
            except Exception as exc:  # noqa: BLE001
                record = {
                    "piid": piid,
                    "status": "error",
                    "error": str(exc),
                    "fetched_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                }
                append_log(log_path, record)
                failures.append(record)
                summary["failures"] += 1
                completed += 1
                print(
                    f"[fpds-atom] completed={completed}/{total} "
                    f"successes={summary['successes']} failures={summary['failures']} "
                    f"last={piid} error={exc}",
                    flush=True,
                )

    summary["finished_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary["failures_detail"] = failures
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(
        json.dumps(
            {
                "requested_piids": summary["requested_piids"],
                "skipped_existing": summary["skipped_existing"],
                "successes": summary["successes"],
                "failures": summary["failures"],
                "log_path": str(log_path),
                "summary_path": str(summary_path),
            },
            sort_keys=True,
        )
    )
    return 0 if summary["failures"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
