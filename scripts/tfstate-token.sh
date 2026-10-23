#!/usr/bin/env bash
# GitLab managed Terraform state icin proje erisim token'ini ~/.config/securestream/tfstate.env'e yazar.
# Token gizli girilir; ekrana, komut satiri argumanlarina ve repoya girmez.
# Token: securestream/securestream > Settings > Access tokens, rol Maintainer, kapsam api, sure <= 1 yil.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CA=$ROOT/infra/ansible/files/securestream-root-ca.crt
API=https://gitlab.securestream.lab/api/v4
OUT=$HOME/.config/securestream/tfstate.env
fail() { echo "HATA: $*" >&2; exit 1; }

read -rsp "GitLab proje erisim token'i (glpat-...): " T; echo
[[ $T == glpat-* && ${#T} -ge 26 ]] || fail "bicim beklenen gibi degil (glpat- oneki, uzunluk ${#T})"

# curl basligi stdin'den okur (-H @-), token arguman listesine girmez
api() { printf 'PRIVATE-TOKEN: %s\n' "$T" | curl -sS --cacert "$CA" -H @- "$API/$1"; }

LEVEL=$(api projects/1 | python3 -c 'import json,sys; d=json.load(sys.stdin); pa=(d.get("permissions") or {}).get("project_access") or {}; print(pa.get("access_level", 0))') || LEVEL=0
[[ $LEVEL -ge 40 ]] || fail "token proje 1'de Maintainer degil (access_level=$LEVEL)"
U=$(api user | python3 -c 'import json,sys; print(json.load(sys.stdin).get("username", ""))') || U=
[[ -n $U ]] || fail "token kullanici adi alinamadi"

umask 077
printf 'TF_HTTP_USERNAME=%s\nTF_HTTP_PASSWORD=%s\n' "$U" "$T" > "$OUT"
chmod 600 "$OUT"
echo "Yazildi: $OUT (izin $(stat -c %a "$OUT"), kullanici $U, token uzunlugu ${#T}, access_level $LEVEL)"
