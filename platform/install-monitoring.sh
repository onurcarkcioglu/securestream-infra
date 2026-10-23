#!/usr/bin/env bash
# Izleme yigini (Item 9): Loki, kube-prometheus-stack (Prometheus + Grafana), Alloy, Falcosidekick -> Loki,
# Grafana admin sirri (ESO), kazima hedefleri ve "SecureStream Security" dashboard'u.
# Insan calistirir, admin kubeconfig ile:
#   sudo KUBECONFIG=/etc/securestream/admin.kubeconfig ~/securestream/platform/install-monitoring.sh
# Chart'lar --repo ile cekilir (root icin helm repo add gerekmez); surumler versions.conf'ta.
# Tekrar calistirmak guvenlidir (helm upgrade --install, kubectl apply). Hicbir sir degeri basilmaz.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR source=versions.conf
source versions.conf
fail() { echo "HATA: $*" >&2; exit 1; }
[[ -n ${KUBECONFIG:-} ]] || fail "KUBECONFIG tanimsiz (admin kubeconfig gerekir)"
kubectl auth can-i create namespaces >/dev/null || fail "bu kimlik namespace olusturamiyor (admin kubeconfig mi?)"

PROM_REPO=https://prometheus-community.github.io/helm-charts
GRAFANA_REPO=https://grafana.github.io/helm-charts
FALCO_REPO=https://falcosecurity.github.io/charts

echo "==> namespace monitoring + Grafana admin sirri (kume icinde uretilir)"
kubectl apply -f manifests/monitoring/namespace.yaml
kubectl apply -f manifests/monitoring/grafana-admin.yaml
for i in $(seq 1 30); do
  kubectl -n monitoring get secret grafana-admin -o name >/dev/null 2>&1 && break
  [[ $i == 30 ]] && fail "ExternalSecret grafana-admin Secret uretmedi: kubectl -n monitoring describe externalsecret grafana-admin"
  sleep 2
done
# Uzunluk kontrolu; deger basilmaz
LEN=$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d | wc -c)
[[ $LEN -ge 32 ]] || fail "grafana-admin sifresi beklenenden kisa ($LEN)"
echo "   grafana-admin: sifre uzunlugu $LEN"

echo "==> Loki ${LOKI_CHART_VERSION}"
helm upgrade --install loki loki --repo "$GRAFANA_REPO" --version "$LOKI_CHART_VERSION" \
  -n monitoring -f helm-values/loki.yaml --wait --timeout 10m

echo "==> kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}"
helm upgrade --install kps kube-prometheus-stack --repo "$PROM_REPO" --version "$KUBE_PROMETHEUS_STACK_VERSION" \
  -n monitoring -f helm-values/kube-prometheus-stack.yaml --wait --timeout 15m

echo "==> Alloy ${ALLOY_CHART_VERSION}"
helm upgrade --install alloy alloy --repo "$GRAFANA_REPO" --version "$ALLOY_CHART_VERSION" \
  -n monitoring -f helm-values/alloy.yaml --wait --timeout 10m

echo "==> Kazima hedefleri ve dashboard"
kubectl apply -f manifests/monitoring/scrape-targets.yaml
kubectl apply -f manifests/monitoring/dashboard-securestream-security.yaml

echo "==> Falco ${FALCO_CHART_VERSION} + Falcosidekick (Loki cikisi)"
helm upgrade --install falco falco --repo "$FALCO_REPO" --version "$FALCO_CHART_VERSION" \
  -n falco -f helm-values/falco.yaml --wait --timeout 10m

echo "==> Dogrulama"
kubectl -n monitoring get pods
kubectl -n falco get pods
CA=../infra/ansible/files/securestream-root-ca.crt
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" https://grafana.securestream.lab/api/health || true)
  [[ $code == 200 ]] && break
  [[ $i == 30 ]] && fail "https://grafana.securestream.lab/api/health -> $code (DNS kaydi ve sertifika?)"
  sleep 5
done
echo "   Grafana TLS (lab CA) /api/health -> 200"
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" https://grafana.securestream.lab/api/dashboards/uid/securestream-security)
[[ $code == 401 ]] || fail "kimliksiz dashboard istegi $code dondu, 401 bekleniyordu"
echo "   Kimliksiz API -> 401"
echo "==> Tamam. Falco -> Loki kaniti: ~/securestream/scripts/monitoring-falco-check.sh"
