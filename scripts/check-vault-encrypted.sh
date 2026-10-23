#!/bin/sh
# Sir yollarindaki her dosya Ansible Vault ile sifreli mi? (secret-scan isinde, gitleaks'ten once)
# Desenler publish-github'daki filtreyle ayni: secrets/, group_vars/*/vault.yml, *.vault
# Gecerli iki bicim:
#   1) tam dosya: ilk satir $ANSIBLE_VAULT;1.x;AES256 (ansible-vault encrypt)
#   2) degisken bazinda (encrypt_string): yorum/bos satir disinda her satir ya "anahtar: !vault |"
#      ya da girintili $ANSIBLE_VAULT;... / hex. Baska her satir (duz deger) FAIL.
# Cikti yalnizca dosya adi, satir numarasi ve satir turu; icerik asla basilmaz.
# Kullanim: scripts/check-vault-encrypted.sh [git deposu, vars. .]
set -eu
cd "${1:-.}"
FILES=$(git ls-files | grep -E '(^|/)secrets/|group_vars/[^/]+/vault\.yml$|\.vault$' || true)
[ -n "$FILES" ] || { echo "HATA: sir yolunda hic dosya bulunamadi (desen ya da depo hatali)"; exit 1; }
RC=0
for f in $FILES; do
  if head -n 1 "$f" | grep -Eq '^\$ANSIBLE_VAULT;1\.[0-9];AES256'; then
    echo "OK    $f (tam dosya sifreli)"
    continue
  fi
  # Degisken bazinda bicim: kurala uymayan satirlarin yalnizca numaralari
  BAD=$(awk '
    /^[[:space:]]*(#|$)/ { next }                                  # yorum / bos
    /^---[[:space:]]*$/ { next }                                   # YAML belge baslangici
    /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+!vault[[:space:]]*\|[-+]?[[:space:]]*$/ { inv=1; n++; next }
    inv && /^[[:space:]]+\$ANSIBLE_VAULT;1\.[0-9];AES256(;[A-Za-z0-9_.-]+)?[[:space:]]*$/ { next }
    inv && /^[[:space:]]+[0-9a-f]+[[:space:]]*$/ { next }
    { inv=0; printf "%d ", NR }
    END { if (n == 0) printf "no-vault-values" }
  ' "$f")
  if [ -z "$BAD" ]; then
    echo "OK    $f (degisken bazinda sifreli)"
  else
    echo "FAIL  $f: sifreli olmayan satir(lar): $BAD"
    RC=1
  fi
done
exit "$RC"
