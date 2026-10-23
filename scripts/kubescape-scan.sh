#!/usr/bin/env bash
# Kubernetes durus taramasi (Kubescape, NSA + MITRE). Salt okunur: kumeye hicbir sey kurulmaz veya yazilmaz.
#   scripts/kubescape-scan.sh            tarar, temizlenmis JSON raporu ve ozet yazar
# Kimlik: varsayilan kubeconfig (ss-mgmt'te claude-readonly). Betik yazma yetkisi olan bir kimlikle calismaz;
# claude-readonly icin `kubescape --dry-run`: gereken 19 kaynak turunun hepsi listelenebiliyor (secrets gerekmiyor).
# Surumler platform/versions.conf'ta sabit; ikili ve kontrol kutuphanesi (regolibrary) SHA256 ile dogrulanir.
# Kubescape'in hazir istisnalari kullanilmaz (bos liste): istisnalar security/exceptions.yaml'da, gerekceli.
# --host-scan kapali: acik olsa kumeye DaemonSet kurar; kubelet kontrolleri (C-0069, C-0070) bu yuzden degerlendirilmez.
# Rapor: tam kaynak nesneleri (ConfigMap, ortam degiskenleri) /dev/shm'deki ham ciktida kalir ve silinir.
# Kaydedilen rapor yalnizca resourceID, kontrol sonuclari ve ozet tasir; DefectDojo "Kubescape JSON Importer" okur.
# Cikti: ${KUBESCAPE_OUT:-~/securestream-reports/kubescape}/kubescape-<UTC>.json (+ latest.json baglantisi)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../platform/versions.conf
source "$ROOT/platform/versions.conf"
OUT=${KUBESCAPE_OUT:-$HOME/securestream-reports/kubescape}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/securestream/kubescape-${KUBESCAPE_VERSION}
KS_URL=https://github.com/kubescape/kubescape/releases/download/${KUBESCAPE_VERSION}/kubescape_${KUBESCAPE_VERSION#v}_linux_amd64
RL_URL=https://github.com/kubescape/regolibrary/releases/download/${KUBESCAPE_REGOLIBRARY_VERSION}
fail() { echo "HATA: $*" >&2; exit 1; }
command -v kubectl >/dev/null || fail "kubectl yok"

# 1) Kimlik: yalnizca okuyabilen bir hesap kabul edilir
WHO=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}') || fail "kubectl auth whoami basarisiz (token suresi?)"
echo "kimlik: $WHO"
for verb_res in "create daemonsets" "create pods" "delete pods" "patch deployments" "get secrets"; do
  # can-i "no" icin exit 1 dondurur; beklenen sonuc bu. Fiil ve kaynak bilerek iki kelimeye bolunur.
  # shellcheck disable=SC2086
  if kubectl auth can-i $verb_res -A >/dev/null 2>&1; then
    fail "kimlik '$WHO' '$verb_res' yapabiliyor; tarama yalnizca salt okunur kimlikle calisir"
  fi
done

# 2) Sabit surumleri indir ve dogrula (onbellek her calismada yeniden dogrulanir)
mkdir -p "$CACHE/fw"
chmod 700 "$CACHE"
if ! echo "$KUBESCAPE_SHA256  $CACHE/kubescape" | sha256sum -c --status 2>/dev/null; then
  echo "kubescape $KUBESCAPE_VERSION indiriliyor"
  curl -fsSL --proto '=https' -o "$CACHE/kubescape.part" "$KS_URL"
  echo "$KUBESCAPE_SHA256  $CACHE/kubescape.part" | sha256sum -c --status || fail "kubescape SHA256 uyusmuyor"
  mv "$CACHE/kubescape.part" "$CACHE/kubescape"
  chmod 700 "$CACHE/kubescape"
fi
echo "$KUBESCAPE_SHA256  $CACHE/kubescape" | sha256sum -c --status || fail "kubescape SHA256 uyusmuyor (onbellek)"
(
  cd "$CACHE/fw"
  curl -fsSL --proto '=https' -o checksums.txt "$RL_URL/checksums.txt"
  echo "$KUBESCAPE_REGOLIBRARY_CHECKSUMS_SHA256  checksums.txt" | sha256sum -c --status || fail "regolibrary checksums.txt SHA256 uyusmuyor"
  for f in nsa mitre default_config_inputs; do
    grep -qE " $f\$" checksums.txt || fail "checksums.txt'de $f yok"
    if ! grep -E " $f\$" checksums.txt | sha256sum -c --status 2>/dev/null; then
      curl -fsSL --proto '=https' -o "$f" "$RL_URL/$f"
    fi
  done
  grep -E " (nsa|mitre|default_config_inputs)\$" checksums.txt | sha256sum -c --quiet || fail "regolibrary dosyasi SHA256 uyusmuyor"
)

# 3) Tarama: ham cikti bellekte (0700), is bitince silinir
WORK=$(mktemp -d /dev/shm/kubescape.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1]))["settings"]["postureControlInputs"], open(sys.argv[2], "w"))' \
  "$CACHE/fw/default_config_inputs" "$WORK/controls-config.json"
echo '[]' > "$WORK/no-exceptions.json"
echo "tarama: NSA + MITRE (regolibrary $KUBESCAPE_REGOLIBRARY_VERSION)"
KS_CACHE_DIR="$WORK/cache" KS_SKIP_UPDATE_CHECK=true "$CACHE/kubescape" scan framework nsa,mitre \
  --keep-local --host-scan=false --fail-on-degraded-config \
  --use-from "$CACHE/fw/nsa,$CACHE/fw/mitre" --controls-config "$WORK/controls-config.json" \
  --exceptions "$WORK/no-exceptions.json" --format json --output "$WORK/raw.json" -l error \
  > "$WORK/scan.log" 2>&1 || { tail -n 20 "$WORK/scan.log" >&2; fail "kubescape basarisiz"; }
[[ -s $WORK/raw.json ]] || fail "kubescape rapor yazmadi"

# 4) Temizle, sir kalmadigini dogrula, ozet bas
mkdir -p "$OUT"
chmod 700 "$OUT"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$OUT/kubescape-$STAMP.json"
python3 -I - "$WORK/raw.json" "$REPORT" <<'PY'
import json
import re
import sys

src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
# Tam nesneler (ConfigMap verisi, pod env degerleri) atilir; DefectDojo parser'i yalnizca resourceID kullanir.
d["resources"] = [{"resourceID": r["resourceID"]} for r in d.get("resources", [])]
# Kume baglami (sunucu adresi, context adi) rapora gerekmez
d.get("metadata", {}).pop("targetMetadata", None)
text = json.dumps(d, indent=1, sort_keys=True)

# Dogrulama: nesne alanlari ve bilinen sir bicimleri olmamali (yalnizca sayi basilir, deger asla)
FORBIDDEN_KEYS = {"object", "data", "stringData", "env", "token", "password"}
found_keys = set()


def walk(x):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in FORBIDDEN_KEYS:
                found_keys.add(k)
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)


walk(d)
PATTERNS = {
    "private key": r"-----BEGIN [A-Z ]*PRIVATE KEY",
    "JWT": r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
    "GitLab token": r"\bgl(pat|rt|dt|cbt|ptt|ft|imt|agent|oas)-",
    "Vault token": r"\bhv[sbr]\.[A-Za-z0-9_-]{20,}",
    "Sonar token": r"\bsq[pau]_[0-9a-f]{20,}",
    "AWS key": r"\bAKIA[0-9A-Z]{16}\b",
    "kubeconfig": r"client-(key|certificate)-data",
}
hits = {name: len(re.findall(p, text)) for name, p in PATTERNS.items()}
bad = {k: v for k, v in hits.items() if v}
if found_keys or bad:
    print(f"HATA: temizlenmis raporda yasak alan {sorted(found_keys)} veya sir bicimi {bad}; rapor yazilmadi", file=sys.stderr)
    sys.exit(1)
with open(dst, "w") as f:
    f.write(text + "\n")

s = d["summaryDetails"]
cov = d.get("scanCoverage") or {}
print(f"uyum skoru: {s.get('complianceScore', 0):.1f} (risk skoru {s.get('score', 0):.1f})")
for fw in s.get("frameworks", []):
    print(f"  {fw['name']}: uyum {fw.get('complianceScore', 0):.1f}")
not_eval = ", ".join(c["controlID"] for c in cov.get("notEvaluatedControls") or [])
print(f"kapsam: {cov.get('evaluatedControls')}/{cov.get('totalControls')} kontrol, degerlendirilmeyen: {not_eval or '-'}")
failed = [c for c in s["controls"].values() if c.get("status") == "failed"]
order = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3}
failed.sort(key=lambda c: (order.get(c.get("severity"), 4), c["controlID"]))
print(f"basarisiz kontrol: {len(failed)} / {len(s['controls'])}")
for c in failed:
    n = (c.get("ResourceCounters") or {}).get("failedResources", 0)
    print(f"  {c.get('severity', '?'):8} {c['controlID']:7} {n:4} kaynak  {c['name']}")
print(f"sir kontrolu: yasak alan 0, sir bicimi 0 ({len(PATTERNS)} desen); kaynak: {len(d['resources'])}")
PY
chmod 600 "$REPORT"
ln -sfn "$(basename "$REPORT")" "$OUT/latest.json"
echo "rapor: $REPORT"
echo "DefectDojo: scan_type 'Kubescape JSON Importer', urun securestream-platform, engagement 'CI/CD', test 'kubescape'"
