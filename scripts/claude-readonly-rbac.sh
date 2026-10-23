#!/usr/bin/env bash
# claude-readonly RBAC manifestini kumenin API kesfinden uretir (platform/manifests/claude-readonly-rbac.yaml).
# RBAC'ta "haric tut" yoktur: secrets disindaki her listelenebilir kaynak acikca yazilir; alt kaynaklar
# (pods/log, pods/exec, serviceaccounts/token ...) hic yazilmaz. Yalnizca get/list/watch.
# Kullanim: claude-readonly-rbac.sh          manifesti yeniden uretir
#           claude-readonly-rbac.sh --check  kume ile manifest farkliysa exit 1 (yeni CRD, kaldirilan grup)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=platform/manifests/claude-readonly-rbac.yaml
NS=claude-readonly
# Hic okunmayacak kaynaklar: Secret degerleri ve uretilmis sir durumu tutabilen ESO generator grubu
EXCLUDED_RESOURCES='^secrets$'
EXCLUDED_GROUPS='^generators[.]external-secrets[.]io$'
fail() { echo "HATA: $*" >&2; exit 2; }

# "pods", "deployments.apps", "certificates.cert-manager.io" -> "<grup> <kaynak>" (cekirdek grup: "-")
RES=$(kubectl api-resources --verbs=list -o name | awk '
  { i = index($0, "."); if (i == 0) print "- " $0; else print substr($0, i + 1) " " substr($0, 1, i - 1) }' \
  | sort -u)
[[ -n $RES ]] || fail "API kesfi bos dondu"
COUNT_SECRETS=$(awk '$1 == "-" && $2 == "secrets"' <<<"$RES" | wc -l)
[[ $COUNT_SECRETS -eq 1 ]] || fail "cekirdek grupta secrets bulunamadi; kesif beklenen gibi degil"

render() {
  cat <<EOF
# Ansible/elle duzenleme yok: scripts/claude-readonly-rbac.sh ile uretilir (kume API kesfi).
# AI asistani icin salt okunur kimlik. Secrets, alt kaynaklar (pods/log, pods/exec) ve
# generators.external-secrets.io okunamaz. Token: scripts/claude-kubeconfig.sh (sureli, Secret'ta saklanmaz).
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: claude-readonly
  namespace: $NS
automountServiceAccountToken: false
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: claude-readonly
rules:
EOF
  awk -v xr="$EXCLUDED_RESOURCES" -v xg="$EXCLUDED_GROUPS" '
    $2 ~ xr && $1 == "-" { next }
    $1 ~ xg { next }
    { g = ($1 == "-") ? "" : $1; if (!(g in seen)) { order[++n] = g; seen[g] = 1 } r[g] = r[g] (r[g] ? ", " : "") "\"" $2 "\"" }
    END {
      for (k = 1; k <= n; k++) {
        g = order[k]
        printf "  - apiGroups: [\"%s\"]\n    resources: [%s]\n    verbs: [\"get\", \"list\", \"watch\"]\n", g, r[g]
      }
    }' <<<"$RES"
  cat <<EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: claude-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: claude-readonly
subjects:
  - kind: ServiceAccount
    name: claude-readonly
    namespace: $NS
EOF
}

NEW=$(render)
grep -q '"secrets"' <<<"$NEW" && fail "secrets manifestte; uretim hatali"
if [[ ${1:-} == --check ]]; then
  if diff <(cat "$OUT") <(echo "$NEW") >/dev/null; then
    echo "OK  $OUT kume ile ayni"
  else
    diff <(cat "$OUT") <(echo "$NEW") || true
    echo "FARK: kume API'si degisti; betigi argumansiz calistir, farki incele, kubectl apply" >&2
    exit 1
  fi
else
  echo "$NEW" > "$OUT"
  echo "Yazildi: $OUT ($(grep -c 'apiGroups' "$OUT") grup)"
fi
