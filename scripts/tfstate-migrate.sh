#!/usr/bin/env bash
# Yerel (sifresiz) Terraform state'ini GitLab managed state'e tasir ve dogrular.
# Tasimadan once state + backup, ansible-vault ile ~/.config/securestream/tfstate-backup-<tarih>.vault
# olarak sifreli yedeklenir ve yedek acilip lineage ile dogrulanir. Tasima scripts/tfstate-verify.sh ile
# dogrulanir (adres + ID, plan exit 0). Yerel kopyalari silmek ayri adimdir: scripts/tfstate-cleanup.sh.
# Ciktida state icerigi yoktur.
#
# Geri donus (state'i yeniden yerel dosyaya almak):
#   cd ~/securestream/infra/terraform/proxmox && mv backend.tf backend.tf.off
#   a) GitLab erisilebilir ve guncel state oradaysa (tercih edilen):
#        set -a; . ~/.config/securestream/pve.env; . ~/.config/securestream/tfstate.env; set +a
#        TF_HTTP_CLIENT_CA_CERTIFICATE_PEM=$(cat ../../ansible/files/securestream-root-ca.crt) \
#          terraform init -migrate-state      # GitLab -> yerel; "yes" onayi
#      (backend.tf.off varken Terraform eski backend'i .terraform/ onbelleginden bilir)
#   b) GitLab erisilemiyorsa, sifreli yedekten:
#        (umask 077; ANSIBLE_CONFIG=../../ansible/ansible.cfg \
#          ansible-vault decrypt --output - ~/.config/securestream/tfstate-backup-<tarih>.vault | tar -xf -)
#        terraform init -reconfigure
#   Her iki durumda: chmod 600 terraform.tfstate*; terraform plan "degisiklik yok" demeli.
#   Not: (b) yedek tarihinden sonraki apply'lari icermez.
set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/infra/terraform/proxmox"
CFG=$HOME/.config/securestream
fail() { echo "HATA: $*" >&2; exit 1; }

[[ -f backend.tf ]] || fail "backend.tf yok"
[[ -f $CFG/tfstate.env ]] || fail "$CFG/tfstate.env yok; once scripts/tfstate-token.sh"
[[ -s terraform.tfstate ]] || fail "yerel terraform.tfstate yok veya bos (zaten tasinmis olabilir)"
set -a; . "$CFG/pve.env"; . "$CFG/tfstate.env"; set +a
TF_HTTP_CLIENT_CA_CERTIFICATE_PEM=$(cat "$ROOT/infra/ansible/files/securestream-root-ca.crt")
export TF_HTTP_CLIENT_CA_CERTIFICATE_PEM
# ansible-vault parolasi mevcut duzenden: ansible.cfg -> vault_password_file
export ANSIBLE_CONFIG=$ROOT/infra/ansible/ansible.cfg
command -v ansible-vault >/dev/null || fail "ansible-vault bulunamadi"
[[ -f terraform.tfstate.backup ]] || fail "terraform.tfstate.backup yok"
BK=$CFG/tfstate-backup-$(date +%Y%m%d-%H%M%S).vault
[[ ! -e $BK ]] || fail "$BK zaten var"

summary() { jq -r '"\(.lineage) instances=\([.resources[].instances[]] | length) serial=\(.serial)"'; }

BEFORE=$(summary < terraform.tfstate)
BEFORE_BAK=$(summary < terraform.tfstate.backup)
echo "Yerel state : $BEFORE"
echo "Yerel backup: $BEFORE_BAK"

# 1) Sifreli yedek: duz metin diske yazilmaz (tar -> stdin -> ansible-vault)
( umask 077; tar -cf - terraform.tfstate terraform.tfstate.backup | ansible-vault encrypt --output "$BK" - )
chmod 600 "$BK"
verify_backup() {
  local s b
  s=$(ansible-vault decrypt --output - "$BK" | tar -xOf - terraform.tfstate | summary) || return 1
  b=$(ansible-vault decrypt --output - "$BK" | tar -xOf - terraform.tfstate.backup | summary) || return 1
  [[ $s == "$BEFORE" && $b == "$BEFORE_BAK" ]]
}
verify_backup || fail "sifreli yedek acilamadi veya lineage/serial/sayi tutmuyor: $BK (tasima yapilmadi)"
head -c 14 "$BK" | grep -q '^\$ANSIBLE_VAULT' || fail "yedek sifreli gorunmuyor: $BK"
echo "Sifreli yedek dogrulandi: $BK (izin $(stat -c %a "$BK"))"

"$ROOT/scripts/tf.sh" init -migrate-state   # Terraform kopyalama icin "yes" onayi ister

# Backend onbelleginde token kalmamali (desen stdin'den, arguman listesine girmez)
if grep -qFf <(printf '%s\n' "$TF_HTTP_PASSWORD") .terraform/terraform.tfstate; then
  fail ".terraform/terraform.tfstate icinde token var"
fi

# Adres + ID karsilastirmasi ve plan exit 0 (lineage bos backend'e tasimada yeniden uretilir, bilgi amacli)
"$ROOT/scripts/tfstate-verify.sh" "$BK"
echo "Tasima tamam. Kalan duz metin yerel kopyalar icin: scripts/tfstate-cleanup.sh $BK"
