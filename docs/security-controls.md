# Security controls and framework mapping

Every control below is implemented and was verified in this lab unless it is marked **Gap** —
gaps are listed openly with the planned fix. Evidence links point to the build log and lessons learned.

## 1. OWASP Top 10 CI/CD Security Risks

| Risk | How SecureStream addresses it | Status |
|---|---|---|
| **CICD-SEC-1** Insufficient flow control | `main` is protected; signing and deploy jobs run only on `main`; deploy uses `resource_group` (one at a time) and `--atomic` rollback | Done |
| **CICD-SEC-2** Inadequate identity and access management | Personal GitLab account for daily work, `root` only for administration; Proxmox API token `terraform@pve` with only VM/datastore/SDN roles; deploy token limited to `read_registry` | Done · **Gap:** 2FA on GitLab accounts pending |
| **CICD-SEC-3** Dependency chain abuse | Python dependencies pinned in `requirements.txt`; Trivy SCA on every commit; CI tool images pinned by digest | Done |
| **CICD-SEC-4** Poisoned pipeline execution | Signing key and kubeconfig are *protected* variables — not exposed to pipelines on unprotected branches; runner is unprivileged | Done |
| **CICD-SEC-5** Insufficient pipeline-based access controls | Group runner (not instance-wide), tagged jobs only (`run_untagged=false`); the deploy identity is a namespace-scoped Role (`can-i`: deploy yes, kube-system secrets no, nodes no) | Done |
| **CICD-SEC-6** Insufficient credential hygiene | Variables masked + hidden; gitleaks with `--redact`; Ansible `no_log` on token-bearing tasks; secrets moved only via pipes; credentials have expiry dates and a rotation runbook | Done |
| **CICD-SEC-7** Insecure system configuration | GitLab sign-up disabled, TLS everywhere from a private CA, runner `no-new-privileges`, Kaniko instead of Docker-in-Docker | Done |
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
| **PW.4** Reuse well-secured software | SCA (Trivy fs) on dependencies; base image by digest; HIGH/CRITICAL fixable CVEs block the build |
| **PW.6** Configure build processes securely | Multi-stage Dockerfile, non-root user, build without privileged containers |
| **PW.7** Review / analyse code | Semgrep (`p/python`, `p/owasp-top-ten`) and ruff bandit rules on every commit |
| **PW.8** Test executable code | Unit tests that encode security requirements (input validation, security headers, auth); OWASP ZAP API scan after deploy |
| **PW.9** Secure-by-default settings | Swagger UI off, security headers on, pod hardening enforced by Pod Security `restricted` |
| **RV.1** Identify vulnerabilities continuously | Trivy on every build; Falco at runtime · **Gap:** continuous SBOM monitoring (Dependency-Track) |
| **RV.2** Assess and remediate | ZAP findings (3 warnings) fixed in code, locked by a test, re-scanned to 0 |
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

## 5. Secrets lifecycle

| Secret | Created | Stored | Consumed by | Rotation |
|---|---|---|---|---|
| Vault unseal keys + initial root token | `vault operator init` piped into `ansible-vault encrypt` | Ansible Vault (excluded from public mirror) | `scripts/vault-unseal.sh` | Root token revoked after setup; rekey procedure in runbook |
| catalog API key | `openssl rand` piped into `vault kv put` | Vault KV v2 | External Secrets → pod env | New KV version + ESO force-sync |
| cosign private key | Generated in RAM (`/dev/shm`) | Ansible Vault + GitLab protected/hidden variable | `sign` job on `main` | Runbook: new key pair, update policy |
| GitLab runner token | GitLab API → `ansible-vault encrypt_string` | Ansible Vault | Runner `config.toml` (mode 0600, `no_log`) | Re-register runner |
| Registry deploy token | GitLab service → Kubernetes secret via pipe | Kubernetes secrets (`catalog`, `kyverno`) | kubelet image pulls, Kyverno | 1-year expiry |
| CI deploy kubeconfig | Built in RAM from a service-account token | GitLab protected/hidden variable | `deploy` job | Delete token secret → new token |
| GitHub mirror token | GitHub UI → `read -rs` → GitLab (encrypted) | GitLab push-mirror config | Push mirror | 90-day expiry (next: 2027-01-20) |
