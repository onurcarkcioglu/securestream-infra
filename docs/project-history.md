# Project history

How SecureStream was built, in the order it happened: what was decided, what broke, and what each step left
behind as a control. Day-to-day detail is in the [engineering log](engineering-log.md) (Turkish) and the
[delivery log](progress.md); every incident has a row in [lessons learned](lessons-learned.md) (`#n` below).

## Goal and constraints

Build a production-style DevSecOps platform for a fictional OTT (streaming) company on **one physical server**,
and treat every security control as something that has to be *proven*, not just configured.

| Constraint | Consequence |
|---|---|
| One Proxmox host, no cloud account | Everything self-hosted: GitLab, Vault, k3s, scanners. Cloud IaC controls are exercised with scan-only samples |
| Home internet behind CGNAT | No port forwarding possible; remote access through Tailscale became a design decision ([ADR-0001](adr/0001-tailscale-instead-of-port-forwarding.md)) |
| Public portfolio, private secrets | GitLab is the source of truth; GitHub receives a mirror with secret files removed from the whole history ([ADR-0008](adr/0008-sanitized-public-mirror.md)) |
| AI-assisted engineering | An AI coding assistant (Claude Code) does much of the implementation and is treated as an untrusted contributor ([AI guardrails](ai-guardrails.md)) |

## Timeline at a glance

| Phase | Outcome | Main evidence |
|---|---|---|
| 1. Foundation | Proxmox, isolated lab network with NAT, Tailscale subnet router, bastion VM | [engineering log](engineering-log.md) |
| 2. Infrastructure as code | Golden image, 8 VMs by Terraform in ~2 minutes, Ansible baseline with `changed=0` on the second run | `infra/terraform/proxmox`, `infra/ansible/roles/baseline` |
| 3. Core services | Split DNS, two-tier private CA with name constraints, reusable certificate role | `roles/dns_server`, `roles/lab_ca`, `roles/lab_cert` |
| 4. Kubernetes platform | Hardened k3s, MetalLB, Traefik, cert-manager | `roles/k3s`, `platform/` |
| 5. Source control and CI | GitLab CE with registry, unprivileged Docker-executor runner, smoke test with a negative TLS check | `roles/gitlab`, `roles/gitlab_runner` |
| 6. Secure delivery pipeline | Lint → test → secret scan → SAST → SCA → build → image scan + SBOM → sign → deploy → DAST, signed images enforced at admission | [catalog-api](https://github.com/onurcarkcioglu/catalog-api), Kyverno policy |
| 7. Secrets management | HashiCorp Vault (Raft, TLS, audit), External Secrets with Kubernetes auth, root token revoked | `roles/vault`, `platform/vault` |
| 8. Documentation and public mirror | Security control mapping, threat model, ADRs, runbooks, filtered GitHub publication | `docs/`, `publish-github` job |
| 9. AI-assisted engineering | Permission rules, an immutable allow-listed status script, read-only cluster identity, incident log | [AI guardrails](ai-guardrails.md) |
| 10. Terraform state hardening | State moved to GitLab-managed state, Proxmox API TLS verification enabled | `scripts/tfstate-*.sh`, `scripts/tf.sh` |
| 11. Platform security expansion | Container/Helm scanning, multi-cloud IaC scanning, vulnerability management, SAST quality gate, shared CI templates, posture scanning | [delivery log](progress.md) |
| 12. Observability and GitOps | Prometheus, Grafana, Loki, Alloy, Falcosidekick, Dependency-Track, Argo CD | [requirements traceability](requirements-traceability.md) §7 |

## 1. Foundation

- Proxmox VE on a dual-Xeon workstation board. Installation problems on the way: wrong NIC port (`NO-CARRIER`),
  double NAT (modem + router), and a CGNAT WAN address that ruled out port forwarding.
- **Isolated lab network** `vmbr1` (10.10.10.0/24) with NAT egress only; the home LAN cannot reach the lab
  except through the hypervisor.
- **Tailscale subnet router** on the hypervisor for remote administration; no open router port, no Funnel.
- **Bastion** `ss-mgmt`: all automation runs from here. Tools moved off the admin laptop into this VM.
- First secret-handling incident: a Proxmox API token was visible in a screenshot. It was revoked and re-issued;
  from then on tokens moved only through SSH pipes. The reflex learned here — *revoke, re-issue, change the
  process* — repeats through the whole project.

## 2. Infrastructure as code

- Golden image with `qemu-guest-agent` built by `virt-customize`; Terraform (`bpg/proxmox`) creates 8 VMs and
  generates the Ansible inventory. A Proxmox API user with the minimum privileges Terraform needs.
- Ansible `baseline` role: updates, unattended upgrades, chrony, auditd, SSH hardening (keys only, no root,
  `AllowUsers`). The SSH handler validates with `sshd -t` before restarting.
- Working rule adopted here and kept since: `--syntax-check` → `--check --diff` → one host → all hosts →
  **second run must report `changed=0`**.
- Proxmox showed 100 % memory for a VM that used 35 %: the balloon driver was off. All VMs got
  `floating = dedicated`; resizes go through Terraform, never the UI, to avoid drift.

## 3. Core services: DNS and private PKI

- dnsmasq on `ss-infra` for `securestream.lab` (split DNS).
- **Two-tier private CA**; the root is limited by **X.509 name constraints** to `securestream.lab` and
  10.10.10.0/24, so a leaked intermediate cannot issue a certificate for any public name.
- `lab_cert` role: the private key is generated on the server that uses it and never leaves it; renewal is automatic.
- Rule: TLS verification is never disabled. Tools get the lab CA explicitly (`--cacert`, `VAULT_CACERT`).

## 4. Kubernetes platform

- k3s v1.36.5 (1 control plane, 2 workers) by an Ansible role: pinned version, **secrets encryption at rest**,
  `protect-kernel-defaults`, API audit log (Secrets at Metadata level so values are never logged), bundled Traefik
  and ServiceLB disabled.
- ingress-nginx had been retired upstream in March 2026; this was caught before installing it. Traefik (pinned
  Helm chart) behind MetalLB L2 (10.10.10.100), cert-manager with a ClusterIssuer on the lab intermediate CA.
- Test workload: non-root, read-only root filesystem, all capabilities dropped, HTTPS without `-k`.

## 5. Source control and CI

- GitLab CE 19.5.1 with container registry, lab CA TLS, sign-up disabled, version held.
- GitLab Runner 19.5.0, Docker executor, **`privileged = false`**, `no-new-privileges`, runner token moved from
  the GitLab API straight into Ansible Vault through a pipe.
- Smoke test pipeline: restricted capabilities, lab DNS, TLS with the lab CA succeeds **and TLS without it fails**.
  The negative test exposed that Alpine's `wget` (BusyBox) has no `--ca-certificate` (#6).

## 6. Secure delivery pipeline (catalog-api)

The workload is a small FastAPI service. Its pipeline (17 jobs today) is the main showcase:

| Stage | Control |
|---|---|
| Lint, unit tests | ruff with bandit (`S`) rules, pytest with coverage |
| Secret scan | gitleaks over the commit range |
| SAST | Semgrep (`p/python`, `p/owasp-top-ten`), SonarQube Quality Gate "SecureStream" |
| SCA | Trivy filesystem scan; gate on fixable HIGH/CRITICAL |
| Container and Helm | Hadolint, Checkov on the rendered chart |
| Build | Maintained Kaniko fork, unprivileged ([ADR-0004](adr/0004-kaniko-fork-for-builds.md)) |
| Image | Trivy image scan, CycloneDX SBOM |
| Sign | cosign key-based signature and signed SBOM attestation ([ADR-0005](adr/0005-cosign-key-based-without-public-tlog.md)) |
| Deploy | Helm with a namespace-scoped deploy identity |
| DAST | OWASP ZAP API scan after deploy |
| Report | DefectDojo upload, Dependency-Track SBOM upload |

- **Every CI tool image is pinned by digest** with a ~2-week cool-down for new releases
  ([ADR-0006](adr/0006-digest-pinning-and-cooldown.md)), motivated by the March 2026 Trivy supply-chain compromise
  (CVE-2026-33634, #4).
- **Admission control**: Kyverno `ImageValidatingPolicy` rejects any image from the project registry that does not
  carry the project's signature ([ADR-0003](adr/0003-kyverno-imagevalidatingpolicy.md)).
- Workload hardening: Pod Security `restricted`, non-root, read-only root filesystem, no capabilities, a
  NetworkPolicy with no egress.
- Each gate was broken on purpose (fake token, vulnerable dependency, Semgrep finding) and verified to fail
  **for the right reason** — the first attempt failed for the wrong one (#1).
- ZAP's first scan raised 3 header warnings; fixed in middleware, locked with a test, re-scanned to 0 (#8).
- **Runtime detection**: Falco with the modern eBPF driver. It did not alert on the first shell test because
  `kubectl exec -t` without `-i` opens no TTY (#9).

## 7. Secrets management

- HashiCorp Vault 2.1.2: Raft storage, TLS, file audit device, kv-v2. Initialised with Shamir 5/3; the init output
  was encrypted with Ansible Vault without ever reaching the screen. `scripts/vault-unseal.sh` decrypts three keys in
  memory and sends them over stdin.
- External Secrets Operator with Vault's Kubernetes auth method: no static Vault token in the cluster, a read-only
  policy per application ([ADR-0007](adr/0007-vault-and-external-secrets.md)).
- The root token was revoked after setup; a new one can only be generated with the unseal key quorum.
- Two more human incidents handled the same way: a pasted terminal log was reverted with `git revert` (no force
  push), and a GitHub token pasted into a chat was revoked and re-issued at once. Token prompts now check the format
  (`read -rsp`, prefix and length) (#11, #12).

## 8. Documentation and the public mirror

- Security controls mapped to **OWASP Top 10 CI/CD Security Risks, NIST SSDF (SP 800-218), SLSA and CIS
  Kubernetes** ([security controls](security-controls.md)), a STRIDE [threat model](threat-model.md), nine
  [ADRs](adr/README.md) and four [runbooks](runbooks/).
- `publish-github`: clones `main`, removes the Ansible Vault files from **every commit** with `git filter-repo`,
  fails if any secret path survives, re-runs gitleaks on the result and only then pushes. It runs only after the
  secret scan, IaC gate and exception check are green.

## 9. AI-assisted engineering

The AI assistant works on the bastion with the operator's Unix user, so the project had to decide what actually
limits it. The answer evolved through real incidents:

| Step | What changed | Lesson |
|---|---|---|
| Permission rules in `.claude/settings.json` (deny/ask/allow) and project rules in `CLAUDE.md` | A test showed `Read`/`cat`/`jq` denied on a fake state file but `python3 open()` succeeding | Deny rules are a guardrail, not a sandbox (#15) |
| `scripts/tf.sh` wrapper | It silently bypassed `ask: terraform apply`; rules moved to the wrapper | Permission rules must follow wrappers (#18) |
| Allow-listed read-only status script | The allowed copy is root-owned (`/usr/local/bin/ci-status`, 0755) because the assistant could edit the repository copy | Allow-listed code must be immutable for the AI (#19) |
| Read-only cluster identity `claude-readonly` | 13/13 `can-i` checks passed, yet plain `kubectl` was still cluster-admin until the admin kubeconfig was moved to `root:root 0600` | The boundary is what the server or kernel enforces (#31, #32) |
| Ansible `--diff` | Would have printed the admin kubeconfig and join token; secret tasks now set `diff: false` | A dry run is still output (#33) |
| Branch deletion, `kubectl get secret` spelled flag-first | Text rules missed; server-side protection and RBAC held | Treat every rule miss as a test result (#23, #36, #38) |

Summary in [AI guardrails](ai-guardrails.md): six layers (text rules, auto-mode classifier, human approval, RBAC,
file ownership, CI gates), with what each one stops and does not stop. Every AI-made change runs through the same
gates as a human change, and the commit history shows it (`Co-Authored-By`).

## 10. Terraform state hardening

- State sat unencrypted on the bastion with mode 0664. Fixed to 0600, then moved to **GitLab-managed Terraform
  state** after an encrypted backup; verified by comparing all 9 instance addresses and IDs and a no-change plan.
  The verification first failed on a changed lineage, which Terraform legitimately creates on migration (#16).
- The Proxmox provider had TLS verification switched off. The hypervisor's CA was verified out of band and is
  trusted **only by the Terraform process** (`scripts/tf.sh`); a wrong CA is rejected (#17).

## 11. Platform security expansion

A planned block of work with one row per workstream in the [delivery log](progress.md):

| Workstream | Result |
|---|---|
| Container and Helm scanning | Hadolint 0 findings; Checkov on the rendered chart, 96 checks, accepted risks time-boxed |
| Multi-cloud IaC scanning | Scan-only AWS/Azure/GCP samples (`insecure/` must be caught, `secure/` must pass); Checkov had no rules for `bpg/proxmox`, so 18 custom checks were written; custom rule `CKV_SS_3` for the GCP default service account (#21, #22) |
| Secret-scan gate | `allow_failure` removed from the platform secret scan; every file on a secret path must carry the Ansible Vault header |
| Vulnerability management | DefectDojo 3.3.300 on `ss-sec` (Ansible, TLS 1.2/1.3, digest-pinned images), SLA 7/30/90/180 days, CI uploads, exceptions mirrored as time-boxed risk acceptances; reimport churn found and fixed (#24, #25, #28) |
| SAST quality gate | SonarQube Community Build 26.9: forced authentication, private by default, gate "SecureStream" (0 new bugs, 0 new vulnerabilities, all hotspots reviewed, coverage ≥ 70 %); a red gate stops signing and deployment (#29, #30) |
| Exception policy | `security/exceptions.yaml`: id, tool, rule, path, reason, owner, created, expires (max 90 days), validated by the `exceptions-check` job on every pipeline |
| Shared CI templates | Separate project `securestream/ci-templates`, consumed by protected tag (`v1.1.0`), all image digests in one file ([ADR-0009](adr/0009-separate-ci-templates-project.md), #34) |
| Kubernetes posture scanning | Kubescape (NSA + MITRE, pinned by SHA256) run with the read-only identity; compliance 64.3, 0 Critical, High findings assessed with owners in [security controls](security-controls.md) §4 |

## 12. Observability and GitOps

- **Monitoring**: kube-prometheus-stack (Prometheus, Grafana, node-exporter, kube-state-metrics), Loki single
  binary, Grafana Alloy for pod logs through the API (no hostPath), Falcosidekick forwarding Falco events to Loki.
  Grafana is served over TLS from the lab CA; anonymous access and sign-up are off; the admin password is generated
  inside the cluster by an External Secrets generator and never leaves it. Dashboard "SecureStream Security":
  Falco events by priority, Kyverno policy results, catalog-api request and error rate, node resources.
  Installed 2026-10-24; the end-to-end check (shell in a container → Falco → Falcosidekick → Loki) passed.
- Before the install: a `helm template` diff proved that adding Falcosidekick leaves the Falco DaemonSet unchanged,
  and a capacity check compared the new charts' requests (~780m CPU, ~1.9 GiB) with the cluster's allocatable.
- node-exporter needs `hostNetwork`, `hostPID` and read-only host mounts: recorded as a reasoned Pod Security
  exception with compensating controls and a review date ([security controls](security-controls.md)).
- **SBOM monitoring**: Dependency-Track 4.14.5 on `ss-sec`; the pipeline uploads the image's CycloneDX SBOM with a
  least-privilege CI team.
- **GitOps**: Argo CD with an AppProject limited to this repository and an Application for the platform manifests
  with **manual sync** — drift becomes visible, applying stays a human decision. Repository access uses a
  read-only GitLab deploy token that is rotated by creating the new token, proving it works and only then revoking
  the old one. The installer's GitLab snippet failed twice on version differences before creating anything (#37, #39).

## By the numbers

| | |
|---|---|
| VMs | 9 (8 by Terraform; the bastion was built by hand and is a documented exception, #14) |
| Platform commits | 95+ on `main`, each through the same CI gates |
| Architecture decisions | 9 ADRs |
| Lessons learned | 39 recorded incidents, each with root cause and the control it changed |
| Runbooks | 4 (Vault unseal, secret leak first 30 minutes, rejected unsigned image, credential rotation) |
| Pinned versions | `platform/versions.conf`, CI images by digest in `securestream/ci-templates` |

## Where it stands, and what is next

Status per requirement is tracked in [requirements traceability](requirements-traceability.md); open risks and the
roadmap are in [security controls](security-controls.md) and the [CHANGELOG](../CHANGELOG.md). Main open items:
Kubescape High fixes (Falco least privilege, read-only CA mounts, resource limits), alert routing, kubelet
benchmarks (kube-bench), SLSA provenance, GitLab 2FA, and a separate Unix user for the AI assistant.
