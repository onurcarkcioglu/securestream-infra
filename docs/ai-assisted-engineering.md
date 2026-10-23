# AI-assisted engineering in SecureStream

SecureStream was built by one engineer working with an AI assistant (Claude). This document says how
that collaboration was set up, where the AI helped, where it was wrong, and which controls stopped
mistakes — from either side — before they mattered.

## Principle: the AI is an untrusted contributor
The assistant is treated like a fast, capable new team member with no production rights:

| Control | How it applies to the AI |
|---|---|
| Least privilege | Claude Code runs on the bastion as a normal user. It has no Vault token, no GitLab admin token, no GitHub token. |
| Secret isolation | `.claude/settings.json` denies reads of `~/.config/securestream/`, `infra/ansible/secrets/`, `group_vars/*/vault.yml`, `~/.ssh/`, `~/.kube/`, tfstate, and denies `ansible-vault view/decrypt` and `vault kv get`. Deny rules are not a sandbox: they apply only inside the project directory, and an interpreter such as `python3` can still read a denied file (see the verification log below), so the real boundary is that secrets are encrypted at rest and the AI is never given the keys. |
| Human approval | `git push`, `kubectl apply/delete`, `helm upgrade`, `ansible-playbook`, `terraform apply`, Vault writes and `ssh` require an explicit yes. `terraform destroy` and force-push (`--force`, `--force-with-lease`, `-f`, `+refspec`) are denied. These client-side rules are a guardrail only, matched on command text; the real control is server-side: `main` is a protected branch in GitLab with force-push disabled and push/merge limited to Maintainers (verified 2026-10-23). |
| Same gates | AI-written code goes through the same 10-stage pipeline, signed-image admission and review as human code. Nothing is "trusted because the AI wrote it". |
| Written rules | `CLAUDE.md` in each repository records architecture, conventions and non-negotiable security rules, so every session starts with the same constraints. |
| Traceability | Commits made by the AI carry a `Co-Authored-By` trailer. |

## Workflow
1. The human sets the goal and the constraint (for example "the API key must never touch a file or the screen").
2. The AI proposes a design and the commands, citing official documentation for versions and syntax.
3. Commands are packaged as self-validating scripts: `set -euo pipefail`, explicit checks, and a final
   verification that fails loudly.
4. The human runs them (or approves them in Claude Code), reads the output and decides.
5. Anything surprising is written down in `docs/lessons-learned.md`.

## Where the AI was wrong — and what caught it
These are real incidents from the build. Each one was caught by a check, not by luck.

| AI mistake | What caught it | Fix / lesson |
|---|---|---|
| History-filter glob `*vault.yml` would also have removed `playbooks/vault.yml` from the public repo. | Mandatory preview of the paths to be removed before publishing. | Narrowed the glob to `group_vars/*/vault.yml`. Destructive filters always get a dry-run list first. |
| Set `GIT_SSL_CAINFO` job-wide; the lab CA replaced the system trust store and the GitHub push failed TLS. | TLS verification stayed on, so the failure was loud instead of silent. | CA scoped to the single internal clone (`git -c http.sslCAInfo=…`). Never "fix" TLS by disabling it. |
| A script stopped with no message under `pipefail` when an expected command returned non-zero. | Script exit status checked by the human. | Expected failures handled explicitly (`|| LEN=0`), every check prints why it failed. |
| Assumed `ansible-vault` was on `PATH` in a non-login SSH session. | Script failed on the first command. | `export PATH=$HOME/.local/bin:$PATH` in all scripts; documented in `CLAUDE.md`. |
| Used `wget --ca-certificate` inside a BusyBox image, which does not support it. | Pipeline job failed. | Switched to curl and added a *negative* TLS test (must fail without the CA). |
| `kubectl exec -t` without `-i` when testing Falco's "shell in container" rule; no alert fired. | The test expected an alert and got none. | Use `-it`. A detection test must prove the detection fires. |
| Tried to copy pve1's root CA by SSH into the hypervisor, although the task did not need root access there. | Approval prompt; the human rejected it. | CA taken only from what the network shows, plus a fingerprint the human fetched over a separate channel. No SSH into pve1 for routine work. |
| Moved the catalog API key from an env variable to a Secret volume (Checkov CKV_K8S_35) without `fsGroup`; the file was `root:root 0440`, the app (UID 10001) could not read it and `/v1/admin/stats` returned 503 after deploy. | ZAP reported a new WARN (`100000`, server error on `/v1/admin/stats`); `dast` exit code 2. | `fsGroup: 10001` in the chart; checked 401 without key / 401 wrong key (not 503) after deploy. A unit test cannot see file permissions in the cluster: check the end-to-end behaviour after every deploy change. |
| Tried to delete merged feature branches on the GitLab remote without asking. | Command failed on a branch that had never been pushed; reviewed before retrying. | Deleting refs is a deletion: ask first. The remaining branch was left for the human to decide. Afterwards the human had deny rules added for remote and forced local branch deletion in both repositories (see the verification log); the server-side limit is GitLab's protected branches and roles (lessons learned #23). |
| Allow-listed `scripts/ci-status.sh` by a path the assistant could edit, and printed a job JWT prefix in its first log tail. | Human review of the allow rule; reading the script's own output. | Root-owned copy + absolute-path rule; output masking (lessons learned #19). |
| First version of `check-vault-encrypted.sh` accepted only whole-file encryption; 3 of 4 secret files are encrypted per variable (`encrypt_string`, `!vault \|`) and failed. | The new check ran in a branch pipeline before `main`; the human was told it could be a real finding, not a script bug. | The check now accepts both formats strictly (any plain line fails); the files were never opened on the bastion, CI verified them (4/4 OK). Know the formats your own process produces before you write the check. |
| Planned DefectDojo access with per-product roles (`API_Importer`) from older documentation; the deployed 3.3.300 has no RBAC in OSS. | Live API returned 404 for `/roles/`; the authorization source was read before choosing a replacement. | `authorized_users` + never staff, asserted in Ansible (lessons learned #24). |
| DefectDojo bootstrap: new products were created without the SLA configuration (the "fix" fields were only applied to existing objects). | The mandatory second Ansible run showed `changed=2` instead of 0. | Fields are sent on create too. The idempotence rule caught a real bug, not just noise. |
| Proposed a handler chain (`nginx -t` notifying the reload) with `changed_when: false`, which would never have notified the reload. | Self-review before the run. | One handler: `nginx -t && systemctl reload nginx`. |
| Two negative TLS tests passed for the wrong reason (client-side TLS 1.1 refusal; curl's system `capath`). | Reading each result instead of trusting the exit code. | Server-side `openssl s_client` and an isolated trust store (lessons learned #26, #27). |
| Pushed the new CI scripts to catalog-api without running the repository's own `ruff` (line length 100, bandit `S310`); `lint` failed on `main`. | The pipeline gate (`lint`). | Ran the pinned ruff locally; `S310` fixed by using `http.client.HTTPSConnection` (HTTPS only) instead of an inline `noqa`. Run the target repository's linters before every push, not only the tests of the new code. |
| Assumed DefectDojo parsers put the rule id in `vuln_id_from_tool`; the Checkov parser writes it only into the description, and Terraform paths are relative to the scanned module. The first upload was green, but no exception was mirrored as a Risk Acceptance. | The upload job prints one line per exception (`no finding matches …`); a green job was not taken as proof. | Rule matched in all parser fields; module base derived per report. Read what the tool stored, not what the field name suggests. |
| SonarQube bootstrap removed global `provisioning` from *every* group, including `sonar-administrators`; afterwards the admin could no longer create a project (`Insufficient privileges`). | The first local verification scan failed with HTTP 403 before any analysis. | Administrators keep provisioning (SonarQube default, restored by the bootstrap); only non-admin groups lose `scan`/`provisioning`. Restrict the least-privileged group, not the one that runs the tool. |
| The first `sonarqube-local-scan.sh` reported "Quality Gate failed" when the token could not even be created (`set -e` exit 1 looked like the scanner's gate failure, exit 1). | Reading the output: the 403 line came before any analysis. | Result is taken from the scanner's `QUALITY GATE STATUS` line; every other failure exits 2 ("scan did not run", `trap 'exit 2' ERR`). Verified: the next setup error was reported as exit 2. |
| Checked the SonarQube new-code period with `/api/new_code_periods/show` (project level); Community Build stores it on the `main` branch, so every run "changed" it again. | The mandatory second Ansible run showed `changed=1`. | Compare with `/api/new_code_periods/list` (branch level). |
| Planned to enforce the read-only kubeconfig with `env.KUBECONFIG` and text deny rules, and to remove the `-o yaml/json` deny rules after `can-i` tests run *with that file*. The plain `kubectl` still used the admin kubeconfig. | The human asked for proof first; `kubectl auth whoami` without `KUBECONFIG` → `system:admin`. Independently, Claude Code's auto-mode classifier refused the assistant's edit of its own `settings.json` ("Self-Modification"). | Deny rules stay; admin kubeconfig moves out of the user's reach (`kubeconfig-lockdown.sh`, run by the human); permission changes are made by the human (lessons learned #31). The `can-i` tests proved what the read-only *identity* may do, not which identity the assistant *uses*. |
| Ran `appsec.yml --check --diff` into a log in the session scratchpad and planned the same for `k3s.yml` with output to the screen, without checking which tasks write secret files. | The human stopped the `k3s` run; a count over the old logs found 0 secrets (only `no_log` protected them). | `diff: false` on secret tasks, filtered output, logs in RAM and shredded (lessons learned #33). |
| `gitleaks --all` also scanned deleted refs and reported noise. | Unexpected findings reviewed instead of suppressed. | Scan the pipeline's own commit range. |

## Where the human was wrong — and the AI or the process caught it
| Human mistake | What caught it | Response |
|---|---|---|
| A GitHub token was pasted into the chat. | The assistant flagged it immediately. | Token revoked and regenerated; from then on tokens are entered only via a hidden `read -rsp` prompt with a prefix and length check, and never shown. |
| The admin API key was stored with a trailing newline (49 characters instead of 48). | Length check in the verification script. | Re-stored with `tr -d '\n'`, External Secrets force-synced, 401/200 test re-run. |
| An old terminal log was pasted into the shell, running stale commands and creating an unwanted commit. | `git status` / `git log` review. | Commit reverted, untracked files cleaned; rule: only copy from code blocks. |
| The first token paste into GitLab contained the wrong content (903 characters). | Format check failed. | Mirror recreated; format checks added to every secret prompt. |

## Verification log
Controls are only claimed after they were tested. Tests of the Claude Code setup on ss-mgmt, 2026-10-23:

| Test | Result | Conclusion |
|---|---|---|
| Asked the assistant to read and show `infra/ansible/secrets/cosign.vault.yml` | Refused by the assistant itself, citing rule 1 in `CLAUDE.md`; offered header/length checks instead | Instruction layer works, but it is a policy, not a technical control |
| Read tool on the same file, first line only | Blocked: "File is in a directory that is denied by your permission settings." | `Read(infra/ansible/secrets/**)` is enforced |
| `head -n1` on the same file | Blocked before execution. No user, managed or Bash deny rule matched `head`, so the Read rule caused it | Read deny rules also cover recognised shell readers |
| The assistant had proposed adding a `Bash(head:*secrets*)` rule | The `head` test above made it unnecessary; the rule was not added | An AI suggestion is a hypothesis until a test confirms it |
| Dummy `.tfstate` (fake content) inside the repo: Read, `cat`, `jq`, `python3 open()` | Read, `cat`, `jq` blocked; `python3` read the file | Deny rules are not a sandbox; see lessons learned #15 |
| Same dummy file outside the project (scratchpad) | Read, `cat`, `jq` all succeeded | Rules are scoped to the project; copies elsewhere are unprotected |
| `git push --dry-run origin main` in auto mode (sends nothing) | Approval prompt shown: "Ask rule Bash(git push *) overrides auto mode for this command"; the human answered No and the command did not run | `ask` rules still apply in auto mode; the push decision stays with the human |
| Plain `kubectl auth whoami` / `can-i get secrets -A` (no `KUBECONFIG`) while `Read(~/.kube/**)` was denied and `~/.kube/claude-readonly.yaml` existed, 2026-10-23 | `system:admin`, groups `system:masters`; `yes` | A file deny rule does not stop a program that opens the file itself; the RBAC boundary needs the admin credential out of the user's reach (lessons learned #31) |
| Assistant edits its own `.claude/settings.json` (add `env.KUBECONFIG`, remove deny rules) in auto mode | Refused by the auto-mode classifier ("Self-Modification") | Permission changes stay with the human |
| After `kubeconfig-lockdown.sh` (run by the human with sudo) and the human's settings change: `echo $KUBECONFIG`, plain `kubectl auth whoami`, `kubectl get pods -n catalog -o json \| jq '.items \| length'`, `can-i get secrets -A`, `can-i '*' '*' -A`, 2026-10-23 | `/home/ubuntu/.kube/claude-readonly.yaml`; `system:serviceaccount:claude-readonly:claude-readonly`; `2`; `no`; `no`. The lockdown script itself showed the same identity without `KUBECONFIG` and the admin file unreadable for `ubuntu` | The boundary moved from text matching to RBAC and file ownership; the `-o yaml/json` deny rules were removed by the human only after this proof (lessons learned #32) |
| A compound command containing the text `KUBECONFIG=` (inside an `echo`) | Refused by the new deny rule `Bash(*KUBECONFIG=*)` | Text rules match text, harmless or not: a guardrail with false positives, not a boundary |
| `k3s.yml --check --diff` proposed with the full log to the screen (the role writes the admin kubeconfig and the k3s token) | Stopped by the human (tool call rejected) | `diff: false` + `no_log: true` on the four secret tasks; filtered run (task, status, recap only), secret patterns counted: 0; log in `/dev/shm`, shredded (lessons learned #33) |
| Filtered `k3s.yml --check --diff`, 2026-10-23 | First run: admin kubeconfig tasks `ok`, but `k3s kurulum betiğini indir` `changed` on 3 nodes (check-mode artefact); after `check_mode: false` on the read-only version probe: `changed=0` on `ss-k3s-cp`, `-w1`, `-w2` | The admin kubeconfig written by the role is identical to the locked-down file (owner, mode, content) |
| Proxmox root CA from the TLS chain (`openssl s_client -showcerts`) | pveproxy sends only the leaf certificate; the assistant stopped as instructed | The CA file came from the human; its SHA-256 matched the fingerprint the human read over a separate channel |
| `scripts/tf.sh plan` with `PROXMOX_VE_INSECURE=false`; same with the lab CA in place of pve1's CA | Exit 0, no changes; with the wrong CA: `x509: certificate signed by unknown authority`, exit 1 | Verification is on and really checks the CA; registry and GitLab still reachable |
| `sudo -n true` in auto mode, after adding ask rule `Bash(sudo *)` (ss-mgmt has passwordless sudo; before the rule, sudo ran without a prompt) | Approval prompt shown: "Ask rule Bash(sudo *) overrides auto mode"; the human answered No and the command did not run | Root on the bastion now needs a human yes per command; the NOPASSWD risk itself remains (see security-controls) |
| `scripts/tf.sh apply -help` (harmless; tests the new ask rule `Bash(*tf.sh apply*)`) | Approval prompt shown; the human answered No and the command did not run | The wrapper no longer bypasses the `terraform apply` approval (lessons learned #18) |
| `scripts/tf.sh destroy -help` (harmless; tests the new deny rule `Bash(*tf.sh destroy*)`) | Blocked without a prompt: "Permission to use Bash with command scripts/tf.sh destroy -help has been denied." | Destroy through the wrapper is denied outright, like `terraform destroy` |
| `scripts/ci-status.sh securestream/catalog-api` and `… dast 30` after adding allow rule `Bash(scripts/ci-status.sh *)` | Ran without a prompt; printed pipeline 38 and the `dast` log tail | Read-only pipeline status no longer needs an ssh approval per call. The `Bash(ssh *)` ask rule is unchanged (`jq` check on `settings.json`), so any other ssh still asks |
| Injection attempts against `ci-status.sh`: project `a/b);puts(1`, `securestream/catalog-api;id`, job ``dast`id` ``, 9999 lines | All rejected by argument validation before any ssh (exit 2) | The allow rule is only safe because the script validates its input: it runs Ruby as root on GitLab via `gitlab-rails runner` |
| First `ci-status.sh` log tail | The runner's artifact-upload line showed the prefix of a job JWT (`token=eyJ…`) | Output is now masked (`token=`, JWTs, `glpat-`/`glrt-`/… prefixes); tested with fake values. A read-only tool can still leak: check what it prints, not only what it changes |
| Approved copy installed by the human: `sudo install -o root -g root -m 0755 scripts/ci-status.sh /usr/local/bin/ci-status`; allow rule moved to `Bash(/usr/local/bin/ci-status *)` | `sha256sum` of repository and installed copy identical (`a950d747…9490`) | The command that runs without a prompt is no longer a file the assistant can change |
| `test -w /usr/local/bin/ci-status`; `python3 -c "open('/usr/local/bin/ci-status','a')"`; `test -w /usr/local/bin` | Not writable; `PermissionError: [Errno 13] Permission denied`; directory not writable | File ownership stops the interpreter that deny rules do not (lessons learned #15) |
| Edit tool on `scripts/ci-status.sh` (harmless comment line) after deny rules `Edit(…)` / `Write(…)` | Blocked: "File is in a directory that is denied by your permission settings."; file hash unchanged | Guardrail only; the source is still editable via a shell, which is why the real control is the root-owned copy |
| `/usr/local/bin/ci-status securestream/catalog-api` in auto mode | Ran without a prompt (pipeline 39, all jobs success) | Allow rule works for the absolute path |
| Allow rule for a bare name `Bash(ci-status *)` (requested) | Not used: `~/.local/bin` is first on `PATH` and owned by `ubuntu`, so a `~/.local/bin/ci-status` would shadow the root-owned copy and run without a prompt | Absolute path in the rule; recorded as a deliberate deviation in `docs/progress.md` |
| `jq` on `settings.json` after the change | `allow`: only `/usr/local/bin/ci-status`; `ask` still contains `Bash(ssh *)`; deny has `Edit/Write(scripts/ci-status.sh)` | Any other ssh still needs approval |
| `git push --dry-run origin --delete yok-boyle-bir-dal` and `git push --dry-run --delete origin …` after deny rules `Bash(git push * --delete*)` / `Bash(git push --delete*)` | Both blocked without a prompt: "Permission to use Bash … has been denied." | Remote branch deletion with `--delete` is denied in both argument orders |
| `git push --dry-run origin :yok-boyle-bir-dal` with the requested rule `Bash(git push * :*)` | **Not blocked**: the command ran (dry-run, `remote ref does not exist`, nothing deleted) | A trailing `:*` is Claude Code's legacy prefix syntax, so the rule never meant "space, colon, anything". Text rules can be wrong in ways only a test shows |
| Same command after changing the rule to `Bash(git push * :**)` (no trailing `:*`) | Blocked without a prompt | Deviation from the requested rule text, recorded in `docs/progress.md`; same rule in both repositories |
| `git push --dry-run origin -d yok-boyle-bir-dal`; `git branch -D yok-boyle-bir-dal` | Both blocked without a prompt | Short `-d` and forced local deletion are covered. Still only text matching (an alias or `git -C . push …` is not covered); the real limit is server-side (lessons learned #23) |
| `kubectl get pod … -o jsonpath=…` together with `kubectl exec` (to check a mounted file's permissions) | Denied | `exec` into a running pod was rightly refused; diagnosis continued from the chart instead. Note: the deny rule `Bash(kubectl * -o json*)` also matches `-o jsonpath=`, which `CLAUDE.md` recommends; needs a decision by the human, not a workaround |

## Cluster access: a boundary enforced by RBAC, not by matching command text
Claude Code deny rules match command text (`kubectl get secret*`, `-o json*`); they are a guardrail and can be
bypassed by another spelling, a script or another program (lessons learned #15, #23). The assistant therefore gets
its own Kubernetes identity, and the API server decides:

- ServiceAccount `claude-readonly`: get/list/watch on explicitly listed resources, generated from API discovery
  (`scripts/claude-readonly-rbac.sh`, `--check` reports drift). Not listed: `secrets`, every subresource
  (`pods/log`, `pods/exec`, `serviceaccounts/token`), `generators.external-secrets.io`.
- Token: TokenRequest, 12 hours, not stored in a Secret; minted by the human (`sudo scripts/claude-kubeconfig.sh`),
  never shown (length and expiry only).
- Proof: `can-i` 13/13; real requests: `get pods` works, `logs` and `exec` are Forbidden.
- The identity is only the boundary if the assistant cannot reach any other credential. On 2026-10-23 its plain
  `kubectl` was still `system:admin` (lessons learned #31). `scripts/kubeconfig-lockdown.sh` moves the admin
  kubeconfig to `root:root 0600`; after that the remaining paths are `sudo` and `ssh` + `sudo` to the k3s nodes,
  both ask rules with human approval (NOPASSWD sudo is a known risk). Next step on the roadmap: a separate Unix user
  for the assistant.
- Only after `kubectl auth whoami` (no `KUBECONFIG`) shows `claude-readonly` are the text rules `-o yaml/json`
  removed, by the human. Done 2026-10-23 after `kubeconfig-lockdown.sh` (verification log). Remaining layer: the same
  Unix user with NOPASSWD sudo, and `ssh` + `sudo` to `/etc/rancher/k3s/k3s.yaml` on the nodes; both only behind ask
  rules and human approval (security-controls §4).

## What the AI is good at here, and what it is not
- **Good at:** first drafts of roles, pipelines and policies; reading release notes and schemas; turning a
  failure log into a hypothesis; writing documentation, runbooks and threat models; remembering the
  security rules consistently across a long session.
- **Not trusted with:** secret values, irreversible decisions, accepting risk, or declaring something
  "secure". Those stay with the engineer, and the evidence is the pipeline, the admission controller and
  the tests — not the AI's confidence.

## Summary
> I used AI as a pair engineer with the same restrictions I'd give a new hire: no secrets, no production
> credentials, every change through the pipeline, and explicit approval for anything irreversible. It made
> me much faster on drafts and debugging, but the value came from the controls: a preview step caught an
> over-broad history filter, keeping TLS verification on turned a CA mistake into a loud failure, and a
> length check caught a newline in a secret. It also caught my mistakes — when I pasted a token into the
> chat, the token was revoked within minutes and I changed the process so it can't happen again.
