#!/usr/bin/env bash
# Guvenlik alarm kurallarini dogrular: PrometheusRule'dan kural dosyasi cikarilir, promtool ile sozdizimi
# (check rules) ve birim testleri (test rules: platform/tests/alert-rules.test.yaml) calistirilir.
# Kume erisimi gerekmez. promtool: scripts/install-dev-tools.sh (kumedeki Prometheus ile ayni surum).
# Kullanim: scripts/alert-rules-test.sh   (exit 1 = kural hatali ya da test basarisiz)
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "HATA: $*" >&2; exit 1; }
PROMTOOL=${PROMTOOL:-$HOME/.local/bin/promtool}
[[ -x $PROMTOOL ]] || fail "promtool yok: scripts/install-dev-tools.sh"
python3 -I -c 'import yaml' 2>/dev/null || fail "python3-yaml yok"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# PrometheusRule.spec -> duz Prometheus kural dosyasi (test dosyasi onu goreli yoldan okur)
python3 -I - platform/manifests/monitoring/alert-rules.yaml "$TMP/alert-rules.yaml" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
assert doc["kind"] == "PrometheusRule", doc["kind"]
yaml.safe_dump({"groups": doc["spec"]["groups"]}, open(sys.argv[2], "w"), sort_keys=False)
print(f"   {sum(len(g['rules']) for g in doc['spec']['groups'])} kural, {len(doc['spec']['groups'])} grup")
PY
cp platform/tests/alert-rules.test.yaml "$TMP/"
"$PROMTOOL" check rules "$TMP/alert-rules.yaml"
(cd "$TMP" && "$PROMTOOL" test rules alert-rules.test.yaml)
