#!/usr/bin/env python3
"""Idempotent DefectDojo structure through the REST API (roles/defectdojo).

Usage: <admin API token on stdin> | dd-bootstrap.py https://defectdojo.securestream.lab

Creates or corrects: SLA configuration, product type, products, one "CI/CD" engagement per product,
and the CI user (no usable password, not staff) in every product's authorized_users.

DefectDojo 3.x OSS has no per-product roles (RBAC moved to the Pro plugin, dojo/authorization/authorization.py):
a non-staff user in a product's authorized_users may view, add, edit and import, but not delete; staff and
superusers may do everything. So the CI user must never be staff.
The token is read from stdin only and never printed. Output lines start with OK or CHANGED.
"""

import datetime as dt
import json
import secrets
import ssl
import sys
import urllib.error
import urllib.request

SLA = {
    "name": "SecureStream",
    "description": "Critical 7, High 30, Medium 90, Low 180 days (docs/vulnerability-management.md)",
    "critical": 7,
    "enforce_critical": True,
    "high": 30,
    "enforce_high": True,
    "medium": 90,
    "enforce_medium": True,
    "low": 180,
    "enforce_low": True,
}
PRODUCT_TYPE = "SecureStream"
PRODUCTS = {
    "catalog-api": "Application: FastAPI catalog service (securestream/catalog-api)",
    "securestream-platform": "Platform: IaC, cluster posture, CI (securestream/securestream)",
}
ENGAGEMENT = "CI/CD"
CI_USER = "gitlab-ci"


class Api:
    def __init__(self, base: str, token: str):
        self.base = base.rstrip("/") + "/api/v2"
        self.headers = {"Authorization": f"Token {token}", "Content-Type": "application/json"}
        self.ctx = ssl.create_default_context()

    def call(self, method: str, path: str, body: dict | None = None) -> dict:
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=self.headers)
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=60) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:500]
            sys.exit(f"FAIL {method} {path}: HTTP {err.code} {detail}")
        return json.loads(raw) if raw else {}

    def all(self, path: str) -> list[dict]:
        sep = "&" if "?" in path else "?"
        return self.call("GET", f"{path}{sep}limit=1000").get("results", [])


def ensure(api: Api, path: str, match: dict, create: dict, fix: dict | None = None, query: str = "") -> dict:
    """Find one object whose fields equal `match`; create it if missing, patch `fix` fields if they differ."""
    found = [o for o in api.all(path + query) if all(o.get(k) == v for k, v in match.items())]
    label = f"{path} {match}"
    if not found:
        obj = api.call("POST", path, {**match, **create, **(fix or {})})
        print(f"CHANGED created {label} id={obj['id']}")
        return obj
    obj = found[0]
    diff = {k: v for k, v in (fix or {}).items() if obj.get(k) != v}
    if diff:
        obj = api.call("PATCH", f"{path}{obj['id']}/", diff)
        print(f"CHANGED updated {label} {sorted(diff)}")
    else:
        print(f"OK {label} id={obj['id']}")
    return obj


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    token = sys.stdin.read().strip()
    if len(token) != 40:
        sys.exit(f"FAIL admin token on stdin has length {len(token)}, expected 40")
    api = Api(sys.argv[1], token)

    sla_fields = {k: v for k, v in SLA.items() if k != "name"}
    sla = ensure(api, "/sla_configurations/", {"name": SLA["name"]}, sla_fields, sla_fields)
    ptype = ensure(api, "/product_types/", {"name": PRODUCT_TYPE}, {"description": "SecureStream lab"})

    # The API requires a password for new users (DD_REQUIRE_PASSWORD_ON_USER). A random one is sent once,
    # never stored or printed; the next Ansible task makes it unusable, so the user cannot log in to the UI.
    user = ensure(
        api,
        "/users/",
        {"username": CI_USER},
        {
            "first_name": "GitLab",
            "last_name": "CI",
            "email": f"{CI_USER}@securestream.lab",
            "is_active": True,
            "password": secrets.token_urlsafe(24) + "Aa1!",
        },
        {"is_superuser": False, "is_staff": False, "is_active": True},
    )

    today = dt.date.today().isoformat()
    for name, description in PRODUCTS.items():
        product = ensure(
            api,
            "/products/",
            {"name": name},
            {"description": description, "prod_type": ptype["id"]},
            {"sla_configuration": sla["id"]},
        )
        ensure(
            api,
            "/engagements/",
            {"name": ENGAGEMENT, "product": product["id"]},
            {
                "target_start": today,
                "target_end": "2030-12-31",
                "engagement_type": "CI/CD",
                "status": "In Progress",
                "deduplication_on_engagement": True,
                "description": "Reimport on every main pipeline (defectdojo-upload)",
            },
            query=f"?product={product['id']}",
        )
        # Add the CI user, keep everyone else who is authorized
        authorized = product.get("authorized_users")
        if authorized is None:
            sys.exit(f"FAIL product {name}: API returns no authorized_users field")
        if user["id"] in authorized:
            print(f"OK {name}: {CI_USER} authorized")
        else:
            api.call("PATCH", f"/products/{product['id']}/", {"authorized_users": [*authorized, user["id"]]})
            print(f"CHANGED {name}: {CI_USER} added to authorized_users")
    return 0


if __name__ == "__main__":
    sys.exit(main())
