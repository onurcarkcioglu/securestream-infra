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
