# Architecture decision records

| ADR | Decision |
|---|---|
| [0001](0001-tailscale-instead-of-port-forwarding.md) | Tailscale subnet router instead of port forwarding |
| [0002](0002-k3s.md) | k3s as the Kubernetes distribution |
| [0003](0003-kyverno-imagevalidatingpolicy.md) | Kyverno `ImageValidatingPolicy` for admission control |
| [0004](0004-kaniko-fork-for-builds.md) | Maintained Kaniko fork for unprivileged builds |
| [0005](0005-cosign-key-based-without-public-tlog.md) | Key-based cosign signing without the public transparency log |
| [0006](0006-digest-pinning-and-cooldown.md) | CI tools pinned by digest, ~2-week cool-down |
| [0007](0007-vault-and-external-secrets.md) | HashiCorp Vault + External Secrets Operator |
| [0008](0008-sanitized-public-mirror.md) | GitLab source of truth, sanitized GitHub mirror |
