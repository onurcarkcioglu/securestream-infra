# AI assistant guardrails

An AI coding assistant (Claude Code) works on the bastion `ss-mgmt` with the same Unix user as the human operator.
It is treated as an untrusted contributor: several independent layers limit what it can read and change, and no
single layer is relied on. This page summarises the layers, what each one can and cannot stop, and the evidence in
this repository. Details: [ai-assisted-engineering](ai-assisted-engineering.md) (incl. the
[verification log](ai-assisted-engineering.md#verification-log)), [lessons learned](lessons-learned.md) (`#n` below),
[security-controls](security-controls.md) §4.

## Layers

| Layer | Stops | Does not stop | Evidence |
|---|---|---|---|
| **Text rules** (`.claude/settings.json`: deny, ask, allow) | Commands and file reads that match the rule text; `ask` rules still prompt in auto mode; recognised shell readers (`cat`, `head`, `jq`) on denied paths | Other spellings (flag first, aliases, `git -C`), wrappers (`scripts/tf.sh`), interpreters (`python3` reads a denied file), files outside the project directory. A rule can be wrong or never match without any error | #15, #18, #23, #35, #36; verification log: dummy `.tfstate` (`python3` read it), `git push … :refspec` with `:*` (not blocked), `kubectl -n default get secret` (blocked after the flag-first rules) |
| **Auto-mode classifier** | Actions judged risky in context, e.g. the assistant editing its own permission settings ("Self-Modification") | It is a model judgement, not a deterministic boundary; it did not stop `kubectl -n … get secret` (#36) | Verification log: assistant edits its own `.claude/settings.json` → refused |
| **Human approval and review** | Every push, `ssh`, `sudo`, `ansible-playbook`, `kubectl apply`, `terraform apply` (ask rules); design proposals and claims reviewed before they become controls | Approval fatigue; the human sees the command text, not every effect. One approved `sudo` is root (NOPASSWD) | #31 (proof demanded before removing deny rules), #33 (`--diff` run rejected), [ADR 0009](adr/0009-separate-ci-templates-project.md) (job token proposal rejected); verification log: `git push --dry-run`, `sudo -n true`, `tf.sh apply -help` prompts |
| **RBAC** (Kubernetes) | Any spelling of a forbidden cluster request: ServiceAccount `claude-readonly` has get/list/watch only, no `secrets`, no `pods/log`, no `pods/exec`; 12 h token | Anything outside the cluster API; `ssh` + `sudo` to `/etc/rancher/k3s/k3s.yaml` on the nodes | #31, #32, #36; verification log: plain `kubectl auth whoami` → `claude-readonly`, `can-i get secrets -A` → no; `platform/manifests/claude-readonly-rbac.yaml` |
| **File ownership** | Writes and reads by any program of the `ubuntu` user, interpreters included: admin kubeconfig `/etc/securestream/admin.kubeconfig` (`root:root 0600`), allow-listed status script `/usr/local/bin/ci-status` (`root:root 0755`) | `sudo` as the same user (NOPASSWD), only held back by the `sudo` ask rule | #19, #31; verification log: `test -w` / `python3 open()` on `/usr/local/bin/ci-status` → permission denied; admin file unreadable for `ubuntu`; `scripts/kubeconfig-lockdown.sh` |
| **CI gates** | Changes that reach a commit: AI commits run the same pipeline (secret scan with Ansible Vault header check, IaC gate, `exceptions-check`, SAST/SCA/image scans, Quality Gate); the public mirror is filtered and re-scanned before it is pushed | Actions that never become a commit (local commands, terminal output); faults the gate does not model (a gate that scans only part of the code looked green) | #2, #21, #34; `.gitlab-ci.yml` (`secret-scan`, `publish-github`), `scripts/check-vault-encrypted.sh`, [ADR 0008](adr/0008-sanitized-public-mirror.md), [requirements traceability](requirements-traceability.md) §6 |

Principle: text rules and the classifier are guardrails; RBAC, file ownership and server-side settings are the
boundary. A guardrail is removed only after the boundary behind it is proven with the identity actually in use (#32).

## Incidents (2026-10-23)

| What happened | Caught by | What changed |
|---|---|---|
| A requested deny rule `Bash(git push * :*)` did not block `git push --dry-run origin :branch` (a trailing `:*` is the legacy prefix syntax) | Harmless dry-run test of the rule (verification log) | Rule rewritten as `Bash(git push * :**)` and re-tested; server-side branch protection named as the real limit (#23) |
| Deny rule `Write(scripts/ci-status.sh)` was present but never matched; config review had counted it as part of the guardrail | Claude Code start-up warning, read by the human | Rule removed by the human; `Edit(path)` already covers the Write tool; every rule is tested with the tool it should stop (#35) |
| The assistant ran `kubectl -n metallb-system get secret` in a compound command (forbidden by project rules); the deny rule did not match the flag-first spelling | RBAC: `Forbidden` for `claude-readonly`, no value read | Human added `Bash(kubectl * get secret*)` / `Bash(kubectl * describe secret*)`; both tested as blocked (#36, verification log) |
| The assistant tried to edit its own `.claude/settings.json` | Auto-mode classifier ("Self-Modification") | Permission changes are made by the human only |
| `k3s.yml --check --diff` was about to print the diff of files that hold the admin kubeconfig and the k3s join token | Human rejected the tool call | `diff: false` next to `no_log: true` on secret tasks; dry runs filtered, logs kept out of persistent paths (#33) |
| The assistant proposed adding `catalog-api` to the job token allowlist of the platform repository, which holds encrypted vault files and infrastructure code | Human review | Shared CI templates moved to a separate project with its own narrow allowlist ([ADR 0009](adr/0009-separate-ci-templates-project.md)) |
| A read-only kubeconfig existed and passed its `can-i` checks, but plain `kubectl` still used the admin credential | Human asked for proof: `kubectl auth whoami` → `system:admin` | Admin kubeconfig moved to `root:root 0600` outside the home directory; `~/.kube/config` → read-only file; only then were the `-o yaml/json` deny rules removed (#31, #32) |
| A shared CI template defined a job variable that would have overridden a consumer's global value | Assistant's self-review before the first consumer push | Defaults moved into the script; consumer branch pipelines compared before tagging (#34) |

## Residual risks

- The assistant runs as the same Unix user as the human, with NOPASSWD sudo. Only the `sudo` ask rule and the human's
  approval stand between it and root, including the admin kubeconfig.
- Secret files in the user's home directory (e.g. `~/.config/securestream/`) are protected from the assistant only by
  text deny rules and project rules, which an interpreter can bypass (#15); their safety rests on encryption at rest
  and on not handing the assistant the keys.
- `ssh` + `sudo` reach an admin kubeconfig on every k3s node; again only an ask rule and approval.
- Text rules have gaps by construction (#18, #23, #36); new wrappers or spellings need new rules and tests.
- The classifier and human approval are judgement-based; approval fatigue grows with the number of prompts.
- The read-only token is renewed every 12 h by the human; an expired token fails closed.
- Terminal output is not filtered by any layer: secrets are kept out of it by procedure (length/prefix checks only,
  `no_log`, filtered dry runs), not by a control.

## Roadmap

- Run the assistant as its own Unix user with only the read-only kubeconfig, no sudo and no SSH keys
  ([security-controls](security-controls.md) §4).
- Central logging and a security dashboard (Loki, Grafana): Kubernetes audit events and Falco alerts in one place
  ([requirements traceability](requirements-traceability.md) §7).
- GitLab 2FA for human accounts.
