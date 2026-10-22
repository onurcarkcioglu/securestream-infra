#!/usr/bin/env bash
# Vault'u unseal eder: 3 anahtar Ansible Vault'tan bellekte cozulur, ekrana basilmaz.
set -euo pipefail
cd "$(dirname "$0")/../infra/ansible"
VAULT_ADDR=https://vault.securestream.lab:8200
CA=$PWD/files/securestream-root-ca.crt
ansible-vault decrypt --output - secrets/vault-init.json.vault 2>/dev/null \
  | python3 -c 'import json,sys; [print(json.dumps({"key": k})) for k in json.load(sys.stdin)["unseal_keys_b64"][:3]]' \
  | while read -r body; do
      printf %s "$body" | curl -s --cacert "$CA" -X PUT --data @- "$VAULT_ADDR/v1/sys/unseal" \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print("sealed:", d["sealed"], "| ilerleme:", d["progress"], "/", d["t"])'
    done
