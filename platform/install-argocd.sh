#!/usr/bin/env bash
# Argo CD (Item 10): kurulum, GitLab okuma erisimi (deploy token) ve "platform-manifests" uygulamasi.
# Insan calistirir, sudo OLMADAN (ssh ubuntu anahtarlariyla); kume islemleri icinde sudo + admin kubeconfig:
#   ~/securestream/platform/install-argocd.sh
# Deploy token (yalnizca read_repository, 90 gun) gitlab-rails'ten pipe ile Secret manifest'ine, oradan
# kubectl apply'a gider: ekrana, argumana, diske girmez.
# Token sirasi: yeni token ("argocd-<UTC zaman>") olusturulur, Secret'a yazilir, Argo CD depoyu yeni token'la
# okuyabildigi dogrulanir; eski "argocd" / "argocd-*" token'lari EN SON iptal edilir. Dogrulama basarisiz olursa
# eski token'lar dokunulmadan kalir; tekrar calistirmak artik token'lari da temizler. Tekrar calistirmak guvenlidir.
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
APP=platform-manifests
TOKEN_NAME="argocd-$(date -u +%Y%m%d%H%M%S)"
# gitlab-rails runner: Ruby kodu ssh uzerinden calisir (kod sir icermez, cikti pipe'ta kalir)
rails() {
  # shellcheck disable=SC2029  # Ruby kodu bilerek istemci tarafinda, printf %q ile
  ssh "$GITLAB" "sudo gitlab-rails runner $(printf %q "$1")"
}

echo "==> Argo CD chart ${ARGOCD_CHART_VERSION}"
k helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" -n argocd --create-namespace -f helm-values/argocd.yaml \
  --set-file 'configs.tls.certificates.gitlab\.securestream\.lab'="$CA" --wait --timeout 10m

echo "==> Yeni GitLab deploy token $TOKEN_NAME (read_repository, 90 gun) -> Secret argocd/repo-securestream"
RB_CREATE=$(cat <<'RUBY'
p = Project.find_by_full_path("securestream/securestream") or abort "HATA: proje yok"
admin = User.find_by_username("root") or abort "HATA: root yok"
res = DeployTokens::CreateService.new(p, admin, name: "__NAME__", read_repository: true,
  expires_at: 90.days.from_now).execute
abort "HATA: deploy token olusturulamadi: #{res[:message]}" unless res[:status] == :success
t = res[:deploy_token]
puts "TOKEN #{t.username} #{t.token}"
RUBY
)
# shellcheck disable=SC2016  # Python tek tirnakta (genisleme yok)
rails "${RB_CREATE//__NAME__/$TOKEN_NAME}" \
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

echo "==> AppProject platform + Application $APP (elle senkronizasyon)"
k kubectl apply -f manifests/argocd/platform-project.yaml

echo "==> Dogrulama"
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" https://argocd.securestream.lab/healthz || true)
  [[ $code == 200 ]] && break
  [[ $i == 30 ]] && fail "https://argocd.securestream.lab/healthz -> $code"
  sleep 5
done
echo "   Argo CD TLS (lab CA) /healthz -> 200"
# Hard refresh: depo yeni token'la yeniden okunur (onceki calismadan kalan onbellekli durum sayilmaz)
k kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sync=""; refresh=pending
for i in $(seq 1 24); do
  refresh=$(k kubectl -n argocd get application "$APP" \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/refresh}' 2>/dev/null || echo pending)
  sync=$(k kubectl -n argocd get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  [[ -z $refresh && -n $sync && $sync != Unknown ]] && break
  sleep 5
done
cmperr=$(k kubectl -n argocd get application "$APP" \
  -o jsonpath='{.status.conditions[?(@.type=="ComparisonError")].message}' 2>/dev/null || true)
echo "   $APP: sync=${sync:-?} (OutOfSync = kume Git'ten farkli; ayrinti arayuzde)"
[[ -z $refresh && -n $sync && $sync != Unknown && -z $cmperr ]] \
  || fail "uygulama depoyu yeni token'la okuyamadi (refresh=${refresh:-bitti}, ${cmperr:-hata mesaji yok}); eski token'lar iptal EDILMEDI: kubectl -n argocd describe application $APP"

echo "==> Eski deploy token'lari iptal (yeni token $TOKEN_NAME dogrulandi)"
RB_REVOKE=$(cat <<'RUBY'
p = Project.find_by_full_path("securestream/securestream") or abort "HATA: proje yok"
keep = p.deploy_tokens.active.find_by(name: "__NAME__") or abort "HATA: yeni token aktif degil; iptal yapilmadi"
old = p.deploy_tokens.active.where("name = ? OR name LIKE ?", "argocd", "argocd-%").where.not(id: keep.id).to_a
old.each(&:revoke!)
puts "REVOKED #{old.size}"
RUBY
)
revoked=$(rails "${RB_REVOKE//__NAME__/$TOKEN_NAME}" | sed -n 's/^REVOKED \([0-9]\{1,\}\)$/\1/p' || true)
[[ -n $revoked ]] || fail "eski token iptali dogrulanamadi (GitLab: securestream/securestream > Settings > Repository > Deploy tokens)"
echo "   iptal edilen eski token: $revoked"
echo "==> Tamam. Admin sifresi: argocd-initial-admin-secret (insan okur, giriste degistirir, sonra Secret'i siler)"
