#!/usr/bin/env bash
# Platform bilesenlerini sabit surumlerle kurar ya da gunceller: MetalLB, cert-manager, Traefik, Kyverno,
# External Secrets. Falco ve izleme yigini: install-monitoring.sh; Argo CD: install-argocd.sh.
# Insan calistirir, admin kubeconfig ile:
#   sudo KUBECONFIG=/etc/securestream/admin.kubeconfig ~/securestream/platform/install.sh
# Chart'lar --repo ile cekilir (root icin helm repo add gerekmez); surumler versions.conf'ta, ayarlar helm-values/.
# Tekrar calistirmak guvenlidir (helm upgrade --install idempotent). Hicbir sir degeri basilmaz.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR source=versions.conf
source versions.conf
fail() { echo "HATA: $*" >&2; exit 1; }
[[ -n ${KUBECONFIG:-} ]] || fail "KUBECONFIG tanimsiz (admin kubeconfig gerekir)"
kubectl auth can-i create namespaces >/dev/null || fail "bu kimlik namespace olusturamiyor (admin kubeconfig mi?)"

echo "==> MetalLB ${METALLB_VERSION} (yalnizca L2; frr-k8s kapali)"
helm upgrade --install metallb metallb --repo https://metallb.github.io/metallb \
  --version "${METALLB_VERSION}" -n metallb-system --create-namespace \
  -f helm-values/metallb.yaml --wait --timeout 10m

# MetalLB webhook'u hazir olana kadar birkac kez dene
for i in $(seq 1 12); do
  kubectl apply -f manifests/metallb-pool.yaml && break
  [[ $i == 12 ]] && fail "MetalLB webhook hazir olmadi: kubectl -n metallb-system get pods"
  echo "   webhook henuz hazir degil, bekleniyor ($i/12)"; sleep 5
done

echo "==> cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager cert-manager --repo https://charts.jetstack.io \
  --version "${CERT_MANAGER_VERSION}" -n cert-manager --create-namespace \
  -f helm-values/cert-manager.yaml --wait --timeout 10m
kubectl apply -f manifests/cluster-issuer.yaml

echo "==> Traefik ${TRAEFIK_VERSION}"
helm upgrade --install traefik traefik --repo https://traefik.github.io/charts \
  --version "${TRAEFIK_VERSION}" -n traefik --create-namespace \
  -f helm-values/traefik.yaml --wait --timeout 10m

# Kyverno tek replikayla calisir: guncelleme sirasinda admission controller kisa sure yeniden baslar.
# Guven deposu yalnizca lab root CA'si (helm-values/kyverno.yaml).
echo "==> Kyverno ${KYVERNO_CHART_VERSION}"
CA=../infra/ansible/files/securestream-root-ca.crt
helm upgrade --install kyverno kyverno --repo https://kyverno.github.io/kyverno/ \
  --version "${KYVERNO_CHART_VERSION}" -n kyverno --create-namespace \
  -f helm-values/kyverno.yaml --set-file "global.caCertificates.data=$CA" --wait --timeout 10m

echo "==> External Secrets ${ESO_CHART_VERSION}"
helm upgrade --install external-secrets external-secrets --repo https://charts.external-secrets.io \
  --version "${ESO_CHART_VERSION}" -n external-secrets --create-namespace \
  -f helm-values/external-secrets.yaml --wait --timeout 10m

# PSA etiketleri: once sunucu tarafinda dry-run; mevcut bir pod yeni seviyeyi ihlal ediyorsa API uyari dondurur.
# Uyari varsa etiketler uygulanmaz (ihlal eden pod yeniden olusturulamazdi). Guncellemeden kalan Terminating
# pod'lar gecici uyari uretebilir: bir dakika boyunca tekrar denenir.
echo "==> Namespace PSA etiketleri (manifests/namespaces.yaml)"
for i in $(seq 1 12); do
  psa_warn=$(kubectl apply --dry-run=server -f manifests/namespaces.yaml 2>&1 >/dev/null | grep -i 'warning' || true)
  [[ -z $psa_warn ]] && break
  [[ $i == 12 ]] && fail "PSA dry-run uyarisi, etiketler uygulanmadi:
$psa_warn"
  sleep 5
done
kubectl apply -f manifests/namespaces.yaml

echo "==> Dogrulama"
for ns in metallb-system cert-manager traefik kyverno external-secrets; do
  notready=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print $1" "$3}')
  [[ -z $notready ]] || fail "$ns: hazir olmayan pod(lar): $notready"
  echo "   $ns: tum pod'lar Running"
done
kubectl -n metallb-system get daemonset metallb-frr-k8s >/dev/null 2>&1 \
  && fail "metallb-frr-k8s DaemonSet hala var (frrk8s.enabled: false bekleniyordu)"
echo "   MetalLB: frr-k8s yok, yalnizca L2 speaker"
code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" https://catalog.securestream.lab/healthz || true)
[[ $code == 200 ]] || fail "https://catalog.securestream.lab/healthz -> HTTP $code (ingress/MetalLB IP?)"
echo "   Ingress (10.10.10.100) uzerinden catalog-api /healthz -> 200"
echo "==> Tamam"
