#!/usr/bin/env bash
# Platform NetworkPolicy'lerini namespace namespace uygular; her birinden sonra o namespace'in islevini test eder
# (webhook'lar sunucu tarafi dry-run ile, ingress HTTPS ile). Test basarisizsa o namespace'in politikalari hemen
# silinir ve betik durur (NetworkPolicy silmek pod olusturmak degildir; Kyverno webhook'u kapali olsa da calisir).
# Insan calistirir, admin kubeconfig ile:
#   sudo KUBECONFIG=/etc/securestream/admin.kubeconfig ~/securestream/scripts/netpol-rollout.sh [namespace...]
# Argumansiz: asagidaki sirayla hepsi. Tekrar calistirmak guvenlidir. Sir basilmaz.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "HATA: $*" >&2; exit 1; }
[[ -t 0 ]] || fail "terminalden calistirin (falco testi kubectl run -it kullanir)"
[[ -n ${KUBECONFIG:-} ]] || fail "KUBECONFIG tanimsiz (admin kubeconfig gerekir)"
kubectl auth can-i create networkpolicies -n kube-system >/dev/null || fail "bu kimlik NetworkPolicy olusturamiyor"
DIR=platform/manifests/network-policies
CA=infra/ansible/files/securestream-root-ca.crt
# Etkisi en kucukten en buyuge; kyverno (pod olusturma webhook'u) en sonda
ORDER=(default demo external-secrets cert-manager metallb-system traefik falco monitoring kyverno)

# Sunucu tarafi dry-run, webhook'u tetikler; webhook'a ulasilamazsa "failed calling webhook" doner
dry_run() {
  local out
  out=$(kubectl apply --dry-run=server -f - 2>&1) && return 0
  echo "$out" >&2
  return 1
}
https_ok() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" "$1" || true)
  [[ $code == "$2" ]] || { echo "   $1 -> HTTP $code (beklenen $2)" >&2; return 1; }
}

test_ns() {
  case $1 in
    default) true ;;
    demo) https_ok https://whoami.apps.securestream.lab/ 200 ;;
    external-secrets) dry_run <<'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: netpol-webhook-test, namespace: demo }
spec:
  secretStoreRef: { name: does-not-exist, kind: SecretStore }
  target: { name: netpol-webhook-test }
  data: [{ secretKey: k, remoteRef: { key: k } }]
EOF
      ;;
    cert-manager) dry_run <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: netpol-webhook-test, namespace: demo }
spec:
  secretName: netpol-webhook-test
  dnsNames: [netpol-webhook-test.securestream.lab]
  issuerRef: { name: securestream-lab-ca, kind: ClusterIssuer }
EOF
      ;;
    metallb-system) dry_run <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: netpol-webhook-test, namespace: metallb-system }
spec:
  addresses: [10.10.10.250/32]
  autoAssign: false
EOF
      ;;
    traefik) https_ok https://catalog.securestream.lab/healthz 200 ;;
    falco)
      # Falcosidekick'e erisim: olay hatti kaniti (kabuk -> Falco -> Falcosidekick -> Loki); -it icin TTY ister,
      # cikti yonlendirilmez
      scripts/monitoring-falco-check.sh ;;
    monitoring)
      https_ok https://grafana.securestream.lab/api/health 200 &&
        https_ok https://grafana.securestream.lab/api/dashboards/uid/securestream-security 401 ;;
    kyverno)
      # Pod olusturma webhook'u (Fail): imzasi gerekmeyen bir pod kabul edilmeli, imzasiz lab imaji reddedilmeli
      dry_run <<'EOF' || return 1
apiVersion: v1
kind: Pod
metadata: { name: netpol-webhook-test, namespace: demo }
spec:
  securityContext: { runAsNonRoot: true, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: t
      image: registry.securestream.lab/securestream/does-not-exist@sha256:0000000000000000000000000000000000000000000000000000000000000000
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
      ;;
  esac
}

# kyverno testi: imzasiz imaj REDDEDILMELI; reddin webhook erisim hatasi olmamasi gerekir
kyverno_check() {
  local out
  if out=$(test_ns kyverno 2>&1); then
    echo "   imzasiz imaj kabul edildi: Kyverno dogrulamasi calismiyor" >&2; return 1
  fi
  if grep -q -i -E 'failed calling webhook|context deadline|connection refused|no route' <<<"$out"; then
    echo "$out" >&2; echo "   Kyverno webhook'una ulasilamadi" >&2; return 1
  fi
  grep -q -i -E 'x509|unknown authority' <<<"$out" && { echo "$out" >&2; echo "   TLS hatasi" >&2; return 1; }
  echo "   imzasiz imaj reddedildi: $(grep -o -i -m1 'denied the request.*' <<<"$out" | cut -c1-140)"
}

run_test() { if [[ $1 == kyverno ]]; then kyverno_check; else test_ns "$1"; fi; }

namespaces=("$@")
[[ ${#namespaces[@]} -gt 0 ]] || namespaces=("${ORDER[@]}")
for ns in "${namespaces[@]}"; do
  f=$DIR/$ns.yaml
  [[ -f $f ]] || fail "$f yok"
  echo "==> $ns"
  python3 -I scripts/netpol-check.py "$f" >/dev/null || fail "$ns: secici/port kontrolu basarisiz: python3 -I scripts/netpol-check.py $f"
  run_test "$ns" || fail "$ns: politikalardan ONCE test basarisiz; once mevcut sorunu cozun"
  kubectl apply -f "$f" >/dev/null
  sleep 5   # kube-router kurallari uygulasin
  ok=0
  for _ in 1 2 3; do
    if run_test "$ns"; then ok=1; break; fi
    sleep 10
  done
  if [[ $ok != 1 ]]; then
    kubectl delete -f "$f" --ignore-not-found >/dev/null
    fail "$ns: politikalardan sonra test basarisiz; politikalar GERI ALINDI ($f)"
  fi
  echo "   $ns: politikalar uygulandi, test gecti"
done
echo "==> Tamam: ${namespaces[*]}"
