# Runbook: Vault is sealed

**Symptom:** `vault status` shows `Sealed true` (after a reboot of ss-vault or the host).
Applications keep running: External Secrets keeps the last synced Kubernetes Secret, but new syncs fail.

## Steps (on ss-mgmt)
1. Confirm: `VAULT_ADDR=https://vault.securestream.lab:8200 VAULT_CACERT=~/securestream/infra/ansible/files/securestream-root-ca.crt vault status`
2. Unseal: `~/securestream/scripts/vault-unseal.sh`
   - Decrypts 3 of 5 unseal keys from Ansible Vault **in memory** and sends them to the API via stdin.
   - Expected output ends with `sealed: False`.
3. Verify sync: `kubectl -n catalog get externalsecret catalog-config` → `SecretSynced True`.

## Notes
- Production would use auto-unseal (cloud KMS or HSM) and distribute key shares to separate people.
- Never paste unseal keys into a terminal, ticket or chat.
