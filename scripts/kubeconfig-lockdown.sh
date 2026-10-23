#!/usr/bin/env bash
# Admin kubeconfig'i asistanin Unix kullanicisindan (ubuntu) ayirir: RBAC'in gercek sinir olmasi icin.
#   ~/.kube/config (admin, system:masters)  ->  /etc/securestream/admin.kubeconfig (root:root 0600)
#   ~/.kube/config                          ->  claude-readonly.yaml'a sembolik bag (token yenilenince ikisi birlikte)
# Insan, ayri bir terminalde calistirir:  sudo ~/securestream/scripts/kubeconfig-lockdown.sh
# Sonra admin islemleri:  sudo kubectl --kubeconfig /etc/securestream/admin.kubeconfig ...
# Tekrar calistirmak guvenlidir (yapilmissa yalnizca dogrular). Token ve anahtar degerleri basilmaz:
# cikti yalnizca kimlik adlari, dosya modlari ve can-i sonuclari.
set -euo pipefail
DEST_DIR=/etc/securestream
DEST=$DEST_DIR/admin.kubeconfig
fail() { echo "HATA: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "root olarak calistir: sudo $0"
U=${SUDO_USER:-}
[[ -n $U && $U != root ]] || fail "sudo ile, hedef kullanicinin kendi oturumundan calistir (SUDO_USER bos)"
H=$(getent passwd "$U" | cut -d: -f6)
SRC=$H/.kube/config
RO=$H/.kube/claude-readonly.yaml
SA_USER=system:serviceaccount:claude-readonly:claude-readonly
command -v kubectl >/dev/null || fail "kubectl yok"

# kubectl auth whoami ciktisindan yalnizca Username satiri
whoami_as() { "$@" auth whoami 2>/dev/null | awk '$1 == "Username" {print $2}'; }

# 1) Salt okunur kubeconfig gecerli ve gercekten SA kimligi
[[ -f $RO ]] || fail "$RO yok: once scripts/claude-kubeconfig.sh"
RO_ID=$(whoami_as sudo -u "$U" env -u KUBECONFIG kubectl --kubeconfig "$RO")
[[ $RO_ID == "$SA_USER" ]] || fail "$RO kimligi '$RO_ID' (beklenen $SA_USER; token suresi dolmus olabilir)"
echo "OK    $RO -> $RO_ID"

# 2) Admin kubeconfig /etc/securestream'e (yoksa); kaynak once gercekten admin mi
install -d -o root -g root -m 0700 "$DEST_DIR"
if [[ -f $DEST ]]; then
  echo "OK    $DEST zaten var"
else
  [[ -f $SRC && ! -L $SRC ]] || fail "$SRC normal dosya degil ve $DEST yok: admin kubeconfig bulunamadi"
  SRC_ID=$(whoami_as kubectl --kubeconfig "$SRC")
  [[ $SRC_ID == system:admin ]] || fail "$SRC kimligi '$SRC_ID' (beklenen system:admin); hicbir sey tasinmadi"
  install -o root -g root -m 0600 "$SRC" "$DEST"
  cmp -s "$SRC" "$DEST" || fail "kopya kaynakla ayni degil; $SRC yerinde birakildi"
  echo "OK    admin kubeconfig kopyalandi -> $DEST"
fi
[[ $(stat -c '%U:%G %a' "$DEST") == "root:root 600" ]] || fail "$DEST sahiplik/mod beklenen gibi degil"
DEST_ID=$(whoami_as kubectl --kubeconfig "$DEST")
[[ $DEST_ID == system:admin ]] || fail "$DEST kimligi '$DEST_ID' (beklenen system:admin)"
echo "OK    $DEST -> $DEST_ID (root:root 600)"

# 3) ~/.kube/config salt okunur dosyaya bag; admin icerigi kullanici dizininden kalkar
if [[ -L $SRC && $(readlink "$SRC") == claude-readonly.yaml ]]; then
  echo "OK    $SRC zaten claude-readonly.yaml'a bag"
else
  ln -sfn claude-readonly.yaml "$SRC"
  chown -h "$U:$U" "$SRC"
  echo "OK    $SRC -> claude-readonly.yaml"
fi

# 4) Kullanici dizininde admin kimlik bilgisi tasiyan baska dosya kaldi mi (yalnizca dosya adi)
LEFT=$(grep -rlsI --exclude-dir=.git --exclude-dir=.venv --exclude-dir=node_modules -e 'client-key-data' -e 'client-key:' "$H" || true)
if [[ -n $LEFT ]]; then
  echo "UYARI kullanici dizininde istemci anahtari iceren dosya(lar) var (icerik basilmadi):"
  sed 's/^/      /' <<<"$LEFT"
else
  echo "OK    $H altinda istemci anahtari iceren dosya yok"
fi

# 5) Kanit: KUBECONFIG olmadan, kullanicinin kendisi olarak
echo
echo "== $U olarak, KUBECONFIG tanimsiz: kubectl auth whoami"
sudo -u "$U" -H env -u KUBECONFIG kubectl auth whoami
echo "== $U olarak, KUBECONFIG tanimsiz: kubectl auth can-i get secrets -A"
CANI=$(sudo -u "$U" -H env -u KUBECONFIG kubectl auth can-i get secrets -A 2>&1 || true)
echo "$CANI"
echo "== $U olarak: $DEST okunabiliyor mu"
if sudo -u "$U" test -r "$DEST"; then READ=evet; else READ=hayir; fi
echo "$READ"

ID=$(whoami_as sudo -u "$U" -H env -u KUBECONFIG kubectl)
[[ $ID == "$SA_USER" && $CANI == no && $READ == hayir ]] \
  || fail "dogrulama basarisiz: kimlik '$ID', can-i '$CANI', admin dosyasi okunur: $READ"
echo
echo "SONUC: $U kullanicisinin kubectl'i yalnizca $SA_USER; admin yalnizca sudo ile."
