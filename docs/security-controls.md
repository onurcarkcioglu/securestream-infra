# Security controls and framework mapping

Every control below is implemented and was verified in this lab unless it is marked **Gap** —
gaps are listed openly with the planned fix. Evidence links point to the build log and lessons learned.

## 1. OWASP Top 10 CI/CD Security Risks

| Risk | How SecureStream addresses it | Status |
|---|---|---|
| **CICD-SEC-1** Insufficient flow control | `main` is protected; signing and deploy jobs run only on `main`; deploy uses `resource_group` (one at a time) and `--atomic` rollback | Done |
| **CICD-SEC-2** Inadequate identity and access management | Personal GitLab account for daily work, `root` only for administration; Proxmox API token `terraform@pve` with only VM/datastore/SDN roles; deploy token limited to `read_registry` | Done · **Gap:** 2FA on GitLab accounts pending · **Known risk:** user `ubuntu` on ss-mgmt has passwordless (`NOPASSWD`) sudo; for the AI assistant it is limited by the Claude Code ask rule `Bash(sudo *)` (approval per command, verified 2026-10-23), not removed. This also bounds the AI's Kubernetes boundary (§4): after `kubeconfig-lockdown.sh` the admin kubeconfig is `root:root 0600`, but `ubuntu` can still read it with `sudo`; the real control is the `sudo` ask rule plus the human's approval of each command, not the file mode |
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
| **PO.3** Implement supporting toolchains | Shared security jobs from one versioned project (`securestream/ci-templates`, consumed by protected tag, [ci-templates](ci-templates.md)); all scanners pinned by digest (`scripts/pin-images.sh` in `securestream/ci-templates`, one `templates/images.yml` for all projects); versions recorded in `platform/versions.conf` |
| **PO.5** Secure development environments | Isolated lab network, bastion-only administration, hardened runner, no inbound ports |
| **PS.1** Protect all forms of code | Protected branches, gitleaks on full history, signed-off public mirror without secrets |
| **PS.2** Verify software release integrity | cosign signatures verified by Kyverno; public key published in the application repository |
| **PS.3** Archive and protect each release | Image + CycloneDX SBOM attestation stored next to the image in the registry |
| **PW.1/PW.2** Design to meet security requirements, review the design | IaC gate `iac-scan` (Checkov + custom Proxmox rules) on all Terraform; scan-only AWS/Azure/GCP samples prove which cloud misconfigurations are caught |
| **PW.4** Reuse well-secured software | SCA (Trivy fs) on dependencies; base image by digest; HIGH/CRITICAL fixable CVEs block the build |
| **PW.6** Configure build processes securely | Multi-stage Dockerfile, non-root user, build without privileged containers; hadolint gates every Dockerfile change (`hadolint` job) |
| **PW.7** Review / analyse code | Semgrep (`p/python`, `p/owasp-top-ten`) and ruff bandit rules on every commit; SonarQube Community Build on every `main` pipeline with the Quality Gate "SecureStream" on new code (0 new bugs, 0 new vulnerabilities, 100 % security hotspots reviewed, coverage ≥ 70 %); a red gate fails `sonarqube`, and `sign`/`deploy` need it. Negative test: a weak-TLS helper (`PROTOCOL_TLSv1`, `CERT_NONE`) failed the gate with `new_vulnerabilities=3` while coverage stayed 100 % |
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
| Pod Security Admission | Every platform namespace labelled with the strictest level its workloads meet (`platform/manifests/namespaces.yaml`, `monitoring/namespace.yaml`): `restricted` for `catalog`, `cert-manager`, `external-secrets`, `traefik`, `kyverno`, `argocd`, `demo`, `default`; `baseline` for `monitoring`; `privileged` only for `falco`, `metallb-system`, `node-exporter` (exceptions below). k3s has no cluster-wide default, so an unlabelled namespace would be privileged. `install.sh` applies the labels only after a server-side dry run reports no violating pod |
| Admission policy | Kyverno `ImageValidatingPolicy` (signature required) |
| Network segmentation | NetworkPolicy: ingress only from the ingress controller, no egress |
| Least-privilege service accounts | `automountServiceAccountToken: false`; deploy Role scoped to one namespace |
| Runtime detection | Falco DaemonSet (modern eBPF, least-privilege mode: `BPF`, `PERFMON`, `SYS_RESOURCE`, `SYS_PTRACE` instead of privileged); events via Falcosidekick to Loki, dashboard "SecureStream Security" in Grafana (`platform/install-monitoring.sh`) |
| Posture scan | Kubescape 4.0.15, frameworks NSA + MITRE (regolibrary v2.0.38, pinned by SHA256), `scripts/kubescape-scan.sh`: runs as `claude-readonly` (refuses an identity that can create pods/DaemonSets or read secrets), no host scan (it would install a DaemonSet), vendor default exceptions off; the saved report keeps resource ids, results and summary only (full objects stay in `/dev/shm` and are deleted; forbidden keys and 7 secret patterns checked before writing). Import: `scripts/kubescape-upload.sh` (human, own DefectDojo key). **Score 2026-10-23: compliance 64.3 (NSA 60.1, MITRE 61.7)**, 38/40 controls evaluated, 24 failed, 0 Critical, 9 High; details below · kubelet and node controls (C-0069/C-0070) are covered by kube-bench below |
| Platform render check | `scripts/platform-render-check.sh`: renders every platform chart with the repository's values (`helm template`, no cluster access) and fails if any container lacks CPU/memory requests and limits, if a pod does not meet its namespace's PSA enforce level, or if its namespace has no level. 32 workloads, 0 findings; negative tests (node-exporter back in `monitoring`, Traefik without limits) fail with 9 findings |
| CIS node benchmark | kube-bench 0.16.0 (profile `k3s-cis-1.9`, the newest k3s profile; the cluster runs 1.36), `scripts/kube-bench-scan.sh` → `infra/ansible/playbooks/kube-bench.yml`: runs in a temporary directory on each k3s node (binary verified by SHA256), the raw report is reduced on the node to an allow-list (test number, description, status, remediation; audit commands and their output never leave the node), checked for secret patterns on ss-mgmt, raw file and binary deleted. **2026-10-24:** workers 17 PASS / 0 FAIL / 2 WARN each; control plane 62 PASS / 4 FAIL / 43 WARN (all 43 are *Manual* checks). Fixed: 1.1.20 PKI certificates 0644 → 0600 (`k3s` role, second run `changed=0`). Assessment of the rest below. DefectDojo import needs a `kube-bench` parser entry in ci-templates (roadmap) |
| AI assistant cluster access | ServiceAccount `claude-readonly` (`platform/manifests/claude-readonly-rbac.yaml`, generated by `scripts/claude-readonly-rbac.sh` from API discovery): get/list/watch on explicitly listed resources; no `secrets`, no subresources (`pods/log`, `pods/exec`), no `generators.external-secrets.io`. Time-limited bound token (12 h, TokenRequest, not stored in a Secret). Admin kubeconfig only at `/etc/securestream/admin.kubeconfig` (`root:root 0600`, `scripts/kubeconfig-lockdown.sh`); `~/.kube/config` links to the read-only file. Verified 2026-10-23: plain `kubectl auth whoami` → `system:serviceaccount:claude-readonly:claude-readonly`, `can-i get secrets -A` → no, `can-i '*' '*' -A` → no, admin file not readable by `ubuntu`. Done · **Known risks:** (1) the assistant runs as the same Unix user as the human (`ubuntu`) and that user has NOPASSWD sudo: `sudo` can read the admin kubeconfig; (2) on the k3s nodes `/etc/rancher/k3s/k3s.yaml` is an admin kubeconfig reachable with `ssh` + `sudo`. For both the only control is the Claude Code ask rules `Bash(ssh *)` / `Bash(sudo *)` plus the human's approval of each command; (3) the read-only token expires after 12 h and must be renewed by the human with `sudo scripts/claude-kubeconfig.sh` (an expired token fails closed). **Roadmap:** run the assistant as its own Unix user with only the read-only kubeconfig, no sudo and no SSH keys |

### Kubescape High findings (2026-10-23)

No control failed with Critical severity (DefectDojo: scoreFactor 10; the only one, C-0069, was not evaluated).
High findings, assessed one by one. Workload findings are almost all in third-party platform components; the
application (`catalog`) fails none of the High controls except through the deploy identity (C-0015).

| Control | Resources | Assessment | Action |
|---|---|---|---|
| C-0012 credentials in configuration | `metallb-controller` | False positive: `METALLB_ML_SECRET_NAME` is the name of a Secret (value checked by length only) | `EXC-0103` (`security/exceptions.yaml`, until 2027-01-21) |
| C-0015 list secrets | 22 subjects: `system:masters`, k3s controllers, cert-manager, ESO, Kyverno, Traefik, `catalog-deployer` | Required by the operators; `catalog-deployer` needs it because Helm stores releases as Secrets in `catalog` (namespace Role only) | Accepted by design; no wildcard; review on every RBAC change |
| C-0041 hostNetwork, C-0046 insecure capabilities | MetalLB speaker / FRR | The chart also installs the frr-k8s BGP backend (`SYS_ADMIN`, `NET_ADMIN`) although the lab uses L2 only (no `BGPPeer`) | **Fixed in values** (`helm-values/metallb.yaml`: `frrk8s.enabled: false`); the speaker keeps `hostNetwork` + `NET_RAW` for ARP: accepted, see PSA exceptions |
| C-0045/C-0048 (writable) hostPath | Falco; Kyverno admission/background/reports | Kyverno mounted the node CA bundle writable; Falco mounted six container-runtime socket directories, five of them for runtimes that do not exist on k3s | **Fixed in values:** Kyverno trusts only the lab root CA from a ConfigMap (`global.caCertificates.data`, no hostPath; the registry chain verifies with that root alone, a public-only trust store fails); Falco keeps only `/run/k3s/containerd` (docker/podman off, cri limited to the k3s socket): accepted, see PSA exceptions |
| C-0057 privileged | Falco; MetalLB FRR (`SYS_ADMIN`) | Falco ran fully privileged although modern eBPF supports least-privilege mode | **Fixed in values:** `driver.modernEbpf.leastPrivileged: true`; FRR removed (above). After the upgrade the shell-in-container evidence (`scripts/monitoring-falco-check.sh`) must pass again |
| C-0270/C-0271 CPU / memory limits | 19 / 14 platform workloads | No limits from the charts' defaults; the `catalog` workload sets them | **Fixed in values:** requests and limits for every container, init container and hook Job (sized at ~4× measured use); enforced by `scripts/platform-render-check.sh` |

Fixes change the cluster (Helm upgrade with the admin kubeconfig) and are run by the human (`platform/install.sh`,
`install-monitoring.sh`, `install-argocd.sh`); afterwards re-run `scripts/kubescape-scan.sh` and compare the score.
Status: fixed in values on 2026-10-24, apply pending.

### kube-bench findings (2026-10-24)

| Check | Assessment | Action |
|---|---|---|
| 1.1.20 PKI certificate file permissions | k3s writes `server/tls/*.crt` as 0644 (keys are already 0600) | **Fixed:** `k3s` role sets 0600; re-scan PASS |
| 1.2.26 `--etcd-cafile` | Not applicable: the datastore is SQLite through kine (`server/db/state.db`), there is no etcd to authenticate to | Accepted (false positive for this datastore) |
| 5.1.3 wildcards in Roles/ClusterRoles | All wildcard roles are Kubernetes/k3s system roles or chart roles (Argo CD controller and server, MetalLB speaker, local-path provisioner); none of this repository's roles uses a wildcard | Accepted for system roles; Argo CD's cluster-wide `*` is the open item (detect-only Argo CD with read-only rules is on the roadmap) |
| 5.1.5 default service accounts in use | `argocd-redis` and `demo/whoami` ran as `default` and mounted its token | **Fixed in manifests:** redis gets its own ServiceAccount, whoami `automountServiceAccountToken: false`, every platform namespace's `default` ServiceAccount has automount off; apply pending |
| 5.1.6 token mounted where not needed | 31 of 33 workloads mount a token; the operators need the API, redis and whoami did not | Same fix as 5.1.5; operators accepted |
| 43 *Manual* WARN (5.2 Pod Security 13, 5.1 RBAC 9, 1.2 API server 4, 5.7 general 4, 3.1 authn 3, others) | kube-bench cannot evaluate them automatically | Covered by controls documented above: PSA levels per namespace (5.2), NetworkPolicies (5.3), External Secrets + Vault and secrets encryption (5.4), Kyverno admission (5.5); the rest reviewed with the next Kubescape run |

### Pod Security Admission exceptions

| Namespace / workload | PSA labels | Warning seen | Why it is accepted | Compensating controls | Review |
|---|---|---|---|---|---|
| `node-exporter` / DaemonSet `kps-prometheus-node-exporter` (kube-prometheus-stack 92.2.0) | `enforce: privileged`, `warn`/`audit: baseline`; the namespace holds nothing else (`platform/manifests/monitoring/namespace.yaml`) | Install on 2026-10-24 (then in `monitoring`): baseline violations `hostNetwork`, `hostPID`, `hostPath` `/proc`, `/sys`, `/` | node-exporter reports node metrics (CPU, memory, disk, network, processes); it can only read them from the host's namespaces and filesystems. No baseline-compatible alternative exists | Upstream image `quay.io/prometheus/node-exporter:v1.12.1-distroless`; `runAsNonRoot` (UID/GID 65534), `readOnlyRootFilesystem`, all three hostPath mounts `readOnly` (`/` with `HostToContainer`); no added capabilities, not privileged; port 9100 only; requests and limits | 2027-01-21 (90 days) |
| `falco` / DaemonSet `falco` (chart 9.2.1) | `enforce: privileged`, `warn`/`audit: baseline` | Baseline violations by design: capabilities `BPF`, `PERFMON`, `SYS_RESOURCE`, `SYS_PTRACE`; AppArmor `unconfined` (set by the chart in least-privilege mode so the eBPF probe can load); hostPath `/proc`, `/etc`, `/sys/kernel` (read-only), `/boot`, `/lib/modules`, `/usr` (driver loader volumes) and `/run/k3s/containerd` (runtime socket, the chart mounts it writable) | Runtime detection reads kernel events and container metadata from the host; that is the control itself | Not privileged since the least-privilege change; only the k3s containerd socket directory; Falco's own events go to Loki; requests and limits | 2027-01-21 |
| `metallb-system` / DaemonSet `metallb-speaker` (chart 0.16.1) | `enforce: privileged`, `warn`/`audit: baseline` | Baseline violations by design: `hostNetwork`, capability `NET_RAW` | L2 mode answers ARP for service IPs on the node's interface | frr-k8s (BGP, `SYS_ADMIN`) removed; controller runs restricted-compatible; requests and limits | 2027-01-21 |

`monitoring` enforces `baseline` (warn/audit `restricted`) after node-exporter moved out: Grafana, Prometheus, Loki,
Alloy, the operator and kube-state-metrics need no host access. The next Kubescape run will still report the three
DaemonSets above under C-0038 (hostPID), C-0041 (hostNetwork), C-0046 (capabilities) and C-0048 (hostPath); they get
`kubescape` entries in `security/exceptions.yaml` with these reasons once the findings exist.

## 5. Scanner exceptions

Findings that cannot be fixed are recorded in `security/exceptions.yaml` of the scanned repository (`id, tool, rule,
path, reason, owner, created, expires`, at most 90 days), never as inline suppressions. Checkov runs in report mode
and `scan-gate.py` (ci-templates) decides: a finding passes only with a matching, unexpired exception; a report with zero
checks fails. Current: catalog-api `EXC-0001` (CKV_K8S_21, render-time namespace, expires 2027-01-21); platform
`EXC-0101`, `EXC-0102` (cloud samples, expire 2027-01-21).

The CI job `exceptions-check` (`exceptions-check.py` (ci-templates)) validates the whole file on every pipeline: schema,
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
| SonarQube admin and PostgreSQL passwords | `openssl rand` piped into `ansible-vault encrypt_string` | `group_vars/security/vault.yml` | 0600 root env files in `/opt/sonarqube`; the initial `admin/admin` is replaced through the API on first start (`sonar-admin.py`), verified: `admin/admin` → `valid:false`, password 0 lines in container logs | Re-generate + `appsec.yml` (the bootstrap only changes `admin/admin`; a later admin rotation needs the old password, DB password a PostgreSQL `ALTER ROLE`) |
| SonarQube CI token (`SONAR_TOKEN`) | Project analysis token (`sqp_`, only `catalog-api`) of user `gitlab-ci` (Browse + Execute Analysis on that project only, no global rights), piped by `scripts/sonarqube-ci-token.sh` from ss-sec straight into GitLab. Only the owner may create such a token, so the script sets a random in-memory password for `gitlab-ci` first; it is never stored | GitLab project variable `securestream/catalog-api`, protected + masked + hidden | `sonarqube` job on `main` | 90 days (next: 2027-01-21); rerun the script (old tokens revoked) |
| GitHub mirror token | GitHub UI → `read -rs` → GitLab (encrypted) | GitLab push-mirror config | Push mirror | 90-day expiry (next: 2027-01-20) |
| Terraform state | `terraform apply` on ss-mgmt | GitLab managed Terraform state (project 1, state `proxmox`): encrypted by GitLab with Lockbox (key derived from `db_key_base` + project ID), locked and versioned. Pre-migration copy: `ansible-vault` encrypted backup in `~/.config/securestream/` (mode `0600`). Local plain-text leftovers removed with `scripts/tfstate-cleanup.sh` | `terraform plan/apply` via http backend (`backend.tf`); project access token in `~/.config/securestream/tfstate.env` (`0600`) | Done (migrated 2026-10-23; 9 instances, addresses + IDs match the backup, `plan` exit 0). Token expires in <= 1 year: renew with `scripts/tfstate-token.sh`. A rebuild from zero starts on a local backend, because GitLab is created by this Terraform |
