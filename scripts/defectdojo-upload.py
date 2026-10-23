#!/usr/bin/env python3
"""Reimport scanner reports into DefectDojo and sync security/exceptions.yaml as Risk Acceptances.

Usage (CI job defectdojo-upload):
  DD_API_KEY=... defectdojo-upload.py --url https://defectdojo.securestream.lab \
      --product catalog-api --report gitleaks=gitleaks.json \
      --report checkov-helm=checkov-helm.json@deploy/helm ...

--report LABEL=FILE[@BASE]: LABEL picks DefectDojo's parser (table below) and is the test title,
so each report keeps its own test in the "CI/CD" engagement. BASE is the directory the scanner was
given, used to map finding paths back to repository paths for exception matching (as scan-gate.py).

Every reimport closes findings that are no longer reported in that test. The first upload of a
label creates its test with import-scan (reimport cannot create a test without auto_create_context).
A missing report file is skipped with a notice (the job that writes it may not run on this
pipeline); any API error fails the job.
Exceptions: each entry becomes a Risk Acceptance named "<product>:<id>" that accepts the matching
findings until `expires`; DefectDojo reactivates them when it expires.
The API key is read from the environment only and never printed.
"""

import argparse
import datetime as dt
import fnmatch
import http.client
import json
import os
import re
import ssl
import sys
import urllib.parse
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
    """Minimal DefectDojo API v2 client. HTTPS only (http.client.HTTPSConnection), lab CA only."""

    def __init__(self, url: str, key: str, cafile: str | None):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.hostname:
            sys.exit(f"FAIL --url must be https://host, got {url!r}")
        self.host, self.port = parsed.hostname, parsed.port or 443
        self.prefix = parsed.path.rstrip("/") + "/api/v2"
        self.auth = {"Authorization": f"Token {key}"}
        self.ctx = ssl.create_default_context(cafile=cafile)

    def call(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        data: bytes | None = None,
        ctype: str = "application/json",
        allow: tuple[int, ...] = (),
    ) -> dict:
        """Return the JSON body; exit on an error status unless it is listed in `allow`."""
        if body is not None:
            data = json.dumps(body).encode()
        conn = http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=300)
        try:
            conn.request(
                method, self.prefix + path, body=data, headers={**self.auth, "Content-Type": ctype}
            )
            resp = conn.getresponse()
            raw = resp.read()
        except (OSError, http.client.HTTPException) as err:
            sys.exit(f"FAIL {method} {path.split('?')[0]}: {err}")
        finally:
            conn.close()
        if resp.status >= 400 and resp.status not in allow:
            detail = raw.decode(errors="replace")[:800]
            sys.exit(f"FAIL {method} {path.split('?')[0]}: HTTP {resp.status} {detail}")
        result = json.loads(raw) if raw else {}
        if resp.status >= 400:
            result["_status"] = resp.status
        return result

    def all(self, path: str, **params: object) -> list[dict]:
        query = urllib.parse.urlencode({**params, "limit": 1000})
        return self.call("GET", f"{path}?{query}").get("results", [])


def multipart(
    fields: dict[str, str], file_field: str, filename: str, content: bytes
) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        header = f'Content-Disposition: form-data; name="{name}"'
        parts.append(f"--{boundary}\r\n{header}\r\n\r\n{value}\r\n".encode())
    header = f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"'
    parts.append(
        f"--{boundary}\r\n{header}\r\nContent-Type: application/octet-stream\r\n\r\n".encode()
        + content
        + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def normalise(path: str, base: str) -> str:
    # As scan-gate.py: scanner paths are relative to the scanned directory or to the repository.
    rel = path.lstrip("/")
    base = base.rstrip("/")
    if not base or rel == base or rel.startswith(base + "/"):
        return rel
    return str(Path(base) / rel)


DIGEST = re.compile(r"@sha256:[0-9a-f]{64}")


def report_content(rep: dict) -> bytes:
    """Report bytes as uploaded. Trivy: the image digest is removed from ArtifactName and Target.
    The parser uses Target as file_path, which is part of the dedup hash; with the digest in it,
    every build closed all image findings and opened them again, resetting their SLA clock."""
    raw = rep["file"].read_bytes()
    if rep["scan_type"] != "Trivy Scan":
        return raw
    data = json.loads(raw)
    if isinstance(data.get("ArtifactName"), str):
        data["ArtifactName"] = DIGEST.sub("", data["ArtifactName"])
    for result in data.get("Results") or []:
        if isinstance(result.get("Target"), str):
            result["Target"] = DIGEST.sub("", result["Target"])
    return json.dumps(data).encode()


CHECK_ID = re.compile(r"^Check Id: (\S+)$", re.MULTILINE)


def finding_rules(finding: dict) -> set[str]:
    """Rule ids a finding can be matched by. Parsers store them in different fields:
    Checkov only in the description ("Check Id: CKV_..."), Trivy as vulnerability ids (CVE)."""
    rules = {finding.get("vuln_id_from_tool"), finding.get("unique_id_from_tool")}
    rules.update(v.get("vulnerability_id") for v in finding.get("vulnerability_ids") or [])
    rules.update(CHECK_ID.findall(finding.get("description") or ""))
    return {r for r in rules if r}


def parse_report(spec: str) -> dict:
    label, _, rest = spec.partition("=")
    file, _, base = rest.partition("@")
    prefix = label.split("-")[0]
    if not file or prefix not in PARSERS:
        sys.exit(f"FAIL --report {spec!r}: expected LABEL=FILE[@BASE], LABEL in {sorted(PARSERS)}")
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
    body, ctype = multipart(
        {k: v for k, v in fields.items() if v}, "file", rep["file"].name, report_content(rep)
    )
    res = api.call("POST", "/reimport-scan/", data=body, ctype=ctype, allow=(404,))
    if res.get("_status") == 404:
        # First upload of this label, no test yet: import-scan creates it in the engagement.
        # close_old_findings must be off here: on import it acts on every test of the same scan type
        # in the engagement (trivy-fs and trivy-image share the Trivy parser).
        fields["close_old_findings"] = "false"
        body, ctype = multipart(
            {k: v for k, v in fields.items() if v}, "file", rep["file"].name, report_content(rep)
        )
        res = api.call("POST", "/import-scan/", data=body, ctype=ctype)
        print(f"NEW  {rep['label']}: {rep['scan_type']} -> test {res.get('test')} created")
        return res.get("test")
    delta = (res.get("statistics") or {}).get("delta") or {}
    counts = " ".join(
        f"{k}={(delta.get(k) or {}).get('total', {}).get('total', 0)}"
        for k in ("created", "closed", "reactivated", "untouched")
    )
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
            print(
                f"RA   {name}: expired {expires}, not synced (exceptions-check fails the pipeline)"
            )
            continue
        ids = []
        for rep, test in tests:
            if rep["tool"] != exc["tool"]:
                continue
            for f in api.all("/findings/", test=test):
                path = normalise(f.get("file_path") or "", rep["base"])
                if exc["rule"] in finding_rules(f) and fnmatch.fnmatch(path, exc["path"]):
                    ids.append(f["id"])
        ra = existing.get(name)
        if ra is None and not ids:
            print(f"RA   {name}: no finding matches {exc['tool']} {exc['rule']} {exc['path']}")
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
            ra = api.call(
                "POST",
                "/risk_acceptance/",
                {"name": name, "owner": me, "accepted_findings": ids, **fields},
            )
            print(f"RA   {name}: created, {len(ids)} finding(s) accepted until {expires}")
            continue
        merged = sorted(set(ra.get("accepted_findings") or []) | set(ids))
        changed = {k: v for k, v in fields.items() if ra.get(k) != v}
        if merged != sorted(ra.get("accepted_findings") or []):
            changed["accepted_findings"] = merged
        if changed:
            api.call("PATCH", f"/risk_acceptance/{ra['id']}/", changed)
            print(
                f"RA   {name}: updated {sorted(changed)}, {len(merged)} finding(s) until {expires}"
            )
        else:
            print(f"RA   {name}: up to date, {len(merged)} finding(s) until {expires}")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--url", required=True)
    ap.add_argument("--product", required=True)
    ap.add_argument("--engagement", default="CI/CD")
    ap.add_argument("--report", action="append", default=[], type=parse_report)
    ap.add_argument("--exceptions", default="security/exceptions.yaml", type=Path)
    ap.add_argument("--cafile", default=os.environ.get("CI_SERVER_TLS_CA_FILE"))
    args = ap.parse_args()

    key = os.environ.get("DD_API_KEY", "")
    if len(key) != 40:
        sys.exit(
            f"FAIL DD_API_KEY has length {len(key)}, expected 40 (protected variable: main only)"
        )
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
