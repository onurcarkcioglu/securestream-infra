# Platform security expansion — progress

Brief: `docs/tasks/platform-security-expansion.md` (kept local). One row per item, appended when the item is done.

| Item | Status | Commit | Evidence |
|---|---|---|---|
| 0 Housekeeping | Done | `docs: gunluk.md engineering-log.md olarak yeniden adlandirildi` | `git log --follow docs/engineering-log.md` shows full history; `grep -rn gunluk.md` → no references; no personal wording left except authorship (LICENSE, GitHub URLs) |
| 1 Capacity check | Done (no resize needed) | `feat: pve1 kapasite betigi (salt okunur, Proxmox API)` | See capacity report below |

### Capacity report (2026-10-23)

| Resource | Requirement | Measured | Result |
|---|---|---|---|
| ss-sec RAM | ≥ 10 GB | 16 GiB in Terraform (`vms.tf`), `free -h`: 15 Gi total, 15 Gi available | OK |
| ss-sec vCPU | ≥ 4 | 8 (`nproc`) | OK |
| ss-sec disk | ≥ 60 GB | 120 GB in Terraform, `/` 116 G, 114 G free | OK |
| k3s free RAM for monitoring | ~3 GB | `kubectl top nodes`: cp 1.7/7.8 GiB, w1 0.8/15.6 GiB, w2 0.8/15.6 GiB used | OK (~35 GiB free) |
| pve1 storage | — | `local-lvm` 724 GiB free of 793, `local` 80 GiB free | OK |
| pve1 RAM / CPU totals | — | Not readable: the `terraform@pve` token has no `Sys.Audit` (HTTP 403). VMs allocated: 54 vCPU, 95 GiB RAM (all running) | **Human check:** read pve1 total RAM in the Proxmox UI; no new VM is added, so the plan does not raise the allocation |

Decision: no `tf.sh apply` needed. Items 4 and 5 run inside the existing ss-sec VM, Item 9 inside the existing k3s nodes.
Order kept as in the brief. Docker is not yet installed on ss-sec (Item 4 `appsec_host` installs it).
| 2 Dockerfile + Helm scanning | Done | catalog-api `0490699`, `74e6a51`, `1c72ce0`, `0ecca7d` | Pipeline 39 all green; hadolint 0 findings; checkov 96 checks, 4 failed, 4 excepted (EXC-0001), 0 blocking. Fixed: CKV_K8S_14/15/35/43. Negative tests: bad Dockerfile line → hadolint exit 1 (not committed); gate without exceptions / expired exception / empty report → exit 1; chart without or with non-sha256 digest → render error |

### Notes and deviations (2026-10-23)

- Item 2 regression: the Secret-as-file change first deployed without `fsGroup` → admin endpoint 503 (caught by ZAP
  WARN 100000 in pipeline 38). Fixed in `0ecca7d`; after deploy: no key 401, wrong key 401. The 200 check needs the key
  from Vault: `scripts/catalog-admin-smoke.sh`, run by the human (open, see final report).
- Checkov runs with `--soft-fail` + `scripts/scan-gate.py` as the decision. This is not a relaxation: the gate fails on
  every finding without a valid exception and also on an empty report, which plain checkov would not.
- Side task (human request): `scripts/ci-status.sh`, approved copy `/usr/local/bin/ci-status` (root:root 0755).
  Deviation: allow rule on the absolute path `Bash(/usr/local/bin/ci-status *)` instead of the requested
  `Bash(ci-status *)`, because `~/.local/bin` is first on `PATH` and user-writable (shadowing would bypass the control).
- Decision (human): the deny rules `kubectl * -o yaml*` / `-o json*` (which also match `-o jsonpath=`) stay until Item 8.
  Until then use `-o wide` / `-o custom-columns`. In Item 8, after `can-i` tests with the `claude-readonly` kubeconfig,
  remove them and record in lessons learned: "the boundary moved from text matching to RBAC".
- Remote branch `ci/hadolint-checkov` (catalog-api, merged) still exists; deleting it is left to the human.
| 3 Multi-cloud IaC scanning | Done | `2f8c266`, `d2a950c`, `f82ac12` | Branch pipelines 41 and 43 green (`iac-scan`, `iac-scan-insecure`); | Local: `iac-scan.sh gate` 4 modules (proxmox 18, aws 38, azure 40, gcp 24 checks), 0 blocking, 2 excepted; negative copy of aws/insecure in scope → 25 blocking, exit 1; `report`: AWS 25, Azure 30, GCP 11 findings, all 10 expected rules caught |

- Resolved (human decision): `secret-scan` in this repository had `allow_failure: true` (since `8c8c8a0`). Now a
  blocking gate, and `publish-github` needs it. Deviation from the approved plan: **no** `.gitleaks.toml` allowlist,
  because gitleaks reports no finding on the full history today (local run and CI log); an allowlist would only hide
  a future plain-text secret on those paths. The requested `$ANSIBLE_VAULT` check was added
  (`scripts/check-vault-encrypted.sh`, same path patterns as the publish filter; tested with fake files: plain-text
  file → FAIL, no files → FAIL).
| 2b secret-scan gate (human request) | Done | `077019f`, `a6433f1` | Pipeline 43: vault check 4/4 OK (3 per-variable, 1 whole file), gitleaks 52 commits, no leaks; `allow_failure` removed; first version of the check failed on per-variable encryption (fixed, see ai-assisted-engineering) |

- Correction (human request): deny rules against branch deletion in both repositories (`--delete`, `-d`, `:refspec`,
  `git branch -D`). Deviation: the requested `Bash(git push * :*)` did not block `git push --dry-run origin :x` (trailing
  `:*` is Claude Code's legacy prefix syntax); replaced by `Bash(git push * :**)`, which blocks it. Evidence: verification
  log in `docs/ai-assisted-engineering.md`, lessons learned #23.

| 5 DefectDojo + vulnerability management | Done (one check open, see notes) | `5f9be86`, `584ac3c`, `7a23241`, `eeba99e`, `a014fc3`, `3b5929a`; catalog-api `4950184`, `b16fad8`, `ca60383`, `e695db2` | `appsec.yml` second run `changed=0`; TLS: lab CA only (public-CA test fails with isolated `capath`), TLS 1.0/1.1 refused server-side, unknown SNI refused, ports 80/8080 closed; admin password 0 lines in container log. Pipelines 51 + 52 green: 7 + 4 reports reimported, Risk Acceptances `catalog-api:EXC-0001` (4 findings), `securestream-platform:EXC-0101/0102` (1 each), all `risk_accepted`, expire 2027-01-21. `exceptions-check` negative tests: expired, > 90 days, duplicate id, missing field, unknown tool, future date, bad date → exit 1. `DD_API_KEY`: length 40, protected/masked/hidden (set by the human with `defectdojo-ci-token.sh`) |

### Item 5 notes (2026-10-23)

- Deviation: no per-product role `API_Importer`. DefectDojo 3.x OSS has no RBAC (moved to Pro); CI user `gitlab-ci` is
  non-staff in `authorized_users` (view/add/edit/import, no delete). Lessons learned #24.
- Deviation: DefectDojo versions pinned in `group_vars/security/main.yml` (like `gitlab_version`), not in
  `platform/versions.conf`, which feeds `platform/install.sh` for k3s.
- Open check: `trivy-image` churn fix (`3b5929a`/`e695db2`). The first pipeline after it still churns once (old findings
  carry the digest path); the next catalog-api pipeline must show `trivy-image … created=0 closed=0`. To be checked
  on the first Item 4 pipeline.
- Admin login: user `admin`, password in `infra/ansible/inventory/group_vars/security/vault.yml`
  (`vault_dd_admin_password`, ansible-vault). The value was never shown.
- CI token expires after 90 days (all DefectDojo API tokens): rotate with `scripts/defectdojo-ci-token.sh` before 2027-01-21.
- Not done: DefectDojo backup (PostgreSQL volume), recorded in `docs/vulnerability-management.md` as roadmap.

## Handoff (session stopped on request, 2026-10-23)

Next order (human decision): **Item 5 (DefectDojo) → Item 4 (SonarQube) → Item 8 (read-only kubeconfig)**;
Items 6, 7, 9, 10 only if the weekly limit allows.

Open for the human:
1. Run `scripts/catalog-admin-smoke.sh` (needs `vault login`): expects 401 / 401 / 200. The assistant verified 401 and
   401 only (no Vault token by design).
2. Remote branch `ci/hadolint-checkov` (catalog-api, merged) and `feat/iac-scan` (securestream, merged): delete or keep.
3. pve1 total RAM/CPU: read in the Proxmox UI (token has no `Sys.Audit`), see capacity report.

Notes for the next session:
- Local scanners were installed in the session scratchpad and are gone: hadolint v2.15.1 (verify with the release's
  `checksums.sha256`), `pip install checkov==3.3.26` in a venv. CI images are pinned (catalog-api `.gitlab-ci.yml`).
- `scripts/scan-gate.py` exists in both repositories (identical); Item 6 makes securestream the single source.
- Item 5 must import hadolint (`hadolint.json`), checkov (`checkov-helm.json`, `iac-reports/*.json`) and use
  `security/exceptions.yaml` of each repository for the Risk Acceptances.
- `kubectl -o yaml/json` deny rules stay until Item 8 (human decision, see notes above).
- Pipeline status without ssh approval: `/usr/local/bin/ci-status <group/project> [job] [lines]`.

| 4 SonarQube + Quality Gate | Done | `c26ab67`, `c76d6a5`, docs commit; catalog-api `886d080` | `appsec.yml` second run `changed=0`; TLS lab CA only (public CA fails with isolated `capath`), 9000/80/5432 not reachable from outside, anonymous API 401, `admin/admin` invalid, admin password 0 lines in container logs. `SONAR_TOKEN`: length 44, prefix `sqp_`, protected/masked/hidden. Pipeline 58 (`main`) all 15 jobs green: `QUALITY GATE STATUS: PASSED`, coverage 100 % parsed, SCM blame 2/2 files. Negative test (local, detached commit, never pushed): TLSv1 + `CERT_NONE` helper → `new_vulnerabilities=3`, gate ERROR, coverage still 100 %; reverted → gate OK with `new_bugs=0`, `new_vulnerabilities=0` |

### Item 4 notes (2026-10-23)

- Item 5 open check closed: pipeline 58 `trivy-image … created=0 closed=0 reactivated=0 untouched=170`.
- Deviation: "current long-term release" does not exist for Community Build (LTA is a paid-edition release). Chosen:
  newest Community Build older than two weeks (26.9.0.129388, 2026-10-02; 26.10 is 6 days old).
- Deviation: PostgreSQL 16.14 instead of 16.15: every 16.15 digest was re-pushed on 2026-10-22. Upgrade after 2026-11-05.
- Deviation: the `sonarqube` job runs on `main` only. `SONAR_TOKEN` is protected (brief) and Community Build analyses only
  the main branch anyway. A red gate stops `sign` and `deploy` (`needs`), not the merge. Branch/MR analysis would need
  a paid edition.
- New code = changes since the first analysis until an analysis older than 30 days exists. The first `main` analysis
  (pipeline 58) is the baseline; existing code is clean on overall measures (0 bugs, 0 vulnerabilities, 0 hotspots,
  coverage 100 %, 3 code smells). Lessons learned #29.
- Server mode: Standard Experience (set via API v2) so the gate can use bugs and vulnerabilities as the brief defines.
- Local verification project `catalog-api-local` stays on the server (2 + 1 analyses, used again by
  `scripts/sonarqube-local-scan.sh`); delete it in the UI if not wanted.
- SonarQube findings are not imported into DefectDojo (not in Item 5's list); roadmap.
- Observation: `defectdojo-upload` updates the Risk Acceptance `catalog-api:EXC-0001` (`accepted_findings`,
  `expiration_date`) on every run; harmless, not idempotent. Not fixed yet.
- Remote branches `ci/sonarqube`, `docs/sonarqube` (catalog-api): merged, left for the human to delete.
