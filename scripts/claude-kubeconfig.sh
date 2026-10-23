#!/usr/bin/env bash
# AI asistaninin salt okunur kubeconfig'ini uretir: ~/.kube/claude-readonly.yaml (0600).
# ServiceAccount claude-readonly icin TokenRequest API ile sureli, bound token (Secret olarak saklanmaz;
# suresi dolunca gecersiz, SA silinince hemen gecersiz). Yonetici kubeconfig'i ile calisir; insan calistirir.
# Token ekrana, komut satiri argumanina ve loga girmez (printf bash builtin'dir). Cikti: uzunluk, bitis, can-i.
# Kullanim (kubeconfig-lockdown.sh sonrasi): sudo scripts/claude-kubeconfig.sh [sure, varsayilan 12h]
# ~/.kube/config bu dosyaya sembolik bag oldugu icin yenileme ikisini birlikte gunceller.
set -euo pipefail
DURATION=${1:-12h}
U=${SUDO_USER:-$(id -un)}
H=$(getent passwd "$U" | cut -d: -f6)
if [[ -z ${ADMIN_KUBECONFIG:-} ]]; then
  ADMIN_KUBECONFIG=/etc/securestream/admin.kubeconfig
  [[ -e $ADMIN_KUBECONFIG ]] || ADMIN_KUBECONFIG=$H/.kube/config   # lockdown oncesi
fi
OUT=$H/.kube/claude-readonly.yaml
NS=claude-readonly
SA=claude-readonly
fail() { echo "HATA: $*" >&2; exit 1; }
k() { kubectl --kubeconfig "$ADMIN_KUBECONFIG" "$@"; }

[[ -r $ADMIN_KUBECONFIG ]] || fail "yonetici kubeconfig okunamiyor: $ADMIN_KUBECONFIG (sudo ile calistir)"
[[ $(realpath -m "$ADMIN_KUBECONFIG") != $(realpath -m "$OUT") ]] || fail "yonetici kubeconfig claude-readonly olamaz"
k -n "$NS" get serviceaccount "$SA" >/dev/null || fail "ServiceAccount yok: kubectl apply -f platform/manifests/claude-readonly-rbac.yaml"

# Gizli olmayan alanlar: API adresi ve kumenin kok CA'si (her namespace'teki kube-root-ca.crt)
SERVER=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(k -n "$NS" get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' | base64 -w0)
[[ $SERVER == https://* && ${#CA} -gt 100 ]] || fail "API adresi ya da CA alinamadi"

umask 077
TMP=$(mktemp "$OUT.XXXXXX")
trap 'rm -f "$TMP"' EXIT
TOKEN=$(k -n "$NS" create token "$SA" --duration "$DURATION")
[[ $TOKEN =~ ^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || fail "token bicimi beklenen gibi degil (uzunluk ${#TOKEN})"
# JWT govdesinden yalnizca bitis zamani (exp) okunur
P=$(cut -d. -f2 <<<"$TOKEN" | tr '_-' '/+'); while (( ${#P} % 4 )); do P+="="; done
EXP=$(base64 -d <<<"$P" | jq -r '.exp')
printf 'apiVersion: v1\nkind: Config\nclusters:\n  - name: securestream\n    cluster:\n      server: %s\n      certificate-authority-data: %s\nusers:\n  - name: claude-readonly\n    user:\n      token: %s\ncontexts:\n  - name: claude-readonly\n    context:\n      cluster: securestream\n      user: claude-readonly\ncurrent-context: claude-readonly\n' \
  "$SERVER" "$CA" "$TOKEN" > "$TMP"
LEN=${#TOKEN}
unset TOKEN P
chown "$U:$U" "$TMP"
mv "$TMP" "$OUT"
trap - EXIT
echo "Yazildi: $OUT (mod $(stat -c %a "$OUT")), token uzunluk $LEN, bitis $(date -d "@$EXP" '+%F %T %Z')"

# Dogrulama: beklenen her cevap tutmazsa kirmizi
RC=0
check() {
  local want=$1; shift
  local got
  got=$(sudo -u "$U" env KUBECONFIG="$OUT" kubectl auth can-i "$@" 2>/dev/null) || true
  if [[ $got == "$want" ]]; then echo "OK    can-i $* -> $got"; else echo "FAIL  can-i $* -> ${got:-hata} (beklenen $want)"; RC=1; fi
}
check yes get pods -A
check yes list deployments.apps -A
check yes watch externalsecrets.external-secrets.io -A
check no get secrets -A
check no list secrets -n catalog
check no get pods --subresource=log -n catalog
check no create pods --subresource=exec -n catalog
check no create pods -n catalog
check no delete pods -n catalog
check no patch deployments.apps -n catalog
check no create serviceaccounts --subresource=token -n "$NS"
check no impersonate serviceaccounts -A
check no list generatorstates.generators.external-secrets.io -A
exit "$RC"
