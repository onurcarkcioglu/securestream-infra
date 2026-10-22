# SecureStream Proje Günlüğü

## Sprint 0 – Hazırlık

**Yapılanlar:** Ubuntu şablonu, izole lab ağı (vmbr1 + NAT), Tailscale subnet route, yönetim VM'i (ss-mgmt), araç kurulumu, kısıtlı yetkili Terraform API kullanıcısı.

**Sorunlar ve çözümler:**
- Proxmox kurulumu: NO-CARRIER (yanlış port), çift NAT (modem + router), CGNAT (100.x WAN IP). Uzaktan erişim Tailscale ile çözüldü.
- /etc/hosts'ta tek fazla karakter web Shell'i bozdu (port 5900 timeout).
- Intel Mac'te Homebrew yok. Araçlar ayrı bir yönetim VM'ine taşındı (bastion/jump host modeli).
- Tailscale subnet rotası yayınlandı ama onaylanmadı. Panel onayı gerekiyor (iki taraflı onay).
- API token'ı ekran çıktısında paylaşıldı. İptal edilip yenilendi; son çözümde token SSH pipe ile doğrudan ss-mgmt'ye aktarıldı, hiçbir ekrana yazılmadı.
- Aynı anda iki SSH bağlantısı passphrase sorunca giriş karıştı. ssh-agent + macOS Keychain ile çözüldü.

**Öğrendiklerim:** Secret sızıntısında refleks: iptal et, yenile, süreci değiştir.

## Sprint 1 – Altyapı kod olarak (1. yarı)

**Yapılanlar:** qemu-guest-agent gömülü golden image (virt-customize), Terraform (bpg/proxmox) ile 8 VM, Terraform'un ürettiği Ansible envanteri.

**Sonuç:** 8 VM yaklaşık 2 dakikada kuruldu, 8/8 Ansible ping başarılı.

**Sorunlar ve çözümler:**
- Uzun heredoc yapıştırmaları terminal ekranını bozdu. Dosyalar grep/tail ile doğrulandı.
- Plan dosyası (tfplan) yanlışlıkla commit edildi. Push edilmeden önce --amend ile çıkarıldı, .gitignore'a eklendi. Sprint 3'te pre-commit ile otomatik engellenecek.
- Uzun süren apply için tmux kullanıldı (SSH koparsa iş devam eder).

**Öğrendiklerim:** plan ve apply ayrı adımlar olmalı; plan önce okunur, sonra uygulanır.

## Sprint 1 – 2. yarı

- Host key doğrulaması geri açıldı (ssh-keyscan ile TOFU; Sprint 5'te SSH sertifikalarına geçilecek).
- Baseline rolü: dist-upgrade, unattended-upgrades, chrony, auditd, SSH sertleştirme (sadece anahtar, root yok, AllowUsers).
- Güvenli dağıtım: önce --check --diff, sonra tek sunucu, sonra hepsi. SSH handler'ı önce `sshd -t` ile doğruluyor.
- İdempotency doğrulandı: ikinci çalıştırmada 8/8 sunucuda changed=0.

## Sprint 1 – 2. yarı

- Host key doğrulaması geri açıldı (ssh-keyscan ile TOFU; Sprint 5'te SSH sertifikalarına geçilecek).
- Baseline rolü: dist-upgrade, unattended-upgrades, chrony, auditd, SSH sertleştirme (sadece anahtar, root yok, AllowUsers).
- Güvenli dağıtım: önce --check --diff, sonra tek sunucu, sonra hepsi. SSH handler'ı önce `sshd -t` ile doğruluyor.
- İdempotency doğrulandı: ikinci çalıştırmada 8/8 sunucuda changed=0.
