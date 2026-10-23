#!/usr/bin/env bash
# /v1/admin/stats uctan uca kontrolu: anahtarsiz 401, yanlis anahtar 401, Vault'taki anahtarla 200.
# Anahtar Vault'tan degiskene alinir ve curl'e yalnizca stdin ile gider; ekrana sadece HTTP kodlari ve
# anahtar uzunlugu yazilir. Insan calistirir (VAULT_TOKEN gerekir); AI asistaninin Vault token'i yoktur.
# Kullanim: VAULT_TOKEN=... scripts/catalog-admin-smoke.sh   (ya da once: vault login)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export VAULT_ADDR=${VAULT_ADDR:-https://vault.securestream.lab:8200}
export VAULT_CACERT=$ROOT/infra/ansible/files/securestream-root-ca.crt
URL=https://catalog.securestream.lab/v1/admin/stats
EXPECTED_LEN=48
fail() { echo "HATA: $*" >&2; exit 1; }

code() { curl -sS -o /dev/null -w '%{http_code}' --cacert "$VAULT_CACERT" -H @- "$URL"; }

KEY=$(vault kv get -field=api_key secret/catalog/config) || fail "Vault'tan okunamadi (vault login / VAULT_TOKEN?)"
LEN=${#KEY}
[[ $LEN -eq $EXPECTED_LEN ]] || fail "anahtar uzunlugu $LEN, beklenen $EXPECTED_LEN"

NO_KEY=$(printf '\n' | code)
WRONG=$(printf 'X-API-Key: wrong-key-for-test\n' | code)
GOOD=$(printf 'X-API-Key: %s\n' "$KEY" | code)
unset KEY

echo "anahtar uzunlugu: $LEN"
echo "anahtarsiz:       $NO_KEY (beklenen 401)"
echo "yanlis anahtar:   $WRONG (beklenen 401)"
echo "dogru anahtar:    $GOOD (beklenen 200)"
[[ $NO_KEY == 401 && $WRONG == 401 && $GOOD == 200 ]] || fail "beklenen kodlar alinamadi"
echo "OK"
