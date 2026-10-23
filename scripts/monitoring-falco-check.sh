#!/usr/bin/env bash
# Item 9 kaniti: konteynerde etkilesimli kabuk -> Falco olayi -> Falcosidekick -> Loki.
# Insan calistirir (terminalde, -it icin), admin kubeconfig ile:
#   sudo KUBECONFIG=/etc/securestream/admin.kubeconfig ~/securestream/scripts/monitoring-falco-check.sh
# 1) monitoring'de gecici bir busybox podunda -it kabuk acilir ve hemen kapanir (pod silinir).
# 2) Loki'ye port-forward ile sorgu: son 10 dakikadaki "Terminal shell in container" olaylari.
# Cikti yalnizca kural, oncelik, pod ve zaman; olay govdesi basilmaz.
set -euo pipefail
fail() { echo "HATA: $*" >&2; exit 1; }
[[ -t 0 ]] || fail "terminalden calistirin (kubectl run -it TTY ister)"
[[ -n ${KUBECONFIG:-} ]] || fail "KUBECONFIG tanimsiz (admin kubeconfig gerekir)"
IMAGE="busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
POD="falco-shell-test-$(date +%s)"

echo "==> $POD: -it kabuk (Falco 'Terminal shell in container' tetiklenmeli)"
kubectl -n monitoring run "$POD" --image="$IMAGE" --restart=Never -it --rm -- sh -c 'echo kabuk acildi; exit 0'

echo "==> Loki sorgusu (port-forward 127.0.0.1:13100)"
kubectl -n monitoring port-forward svc/loki 13100:3100 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
for i in $(seq 1 20); do
  curl -sf http://127.0.0.1:13100/ready >/dev/null && break
  [[ $i == 20 ]] && fail "Loki port-forward hazir degil"
  sleep 1
done
# Falcosidekick olayi birkac saniye icinde iletir
for i in $(seq 1 12); do
  OUT=$(curl -sfG http://127.0.0.1:13100/loki/api/v1/query_range \
    --data-urlencode 'query={rule="Terminal shell in container"}' \
    --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" --data-urlencode limit=20)
  N=$(jq '[.data.result[].values[]] | length' <<<"$OUT")
  [[ $N -gt 0 ]] && break
  sleep 5
done
[[ $N -gt 0 ]] || fail "Loki'de son 10 dakikada 'Terminal shell in container' olayi yok"
echo "Loki: $N olay. Son olaylar (zaman, oncelik, pod):"
jq -r '.data.result[] | .stream as $s | .values[] | [(.[0] | tonumber / 1e9 | todate), $s.priority, ((.[1] | fromjson? | .output_fields["k8s.pod.name"]) // "?")] | @tsv' <<<"$OUT" \
  | sort -r | head -5
if grep -q "$POD" <<<"$(jq -r '.data.result[].values[][1]' <<<"$OUT")"; then
  echo "OK: olay test podu $POD icin"
else
  fail "olaylar var ama $POD icin degil"
fi
