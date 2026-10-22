# Lessons learned

Real problems met while building this lab. Each one changed a script, a check or a process.

| # | What happened | Root cause | Fix | Lesson |
|---|---|---|---|---|
| 1 | In the gate test, lint and unit tests failed — but never read the code | `requests==2.19.1` needs `idna<2.8`; `pip install` failed first | Lint installs only pinned `ruff`; rerun showed `S602` caught on its own | A red pipeline is only useful if it is red for the right reason |
| 2 | A deleted branch's fake token broke the `main` pipeline | gitleaks scans `git log --all`; the runner's cached clone kept deleted refs | `GIT_STRATEGY: clone` + `--log-opts=$CI_COMMIT_SHA` | Deleting a branch does not delete a secret: rotate, then rewrite history |
| 3 | Kyverno: `DENIED: access forbidden` | Deploy-token creation failed; an empty credential was written to the secret | Use GitLab's own service; refuse empty values before writing | Read errors layer by layer (DNS ok → TLS ok → auth failed); guard against empty secrets |
| 4 | Trivy supply-chain attack, March 2026 (CVE-2026-33634) | Malicious releases under legitimate tags | All CI tools pinned by digest; cool-down period | Security tools are part of the supply chain too |
| 5 | Kaniko archived by Google | Upstream maintenance ended | Maintained fork, pinned | Tool choices need ongoing maintenance review |
| 6 | Smoke test `wget --ca-certificate` failed | Alpine's wget is BusyBox | `curl --cacert` plus a negative test (no CA → must fail) | A negative test proves verification really happens |
| 7 | Ansible `--check` failed on `dpkg_selections` | Package not installed in check mode | `when: not ansible_check_mode` | Dry runs must be clean or nobody uses them |
| 8 | ZAP raised 3 warnings | Missing security headers | Middleware + unit test + `--no-server-header` | Fix, lock with a test, re-scan: 3 → 0 |
| 9 | Falco did not alert on a shell | `kubectl exec -t` without `-i` allocates no TTY | Test with `-it` | No alert is not always a tool failure — check the rule's conditions |
| 10 | API key from Vault was 49 characters, not 48 | `openssl rand` adds a newline; `vault kv put key=-` stored it | `tr -d '\n'`; verify expected length after delivery | Invisible characters in secrets cause "correct but does not work" bugs |
| 11 | A long terminal log was pasted into the bastion shell | Clipboard held a saved log instead of a command | Unwanted commit reverted with `git revert` (no force-push); terminal with paste protection; outputs exported to files | Prefer scripts with `set -euo pipefail` over long pasted blocks |
| 12 | A GitHub token was pasted into a chat | Human error while copying | Revoked and regenerated immediately; format-checked hidden input | Rotate first, investigate second |
| 13 | A step script stopped silently | `set -o pipefail` treated an expected "not found yet" as fatal | Handle expected failures explicitly (`\|\| LEN=0`), fail loudly with details | Fail-fast needs explicit handling of expected errors |
