#!/usr/bin/env python3
"""Security gate for scanner reports with time-boxed exceptions.

Usage: scan-gate.py --tool checkov --report checkov-helm.json --base deploy/helm
                    [--exceptions security/exceptions.yaml]
--base is the directory given to the scanner (checkov reports paths relative to it).

The scanner runs in report mode; this script decides. A finding passes only if an exception with the
same tool and rule matches its path and has not expired. A missing, empty or unparsable report, or a
report with zero checks, fails the gate: a scanner that did not run must never look green.
"""

import argparse
import datetime as dt
import fnmatch
import json
import sys
from pathlib import Path

import yaml


def load_exceptions(path: Path, tool: str, today: dt.date) -> list[dict]:
    if not path.exists():
        return []
    data = yaml.safe_load(path.read_text()) or {}
    active = []
    for exc in data.get("exceptions") or []:
        if exc.get("tool") != tool:
            continue
        if dt.date.fromisoformat(str(exc["expires"])) < today:
            print(f"EXPIRED  {exc['id']} ({exc['rule']}) expired {exc['expires']}: not applied")
            continue
        active.append(exc)
    return active


def checkov_findings(report: object, base: str) -> tuple[int, list[dict]]:
    reports = report if isinstance(report, list) else [report]
    total, findings = 0, []
    for rep in reports:
        summary = rep.get("summary", {})
        total += summary.get("passed", 0) + summary.get("failed", 0)
        for chk in rep.get("results", {}).get("failed_checks", []):
            path = chk.get("repo_file_path") or chk.get("file_path", "")
            findings.append(
                {
                    "rule": chk["check_id"],
                    "path": normalise(path, base),
                    "line": (chk.get("file_line_range") or [0])[0],
                    "title": f"{chk.get('resource', '')}: {chk.get('check_name', '')}",
                }
            )
    return total, findings


def normalise(path: str, base: str) -> str:
    # checkov helm: "/catalog-api/templates/x.yaml" (relative to the scanned directory);
    # checkov terraform: "/infra/terraform/x/main.tf" (relative to the working directory).
    rel = path.lstrip("/")
    base = base.rstrip("/")
    return rel if rel == base or rel.startswith(base + "/") else str(Path(base) / rel)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True, choices=["checkov"])
    ap.add_argument("--report", required=True, type=Path)
    ap.add_argument("--exceptions", type=Path, default=Path("security/exceptions.yaml"))
    ap.add_argument("--base", required=True)
    args = ap.parse_args()

    try:
        report = json.loads(args.report.read_text())
    except (OSError, ValueError) as err:
        print(f"GATE FAIL: report {args.report} unreadable: {err}")
        return 1
    total, findings = checkov_findings(report, args.base)
    if total == 0:
        print(f"GATE FAIL: {args.report} contains zero checks; the scanner did not scan anything")
        return 1

    excs = load_exceptions(args.exceptions, args.tool, dt.date.today())
    blocking = []
    for f in findings:
        match = next(
            (e for e in excs if e["rule"] == f["rule"] and fnmatch.fnmatch(f["path"], e["path"])),
            None,
        )
        tag = f"EXCEPTED {match['id']}" if match else "BLOCKING"
        print(f"{tag:<17} {f['rule']:<12} {f['path']}:{f['line']}  {f['title']}")
        if not match:
            blocking.append(f)

    print(f"{args.tool}: {total} checks, {len(findings)} failed, {len(blocking)} blocking")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
