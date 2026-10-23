#!/usr/bin/env bash
# Dependency-Track CI takimi (gitlab-ci; yalnizca BOM_UPLOAD + PROJECT_CREATION_UPLOAD + VIEW_PORTFOLIO) icin API
# anahtari (odt_) uretir ve dogrudan catalog-api proje degiskeni DTRACK_API_KEY'e yazar (protected + masked +
# hidden). Anahtar ss-sec'teki dtrack-admin.py'den pipe ile GitLab'a gider: ekrana, komut satiri argumanina ve
# diske girmez. Takimin eski anahtarlari hemen silinir. Dogrulama yalnizca uzunluk, onek ve bayraklarla.
# Yenilemek icin bu betigi tekrar calistir.
set -euo pipefail
SEC=ubuntu@10.10.10.12
GITLAB=ubuntu@10.10.10.10
DTRACK_URL=https://dtrack.securestream.lab
fail() { echo "HATA: $*" >&2; exit 1; }

# GitLab: deger stdin'den okunur, bicim kontrolunden sonra yazilir; cikti yalnizca uzunluk, onek ve bayraklar
RB=$(cat <<'RUBY'
v = STDIN.read.strip
abort "HATA: anahtar bicimi beklenen gibi degil (uzunluk #{v.length})" unless v.match?(/\Aodt_[A-Za-z0-9_]{20,}\z/)
p = Project.find_by_full_path("securestream/catalog-api") or abort "HATA: proje yok"
var = p.variables.find_or_initialize_by(key: "DTRACK_API_KEY", environment_scope: "*")
created = var.new_record?
var.assign_attributes(value: v, protected: true, masked: true, raw: true, variable_type: "env_var")
var.hidden = true if created
var.save!
var.reload
puts "DTRACK_API_KEY #{created ? 'olusturuldu' : 'guncellendi'}: uzunluk #{var.value.length}, onek #{var.value[0, 4]}, " \
     "protected=#{var.protected} masked=#{var.masked} hidden=#{var.hidden}"
RUBY
)

# shellcheck disable=SC2029  # URL ve Ruby kodu bilerek istemci tarafinda genisletilir (printf %q ile kacisli)
OUT=$(ssh "$SEC" "sudo python3 /opt/dependency-track/dtrack-admin.py ci-key $DTRACK_URL" \
  | sed -n 's/^TOKEN \(odt_[A-Za-z0-9_]\{20,\}\)$/\1/p' \
  | ssh "$GITLAB" "sudo gitlab-rails runner $(printf %q "$RB")") || fail "anahtar uretilemedi ya da yazilamadi"
echo "$OUT"
[[ $OUT == *"onek odt_, protected=true masked=true hidden=true"* ]] || fail "dogrulama basarisiz: $OUT"
