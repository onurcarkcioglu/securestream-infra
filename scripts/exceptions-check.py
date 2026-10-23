#!/usr/bin/env python3
"""Validate security/exceptions.yaml: schema, uniqueness and time-boxing.

Usage: exceptions-check.py [--file security/exceptions.yaml] [--today YYYY-MM-DD]

Fails (exit 1) on: a missing or unparsable file, a missing or empty field, a malformed or duplicate id,
an unknown tool, an exception that has expired, starts in the future, or runs longer than 90 days.
An exception that expires within 14 days is reported as WARN (does not fail).
Schema and process: docs/vulnerability-management.md.
"""

import argparse
import datetime as dt
import re
import sys
from pathlib import Path

import yaml

FIELDS = ("id", "tool", "rule", "path", "reason", "owner", "created", "expires")
TOOLS = {"gitleaks", "semgrep", "trivy", "hadolint", "checkov", "zap", "kubescape"}
ID_RE = re.compile(r"^EXC-\d{4}$")
MAX_DAYS = 90
WARN_DAYS = 14


def as_date(value: object) -> dt.date:
    # YAML parses an unquoted 2026-10-23 as a date already; a quoted one is a string.
    if isinstance(value, dt.date):
        return value
    return dt.date.fromisoformat(str(value))


def check(entry: object, today: dt.date, seen: set[str]) -> tuple[list[str], list[str]]:
    if not isinstance(entry, dict):
        return [f"entry is not a mapping: {entry!r}"], []
    errors, warnings = [], []
    missing = [f for f in FIELDS if entry.get(f) in (None, "")]
    if missing:
        errors.append(f"missing or empty field(s): {', '.join(missing)}")
    unknown = sorted(set(entry) - set(FIELDS))
    if unknown:
        errors.append(f"unknown field(s): {', '.join(unknown)}")
    exc_id = str(entry.get("id", ""))
    if exc_id and not ID_RE.match(exc_id):
        errors.append(f"id {exc_id!r} does not match EXC-NNNN")
    if exc_id in seen:
        errors.append(f"duplicate id {exc_id}")
    seen.add(exc_id)
    if entry.get("tool") and entry["tool"] not in TOOLS:
        errors.append(f"unknown tool {entry['tool']!r} (known: {', '.join(sorted(TOOLS))})")
    try:
        created, expires = as_date(entry.get("created")), as_date(entry.get("expires"))
    except (TypeError, ValueError):
        errors.append("created/expires is not a valid YYYY-MM-DD date")
        return errors, warnings
    if created > today:
        errors.append(f"created {created} is in the future")
    if expires <= created:
        errors.append(f"expires {expires} is not after created {created}")
    if (expires - created).days > MAX_DAYS:
        errors.append(f"runs {(expires - created).days} days, maximum is {MAX_DAYS}")
    if expires < today:
        errors.append(f"EXPIRED on {expires}: fix the finding or renew with a new review")
    elif (expires - today).days <= WARN_DAYS:
        warnings.append(f"expires in {(expires - today).days} day(s) on {expires}")
    return errors, warnings


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", default="security/exceptions.yaml", type=Path)
    ap.add_argument("--today", type=dt.date.fromisoformat, default=dt.date.today())
    args = ap.parse_args()

    if not args.file.is_file():
        print(f"FAIL {args.file}: file not found")
        return 1
    try:
        data = yaml.safe_load(args.file.read_text())
    except yaml.YAMLError as err:
        print(f"FAIL {args.file}: not valid YAML: {err}")
        return 1
    if not isinstance(data, dict) or not isinstance(data.get("exceptions"), list):
        print(f"FAIL {args.file}: top-level key 'exceptions' must be a list (may be empty: [])")
        return 1

    failed, seen = 0, set()
    for n, entry in enumerate(data["exceptions"], 1):
        label = entry.get("id", f"entry #{n}") if isinstance(entry, dict) else f"entry #{n}"
        errors, warnings = check(entry, args.today, seen)
        for msg in errors:
            print(f"FAIL {label}: {msg}")
        for msg in warnings:
            print(f"WARN {label}: {msg}")
        if errors:
            failed += 1
        elif not warnings:
            print(f"OK   {label}: {entry['tool']} {entry['rule']} until {entry['expires']}")
    print(f"{len(data['exceptions'])} exception(s), {failed} failed (today {args.today})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
