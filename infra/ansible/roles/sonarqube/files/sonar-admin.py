#!/usr/bin/env python3
"""Idempotent SonarQube administration through the Web API (roles/sonarqube).

Usage (root on ss-sec, reads SONAR_ADMIN_PASSWORD from admin.env next to this script):
  sonar-admin.py bootstrap https://sonar.securestream.lab
  sonar-admin.py ci-token  https://sonar.securestream.lab   (only scripts/sonarqube-ci-token.sh)
  sonar-admin.py local-token https://sonar.securestream.lab catalog-api-local   (scripts/sonarqube-local-scan.sh)
  sonar-admin.py revoke-local https://sonar.securestream.lab
  sonar-admin.py gate https://sonar.securestream.lab <project>   (status and conditions, no secrets)

bootstrap creates or corrects: admin password (from the initial admin/admin), server settings, the
"SecureStream" quality gate as default, the private project catalog-api with its new-code period, and the CI
user gitlab-ci (random unknown password, only Browse + Execute Analysis on that project). Global analysis and
provisioning rights are removed from every group. Output lines start with OK or CHANGED.

ci-token revokes the CI user's previous tokens, sets a random in-memory password for the CI user (only the owner
may create a project analysis token) and prints one line "TOKEN <project analysis token>" for a pipe.
No secret is ever printed by bootstrap, written to disk or passed as an argument.
"""

import base64
import datetime as dt
import json
import secrets
import ssl
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ADMIN = "admin"
INITIAL_PASSWORD = "admin"
CI_USER = "gitlab-ci"
PROJECT = "catalog-api"
GATE = "SecureStream"
# New code = changes since the newest analysis older than 30 days (the first analysis while none is that old).
# Community Build analyses only the main branch, so a reference branch is not available. The first analysis
# is the baseline and carries no new code: the existing code is judged by the overall measures.
NEW_CODE = ("NUMBER_OF_DAYS", "30")
TOKEN_DAYS = 90
# Local verification scans (scripts/sonarqube-local-scan.sh): own projects, admin-owned 1-day tokens
LOCAL_PROJECT_PREFIX = "catalog-api-local"
LOCAL_PREFIX = "local-scan-"
# metric -> (operator, error threshold); conditions are evaluated on new code
CONDITIONS = {
    "new_bugs": ("GT", "0"),
    "new_vulnerabilities": ("GT", "0"),
    "new_security_hotspots_reviewed": ("LT", "100"),
    "new_coverage": ("LT", "70"),
}
PROJECT_PERMISSIONS = {"user", "scan"}
# Only administrators create projects; analysis needs a project token. "admin" alone does not include
# provisioning, so the administrators group keeps it (SonarQube default).
ADMIN_GROUP = "sonar-administrators"
GLOBAL_PERMISSIONS_DENIED = {"scan", "provisioning"}


class Api:
    def __init__(self, base: str, password: str):
        self.base = base.rstrip("/")
        self.ctx = ssl.create_default_context()
        self.auth(password)

    def auth(self, password: str, login: str = ADMIN) -> None:
        raw = f"{login}:{password}".encode()
        self.headers = {"Authorization": "Basic " + base64.b64encode(raw).decode()}

    def call(self, method: str, path: str, params: dict | None = None, ok=(200, 204)) -> dict:
        query = urllib.parse.urlencode(params or {})
        url = self.base + path
        data = None
        if method == "GET" and query:
            url += "?" + query
        elif query:
            data = query.encode()
        req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            if err.code in ok:
                return {}
            detail = err.read().decode(errors="replace")[:500]
            sys.exit(f"FAIL {method} {path}: HTTP {err.code} {detail}")
        return json.loads(raw) if raw else {}

    def v2(self, method: str, path: str, body: dict | None = None) -> dict:
        headers = dict(self.headers, **({"Content-Type": "application/merge-patch+json"} if body else {}))
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:500]
            sys.exit(f"FAIL {method} {path}: HTTP {err.code} {detail}")
        return json.loads(raw) if raw else {}

    def valid(self) -> bool:
        # Wrong credentials may answer 401 instead of {"valid": false}
        return bool(self.call("GET", "/api/authentication/validate", ok=(401,)).get("valid"))


def read_password() -> str:
    env = Path(__file__).with_name("admin.env")
    for line in env.read_text().splitlines():
        if line.startswith("SONAR_ADMIN_PASSWORD="):
            return line.split("=", 1)[1]
    sys.exit(f"FAIL SONAR_ADMIN_PASSWORD missing in {env}")


def complex_enough(pw: str) -> bool:
    return (
        len(pw) >= 12
        and any(c.islower() for c in pw)
        and any(c.isupper() for c in pw)
        and any(c.isdigit() for c in pw)
        and any(c in string.punctuation for c in pw)
    )


def wait_up(api: Api) -> None:
    # Without credentials: a not yet valid password must not turn the status check into a 401
    headers, api.headers = api.headers, {}
    for _ in range(60):
        if api.call("GET", "/api/system/status").get("status") == "UP":
            api.headers = headers
            return
        time.sleep(5)
    sys.exit("FAIL SonarQube is not UP")


def admin_login(api: Api, password: str) -> None:
    api.auth(password)
    if api.valid():
        print("OK admin password")
        return
    if not complex_enough(password):
        sys.exit("FAIL vault password does not meet SonarQube complexity rules (value not shown)")
    api.auth(INITIAL_PASSWORD)
    if not api.valid():
        sys.exit("FAIL admin login fails with both the vault password and the initial password")
    api.call(
        "POST",
        "/api/users/change_password",
        {"login": ADMIN, "previousPassword": INITIAL_PASSWORD, "password": password},
    )
    api.auth(password)
    if not api.valid():
        sys.exit("FAIL admin password change did not take effect")
    print("CHANGED admin password set from vault")


def settings(api: Api, base: str) -> None:
    wanted = {"sonar.core.serverBaseURL": base, "sonar.forceAuthentication": "true"}
    current = {
        s["key"]: s.get("value")
        for s in api.call("GET", "/api/settings/values", {"keys": ",".join(wanted)})["settings"]
    }
    for key, value in wanted.items():
        if current.get(key) == value:
            print(f"OK setting {key}")
        else:
            api.call("POST", "/api/settings/set", {"key": key, "value": value})
            print(f"CHANGED setting {key}={value}")
    # Standard Experience mode: the gate is defined on bugs and vulnerabilities, which MQR mode
    # (default since 10.8) replaces with software-quality impacts. Only settable through API v2.
    if api.v2("GET", "/api/v2/clean-code-policy/mode")["mode"] == "STANDARD_EXPERIENCE":
        print("OK mode STANDARD_EXPERIENCE")
    else:
        api.v2("PATCH", "/api/v2/clean-code-policy/mode", {"mode": "STANDARD_EXPERIENCE"})
        print("CHANGED mode STANDARD_EXPERIENCE")
    # Projects created later (by anyone with provisioning rights) start private
    api.call("POST", "/api/projects/update_default_visibility", {"projectVisibility": "private"})


def quality_gate(api: Api) -> None:
    gates = {g["name"]: g for g in api.call("GET", "/api/qualitygates/list")["qualitygates"]}
    if GATE not in gates:
        api.call("POST", "/api/qualitygates/create", {"name": GATE})
        print(f"CHANGED created quality gate {GATE}")
    conds = api.call("GET", "/api/qualitygates/show", {"name": GATE}).get("conditions", [])
    by_metric = {c["metric"]: c for c in conds}
    for metric, (op, error) in CONDITIONS.items():
        c = by_metric.pop(metric, None)
        if c is None:
            api.call(
                "POST",
                "/api/qualitygates/create_condition",
                {"gateName": GATE, "metric": metric, "op": op, "error": error},
            )
            print(f"CHANGED condition {metric} {op} {error}")
        elif (c.get("op"), c.get("error")) != (op, error):
            api.call(
                "POST",
                "/api/qualitygates/update_condition",
                {"id": c["id"], "metric": metric, "op": op, "error": error},
            )
            print(f"CHANGED condition {metric} {op} {error}")
        else:
            print(f"OK condition {metric} {op} {error}")
    for metric, c in by_metric.items():
        api.call("POST", "/api/qualitygates/delete_condition", {"id": c["id"]})
        print(f"CHANGED removed condition {metric}")
    if not gates.get(GATE, {}).get("isDefault"):
        api.call("POST", "/api/qualitygates/set_as_default", {"name": GATE})
        print(f"CHANGED {GATE} is the default quality gate")
    else:
        print(f"OK {GATE} is the default quality gate")


def project(api: Api, key: str = PROJECT) -> None:
    found = api.call("GET", "/api/projects/search", {"projects": key})["components"]
    if not found:
        api.call(
            "POST",
            "/api/projects/create",
            {"project": key, "name": key, "visibility": "private", "mainBranch": "main"},
        )
        print(f"CHANGED created private project {key}")
    elif found[0].get("visibility") != "private":
        api.call(
            "POST", "/api/projects/update_visibility", {"project": key, "visibility": "private"}
        )
        print(f"CHANGED project {key} is private")
    else:
        print(f"OK project {key} (private)")
    # Community Build stores a project-level period on the main branch; "show" reports only the project level
    periods = api.call("GET", "/api/new_code_periods/list", {"project": key})["newCodePeriods"]
    main = next((p for p in periods if p.get("branchKey") == "main"), {})
    if (main.get("type"), str(main.get("value"))) == NEW_CODE:
        print(f"OK new code period {NEW_CODE[0]} {NEW_CODE[1]}")
    else:
        api.call(
            "POST",
            "/api/new_code_periods/set",
            {"project": key, "type": NEW_CODE[0], "value": NEW_CODE[1]},
        )
        print(f"CHANGED new code period {NEW_CODE[0]} {NEW_CODE[1]}")


def ci_user(api: Api) -> None:
    users = api.call("GET", "/api/users/search", {"q": CI_USER})["users"]
    if not any(u["login"] == CI_USER for u in users):
        # Nobody knows this password: the user only authenticates with project analysis tokens
        pw = secrets.token_urlsafe(32) + "aA1!"
        api.call(
            "POST",
            "/api/users/create",
            {"login": CI_USER, "name": "GitLab CI", "password": pw, "local": "true"},
        )
        print(f"CHANGED created user {CI_USER}")
    else:
        print(f"OK user {CI_USER}")
    rows = api.call(
        "GET", "/api/permissions/users", {"projectKey": PROJECT, "q": CI_USER, "ps": 100}
    )["users"]
    have = next((set(u["permissions"]) for u in rows if u["login"] == CI_USER), set())
    for perm in sorted(PROJECT_PERMISSIONS - have):
        api.call(
            "POST",
            "/api/permissions/add_user",
            {"login": CI_USER, "projectKey": PROJECT, "permission": perm},
        )
        print(f"CHANGED {CI_USER}: {perm} on {PROJECT}")
    for perm in sorted(have - PROJECT_PERMISSIONS):
        api.call(
            "POST",
            "/api/permissions/remove_user",
            {"login": CI_USER, "projectKey": PROJECT, "permission": perm},
        )
        print(f"CHANGED {CI_USER}: removed {perm} on {PROJECT}")
    if have == PROJECT_PERMISSIONS:
        print(f"OK {CI_USER}: {','.join(sorted(PROJECT_PERMISSIONS))} on {PROJECT}")


def global_permissions(api: Api) -> None:
    changed = False
    groups = api.call("GET", "/api/permissions/groups", {"permission": "provisioning", "ps": 100})
    if not any(g["name"] == ADMIN_GROUP and "provisioning" in g.get("permissions", []) for g in groups["groups"]):
        api.call("POST", "/api/permissions/add_group", {"groupName": ADMIN_GROUP, "permission": "provisioning"})
        print(f"CHANGED group {ADMIN_GROUP}: global provisioning")
        changed = True
    for perm in sorted(GLOBAL_PERMISSIONS_DENIED):
        groups = api.call("GET", "/api/permissions/groups", {"permission": perm, "ps": 100})
        for g in groups["groups"]:
            if g["name"] != ADMIN_GROUP and perm in g.get("permissions", []):
                api.call(
                    "POST", "/api/permissions/remove_group", {"groupName": g["name"], "permission": perm}
                )
                print(f"CHANGED group {g['name']}: removed global {perm}")
                changed = True
    if not changed:
        print(f"OK only {ADMIN_GROUP} holds global provisioning, no group holds global scan")


def ci_token(api: Api, base: str) -> None:
    for t in api.call("GET", "/api/user_tokens/search", {"login": CI_USER})["userTokens"]:
        api.call("POST", "/api/user_tokens/revoke", {"login": CI_USER, "name": t["name"]})
    # A project analysis token can only be generated by its owner. The CI user gets a fresh random password
    # that lives only in this process, generates its own token, and the password is never stored.
    pw = secrets.token_urlsafe(32) + "aA1!"
    api.call("POST", "/api/users/change_password", {"login": CI_USER, "password": pw})
    ci = Api(base, pw)
    ci.auth(pw, CI_USER)
    del pw
    today = dt.date.today()
    res = ci.call(
        "POST",
        "/api/user_tokens/generate",
        {
            "name": f"gitlab-ci-{today.isoformat()}",
            "type": "PROJECT_ANALYSIS_TOKEN",
            "projectKey": PROJECT,
            "expirationDate": (today + dt.timedelta(days=TOKEN_DAYS)).isoformat(),
        },
    )
    print("TOKEN " + res["token"])


def local_token(api: Api, key: str) -> None:
    project(api, key)
    # Nobody holds global scan; the admin may analyse only the local verification project
    api.call("POST", "/api/permissions/add_user", {"login": ADMIN, "projectKey": key, "permission": "scan"})
    revoke_local(api)
    today = dt.date.today()
    res = api.call(
        "POST",
        "/api/user_tokens/generate",
        {
            "name": f"{LOCAL_PREFIX}{dt.datetime.now():%Y%m%d%H%M%S}",
            "type": "PROJECT_ANALYSIS_TOKEN",
            "projectKey": key,
            "expirationDate": (today + dt.timedelta(days=1)).isoformat(),
        },
    )
    print("TOKEN " + res["token"])


def revoke_local(api: Api) -> None:
    for t in api.call("GET", "/api/user_tokens/search")["userTokens"]:
        if t["name"].startswith(LOCAL_PREFIX):
            api.call("POST", "/api/user_tokens/revoke", {"name": t["name"]})
            print(f"CHANGED revoked {t['name']}", file=sys.stderr)


def gate(api: Api, key: str) -> None:
    status = api.call("GET", "/api/qualitygates/project_status", {"projectKey": key})["projectStatus"]
    print(f"GATE {key} {status['status']}")
    for c in status.get("conditions", []):
        print(f"  {c['status']:5} {c['metricKey']} {c['comparator']} {c['errorThreshold']} actual={c.get('actualValue', '-')}")


def main() -> int:
    cmds = {"bootstrap": 3, "ci-token": 3, "local-token": 4, "revoke-local": 3, "gate": 4}
    if len(sys.argv) < 2 or cmds.get(sys.argv[1]) != len(sys.argv):
        sys.exit(__doc__)
    base = sys.argv[2]
    password = read_password()
    api = Api(base, password)
    wait_up(api)
    if sys.argv[1] == "ci-token":
        if not api.valid():
            sys.exit("FAIL admin login failed; run appsec.yml first")
        ci_token(api, base)
        return 0
    if sys.argv[1] == "gate":
        gate(api, sys.argv[3])
        return 0
    if sys.argv[1] in ("local-token", "revoke-local"):
        if not api.valid():
            sys.exit("FAIL admin login failed; run appsec.yml first")
        if sys.argv[1] == "local-token":
            if not sys.argv[3].startswith(LOCAL_PROJECT_PREFIX):
                sys.exit(f"FAIL local scans only go to projects named {LOCAL_PROJECT_PREFIX}*")
            local_token(api, sys.argv[3])
        else:
            revoke_local(api)
        return 0
    admin_login(api, password)
    settings(api, base)
    quality_gate(api)
    project(api)
    ci_user(api)
    global_permissions(api)
    return 0


if __name__ == "__main__":
    sys.exit(main())
