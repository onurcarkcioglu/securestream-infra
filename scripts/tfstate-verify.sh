#!/usr/bin/env bash
# GitLab'daki Terraform state'ini sifreli yerel yedekle karsilastirir. Ciktida state icerigi yoktur.
# Kullanim: scripts/tfstate-verify.sh [~/.config/securestream/tfstate-backup-<tarih>.vault]  (varsayilan: en yenisi)
# Sart: kaynak adresleri + ID'ler yedekle ayni ve terraform plan "degisiklik yok" (exit 0).
# Lineage/serial yalnizca bilgi icin yazdirilir: bos bir remote backend'e tasimada Terraform yeni lineage
# uretir (terraform v1.16.6, internal/states/remote/state.go, PersistState), esitlik beklenmez.
set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT/infra/terraform/proxmox"
CFG=$HOME/.config/securestream
fail() { echo "HATA: $*" >&2; exit 1; }

BK=${1:-$(ls -t "$CFG"/tfstate-backup-*.vault 2>/dev/null | head -n1 || true)}
[[ -n $BK && -f $BK ]] || fail "sifreli yedek bulunamadi"
head -c 14 "$BK" | grep -q '^\$ANSIBLE_VAULT' || fail "yedek sifreli gorunmuyor: $BK"
[[ -f $CFG/tfstate.env ]] || fail "$CFG/tfstate.env yok"
set -a; . "$CFG/pve.env"; . "$CFG/tfstate.env"; set +a
TF_HTTP_CLIENT_CA_CERTIFICATE_PEM=$(cat "$ROOT/infra/ansible/files/securestream-root-ca.crt")
export TF_HTTP_CLIENT_CA_CERTIFICATE_PEM
# ansible-vault parolasi mevcut duzenden: ansible.cfg -> vault_password_file
export ANSIBLE_CONFIG=$ROOT/infra/ansible/ansible.cfg

# Kaynak adresi (module/data/index dahil) + ID, adrese gore sirali
ids() {
  jq -c '[.resources[] as $r | $r.instances[] | {
      addr: ((if $r.module then $r.module + "." else "" end)
             + (if $r.mode == "data" then "data." else "" end) + $r.type + "." + $r.name
             + (if .index_key == null then "" else "[" + (.index_key | tojson) + "]" end)),
      id: .attributes.id}] | sort_by(.addr)'
}
meta() { jq -r '"lineage=\(.lineage) serial=\(.serial)"'; }
backup_state() { ansible-vault decrypt --output - "$BK" | tar -xOf - terraform.tfstate; }

B_IDS=$(backup_state | ids) || fail "yedek acilamadi: $BK"
R_IDS=$("$ROOT/scripts/tf.sh" state pull | ids) || fail "GitLab state okunamadi"
N=$(jq length <<<"$B_IDS")
[[ $N -gt 0 ]] || fail "yedekte kaynak yok: $BK"
if [[ $B_IDS != "$R_IDS" ]]; then
  echo "Fark (< yedek, > GitLab):" >&2
  diff <(jq -r '.[] | "\(.addr) \(.id)"' <<<"$B_IDS") <(jq -r '.[] | "\(.addr) \(.id)"' <<<"$R_IDS") >&2 || true
  fail "kaynak adresleri/ID'ler tutmuyor"
fi
echo "Kaynaklar: $N adres+ID yedekle ayni"
echo "Bilgi: yedek $(backup_state | meta) | GitLab $("$ROOT/scripts/tf.sh" state pull | meta)"

set +e; "$ROOT/scripts/tf.sh" plan -detailed-exitcode -input=false -lock-timeout=60s; RC=$?; set -e
case $RC in
  0) echo "Plan: degisiklik yok" ;;
  2) fail "plan degisiklik gosteriyor; apply YAPMAYIN" ;;
  *) fail "plan hata verdi (kod $RC)" ;;
esac
echo "DOGRULAMA GECTI: $BK"
