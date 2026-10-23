#!/usr/bin/env python3
"""Idempotent Dependency-Track administration through the REST API (roles/dependency_track).

Usage (root on ss-sec, reads DTRACK_ADMIN_PASSWORD from admin.env next to this script):
  dtrack-admin.py bootstrap https://dtrack.securestream.lab
  dtrack-admin.py ci-key    https://dtrack.securestream.lab   (only scripts/dtrack-ci-token.sh)

bootstrap creates or corrects: the admin password (from the initial admin/admin, which must be changed on first
login), the CI team "gitlab-ci" with exactly BOM_UPLOAD, PROJECT_CREATION_UPLOAD and VIEW_PORTFOLIO, and removes
the default "Automation" team (it is created with an API key nobody uses). Output lines start with OK or CHANGED.

ci-key deletes the CI team's previous API keys, creates a new one and prints one line "TOKEN <key>" for a pipe.
No secret is ever printed by bootstrap, written to disk or passed as an argument.
"""

import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ADMIN = "admin"
INITIAL_PASSWORD = "admin"
CI_TEAM = "gitlab-ci"
CI_PERMISSIONS = {"BOM_UPLOAD", "PROJECT_CREATION_UPLOAD", "VIEW_PORTFOLIO"}
DEFAULT_TEAM_TO_REMOVE = "Automation"


def admin_password() -> str:
    env = Path(__file__).with_name("admin.env")
    for line in env.read_text().splitlines():
        if line.startswith("DTRACK_ADMIN_PASSWORD="):
            value = line.split("=", 1)[1]
            if len(value) < 32:
                sys.exit("FAIL admin password in admin.env is too short")
            return value
    sys.exit("FAIL DTRACK_ADMIN_PASSWORD missing in admin.env")


class Api:
    def __init__(self, base: str):
        if not base.startswith("https://"):
            sys.exit("FAIL base URL must be https")
        self.base = base.rstrip("/")
        self.ctx = (
            ssl.create_default_context()
        )  # system store contains the lab CA (ca_trust role)
        self.token = ""

    def call(
        self, method: str, path: str, body=None, form=None, allow=()
    ) -> tuple[int, str]:
        # login ucu text/plain (JWT), digerleri JSON doner
        headers = {"Accept": "application/json, text/plain"}
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(
            self.base + path, data=data, method=method, headers=headers
        )
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
                return resp.status, resp.read().decode()
        except urllib.error.HTTPError as err:
            text = err.read().decode(errors="replace")
            if err.code in allow:
                return err.code, text
            # Error bodies of these endpoints carry no secrets; the request body is never printed
            sys.exit(f"FAIL {method} {path}: HTTP {err.code} {text[:300]}")

    def json(self, method: str, path: str, body=None):
        _, text = self.call(method, path, body=body)
        return json.loads(text) if text else None


def wait_ready(api: Api) -> None:
    for _ in range(60):
        try:
            status, _ = api.call("GET", "/api/version", allow=(502, 503))
            if status == 200:
                return
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(5)
    sys.exit("FAIL API not ready")


def login(api: Api, password: str) -> None:
    status, text = api.call(
        "POST",
        "/api/v1/user/login",
        form={"username": ADMIN, "password": password},
        allow=(401,),
    )
    if status != 200:
        sys.exit(f"FAIL admin login: HTTP {status} {text[:100]}")
    api.token = text.strip()


def ensure_admin_password(api: Api, password: str) -> None:
    status, text = api.call(
        "POST",
        "/api/v1/user/login",
        form={"username": ADMIN, "password": password},
        allow=(401,),
    )
    if status == 200:
        print("OK      admin password")
        api.token = text.strip()
        return
    status, text = api.call(
        "POST",
        "/api/v1/user/login",
        form={"username": ADMIN, "password": INITIAL_PASSWORD},
        allow=(401,),
    )
    if status != 401 or "FORCE_PASSWORD_CHANGE" not in text:
        sys.exit(
            "FAIL admin login fails with both the vault password and the initial password"
        )
    api.call(
        "POST",
        "/api/v1/user/forceChangePassword",
        form={
            "username": ADMIN,
            "password": INITIAL_PASSWORD,
            "newPassword": password,
            "confirmPassword": password,
        },
    )
    login(api, password)
    print("CHANGED admin password (initial password replaced)")


def teams(api: Api) -> dict:
    return {t["name"]: t for t in api.json("GET", "/api/v1/team") or []}


def ensure_ci_team(api: Api) -> dict:
    team = teams(api).get(CI_TEAM)
    if team is None:
        team = api.json("PUT", "/api/v1/team", {"name": CI_TEAM})
        print(f"CHANGED team {CI_TEAM} created")
    have = {p["name"] for p in team.get("permissions") or []}
    for perm in sorted(CI_PERMISSIONS - have):
        api.call("POST", f"/api/v1/permission/{perm}/team/{team['uuid']}")
        print(f"CHANGED team {CI_TEAM}: +{perm}")
    for perm in sorted(have - CI_PERMISSIONS):
        api.call("DELETE", f"/api/v1/permission/{perm}/team/{team['uuid']}")
        print(f"CHANGED team {CI_TEAM}: -{perm}")
    if have == CI_PERMISSIONS:
        print(f"OK      team {CI_TEAM}: {', '.join(sorted(CI_PERMISSIONS))}")
    return teams(api)[CI_TEAM]


def remove_default_team(api: Api) -> None:
    team = teams(api).get(DEFAULT_TEAM_TO_REMOVE)
    if team is None:
        print(f"OK      default team {DEFAULT_TEAM_TO_REMOVE} absent")
        return
    api.call("DELETE", "/api/v1/team", body={"uuid": team["uuid"]})
    print(f"CHANGED default team {DEFAULT_TEAM_TO_REMOVE} removed (with its API key)")


def key_ids(team: dict) -> list[str]:
    # 4.13+: keys are stored hashed and listed by publicId; older listings carry the key itself
    return [k.get("publicId") or k.get("key") for k in team.get("apiKeys") or [] if k]


def ci_key(api: Api) -> None:
    team = ensure_ci_team(api)
    for kid in key_ids(team):
        api.call("DELETE", f"/api/v1/team/key/{urllib.parse.quote(kid, safe='')}")
    created = api.json("PUT", f"/api/v1/team/{team['uuid']}/key")
    key = (created or {}).get("key", "")
    if not key.startswith("odt_"):
        sys.exit("FAIL new API key has an unexpected format")
    print(f"TOKEN {key}")


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in ("bootstrap", "ci-key"):
        sys.exit(__doc__)
    cmd, base = sys.argv[1], sys.argv[2]
    api = Api(base)
    wait_ready(api)
    password = admin_password()
    if cmd == "bootstrap":
        ensure_admin_password(api, password)
        ensure_ci_team(api)
        remove_default_team(api)
    else:
        login(api, password)
        ci_key(api)
    return 0


if __name__ == "__main__":
    sys.exit(main())
