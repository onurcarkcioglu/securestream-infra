#!/bin/sh
# Sir yollarindaki her dosya Ansible Vault ile sifreli mi? (secret-scan isinde, gitleaks'ten once)
# Desenler publish-github'daki filtreyle ayni: secrets/, group_vars/*/vault.yml, *.vault
# Yalnizca ilk satirin onekine bakar ($ANSIBLE_VAULT;1.x;AES256) ve dosya adini yazar; icerik basmaz.
# Kullanim: scripts/check-vault-encrypted.sh [git deposu, vars. .]
set -eu
cd "${1:-.}"
FILES=$(git ls-files | grep -E '(^|/)secrets/|group_vars/[^/]+/vault\.yml$|\.vault$' || true)
[ -n "$FILES" ] || { echo "HATA: sir yolunda hic dosya bulunamadi (desen ya da depo hatali)"; exit 1; }
RC=0
for f in $FILES; do
  if head -n 1 "$f" | grep -Eq '^\$ANSIBLE_VAULT;1\.[0-9];AES256'; then
    echo "OK    $f"
  else
    echo "FAIL  $f (Ansible Vault basligi yok: sifrelenmemis olabilir)"
    RC=1
  fi
done
exit "$RC"
