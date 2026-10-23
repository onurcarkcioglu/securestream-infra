"""Closes a Checkov blind spot for the GCP default service account.

CKV_GCP_30/31 match the default service account only as a literal e-mail
("<n>-compute@developer.gserviceaccount.com"). A reference through the data source
google_compute_default_service_account is not detected (checked with Checkov 3.3.26).
"""

from typing import Any

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


class GcpVmDefaultServiceAccountViaDataSource(BaseResourceCheck):
    def __init__(self) -> None:
        super().__init__(
            name="GCP VM must not use the default service account (also via data source)",
            id="CKV_SS_3",
            categories=[CheckCategories.IAM],
            supported_resources=["google_compute_instance"],
        )

    def scan_resource_conf(self, conf: dict[str, list[Any]]) -> CheckResult:
        for sa in conf.get("service_account") or []:
            email = str((sa.get("email") or [""])[0]) if isinstance(sa, dict) else ""
            if "google_compute_default_service_account" in email or email.endswith(
                "-compute@developer.gserviceaccount.com"
            ):
                return CheckResult.FAILED
        return CheckResult.PASSED


check = GcpVmDefaultServiceAccountViaDataSource()
