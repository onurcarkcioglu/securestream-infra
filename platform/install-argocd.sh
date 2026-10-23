#!/usr/bin/env bash
# Argo CD (Item 10): kurulum, GitLab okuma erisimi (deploy token) ve "platform-manifests" uygulamasi.
# Insan calistirir, sudo OLMADAN (ssh ubuntu anahtarlariyla); kume islemleri icinde sudo + admin kubeconfig:
#   ~/securestream/platform/install-argocd.sh
# Deploy token (yalnizca read_repository, 90 gun) gitlab-rails'ten pipe ile Secret manifest'ine, oradan
# kubectl apply'a gider: ekrana, argumana, diske girmez. Her calistirmada eski "argocd" token'i iptal edilir.
# Tekrar calistirmak guvenlidir.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source-path=SCRIPTDIR source=versions.conf
source versions.conf
fail() { echo "HATA: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || fail "sudo olmadan calistirin (ssh icin kullanici anahtari gerekir)"
ADMIN_KUBECONFIG=/etc/securestream/admin.kubeconfig
k() { sudo env KUBECONFIG="$ADMIN_KUBECONFIG" "$@"; }
GITLAB=ubuntu@10.10.10.10
REPO=https://gitlab.securestream.lab/securestream/securestream.git
CA=../infra/ansible/files/securestream-root-ca.crt

echo "==> Argo CD chart ${ARGOCD_CHART_VERSION}"
k helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace -f helm-values/argocd.yaml \
  --set-file 'configs.tls.certificates.gitlab\.securestream\.lab'="$CA" --wait --timeout 10m

echo "==> GitLab deploy token (read_repository, 90 gun) -> Secret argocd/repo-securestream"
RB=$(cat <<'RUBY'
p = Project.find_by_full_path("securestream/securestream") or abort "HATA: proje yok"
p.deploy_tokens.active.where(name: "argocd").each(&:revoke!)
admin = User.find_by_username("root") or abort "HATA: root yok"
res = DeployTokens::CreateService.new(p, admin, name: "argocd", read_repository: true,
  expires_at: 90.days.from_now).execute
abort "HATA: deploy token olusturulamadi: #{res[:message]}" unless res[:status] == :success
t = res[:deploy_token]
puts "TOKEN #{t.username} #{t.token}"
RUBY
)
# shellcheck disable=SC2016,SC2029  # Python tek tirnakta (genisleme yok); Ruby kodu bilerek istemci tarafinda, printf %q ile
ssh "$GITLAB" "sudo gitlab-rails runner $(printf %q "$RB")" \
  | sed -n 's/^TOKEN \([A-Za-z0-9+_.-]\{4,\}\) \([A-Za-z0-9_-]\{20,\}\)$/\1 \2/p' \
  | python3 -I -c '
import json, sys
line = sys.stdin.read().split()
if len(line) != 2:
    sys.exit("HATA: deploy token alinamadi")
user, token = line
json.dump({"apiVersion": "v1", "kind": "Secret",
           "metadata": {"name": "repo-securestream", "namespace": "argocd",
                        "labels": {"argocd.argoproj.io/secret-type": "repository"}},
           "stringData": {"type": "git", "url": sys.argv[1], "username": user, "password": token}},
          sys.stdout)' "$REPO" \
  | k kubectl apply -f -

echo "==> AppProject platform + Application platform-manifests (elle senkronizasyon)"
k kubectl apply -f manifests/argocd/platform-project.yaml

echo "==> Dogrulama"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" https://argocd.securestream.lab/healthz || true)
  [[ $code == 200 ]] && break
  [[ $i == 30 ]] && fail "https://argocd.securestream.lab/healthz -> $code"
  sleep 5
done
echo "   Argo CD TLS (lab CA) /healthz -> 200"
for i in $(seq 1 24); do
  sync=$(k kubectl -n argocd get application platform-manifests -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  [[ -n $sync && $sync != Unknown ]] && break
  sleep 5
done
echo "   platform-manifests: sync=${sync:-?} (OutOfSync = kume Git'ten farkli; ayrinti arayuzde)"
[[ -n $sync && $sync != Unknown ]] || fail "uygulama depoyu okuyamadi: kubectl -n argocd describe application platform-manifests"
echo "==> Tamam. Admin sifresi: argocd-initial-admin-secret (insan okur, giriste degistirir, sonra Secret'i siler)"
