# Security controls and framework mapping

Every control below is implemented and was verified in this lab unless it is marked **Gap** —
gaps are listed openly with the planned fix. Evidence links point to the build log and lessons learned.

## 1. OWASP Top 10 CI/CD Security Risks

| Risk | How SecureStream addresses it | Status |
|---|---|---|
| **CICD-SEC-1** Insufficient flow control | `main` is protected; signing and deploy jobs run only on `main`; deploy uses `resource_group` (one at a time) and `--atomic` rollback | Done |
| **CICD-SEC-2** Inadequate identity and access management | Personal GitLab account for daily work, `root` only for administration; Proxmox API token `terraform@pve` with only VM/datastore/SDN roles; deploy token limited to `read_registry` | Done · **Gap:** 2FA on GitLab accounts pending · **Known risk:** user `ubuntu` on ss-mgmt has passwordless (`NOPASSWD`) sudo; for the AI assistant it is limited by the Claude Code ask rule `Bash(sudo *)` (approval per command, verified 2026-10-23), not removed |
| **CICD-SEC-3** Dependency chain abuse | Python dependencies pinned in `requirements.txt`; Trivy SCA on every commit; CI tool images pinned by digest | Done |
| **CICD-SEC-4** Poisoned pipeline execution | Signing key and kubeconfig are *protected* variables — not exposed to pipelines on unprotected branches; runner is unprivileged | Done |
| **CICD-SEC-5** Insufficient pipeline-based access controls | Group runner (not instance-wide), tagged jobs only (`run_untagged=false`); the deploy identity is a namespace-scoped Role (`can-i`: deploy yes, kube-system secrets no, nodes no) | Done |
| **CICD-SEC-6** Insufficient credential hygiene | Variables masked + hidden; gitleaks with `--redact` as a blocking gate in both repositories (no `allow_failure`, no allowlist); every file on a secret path must carry an Ansible Vault header (`scripts/check-vault-encrypted.sh`); Ansible `no_log` on token-bearing tasks; secrets moved only via pipes; credentials have expiry dates and a rotation runbook | Done |
| **CICD-SEC-7** Insecure system configuration | GitLab sign-up disabled, TLS everywhere from a private CA, runner `no-new-privileges`, Kaniko instead of Docker-in-Docker; Terraform verifies the Proxmox API against pve1's own CA (`scripts/tf.sh`, CA SHA-256 `83:0B:10:A3:…:6B:92`, `PROXMOX_VE_INSECURE=false` enforced; verification was skipped until 2026-10-23) | Done |
| **CICD-SEC-8** Ungoverned usage of third-party services | GitHub mirror token is fine-grained (two repositories, contents only, 90 days); third-party tools adopted after a ~2-week cool-down | Done |
| **CICD-SEC-9** Improper artifact integrity validation | cosign signature + signed SBOM attestation; Kyverno verifies the signature at admission; deploy by digest | Done |
| **CICD-SEC-10** Insufficient logging and visibility | Vault file audit log, k3s API audit log, Falco runtime alerts, GitLab audit events | Partial · **Gap:** central log aggregation (Loki) pending |

## 2. NIST SSDF (SP 800-218)

| Practice | Implementation |
|---|---|
| **PO.3** Implement supporting toolchains | All scanners pinned by digest (`scripts/pin-images.sh`); versions recorded in `platform/versions.conf` |
| **PO.5** Secure development environments | Isolated lab network, bastion-only administration, hardened runner, no inbound ports |
| **PS.1** Protect all forms of code | Protected branches, gitleaks on full history, signed-off public mirror without secrets |
| **PS.2** Verify software release integrity | cosign signatures verified by Kyverno; public key published in the application repository |
| **PS.3** Archive and protect each release | Image + CycloneDX SBOM attestation stored next to the image in the registry |
| **PW.1/PW.2** Design to meet security requirements, review the design | IaC gate `iac-scan` (Checkov + custom Proxmox rules) on all Terraform; scan-only AWS/Azure/GCP samples prove which cloud misconfigurations are caught |
| **PW.4** Reuse well-secured software | SCA (Trivy fs) on dependencies; base image by digest; HIGH/CRITICAL fixable CVEs block the build |
| **PW.6** Configure build processes securely | Multi-stage Dockerfile, non-root user, build without privileged containers; hadolint gates every Dockerfile change (`hadolint` job) |
| **PW.7** Review / analyse code | Semgrep (`p/python`, `p/owasp-top-ten`) and ruff bandit rules on every commit |
| **PW.8** Test executable code | Unit tests that encode security requirements (input validation, security headers, auth); OWASP ZAP API scan after deploy |
| **PW.9** Secure-by-default settings | Swagger UI off, security headers on, pod hardening enforced by Pod Security `restricted`; Helm chart scanned by Checkov (`checkov-helm`), renders only by image digest |
| **RV.1** Identify vulnerabilities continuously | Trivy on every build; Falco at runtime · **Gap:** continuous SBOM monitoring (Dependency-Track) |
| **RV.2** Assess and remediate | DefectDojo register (`defectdojo-upload`): every `main` pipeline reimports all scanner reports; SLA Critical 7 / High 30 / Medium 90 / Low 180 days; prioritisation severity × exploitability × exposure ([vulnerability-management](vulnerability-management.md)). ZAP findings (3 warnings) fixed in code, locked by a test, re-scanned to 0 |
| **RV.3** Analyse root causes | Each incident has a root-cause entry in [lessons-learned](lessons-learned.md) |

## 3. SLSA (v1.0, Build track)

| Requirement | Status |
|---|---|
| Builds run on a hosted, dedicated build platform (not a developer laptop) | Yes — GitLab Runner on its own VM, ephemeral job containers |
| Build output is signed | Yes — cosign signature on every `main` image |
| SBOM attached and signed | Yes — CycloneDX attestation |
| **Provenance** generated and signed | **Gap** — SLSA provenance attestation is on the roadmap; today the evidence is signature + SBOM + pipeline logs |

Honest position: the signing and SBOM pieces are in place; formal SLSA Build L2 needs provenance attestation.

## 4. Kubernetes hardening (CIS-aligned)

| Control | Where |
|---|---|
| Secrets encryption at rest | k3s `secrets-encryption` |
| API server audit log | k3s server configuration (Ansible `k3s` role) |
| `protect-kernel-defaults` | k3s configuration |
| Pod Security Admission `restricted` | `catalog` namespace |
| Admission policy | Kyverno `ImageValidatingPolicy` (signature required) |
| Network segmentation | NetworkPolicy: ingress only from the ingress controller, no egress |
| Least-privilege service accounts | `automountServiceAccountToken: false`; deploy Role scoped to one namespace |
| Runtime detection | Falco DaemonSet (modern eBPF) |
| Benchmark scan | **Gap** — kube-bench / Kubescape scheduled for the next phase |

## 5. Scanner exceptions

Findings that cannot be fixed are recorded in `security/exceptions.yaml` of the scanned repository (`id, tool, rule,
path, reason, owner, created, expires`, at most 90 days), never as inline suppressions. Checkov runs in report mode
and `scripts/scan-gate.py` decides: a finding passes only with a matching, unexpired exception; a report with zero
checks fails. Current: catalog-api `EXC-0001` (CKV_K8S_21, render-time namespace, expires 2027-01-21); platform
`EXC-0101`, `EXC-0102` (cloud samples, expire 2027-01-21).

The CI job `exceptions-check` (`scripts/exceptions-check.py`) validates the whole file on every pipeline: schema,
unique `EXC-NNNN` ids, known tool, at most 90 days, not expired (fails), WARN 14 days before expiry. The same entries
are mirrored to DefectDojo as time-boxed Risk Acceptances (`<product>:<id>`) by `defectdojo-upload`; DefectDojo
reactivates the findings when they expire. Process and roles: [vulnerability-management](vulnerability-management.md).

## 6. Secrets lifecycle

| Secret | Created | Stored | Consumed by | Rotation |
|---|---|---|---|---|
| Vault unseal keys + initial root token | `vault operator init` piped into `ansible-vault encrypt` | Ansible Vault (excluded from public mirror) | `scripts/vault-unseal.sh` | Root token revoked after setup; rekey procedure in runbook |
| catalog API key | `openssl rand` piped into `vault kv put` | Vault KV v2 | External Secrets → read-only file in the pod (`/run/secrets/catalog`, not env; CKV_K8S_35) | New KV version + ESO force-sync |
| cosign private key | Generated in RAM (`/dev/shm`) | Ansible Vault + GitLab protected/hidden variable | `sign` job on `main` | Runbook: new key pair, update policy |
| GitLab runner token | GitLab API → `ansible-vault encrypt_string` | Ansible Vault | Runner `config.toml` (mode 0600, `no_log`) | Re-register runner |
| Registry deploy token | GitLab service → Kubernetes secret via pipe | Kubernetes secrets (`catalog`, `kyverno`) | kubelet image pulls, Kyverno | 1-year expiry |
| CI deploy kubeconfig | Built in RAM from a service-account token | GitLab protected/hidden variable | `deploy` job | Delete token secret → new token |
| DefectDojo service secrets (Django secret key, AES key, PostgreSQL, admin, Jira webhook) | `openssl rand` piped into `ansible-vault encrypt_string` | `group_vars/security/vault.yml` | 0600 root env files on ss-sec; the admin password only reaches the one-shot initializer (unset, DefectDojo would generate one and print it to the container log) | Re-generate + `appsec.yml` (DB password needs a PostgreSQL `ALTER ROLE` too) |
| DefectDojo CI API key (`DD_API_KEY`) | Django `Token` for user `gitlab-ci` (no usable password, not staff, `authorized_users` of the two products), piped by `scripts/defectdojo-ci-token.sh` straight into GitLab | GitLab group variable, protected + masked + hidden | `defectdojo-upload` jobs on `main` | All DefectDojo API tokens expire after 90 days; rerun the script (old token is deleted) |
| GitHub mirror token | GitHub UI → `read -rs` → GitLab (encrypted) | GitLab push-mirror config | Push mirror | 90-day expiry (next: 2027-01-20) |
| Terraform state | `terraform apply` on ss-mgmt | GitLab managed Terraform state (project 1, state `proxmox`): encrypted by GitLab with Lockbox (key derived from `db_key_base` + project ID), locked and versioned. Pre-migration copy: `ansible-vault` encrypted backup in `~/.config/securestream/` (mode `0600`). Local plain-text leftovers removed with `scripts/tfstate-cleanup.sh` | `terraform plan/apply` via http backend (`backend.tf`); project access token in `~/.config/securestream/tfstate.env` (`0600`) | Done (migrated 2026-10-23; 9 instances, addresses + IDs match the backup, `plan` exit 0). Token expires in <= 1 year: renew with `scripts/tfstate-token.sh`. A rebuild from zero starts on a local backend, because GitLab is created by this Terraform |
