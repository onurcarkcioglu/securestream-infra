#!/usr/bin/env bash
# DefectDojo CI kullanicisi (gitlab-ci; staff degil, urunlerin authorized_users listesinde) icin API token'i uretir ya da yeniler ve
# dogrudan GitLab grup degiskeni DD_API_KEY'e yazar (protected + masked + hidden).
# Token ss-sec'teki Django'dan pipe ile GitLab'a gider: ekrana, komut satiri argumanina ve diske girmez.
# Token 90 gunde sona erer (DD_API_TOKEN_DEFAULT_EXPIRY_DAYS); yenilemek icin bu betigi tekrar calistir.
# Eski token hemen gecersiz olur. Dogrulama yalnizca uzunluk ve bayraklarla.
set -euo pipefail
SEC=ubuntu@10.10.10.12
GITLAB=ubuntu@10.10.10.10
COMPOSE=/opt/defectdojo/docker-compose.yml
fail() { echo "HATA: $*" >&2; exit 1; }

# ss-sec: eski token silinir, yenisi uretilir; yalnizca "TOKEN <40 hex>" satiri disari cikar
PY=$(cat <<'EOF'
from django.contrib.auth import get_user_model
from rest_framework.authtoken.models import Token
u = get_user_model().objects.get(username="gitlab-ci")
assert not u.is_superuser and not u.is_staff and not u.has_usable_password()
Token.objects.filter(user=u).delete()
print("TOKEN " + Token.objects.create(user=u).key)
EOF
)

# GitLab: deger stdin'den okunur, bicim kontrolunden sonra yazilir; cikti yalnizca uzunluk ve bayraklar
RB=$(cat <<'EOF'
v = STDIN.read.strip
abort "HATA: token bicimi beklenen gibi degil (uzunluk #{v.length})" unless v.match?(/\A[0-9a-f]{40}\z/)
g = Group.find_by_full_path("securestream") or abort "HATA: grup yok"
var = g.variables.find_or_initialize_by(key: "DD_API_KEY", environment_scope: "*")
created = var.new_record?
var.assign_attributes(value: v, protected: true, masked: true, raw: true, variable_type: "env_var")
var.hidden = true if created
var.save!
var.reload
puts "DD_API_KEY #{created ? 'olusturuldu' : 'guncellendi'}: uzunluk #{var.value.length}, " \
     "protected=#{var.protected} masked=#{var.masked} hidden=#{var.hidden}"
EOF
)

OUT=$(ssh "$SEC" "sudo docker compose -f $COMPOSE exec -T uwsgi python manage.py shell -c $(printf %q "$PY")" 2>/dev/null \
  | sed -n 's/^TOKEN \([0-9a-f]\{40\}\)$/\1/p' \
  | ssh "$GITLAB" "sudo gitlab-rails runner $(printf %q "$RB")") || fail "token uretilemedi ya da yazilamadi"
echo "$OUT"
[[ $OUT == *"uzunluk 40, protected=true masked=true hidden=true"* ]] || fail "dogrulama basarisiz: $OUT"
