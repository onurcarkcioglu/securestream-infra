#!/usr/bin/env bash
# Kubescape raporunu DefectDojo'ya yukler (urun securestream-platform, engagement "CI/CD", test "kubescape") ve
# security/exceptions.yaml'daki kubescape istisnalarini Risk Acceptance olarak esitler.
#   scripts/kubescape-upload.sh [rapor]   varsayilan: ~/securestream-reports/kubescape/latest.json
# Insan calistirir: DefectDojo API v2 anahtari (kendi kullanicisinin, UI -> API v2 Key) gizli istemle okunur,
# yalnizca bu Python surecinin ortamina verilir; ekrana, argumana, dosyaya yazilmaz. CI anahtari burada kullanilmaz.
# Yukleyici: ci-templates/scripts/defectdojo-upload.py (CI ile ayni kod, kaynak kimligi eslesmesi gerekir).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPORT=${1:-$HOME/securestream-reports/kubescape/latest.json}
UPLOADER=${DD_UPLOADER:-$HOME/ci-templates/scripts/defectdojo-upload.py}
CA="$ROOT/infra/ansible/files/securestream-root-ca.crt"
fail() { echo "HATA: $*" >&2; exit 1; }
[[ -s $REPORT ]] || fail "rapor yok: $REPORT (once scripts/kubescape-scan.sh)"
[[ -f $UPLOADER ]] || fail "defectdojo-upload.py yok: $UPLOADER"
grep -q 'component_name' "$UPLOADER" || fail "$UPLOADER eski: Kubescape istisnalari icin component_name eslesmesi gerekir"
# Rapor bu betigin temizledigi bicimde mi (tam nesne yok)
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(any("object" in r for r in d["resources"]))' "$REPORT" \
  || fail "raporda kaynak nesneleri var; yalnizca scripts/kubescape-scan.sh ciktisi yuklenir"

read -rsp "DefectDojo API v2 anahtari (40 hex, gorunmez): " DD_API_KEY
echo
[[ $DD_API_KEY =~ ^[0-9a-f]{40}$ ]] || { unset DD_API_KEY; fail "bicim gecersiz (40 kucuk hex karakter bekleniyor)"; }
cd "$ROOT"
DD_API_KEY=$DD_API_KEY python3 -I "$UPLOADER" --url https://defectdojo.securestream.lab \
  --product securestream-platform --report "kubescape=$REPORT" \
  --exceptions security/exceptions.yaml --cafile "$CA"
unset DD_API_KEY
