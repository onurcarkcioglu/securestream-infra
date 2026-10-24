#!/usr/bin/env bash
# kube-bench CIS taramasi (k3s profili) uc k3s dugumunde, Ansible ile (infra/ansible/playbooks/kube-bench.yml).
# Ham rapor dugumde temizlenir; ss-mgmt'ye yalnizca kontrol numarasi, aciklama, durum ve iyilestirme gelir.
# Burada ayrica sir kalibi aranir; bulunursa rapor silinir. Kume API'si ve kubeconfig kullanilmaz.
# Kullanim: scripts/kube-bench-scan.sh   (rapor: ~/securestream-reports/kube-bench/<zaman>/, latest -> son)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../platform/versions.conf
source "$ROOT/platform/versions.conf"
export PATH=$HOME/.local/bin:$PATH
fail() { echo "HATA: $*" >&2; exit 1; }
command -v ansible-playbook >/dev/null || fail "ansible-playbook yok"
BASE=$HOME/securestream-reports/kube-bench
OUT=$BASE/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
chmod 0700 "$BASE"

cd "$ROOT/infra/ansible"
ansible-playbook playbooks/kube-bench.yml \
  -e "kube_bench_version=$KUBE_BENCH_VERSION" -e "kube_bench_sha256=$KUBE_BENCH_SHA256" \
  -e "kube_bench_benchmark=$KUBE_BENCH_BENCHMARK" -e "kube_bench_report_dir=$OUT"

shopt -s nullglob
reports=("$OUT"/*.json)
[[ ${#reports[@]} -eq 3 ]] || fail "3 dugum raporu bekleniyordu, ${#reports[@]} geldi ($OUT)"
# Savunma derinligi: temizleyiciden sonra sir kalibi kalmamali (deger basilmaz, yalnizca dosya adi)
if grep -l -E -e '-----BEGIN [A-Z ]*PRIVATE KEY' -e 'K10[0-9a-f]{20,}' -e '(token|password)[=:]\s*\S{8,}' "${reports[@]}"; then
  rm -rf "$OUT"
  fail "temiz raporda sir kalibi var (yukaridaki dosya); rapor silindi, kube-bench-sanitize.py'yi inceleyin"
fi
ln -sfn "$OUT" "$BASE/latest"

python3 -I - "${reports[@]}" <<'PY'
import json, sys
for path in sys.argv[1:]:
    rep = json.load(open(path))
    counts, fails = {}, []
    for control in rep["Controls"]:
        for test in control["tests"]:
            for r in test["results"]:
                counts[r["status"]] = counts.get(r["status"], 0) + 1
                if r["status"] == "FAIL":
                    fails.append(f'{r["test_number"]} {r["test_desc"][:100]}')
    print(f'== {rep["node"]}: ' + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    for f in fails:
        print("   FAIL", f)
PY
echo "Rapor: $OUT"
