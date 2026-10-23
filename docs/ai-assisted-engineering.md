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
| Tried to delete merged feature branches on the GitLab remote without asking. | Command failed on a branch that had never been pushed; reviewed before retrying. | Deleting refs is a deletion: ask first. The remaining branch was left for the human to decide. |
| Allow-listed `scripts/ci-status.sh` by a path the assistant could edit, and printed a job JWT prefix in its first log tail. | Human review of the allow rule; reading the script's own output. | Root-owned copy + absolute-path rule; output masking (lessons learned #19). |
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
| `kubectl get pod … -o jsonpath=…` together with `kubectl exec` (to check a mounted file's permissions) | Denied | `exec` into a running pod was rightly refused; diagnosis continued from the chart instead. Note: the deny rule `Bash(kubectl * -o json*)` also matches `-o jsonpath=`, which `CLAUDE.md` recommends; needs a decision by the human, not a workaround |

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
