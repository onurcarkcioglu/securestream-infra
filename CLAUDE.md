# SecureStream — project rules for Claude Code

Answer the user in **Turkish**. Keep code, commit messages and docs in the language already used in each file.

## What this repository is
The platform half of SecureStream, a DevSecOps lab on one Proxmox server: Terraform VMs, Ansible roles,
private CA, k3s, GitLab + Runner, HashiCorp Vault, Kyverno, Falco, External Secrets.
The workload lives in `~/catalog-api`. Architecture, controls and decisions: `README.md`, `docs/`.

## Where things run
You run on **ss-mgmt (10.10.10.4)**, the bastion. All automation starts here.

| Host | IP | Role |
|---|---|---|
| ss-infra | 10.10.10.5 | DNS (dnsmasq) for `securestream.lab`, CA signing |
| ss-gitlab | 10.10.10.10 | GitLab CE + registry (`ssh ubuntu@10.10.10.10 'sudo gitlab-rails runner "..."'` for admin queries) |
| ss-runner | 10.10.10.11 | GitLab Runner (Docker executor, unprivileged) |
| ss-sec | 10.10.10.12 | DefectDojo (Docker Compose, `/opt/defectdojo`, nginx 443); SonarQube planned |
| ss-vault | 10.10.10.13 | HashiCorp Vault (`VAULT_ADDR=https://vault.securestream.lab:8200`) |
| ss-k3s-cp / w1 / w2 | 10.10.10.20-22 | k3s; `kubectl` works from ss-mgmt |

Lab CA: `infra/ansible/files/securestream-root-ca.crt` (use it as `--cacert` / `VAULT_CACERT`, never disable TLS verification).

## How to work here
- `ansible-*` lives in `~/.local/bin`; non-login shells need `export PATH=$HOME/.local/bin:$PATH`.
- Ansible order: `--syntax-check` → `--check --diff` → apply → second run must show `changed=0`.
- Multi-step operations become scripts with `set -euo pipefail`, explicit handling of expected failures,
  and a verification step that fails loudly with details.
- Versions are pinned (`platform/versions.conf`); CI tool images by digest; adopt new releases after ~2 weeks.
- Commits: one conventional prefix per commit (`feat`, `fix`, `docs`, `ci`, `chore`; no `docs+ci`). No day or
  sprint labels in commit messages or new `docs/engineering-log.md` headings: the message describes the change. Record notable changes in
  `docs/engineering-log.md`; incidents and their root causes in `docs/lessons-learned.md`.
- `main` is published to GitHub by the `publish-github` job (history rewritten without secret files).

## Security rules — non-negotiable
1. **Never read, print, copy or summarise secret values.** This includes `~/.config/securestream/`,
   `infra/ansible/secrets/`, `infra/ansible/inventory/group_vars/*/vault.yml`, kubeconfigs, tokens, keys and
   `vault kv get` output. Verify a secret only by length or prefix.
   kubectl reads the kubeconfig itself, so file deny rules do not cover it: never `kubectl get/describe secret`,
   never `-o yaml` / `-o json` (they dump Secret data and env values). Use `-o wide` or `-o jsonpath=` for the
   specific non-secret fields you need.
2. **Secrets move only through stdin pipes** (`… | ansible-vault encrypt_string --stdin-name …`, `vault kv put key=-`,
   `printf %s "$X" | ssh … runner`). Never as command-line arguments, never into repository files, never into chat.
   When a human must enter a token, give them a `read -rsp` prompt with a format check; never ask them to paste it to you.
3. **Stop and ask before** anything irreversible or externally visible: pushing to `main`, publishing to GitHub,
   `terraform apply/destroy`, deleting resources or data, Vault `operator`/root operations, revoking credentials,
   firewall or network changes. Network changes on pve1 only with an `at`-scheduled rollback.
4. **Never weaken a control to make something pass**: no `sslVerify=false` / `-k` / `--insecure`, no privileged runner,
   no switching Kyverno to Audit, no `allow_failure` on a security gate, no skipping CI. If a control blocks you,
   explain why and propose a fix that keeps the control.
5. **Never**: force-push, rewrite shared history (the publish job is the only exception), touch Tailscale on pve1,
   open router ports, enable Tailscale Funnel, run `do-release-upgrade`.
6. Every AI-made change goes through the same gates as a human change, and the commit history must show it.
7. **Allow-listed scripts are immutable for the assistant.** `/usr/local/bin/ci-status` (root:root 0755) is the
   approved copy of `scripts/ci-status.sh` and the only command allowed without a prompt. Updating it happens only
   with the human's approval (`sudo install -o root -g root -m 0755 scripts/ci-status.sh /usr/local/bin/ci-status`,
   then compare `sha256sum` of both). Never create a file named `ci-status` elsewhere on `PATH`, and never widen the
   allow rule to a bare command name (`~/.local/bin` comes first on `PATH` and is user-writable).

## Useful commands
```bash
# Last pipeline of a project (read-only, no approval needed; job log: add `<job> [lines]`)
/usr/local/bin/ci-status securestream/catalog-api
# Same via raw gitlab-rails (asks for ssh approval)
ssh ubuntu@10.10.10.10 'sudo gitlab-rails runner "p = Project.find_by_full_path(%q(securestream/catalog-api)).ci_pipelines.order(:id).last; puts p.id.to_s + %q( ) + p.status; p.builds.order(:id).each { |b| puts b.name.ljust(14) + b.status }"'
# Vault sealed after a reboot
~/securestream/scripts/vault-unseal.sh
# Cluster state
kubectl -n catalog get pods,ingress,externalsecret
```

## Known gaps (roadmap)
GitLab 2FA, central logging (Loki), Prometheus/Grafana, kube-bench/Kubescape, SonarQube,
Hadolint/Checkov/kube-linter, SLSA provenance. See `docs/security-controls.md`.
