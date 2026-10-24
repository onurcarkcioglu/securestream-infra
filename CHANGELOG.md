# Changelog

All notable changes to the SecureStream platform. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the platform is not versioned, so entries are grouped by
date. The narrative version is [docs/project-history.md](docs/project-history.md); incidents and root causes are in
[docs/lessons-learned.md](docs/lessons-learned.md).

## [Unreleased]

### Added
- Project history, changelog and documentation index for the public repository.
- Security alerting: 8 Prometheus rules (Falco, Kyverno, cert-manager, catalog-api) with promtool unit tests,
  Falcosidekick and cert-manager scrape targets, "Firing security alerts" dashboard panel.
- `scripts/platform-render-check.sh`: renders every platform chart and enforces requests/limits and namespace PSA levels.
- Pod Security Admission level for every platform namespace (`platform/manifests/namespaces.yaml`).
- Default-deny ingress NetworkPolicies for the platform namespaces, a per-namespace rollout script with
  automatic rollback and a selector/port check against live pods.
- CIS node benchmark with kube-bench (`k3s-cis-1.9`) through Ansible; raw reports are sanitised on the node.

### Security
- SLSA v1 build provenance for catalog-api images: provenance generated and verified in CI (pipeline 105); admission
  enforcement rolled back after failed positive test, root cause open. The cluster keeps the signature-only policy.
- Kubescape High findings fixed in values: Falco least privilege, Kyverno without hostPath (lab CA from a
  ConfigMap), MetalLB without the frr-k8s BGP backend, requests and limits for every container.
- node-exporter moved to its own namespace; `monitoring` enforces `baseline`.
- k3s PKI certificates 0600 (CIS 1.1.20); default ServiceAccounts no longer mount tokens; argocd-redis and the
  demo app stop using the default ServiceAccount (CIS 5.1.5/5.1.6).
- Argo CD ApplicationSet controller really disabled (`replicas: 0`; the old key was ignored by the chart).

### Changed
- Applied to the cluster on 2026-10-24: namespace PSA levels and default ServiceAccount token settings
  (`install.sh`), Falco least privilege and node-exporter namespace (`install-monitoring.sh`), Argo CD repository
  access with deploy token rotation (`install-argocd.sh`). Platform NetworkPolicy rollout deferred.
- `platform/install.sh` installs Kyverno and External Secrets with values files and verifies the result.
- Published documents use workstream names instead of internal item and sprint labels.

## 2026-10-24

### Added
- Monitoring stack installed: kube-prometheus-stack 92.2.0, Loki 7.3.0, Alloy 1.13.1, Falcosidekick → Loki;
  end-to-end Falco → Loki evidence passed.
- Pod Security Admission exception for node-exporter (`hostNetwork`, `hostPID`, read-only host mounts) with
  compensating controls and a review date.
- Argo CD 10.10.2 installed (repository access pending the installer re-run).

### Fixed
- `install-argocd.sh`: deploy token rotation creates and verifies the new token before revoking old ones; GitLab
  19.x service class; ISO 8601 expiry date with a `valid?` dry run before creation.
- `install-monitoring.sh`: stops early with a clear message when Falco is not installed; connection errors in the
  verification show the HTTP code.

## 2026-10-23

### Added
- Claude Code project rules, permission rules and a verification log for AI-assisted engineering.
- GitLab-managed Terraform state with encrypted backup and verification scripts.
- Read-only CI status script with a root-owned allow-listed copy.
- Scan-only AWS, Azure and GCP Terraform samples, custom Checkov rules for `bpg/proxmox`, `iac-scan` gate.
- DefectDojo 3.3.300 (vulnerability management), `exceptions-check` gate, CI uploads with time-boxed risk acceptances.
- SonarQube Community Build 26.9 with the "SecureStream" Quality Gate.
- Read-only Kubernetes identity `claude-readonly` for the AI assistant; admin kubeconfig moved to `root:root 0600`.
- Shared CI templates project `securestream/ci-templates` (tags `v1.0.0`, `v1.1.0`).
- Kubescape posture scanning (NSA, MITRE) with sanitized reports.
- Dependency-Track 4.14.5 for continuous SBOM monitoring.
- Monitoring stack and Argo CD prepared (values, manifests, installers).
- Requirements traceability matrix and AI guardrails summary.

### Security
- Proxmox API TLS verification enabled (hypervisor CA trusted only by the Terraform process).
- Secret scan became a blocking gate; secret paths must carry the Ansible Vault header.
- Deny rules for branch deletion and for `kubectl get/describe secret`; Ansible secret tasks no longer print diffs.

## 2026-10-22

### Added
- Terraform for 8 lab VMs and a generated Ansible inventory.
- Ansible roles: baseline hardening, split DNS, two-tier lab CA with name constraints, reusable certificate role.
- k3s with secrets encryption and API audit log; MetalLB, Traefik, cert-manager.
- GitLab CE 19.5.1 with registry; unprivileged GitLab Runner and a smoke-test pipeline with a negative TLS check.
- Kyverno image signature verification, namespace-scoped deploy RBAC, Falco (modern eBPF).
- HashiCorp Vault 2.1.2 (TLS, Raft, audit) and External Secrets with Vault Kubernetes auth.
- README, security control mapping (OWASP CI/CD Top 10, NIST SSDF, SLSA), threat model, ADRs, runbooks and the
  sanitized GitHub mirror.

### Changed
- Traefik instead of ingress-nginx (retired upstream, no security fixes).
