# Runbook: credential inventory and rotation

| Credential | Expiry | Rotation |
|---|---|---|
| GitHub mirror token (fine-grained) | **2027-01-20** | GitHub → regenerate → `read -rsp` → update GitLab push mirror |
| GitLab registry deploy token `k3s-pull` | 1 year | Create new token via GitLab service → rewrite `registry-pull` secrets (`catalog`, `kyverno`) → revoke old |
| CI deploy kubeconfig (service-account token) | none (secret-based) | Delete `catalog-deployer-token` secret → recreate → update `KUBECONFIG_B64` |
| cosign key pair | none | Generate in `/dev/shm` → update CI variables + Ansible Vault backup → update `cosign.pub` and the Kyverno policy → re-sign current images |
| Runner authentication token | none | Create new runner → `ansible-vault encrypt_string` → run `runner.yml` → delete old runner |
| Vault unseal keys | none | `vault operator rekey` → store new shares → retire old file |
| catalog API key (Vault KV) | none | Write new KV version (`tr -d '\n'`!) → `kubectl annotate externalsecret … force-sync=…` → restart pods |
| Lab CA intermediate | 2 years | Re-issue from root, redeploy `lab_ca` / `ca_trust`; server certificates renew automatically 30 days before expiry |

Credentials without an expiry are reviewed every 90 days.
