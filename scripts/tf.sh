#!/usr/bin/env bash
# terraform'u yalnizca bu surec icin dogru guven ayarlariyla calistirir; sistem geneli hicbir sey degismez.
# - Proxmox API: TLS dogrulamasi acik (PROXMOX_VE_INSECURE=false zorunlu). bpg/proxmox ozel CA parametresi
#   sunmuyor (v0.118.0, proxmox/api/client.go: RootCAs bos -> Go sistem havuzu). pve1'in kendi CA'si sistem
#   paketiyle birlestirilip yalnizca terraform'a SSL_CERT_FILE olarak verilir; sistem paketi de icinde oldugu
#   icin registry.terraform.io bozulmaz (bkz. lessons-learned GIT_SSL_CAINFO dersi).
# - GitLab state: TF_HTTP_CLIENT_CA_CERTIFICATE_PEM = lab CA.
# Kullanim: scripts/tf.sh plan | apply | state list | init ...
# Negatif test: TF_PVE_CA_OVERRIDE=<pem> ile baska bir CA verilir; baglanti reddedilmeli.
set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TFDIR=$ROOT/infra/terraform/proxmox
CFG=$HOME/.config/securestream
fail() { echo "HATA: $*" >&2; exit 1; }

SYS_BUNDLE=/etc/ssl/certs/ca-certificates.crt
PVE_CA_SHA256=83:0B:10:A3:01:98:9E:2D:F4:97:6B:59:26:BA:51:C2:15:20:99:3D:3C:EA:EE:7B:6C:87:63:4F:19:44:6B:92
PVE_CA=${TF_PVE_CA_OVERRIDE:-$TFDIR/pve-root-ca.pem}
[[ -f $SYS_BUNDLE ]] || fail "$SYS_BUNDLE yok"
[[ -f $PVE_CA ]] || fail "$PVE_CA yok"
if [[ -z ${TF_PVE_CA_OVERRIDE:-} ]]; then
  GOT=$(openssl x509 -in "$PVE_CA" -noout -fingerprint -sha256 | cut -d= -f2)
  [[ $GOT == "$PVE_CA_SHA256" ]] || fail "pve-root-ca.pem parmak izi beklenen degil: $GOT"
else
  echo "UYARI: test icin baska CA kullaniliyor: $PVE_CA" >&2
fi

[[ -f $CFG/pve.env && -f $CFG/tfstate.env ]] || fail "$CFG/pve.env veya tfstate.env yok"
set -a; . "$CFG/pve.env"; . "$CFG/tfstate.env"; set +a
[[ ${PROXMOX_VE_INSECURE:-false} == false ]] || fail "PROXMOX_VE_INSECURE=$PROXMOX_VE_INSECURE; false olmali"
export PROXMOX_VE_INSECURE=false
[[ ${PROXMOX_VE_ENDPOINT:-} == https://* ]] || fail "PROXMOX_VE_ENDPOINT https:// ile baslamiyor"
TF_HTTP_CLIENT_CA_CERTIFICATE_PEM=$(cat "$ROOT/infra/ansible/files/securestream-root-ca.crt")
export TF_HTTP_CLIENT_CA_CERTIFICATE_PEM

BUNDLE=$(mktemp)
trap 'rm -f "$BUNDLE"' EXIT
cat "$SYS_BUNDLE" "$PVE_CA" > "$BUNDLE"
cd "$TFDIR"
SSL_CERT_FILE=$BUNDLE terraform "$@"
