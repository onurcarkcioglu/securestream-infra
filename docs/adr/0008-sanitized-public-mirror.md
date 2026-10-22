# ADR-0008: GitLab as source of truth, sanitized public mirror on GitHub

**Status:** accepted · **Date:** 2026-10-22

## Context
The project should be public as a reference, but the repository contains Ansible-Vault-encrypted files
(including Vault unseal keys). Encrypted is not the same as safe to publish: once public, an attacker has
unlimited time to attack the password.

## Decision
- `catalog-api` (no secrets) is a GitLab push mirror of the protected `main` branch only.
- `securestream-infra` is published by a pipeline job that rewrites history with `git filter-repo` to
  remove `infra/ansible/secrets/` and every `inventory/group_vars/*/vault.yml`, runs gitleaks on the result, and only then pushes.
- The mirror credential is a fine-grained GitHub token: two repositories, contents only, 90-day expiry.

## Consequences
- Public history differs from the private one (commit hashes change) — documented in the README.
- Publishing is a controlled, auditable step instead of a manual push.
