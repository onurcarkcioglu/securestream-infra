# Security Policy

This is a portfolio / lab project, not a production service. The lab is not reachable from the internet.

## Reporting a vulnerability
Please use GitHub's **"Report a vulnerability"** (Security tab → Advisories) instead of a public issue.
I aim to acknowledge reports within 7 days.

## What is intentionally not in this repository
Private keys, tokens, kubeconfigs, Vault unseal keys and every Ansible Vault file. They are removed from the
entire history before publication (see [ADR-0008](docs/adr/0008-sanitized-public-mirror.md)), and the published
history is scanned with gitleaks before each push.
