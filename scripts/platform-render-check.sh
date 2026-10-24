#!/usr/bin/env bash
# Platform chart'larini repodaki values ile render eder (helm template, kumeye dokunmaz) ve denetler:
# her konteynerde istek+limit, her pod namespace'inin PSA enforce seviyesine uygun (platform-render-check.py).
# Kume erisimi ve sir gerekmez; chart'lar --repo ile ceker. Kurulum betiklerindeki release/values ile ayni tutulur.
# Kullanim: scripts/platform-render-check.sh   (exit 1 = ihlal; ayrinti ekrana)
set -euo pipefail
cd "$(dirname "$0")/../platform"
# shellcheck source-path=SCRIPTDIR/../platform source=../platform/versions.conf
source versions.conf
fail() { echo "HATA: $*" >&2; exit 2; }
command -v helm >/dev/null || fail "helm yok"
python3 -I -c 'import yaml' 2>/dev/null || fail "python3-yaml yok"
KUBE_VERSION=${KUBE_VERSION:-v1.36.5+k3s1}
CA=../infra/ansible/files/securestream-root-ca.crt
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# release | namespace | chart | repo | surum | values | ek argumanlar
CHARTS=(
  "metallb|metallb-system|metallb|https://metallb.github.io/metallb|$METALLB_VERSION|metallb.yaml|"
  "cert-manager|cert-manager|cert-manager|https://charts.jetstack.io|$CERT_MANAGER_VERSION|cert-manager.yaml|"
  "traefik|traefik|traefik|https://traefik.github.io/charts|$TRAEFIK_VERSION|traefik.yaml|"
  "kyverno|kyverno|kyverno|https://kyverno.github.io/kyverno/|$KYVERNO_CHART_VERSION|kyverno.yaml|--set-file=global.caCertificates.data=$CA"
  "external-secrets|external-secrets|external-secrets|https://charts.external-secrets.io|$ESO_CHART_VERSION|external-secrets.yaml|"
  "falco|falco|falco|https://falcosecurity.github.io/charts|$FALCO_CHART_VERSION|falco.yaml|"
  "loki|monitoring|loki|https://grafana.github.io/helm-charts|$LOKI_CHART_VERSION|loki.yaml|"
  "kps|monitoring|kube-prometheus-stack|https://prometheus-community.github.io/helm-charts|$KUBE_PROMETHEUS_STACK_VERSION|kube-prometheus-stack.yaml|"
  "alloy|monitoring|alloy|https://grafana.github.io/helm-charts|$ALLOY_CHART_VERSION|alloy.yaml|"
  "argocd|argocd|argo-cd|https://argoproj.github.io/argo-helm|$ARGOCD_CHART_VERSION|argocd.yaml|--set-file=configs.tls.certificates.gitlab\\.securestream\\.lab=$CA"
)

for row in "${CHARTS[@]}"; do
  IFS='|' read -r release ns chart repo version values extra <<<"$row"
  args=(template "$release" "$chart" --repo "$repo" --version "$version" -n "$ns" -f "helm-values/$values"
        --kube-version "$KUBE_VERSION")
  [[ -n $extra ]] && args+=("$extra")
  helm "${args[@]}" > "$OUT/$release.yaml" || fail "$release render edilemedi"
  echo "   render: $release ($chart $version)"
done

python3 -I ../scripts/platform-render-check.py \
  manifests/namespaces.yaml manifests/monitoring/namespace.yaml manifests/namespace-catalog.yaml -- "$OUT"/*.yaml
