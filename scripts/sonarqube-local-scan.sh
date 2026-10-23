#!/usr/bin/env bash
# Yerel dogrulama: catalog-api calisma kopyasini (commit'lenmis dal + coverage.xml) ss-sec'te sonar-scanner ile
# ayri bir catalog-api-local* projesine analiz eder. CI projesinin (catalog-api) gecmisi kirlenmez.
# Cikis kodu Quality Gate sonucudur (0 = gecti); ardindan kosullar yazilir. ss-mgmt'te Docker yok.
# Token ss-sec'te uretilir (admin'e ait, tek proje, 1 gun), yalnizca uzak kabugun ortaminda yasar ve sonunda
# iptal edilir; ekrana, argumana ve diske girmez. TLS dogrulamasi kapatilmaz: truststore yalnizca lab CA.
# Kullanim: sonarqube-local-scan.sh <catalog-api dizini> [catalog-api-local...]
set -euo pipefail
REPO=${1:?kullanim: sonarqube-local-scan.sh <catalog-api dizini> [proje-anahtari]}
KEY=${2:-catalog-api-local}
SEC=ubuntu@10.10.10.12
SONAR_URL=https://sonar.securestream.lab
CA=$(cd "$(dirname "$0")/.." && pwd)/infra/ansible/files/securestream-root-ca.crt
fail() { echo "HATA: $*" >&2; exit 2; }

IMAGE=$(sed -n 's/^  SONAR_SCANNER_IMAGE: "\(.*\)"$/\1/p' "$REPO/.gitlab-ci.yml")
[[ $IMAGE == *@sha256:* ]] || fail "SONAR_SCANNER_IMAGE digest ile bulunamadi ($REPO/.gitlab-ci.yml)"
[[ -f $REPO/coverage.xml ]] || fail "coverage.xml yok: once 'pytest --cov=app --cov-report=xml'"
# Yeni kod git blame ile belirlenir: commit'lenmemis satirlar yeni kod sayilmaz, test yaniltir
git -C "$REPO" diff --quiet HEAD || fail "commit edilmemis degisiklik var"

REMOTE=$(cat <<'EOF'
set -euo pipefail
# Beklenmeyen her hata 2: 1 yalnizca "kapi kaldi" demek
trap 'exit 2' ERR
KEY=$1 IMAGE=$2 URL=$3
D=$(mktemp -d)
trap 'rm -rf "$D"; python3 /opt/sonarqube/sonar-admin.py revoke-local "$URL" 2>/dev/null' EXIT
tar -xf - -C "$D"
docker pull -q "$IMAGE" >/dev/null
U=$(docker image inspect -f '{{.Config.User}}' "$IMAGE")
chown -R "${U:-1000}" "$D"
SONAR_TOKEN=$(python3 /opt/sonarqube/sonar-admin.py local-token "$URL" "$KEY" | sed -n 's/^TOKEN \(sqp_[0-9a-f]\{40\}\)$/\1/p') || true
[[ ${#SONAR_TOKEN} -eq 44 ]] || { echo "HATA: token alinamadi (uzunluk ${#SONAR_TOKEN})" >&2; exit 2; }
export SONAR_TOKEN
# Sonuc cikis koduna degil scanner'in kapi satirina bagli: TLS/yetki hatasi "kapi kaldi" sayilmaz
OUT=$(docker run --rm --network host -e SONAR_TOKEN -e SONAR_HOST_URL="$URL" -v "$D:/usr/src" -w /usr/src \
  --entrypoint sh "$IMAGE" -c '
    keytool -importcert -noprompt -alias securestream-lab -file .lab-ca.crt -keystore /tmp/lab-ca.p12 \
      -storetype PKCS12 -storepass changeit >/dev/null
    sonar-scanner -Dsonar.projectKey="$0" -Dsonar.projectName="$0" \
      -Dsonar.scanner.truststorePath=/tmp/lab-ca.p12 -Dsonar.scanner.truststorePassword=changeit \
      -Dsonar.scanner.skipJreProvisioning=true' "$KEY" 2>&1) || true
unset SONAR_TOKEN
grep -E 'QUALITY GATE|ERROR|EXECUTION' <<<"$OUT" || true
case $OUT in
  *"QUALITY GATE STATUS: PASSED"*) RC=0 ;;
  *"QUALITY GATE STATUS: FAILED"*) RC=1 ;;
  *) RC=2 ;;
esac
python3 /opt/sonarqube/sonar-admin.py gate "$URL" "$KEY" || true
exit "$RC"
EOF
)

set +e
tar -cf - -C "$REPO" --exclude=.venv --exclude=.cache --exclude=.scannerwork --exclude=__pycache__ . \
    -C "$(dirname "$CA")" --transform 's|^securestream-root-ca.crt$|.lab-ca.crt|' "$(basename "$CA")" \
  | ssh "$SEC" "sudo bash -c $(printf %q "$REMOTE") _ $(printf %q "$KEY") $(printf %q "$IMAGE") $SONAR_URL"
RC=$?
set -e
case $RC in
  0) echo "SONUC: Quality Gate GECTI ($KEY)" ;;
  1) echo "SONUC: Quality Gate KALDI ($KEY)" ;;
  *) echo "SONUC: tarama calismadi (cikis $RC)" ;;
esac
exit "$RC"
