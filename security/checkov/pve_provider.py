"""Custom Checkov checks for the bpg/proxmox provider block (Checkov ships none for Proxmox)."""

from typing import Any

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.provider.base_check import BaseProviderCheck


class ProxmoxProviderTLS(BaseProviderCheck):
    def __init__(self) -> None:
        # Lessons learned #17: TLS verification was off; scripts/tf.sh enforces it at runtime too.
        super().__init__(
            name="Proxmox provider must not set insecure = true",
            id="CKV_SS_1",
            categories=[CheckCategories.NETWORKING],
            supported_provider=["proxmox"],
        )

    def scan_provider_conf(self, conf: dict[str, list[Any]]) -> CheckResult:
        value = (conf.get("insecure") or [False])[0]
        return CheckResult.FAILED if value in (True, "true", "True") else CheckResult.PASSED


class ProxmoxProviderNoInlineCredentials(BaseProviderCheck):
    def __init__(self) -> None:
        # Credentials come from ~/.config/securestream/pve.env via environment variables only.
        super().__init__(
            name="Proxmox provider must not contain inline credentials",
            id="CKV_SS_2",
            categories=[CheckCategories.SECRETS],
            supported_provider=["proxmox"],
        )

    def scan_provider_conf(self, conf: dict[str, list[Any]]) -> CheckResult:
        inline = {"api_token", "password", "username", "auth_ticket", "csrf_prevention_token"}
        return CheckResult.FAILED if inline & conf.keys() else CheckResult.PASSED


tls_check = ProxmoxProviderTLS()
credentials_check = ProxmoxProviderNoInlineCredentials()
