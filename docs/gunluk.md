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

- Proxmox ss-infra için %100 bellek gösterdi; gerçek kullanım %35'ti. Sebep: balloon sürücüsü kapalıydı, Proxmox VM içini göremiyordu. Tüm VM'lerde floating=dedicated yapıldı (ölçüm açık, bellek geri alınmıyor).
- Boyut değişikliği Proxmox arayüzünden değil Terraform'dan yapıldı (drift olmasın). İlk denemede sed eşleşme bulamadı ve sessizce geçti; grep ile doğrulama sayesinde fark edildi.

### k3s cluster
- k3s v1.36.5+k3s1 (stable kanal, sabit sürüm), 1 control plane + 2 worker, Ansible rolüyle.
- Güvenlik: secrets-encryption, protect-kernel-defaults (CIS), API audit log (secret'lar Metadata seviyesinde, değer loglanmıyor), Traefik/ServiceLB kapalı.
- Cluster token'ı Ansible Vault ile şifreli; vault parolası repo dışında. Token üretilirken ekrana basılmadı.
- Hatalar: Vault parolası bir kez ekrana basıldı → kullanılmadan yenilendi. Token'a satır sonu karıştı (uzunluk 65) → `tr -d '\n'` ile düzeltildi. Yanlış klasörde çalışan komutlar → her bloğa `cd` eklendi.
- İdempotency: ikinci çalıştırmada 3/3 node changed=0.

### Platform: MetalLB, Traefik, cert-manager
- ingress-nginx Mart 2026'da emekliye ayrıldı (güvenlik yaması yok). Kurmadan önce fark edildi, yerine Helm ile sabit sürümlü Traefik kuruldu.
- MetalLB L2: Traefik 10.10.10.100 aldı. cert-manager, Lab Intermediate CA ile ClusterIssuer; CA anahtarı ss-mgmt diskine yazılmadan (process substitution) secret olarak yüklendi; k3s secrets-encryption ile diskte şifreli.
- HTTP->HTTPS yönlendirmesi iç porta (8443) gidiyordu; hedef :443 yapıldı.
- Test uygulaması (whoami) non-root, read-only rootfs, drop ALL capabilities ile çalışıyor; curl -k olmadan HTTPS başarılı.
- `.gitignore` içindeki `*.env` kuralı gizli olmayan versions.env'i de dışarıda bıraktı -> install.sh tekrarlanamaz oldu; versions.conf olarak düzeltildi.

## Sprint 1 - GitLab hesaplari ve ilk push (2026-10-22)
- root: admin isleri icin, e-posta onurcarkcioglu+root@gmail.com.
- carkcioglu: gunluk hesap (Regular), securestream grubunda Owner.
- Parolalar ekrana basilmadan aktarildi: read -rs + printf | ssh ... gitlab-rails runner (STDIN).
- ss-mgmt anahtari carkcioglu hesabina Keys::CreateService ile eklendi (1 yil, auth+signing).
- Ders: profil formundan e-posta degistirmek unconfirmed_email birakir; u.confirm onu onaylar.
- BEKLEYEN: root parolasi 24+ karakter, root ve carkcioglu icin 2FA.
- BEKLEYEN: apt_repository -> deb822_repository (gitlab ve gitlab_runner rolleri).

## Sprint 1 - KAPANIS: GitLab Runner (2026-10-22)
- ss-runner: docker.io + gitlab-runner 19.5.0-1 (hold), Docker executor, grup runner'i, etiketler docker/securestream, run_untagged=false.
- Token: CreateRunnerService -> SSH pipe -> ansible-vault encrypt_string. Hic ekranda gorunmedi.
- Guvenlik: privileged=false, no-new-privileges, tls-ca-file=lab CA, config.toml 0600 + no_log.
- Kalite: --syntax-check, --check --diff temiz, ikinci turda changed=0.
- Duman testi (pipeline #3 success): CapEff kisitli, lab DNS, CA ile TLS tamam, CA'siz TLS reddedildi.
- Ders: Alpine wget = BusyBox, --ca-certificate yok; curl --cacert kullan.
- Ders: --check modunda kurulmamis paket icin dpkg_selections patlar -> when: not ansible_check_mode.

## Sprint 2 - catalog-api guvenli pipeline, asama 1 (2026-10-22)
- catalog-api: FastAPI, 8 test, /docs kapali, girdi dogrulama testi, ruff (bandit S kurallari).
- Pipeline: lint, test, gitleaks, semgrep, trivy fs, kaniko build, trivy image + CycloneDX SBOM. Ilk calisma 7/7 yesil.
- Tum arac imajlari digest ile sabit (scripts/pin-images.sh). Neden: CVE-2026-33634 Trivy tedarik zinciri saldirisi (Mart 2026).
- Kaniko: Google arsivledi -> bakimi suren fork martizih/kaniko. Privileged gerekmez.
- Surum secimi: yeni surumlerde ~2 hafta bekleme (semgrep 1.180.0).
- Kapi testi (demo dali): gitleaks gitlab-pat (REDACTED), semgrep 1 blocking, trivy CVE-2018-18074 -> hepsi kirmizi.
- Ders: requests 2.19.1 idna cakismasi lint ve test'i pip install asamasinda dusurdu; lint guvenlik kontrolu korlesti.
  Duzeltme: lint yalnizca sabit ruff kurar. Tekrar testte ruff S602'yi kendi basina yakaladi.
