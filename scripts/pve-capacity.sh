#!/usr/bin/env bash
# pve1 kapasitesi (salt okunur): RAM, CPU, depolama ve VM'lere ayrilan kaynaklar. pve1'e SSH yok;
# Proxmox API, terraform'un kisitli token'i ve pve1 CA'si ile (TLS dogrulamasi acik) okunur.
# Token yalnizca stdin uzerinden curl'e gider (komut satirinda/ekranda gorunmez).
# Kullanim: scripts/pve-capacity.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CFG=$HOME/.config/securestream
PVE_CA=$ROOT/infra/terraform/proxmox/pve-root-ca.pem
NODE=${NODE:-pve1}
fail() { echo "HATA: $*" >&2; exit 1; }

[[ -f $CFG/pve.env ]] || fail "$CFG/pve.env yok"
set -a; . "$CFG/pve.env"; set +a
[[ ${PROXMOX_VE_ENDPOINT:-} == https://* ]] || fail "PROXMOX_VE_ENDPOINT https:// ile baslamiyor"
[[ -n ${PROXMOX_VE_API_TOKEN:-} ]] || fail "PROXMOX_VE_API_TOKEN bos"

api() {
  printf 'Authorization: PVEAPIToken=%s\n' "$PROXMOX_VE_API_TOKEN" |
    curl -sS --fail --cacert "$PVE_CA" -H @- "${PROXMOX_VE_ENDPOINT%/}/api2/json$1"
}

echo "== $NODE =="
# terraform@pve token'inda Sys.Audit yok: 403 beklenen bir sonuc, betigi durdurmaz.
if STATUS=$(api "/nodes/$NODE/status" 2>/dev/null); then
  jq -r '.data |
    "CPU: \(.cpuinfo.cpus) thread, kullanim %\(.cpu*100|floor)",
    "RAM: toplam \(.memory.total/1073741824|floor) GiB, kullanilan \(.memory.used/1073741824|floor) GiB, bos \(.memory.free/1073741824|floor) GiB"' <<<"$STATUS"
else
  echo "Dugum durumu okunamadi (token'da Sys.Audit yok); toplam RAM/CPU pve1 arayuzunden insan tarafindan okunmali."
fi
echo "== Depolama =="
api "/nodes/$NODE/storage" | jq -r '.data[] | select(.active==1) |
  "\(.storage): toplam \(.total/1073741824|floor) GiB, kullanilan \(.used/1073741824|floor) GiB, bos \(.avail/1073741824|floor) GiB"'
echo "== VM'lere ayrilan =="
api "/nodes/$NODE/qemu" | jq -r '
  (.data | sort_by(.vmid)[] | "\(.vmid) \(.name) \(.status) cpu=\(.cpus) ram=\(.maxmem/1073741824|floor)GiB disk=\(.maxdisk/1073741824|floor)GiB"),
  "TOPLAM (calisan): cpu=\([.data[]|select(.status=="running")|.cpus]|add) ram=\([.data[]|select(.status=="running")|.maxmem]|add/1073741824|floor)GiB"'
