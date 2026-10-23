#!/usr/bin/env bash
# Tasimadan sonra kalan duz metin yerel state kopyalarini siler.
# Once scripts/tfstate-verify.sh calisir (sifreli yedek + GitLab state + plan exit 0); gecmezse hicbir sey silinmez.
# Kullanim: scripts/tfstate-cleanup.sh [~/.config/securestream/tfstate-backup-<tarih>.vault]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "HATA: $*" >&2; exit 1; }

"$ROOT/scripts/tfstate-verify.sh" "$@"

cd "$ROOT/infra/terraform/proxmox"
FILES=()
for f in terraform.tfstate terraform.tfstate.backup; do
  if [[ -e $f ]]; then FILES+=("$f"); fi
done
if [[ ${#FILES[@]} -eq 0 ]]; then echo "Silinecek yerel kopya yok."; exit 0; fi
ls -l "${FILES[@]}"
read -rp "Bu dosyalari shred ile silmek icin SIL yazin (baska bir sey: birak): " ANS
if [[ $ANS != SIL ]]; then echo "Silinmedi."; exit 0; fi
shred -u "${FILES[@]}"
if ls terraform.tfstate* >/dev/null 2>&1; then fail "yerel state dosyasi hala var"; fi
echo "Yerel duz metin kopyalar silindi; state yalnizca GitLab'da (+ sifreli yedek)."
