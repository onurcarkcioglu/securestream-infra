#!/usr/bin/env bash
# SonarQube CI kullanicisi (gitlab-ci; yalnizca catalog-api projesinde Browse + Execute Analysis) icin 90 gunluk
# proje analiz token'i (sqp_) uretir ve dogrudan catalog-api proje degiskeni SONAR_TOKEN'a yazar
# (protected + masked + hidden). Token ss-sec'teki sonar-admin.py'den pipe ile GitLab'a gider: ekrana,
# komut satiri argumanina ve diske girmez. Kullanicinin eski token'lari hemen gecersiz olur.
# Dogrulama yalnizca uzunluk, onek ve bayraklarla. Yenilemek icin bu betigi tekrar calistir.
set -euo pipefail
SEC=ubuntu@10.10.10.12
GITLAB=ubuntu@10.10.10.10
SONAR_URL=https://sonar.securestream.lab
fail() { echo "HATA: $*" >&2; exit 1; }

# GitLab: deger stdin'den okunur, bicim kontrolunden sonra yazilir; cikti yalnizca uzunluk, onek ve bayraklar
RB=$(cat <<'EOF'
v = STDIN.read.strip
abort "HATA: token bicimi beklenen gibi degil (uzunluk #{v.length})" unless v.match?(/\Asqp_[0-9a-f]{40}\z/)
p = Project.find_by_full_path("securestream/catalog-api") or abort "HATA: proje yok"
var = p.variables.find_or_initialize_by(key: "SONAR_TOKEN", environment_scope: "*")
created = var.new_record?
var.assign_attributes(value: v, protected: true, masked: true, raw: true, variable_type: "env_var")
var.hidden = true if created
var.save!
var.reload
puts "SONAR_TOKEN #{created ? 'olusturuldu' : 'guncellendi'}: uzunluk #{var.value.length}, onek #{var.value[0, 4]}, " \
     "protected=#{var.protected} masked=#{var.masked} hidden=#{var.hidden}"
EOF
)

OUT=$(ssh "$SEC" "sudo python3 /opt/sonarqube/sonar-admin.py ci-token $SONAR_URL" \
  | sed -n 's/^TOKEN \(sqp_[0-9a-f]\{40\}\)$/\1/p' \
  | ssh "$GITLAB" "sudo gitlab-rails runner $(printf %q "$RB")") || fail "token uretilemedi ya da yazilamadi"
echo "$OUT"
[[ $OUT == *"uzunluk 44, onek sqp_, protected=true masked=true hidden=true"* ]] || fail "dogrulama basarisiz: $OUT"
