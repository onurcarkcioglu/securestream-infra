#!/usr/bin/env bash
# Terraform IaC taramasi (Checkov). Yerelde ve CI'da ayni betik.
#   scripts/iac-scan.sh gate     infra/terraform altindaki her modul (samples/*/insecure haric) ayri taranir;
#                                her rapor scripts/scan-gate.py'den gecer (istisnalar: security/exceptions.yaml).
#   scripts/iac-scan.sh report   samples/*/insecure taranir, yakalanan kurallar listelenir; kapi degil, exit 0.
# Her dizin ayri calistirilir: Checkov 3.3.26'da Terraform icin --skip-path gecersiz regex uretiyor
# (module_finder.py: '|'.join(f"({excluded_paths})")) ve birden fazla -d ayni dizini tekrar tekrar tariyor.
# Ozel kurallar: security/checkov (Proxmox provider/VM, GCP default service account).
# Ciktilar: iac-reports/<dizin>.json
set -euo pipefail
MODE=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=iac-reports
CHECKOV=${CHECKOV:-checkov}
PYTHON=${PYTHON:-python3}
fail() { echo "HATA: $*" >&2; exit 1; }
[[ $MODE == gate || $MODE == report ]] || fail "kullanim: $0 gate|report"
mkdir -p "$OUT"

modules() {
  find infra/terraform -name '*.tf' -not -path '*/.terraform/*' -printf '%h\n' | sort -u |
    if [[ $1 == gate ]]; then grep -v '^infra/terraform/samples/[^/]*/insecure$'; else grep '^infra/terraform/samples/[^/]*/insecure$'; fi
}

scan() { # $1 = dizin -> rapor yolu
  local report="$OUT/$(echo "$1" | tr / _).json"
  "$CHECKOV" -d "$1" --framework terraform --external-checks-dir security/checkov \
    --quiet --soft-fail -o json > "$report"
  echo "$report"
}

mapfile -t DIRS < <(modules "$MODE")
(( ${#DIRS[@]} > 0 )) || fail "taranacak Terraform dizini bulunamadi"

if [[ $MODE == gate ]]; then
  RC=0
  for d in "${DIRS[@]}"; do
    echo "== $d"
    report=$(scan "$d")
    "$PYTHON" scripts/scan-gate.py --tool checkov --report "$report" --base "$d" || RC=1
  done
  (( RC == 0 )) && echo "iac-scan: ${#DIRS[@]} dizin, kapi gecti" || echo "iac-scan: kapi KALDI"
  exit "$RC"
fi

# report: kasitli guvensiz ornekler. Beklenen tespitler brief'teki senaryolardir.
declare -A EXPECTED=(
  [aws]="CKV_AWS_20 CKV_AWS_145 CKV_AWS_24 CKV_AWS_63"
  [azure]="CKV_AZURE_59 CKV_AZURE_10 CKV_AZURE_14"
  [gcp]="CKV_GCP_28 CKV_GCP_2 CKV_SS_3"
)
MISSED=0
for d in "${DIRS[@]}"; do
  cloud=$(basename "$(dirname "$d")")
  report=$(scan "$d")
  echo "== $d"
  "$PYTHON" - "$report" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
reports = data if isinstance(data, list) else [data]
rows = sorted({(c["check_id"], c["resource"], c["check_name"]) for r in reports for c in r["results"].get("failed_checks", [])})
for rule, res, name in rows:
    print(f"  {rule:<14} {res:<45} {name}")
print(f"  {len(rows)} findings")
EOF
  caught=$("$PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d if isinstance(d,list) else [d]; print("\n".join(sorted({c["check_id"] for r in d for c in r["results"].get("failed_checks",[])})))' "$report")
  for rule in ${EXPECTED[$cloud]:-}; do
    if grep -qx "$rule" <<<"$caught"; then echo "  expected $rule: caught"; else echo "  expected $rule: MISSED"; MISSED=1; fi
  done
done
(( MISSED == 0 )) && echo "iac-scan-insecure: all expected findings caught" ||
  echo "UYARI: beklenen bir tespit kacirildi (tarayici surumu ya da ornek degisti); kapi degil, inceleyin"
exit 0
