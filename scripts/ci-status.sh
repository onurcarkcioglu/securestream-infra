#!/usr/bin/env bash
# GitLab pipeline durumu ve is logu (salt okunur). Claude Code'da onaysiz calisir (allow kurali);
# bu yuzden argumanlar siki dogrulanir: gitlab-rails runner root yetkisiyle Ruby calistirir,
# dogrulanmamis girdi kod enjeksiyonu olurdu. Betik yalnizca okur (find_by, order, trace.raw).
# Kullanim:
#   scripts/ci-status.sh <grup/proje>                 son pipeline: id, sha, durum, isler
#   scripts/ci-status.sh <grup/proje> <is> [satir]    son pipeline'daki isin logunun son N satiri (vars. 40, en cok 500)
#   PIPELINE=<id> scripts/ci-status.sh ...            son yerine belirli bir pipeline
set -euo pipefail
GITLAB=ubuntu@10.10.10.10
fail() { echo "HATA: $*" >&2; exit 2; }

PROJECT=${1:-}
JOB=${2:-}
LINES=${3:-40}
PIPELINE=${PIPELINE:-}

[[ $PROJECT =~ ^[a-z0-9][a-z0-9._-]{0,63}/[a-z0-9][a-z0-9._-]{0,63}$ ]] || fail "proje 'grup/proje' biciminde olmali: '$PROJECT'"
[[ -z $JOB || $JOB =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || fail "is adi gecersiz: '$JOB'"
[[ $LINES =~ ^[0-9]{1,3}$ ]] && (( LINES >= 1 && LINES <= 500 )) || fail "satir sayisi 1-500 olmali: '$LINES'"
[[ -z $PIPELINE || $PIPELINE =~ ^[0-9]{1,9}$ ]] || fail "PIPELINE sayi olmali: '$PIPELINE'"
(( $# <= 3 )) || fail "en fazla 3 arguman"

# Degerler dogrulandiktan sonra %q() icine yerlestirilir; izin verilen karakterlerde ')' yok.
RUBY="p = Project.find_by_full_path(%q($PROJECT)) or abort(%q(proje yok));"
if [[ -n $PIPELINE ]]; then
  RUBY+=" pl = p.ci_pipelines.find_by(id: $PIPELINE) or abort(%q(pipeline yok));"
else
  RUBY+=" pl = p.ci_pipelines.order(:id).last or abort(%q(pipeline yok));"
fi
if [[ -z $JOB ]]; then
  RUBY+=" puts [pl.id, pl.ref, pl.sha[0,7], pl.status].join(%q( ));"
  RUBY+=" pl.builds.order(:id).each { |b| puts b.name.ljust(20) + b.status + (b.allow_failure ? %q( (allow_failure)) : %q()) }"
else
  RUBY+=" b = pl.builds.where(name: %q($JOB)).order(:id).last or abort(%q(is yok));"
  RUBY+=" puts %q(== ) + [pl.id, b.name, b.status, b.exit_code].join(%q( ));"
  RUBY+=" puts b.trace.raw.to_s.lines.last($LINES).join"
fi

# Log satirlarindan zaman damgasi/akis onekini, ANSI renklerini ve section isaretlerini temizle.
# Maskeleme: runner'in artifact yanitindaki "token=" (job JWT oneki), JWT'ler ve GitLab token onekleri.
# Masked CI degiskenlerini GitLab zaten gizler; bu ikinci bir emniyet.
ssh -o BatchMode=yes "$GITLAB" "sudo gitlab-rails runner \"$RUBY\"" |
  sed -E 's/^[0-9T:.-]+Z [0-9]{2}[OE][+ ]?//; s/\x1b\[[0-9;]*[A-Za-z]//g; s/section_(start|end):[0-9]+:[a-z_]+//g' |
  sed -E 's/(token=)[^ ]+/\1[MASKED]/g; s/eyJ[A-Za-z0-9_-]{4,}(\.[A-Za-z0-9_-]*){0,2}/[MASKED-JWT]/g; s/(glpat|glrt|gldt|glcbt|glptt|glft)-[A-Za-z0-9_.-]+/\1-[MASKED]/g'
