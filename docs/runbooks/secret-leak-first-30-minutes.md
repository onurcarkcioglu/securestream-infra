# Runbook: a secret has leaked — the first 30 minutes

A secret is leaked when it appears anywhere it was not meant to be: a commit, a CI log, a chat message,
a screenshot, a ticket. **Rotate first, investigate second.**

| Minute | Action |
|---|---|
| 0–5 | **Revoke / rotate** the credential at its source (GitHub token page, GitLab token, Vault, cloud console). Do not wait to understand the scope first. |
| 5–10 | **Scope:** what could the credential do (repositories, permissions, expiry)? Was it used? Check provider audit logs. |
| 10–20 | **Contain:** replace the credential everywhere it is consumed (mirror config, CI variable, Vault). Verify the old one fails. |
| 20–30 | **Clean up:** if it reached Git, rewrite history (`git filter-repo`), run housekeeping, clear runner caches — after rotation, never instead of it. Remember that deleting a branch does not delete the commit. |
| After | Root cause and a guard that prevents the class of mistake (format check, gitleaks rule, process change). |

## Real example from this lab (2026-10-22)
A GitHub fine-grained token was pasted into a chat by mistake.
1. Token deleted and regenerated within minutes.
2. Scope: two empty repositories, contents read/write, never used.
3. New token entered only through `read -rsp` with a format check (`github_pat_` prefix, length) before use.
4. Lesson: credentials move only between the password manager and a hidden terminal prompt.
