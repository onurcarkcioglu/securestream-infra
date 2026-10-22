#!/usr/bin/env bash
# Platform bileşenlerini sabit sürümlerle kurar ya da günceller.
# Tekrar çalıştırmak güvenlidir (helm upgrade --install idempotent).
set -euo pipefail
cd "$(dirname "$0")"
source versions.conf

echo "==> MetalLB ${METALLB_VERSION}"
helm upgrade --install metallb metallb/metallb \
  --version "${METALLB_VERSION}" -n metallb-system --create-namespace --wait

# MetalLB webhook'u hazır olana kadar birkaç kez dene
for i in $(seq 1 12); do
  kubectl apply -f manifests/metallb-pool.yaml && break
  echo "   webhook henüz hazır değil, bekleniyor ($i/12)"; sleep 5
done

echo "==> cert-manager ${CERT_MANAGER_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "${CERT_MANAGER_VERSION}" -n cert-manager --create-namespace \
  -f helm-values/cert-manager.yaml --wait
kubectl apply -f manifests/cluster-issuer.yaml

echo "==> Traefik ${TRAEFIK_VERSION}"
helm upgrade --install traefik traefik/traefik \
  --version "${TRAEFIK_VERSION}" -n traefik --create-namespace \
  -f helm-values/traefik.yaml --wait

echo "==> Tamam"
