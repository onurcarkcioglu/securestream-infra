# ADR-0009: Shared CI templates in a separate project, consumed by tag

**Status:** accepted · **Date:** 2026-10-23

## Context
The security jobs (gitleaks, Semgrep, Trivy, Checkov, hadolint, SonarQube, exception check, DefectDojo upload), the
pinned tool images and three helper scripts (`scan-gate.py`, `exceptions-check.py`, `defectdojo-upload.py`) were
duplicated in `securestream` and `catalog-api`. A new project could not join the chain without copying them.

Templates can be included from any project the pipeline user can read, but the helper scripts must be fetched at
run time with `CI_JOB_TOKEN`. The first proposal was to keep templates and scripts in `securestream` and add
`catalog-api` to its job token allowlist. That would have let every `catalog-api` job read the whole platform
repository: Ansible-Vault-encrypted files, Terraform, inventory. Rejected by the human reviewer as too broad.

## Decision
- New private project `securestream/ci-templates` with only templates, helper scripts and the hash-pinned
  `requirements-ci.txt`. No secrets, no infrastructure code.
- `templates/images.yml` is the only place where CI tool images are pinned by digest (`scripts/pin-images.sh`).
- Job `ss-tools` (`.pre`) clones `ci-templates` at `SS_CI_REF` and passes the scripts as the `.ss-tools/` artifact.
- Consumers include a **tag**, never a branch; `include: ref` and `SS_CI_REF` are one YAML anchor, so they cannot
  drift. Tags `v*` are protected (Maintainer only). Release: change, own pipeline green, release candidate tag
  tested in consumer branch pipelines, then the final tag on the same commit.
- Job token: inbound allowlist of `ci-templates` contains only `securestream/catalog-api` and
  `securestream/securestream`; the allowlist of `securestream` is unchanged.
- `ci-templates` runs its own pipeline: `lint` (ruff, YAML, digest check, shell syntax) and `secret-scan`
  (its own template).

## Consequences
- Verified: `catalog-api` jobs can read `ci-templates`, not `securestream`; first tag `v1.0.0` (= `v1.0.0-rc.2`,
  `fb5442c`) gave identical results in both consumers (catalog-api pipeline 70, securestream pipeline 71).
- Every consumer pipeline depends on `ci-templates` being reachable; a template change reaches a project only when
  that project raises its tag (reviewed in its own merge).
- A protected tag can still be deleted and recreated by a Maintainer; pinning the include to a commit SHA would be
  stricter. `ss-tools` logs the commit it fetched and the SHA-256 of every script.
- Template job variables override a consumer's global variables, so templates take defaults inside the script
  (`${VAR:-default}`), never as job variables.
