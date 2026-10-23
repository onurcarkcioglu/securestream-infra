# Shared CI templates

Security jobs, helper scripts and every CI tool image digest live in the private project
`securestream/ci-templates` ([ADR-0009](adr/0009-separate-ci-templates-project.md)). Projects include a tag.

## Join the security chain in five lines

```yaml
include:
  - project: securestream/ci-templates
    ref: &ss_ci_ref v1.0.0
    file: [templates/secret-scan.yml, templates/sast.yml, templates/sca.yml, templates/exceptions-check.yml]
variables: { SS_CI_REF: *ss_ci_ref }
```

Prerequisites: stages `test`, `scan` (and `report` for DefectDojo) in the project's `stages`, a
`security/exceptions.yaml` (may be `exceptions: []`), the runner tag through `default: tags`, and the project on the
CI/CD job token allowlist of `ci-templates` (Settings → CI/CD → Job token permissions; a Maintainer adds it).

## Templates

| File | Job(s) | Runs when | Needs from the project |
|---|---|---|---|
| `secret-scan.yml` | `secret-scan` | every pipeline | — |
| `sast.yml` | `sast` (Semgrep) | every pipeline | — |
| `sca.yml` | `sca` (Trivy fs), base `.ss-trivy` | every pipeline | — |
| `iac-scan.yml` | `checkov-helm`, base `.ss-checkov` | `deploy/helm/**/Chart.yaml` exists | `CHECKOV_HELM_VALUES` (values file with an image digest) |
| `dockerfile-lint.yml` | `hadolint` | `Dockerfile` exists | — |
| `sonarqube.yml` | `sonarqube` | `main` and `sonar-project.properties` exists | protected `SONAR_TOKEN`; `coverage.xml` from a `unit-test` job |
| `exceptions-check.yml` | `exceptions-check` | every pipeline | `security/exceptions.yaml` |
| `defectdojo-upload.yml` | `defectdojo-upload` | `main`, also after red jobs | `DD_REPORTS` (`name=file[@base] …`) and/or `iac-reports/*.json`; `DD_PRODUCT` (default: project name); `DD_API_KEY` |

`images.yml` (all image digests) and `tools.yml` (job `ss-tools`) are pulled in by the templates.
Override a job by redefining keys with the same job name (for example `secret-scan: before_script: …` in
`securestream`). Set inputs as global `variables`; templates never set them at job level.

## Changing a template or an image
1. In `ci-templates`: change, for images `scripts/pin-images.sh NAME_IMAGE=image:tag` (~2-week cool-down), merge;
   its own pipeline (`lint`, `secret-scan`) must be green.
2. Tag a release candidate (`vX.Y.Z-rc.N`), point a consumer branch at it, compare the branch pipeline with `main`.
3. Tag `vX.Y.Z` on the same commit; raise the tag in each consumer through its normal review and pipeline.
