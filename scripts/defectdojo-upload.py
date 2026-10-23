#!/usr/bin/env python3
"""Reimport scanner reports into DefectDojo and sync security/exceptions.yaml as Risk Acceptances.

Usage (CI job defectdojo-upload):
  DD_API_KEY=... defectdojo-upload.py --url https://defectdojo.securestream.lab --product catalog-api \
      --report gitleaks=gitleaks.json --report checkov-helm=checkov-helm.json@deploy/helm ...

--report LABEL=FILE[@BASE]: LABEL picks DefectDojo's parser (table below) and is the test title, so each
report keeps its own test in the "CI/CD" engagement. BASE is the directory the scanner was given, used to
map finding paths back to repository paths for exception matching (same rule as scan-gate.py).

Every reimport closes findings that are no longer reported. A missing report file is skipped with a
notice (the job that writes it may not run on this pipeline); any API error fails the job.
Exceptions: each entry becomes a Risk Acceptance named "<product>:<id>" that accepts the matching
findings until `expires`; DefectDojo reactivates them when it expires.
The API key is read from the environment only and never printed.
"""

import argparse
import datetime as dt
import fnmatch
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

import yaml

# label prefix -> (DefectDojo parser name, exceptions.yaml tool)
PARSERS = {
    "gitleaks": ("Gitleaks Scan", "gitleaks"),
    "semgrep": ("Semgrep JSON Report", "semgrep"),
    "trivy": ("Trivy Scan", "trivy"),
    "hadolint": ("Hadolint Dockerfile check", "hadolint"),
    "checkov": ("Checkov Scan", "checkov"),
    "zap": ("ZAP Scan", "zap"),
    "kubescape": ("Kubescape JSON Importer", "kubescape"),
}


class Api:
    def __init__(self, url: str, key: str, cafile: str | None):
        self.base = url.rstrip("/") + "/api/v2"
        self.auth = {"Authorization": f"Token {key}"}
        self.ctx = ssl.create_default_context(cafile=cafile)

    def call(self, method: str, path: str, body: dict | None = None, data: bytes | None = None,
             ctype: str = "application/json") -> dict:
        if body is not None:
            data = json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers={**self.auth, "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=300) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:800]
            sys.exit(f"FAIL {method} {path.split('?')[0]}: HTTP {err.code} {detail}")
        except urllib.error.URLError as err:
            sys.exit(f"FAIL {method} {path.split('?')[0]}: {err.reason}")
        return json.loads(raw) if raw else {}

    def all(self, path: str, **params: object) -> list[dict]:
        query = urllib.parse.urlencode({**params, "limit": 1000})
        return self.call("GET", f"{path}?{query}").get("results", [])


def multipart(fields: dict[str, str], file_field: str, file_path: Path) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{file_path.name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n".encode()
        + file_path.read_bytes()
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def normalise(path: str, base: str) -> str:
    # Same rule as scan-gate.py: scanner paths are relative to the scanned directory or to the repository.
    rel = path.lstrip("/")
    base = base.rstrip("/")
    if not base or rel == base or rel.startswith(base + "/"):
        return rel
    return str(Path(base) / rel)


def parse_report(spec: str) -> dict:
    label, _, rest = spec.partition("=")
    file, _, base = rest.partition("@")
    prefix = label.split("-")[0]
    if not file or prefix not in PARSERS:
        sys.exit(f"FAIL --report {spec!r}: expected LABEL=FILE[@BASE], LABEL starting with {sorted(PARSERS)}")
    scan_type, tool = PARSERS[prefix]
    return {"label": label, "file": Path(file), "base": base, "scan_type": scan_type, "tool": tool}


def reimport(api: Api, args: argparse.Namespace, rep: dict) -> int | None:
    if not rep["file"].is_file():
        print(f"SKIP {rep['label']}: {rep['file']} not found (job did not run or wrote no report)")
        return None
    env = os.environ
    fields = {
        "scan_type": rep["scan_type"],
        "product_name": args.product,
        "engagement_name": args.engagement,
        "test_title": rep["label"],
        "auto_create_context": "false",
        "close_old_findings": "true",
        "active": "true",
        "verified": "false",
        "minimum_severity": "Info",
        "scan_date": dt.date.today().isoformat(),
        "build_id": env.get("CI_PIPELINE_ID", ""),
        "commit_hash": env.get("CI_COMMIT_SHA", ""),
        "branch_tag": env.get("CI_COMMIT_REF_NAME", ""),
        "version": env.get("CI_COMMIT_SHORT_SHA", ""),
    }
    body, ctype = multipart({k: v for k, v in fields.items() if v}, "file", rep["file"])
    res = api.call("POST", "/reimport-scan/", data=body, ctype=ctype)
    delta = (res.get("statistics") or {}).get("delta") or {}
    counts = " ".join(f"{k}={(delta.get(k) or {}).get('total', {}).get('total', 0)}"
                      for k in ("created", "closed", "reactivated", "untouched"))
    print(f"OK   {rep['label']}: {rep['scan_type']} -> test {res.get('test')} {counts}")
    return res.get("test")


def sync_exceptions(api: Api, args: argparse.Namespace, tests: list[tuple[dict, int]]) -> None:
    data = yaml.safe_load(args.exceptions.read_text()) if args.exceptions.is_file() else {}
    entries = (data or {}).get("exceptions") or []
    if not entries:
        print(f"RA   no exceptions in {args.exceptions}")
        return
    me = api.call("GET", "/user_profile/")["user"]["id"]
    existing = {ra["name"]: ra for ra in api.all("/risk_acceptance/")}
    today = dt.date.today()
    for exc in entries:
        name = f"{args.product}:{exc['id']}"
        expires = dt.date.fromisoformat(str(exc["expires"]))
        if expires < today:
            print(f"RA   {name}: expired {expires}, not synced (exceptions-check fails the pipeline)")
            continue
        ids = []
        for rep, test in tests:
            if rep["tool"] != exc["tool"]:
                continue
            for f in api.all("/findings/", test=test):
                rule = f.get("vuln_id_from_tool") or ""
                path = normalise(f.get("file_path") or "", rep["base"])
                if rule == exc["rule"] and fnmatch.fnmatch(path, exc["path"]):
                    ids.append(f["id"])
        ra = existing.get(name)
        if ra is None and not ids:
            print(f"RA   {name}: no matching finding ({exc['tool']} {exc['rule']} {exc['path']}), nothing to accept")
            continue
        fields = {
            "expiration_date": expires.isoformat(),
            "decision": "A",
            "decision_details": exc["reason"].strip(),
            "recommendation": "A",
            "accepted_by": exc["owner"],
            "reactivate_expired": True,
        }
        if ra is None:
            ra = api.call("POST", "/risk_acceptance/", {"name": name, "owner": me, "accepted_findings": ids, **fields})
            print(f"RA   {name}: created, {len(ids)} finding(s) accepted until {expires}")
            continue
        merged = sorted(set(ra.get("accepted_findings") or []) | set(ids))
        changed = {k: v for k, v in fields.items() if ra.get(k) != v}
        if merged != sorted(ra.get("accepted_findings") or []):
            changed["accepted_findings"] = merged
        if changed:
            api.call("PATCH", f"/risk_acceptance/{ra['id']}/", changed)
            print(f"RA   {name}: updated {sorted(changed)}, {len(merged)} finding(s) until {expires}")
        else:
            print(f"RA   {name}: up to date, {len(merged)} finding(s) until {expires}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", required=True)
    ap.add_argument("--product", required=True)
    ap.add_argument("--engagement", default="CI/CD")
    ap.add_argument("--report", action="append", default=[], type=parse_report)
    ap.add_argument("--exceptions", default="security/exceptions.yaml", type=Path)
    ap.add_argument("--cafile", default=os.environ.get("CI_SERVER_TLS_CA_FILE"))
    args = ap.parse_args()

    key = os.environ.get("DD_API_KEY", "")
    if len(key) != 40:
        sys.exit(f"FAIL DD_API_KEY has length {len(key)}, expected 40 (protected variable: main only)")
    api = Api(args.url, key, args.cafile)

    tests = []
    for rep in args.report:
        test = reimport(api, args, rep)
        if test:
            tests.append((rep, test))
    if not tests:
        sys.exit("FAIL no report was imported")
    sync_exceptions(api, args, tests)
    return 0


if __name__ == "__main__":
    sys.exit(main())
