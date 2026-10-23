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
- Plan dosyası (tfplan) yanlışlıkla commit edildi. Push edilmeden önce --amend ile çıkarıldı, .gitignore'a eklendi. pre-commit ile otomatik engelleme yol haritasında (henüz kurulmadı).
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
- root: admin isleri icin, ayri bir e-posta adresiyle.
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

## DAST ve runtime guvenligi (2026-10-22)
- catalog.securestream.lab DNS kaydi (ingress 10.10.10.100).
- DAST: OWASP ZAP API taramasi deploy sonrasi; zap-rules.tsv'deki XSS/SQLi/komut enjeksiyonu kurallari FAIL, digerleri WARN (allow_failure exit 2).
- Ilk tarama: 3 WARN (X-Content-Type-Options, HSTS, CORP). Duzeltme: guvenlik basliklari middleware + test + uvicorn --no-server-header.
  Sonuc: WARN 0, PASS 117 -> 120, pipeline 10/10 yesil.
- Falco (chart 9.2.1, modern eBPF): container plugin k3s soketini buldu.
- Ders: kubectl exec -t, -i olmadan TTY acmaz; "Terminal shell in container" kurali bu yuzden tetiklenmedi. -it ile alarm geldi.

## HashiCorp Vault + External Secrets (2026-10-22)
- Vault 2.1.2 (ss-vault): TLS (lab CA), Raft, file audit, kv-v2. Init 5/3 Shamir; cikti ekrana basilmadan ansible-vault ile sifrelendi.
- scripts/vault-unseal.sh: 3 anahtar bellekte cozulur, API'ye stdin ile gider.
- Kubernetes auth: token reviewer SA (system:auth-delegator); rol catalog -> SA catalog-eso, ns catalog, audience vault, policy catalog-read (yalnizca okuma).
- External Secrets Operator 2.11.0: SecretStore (Vault CA ile) + ExternalSecret -> catalog-config Secret.
- Uygulama: /v1/admin/stats anahtarla korunuyor; anahtarsiz 401, anahtarla 200.
- Kurulum bitince root token iptal edildi; gerekirse unseal anahtarlariyla 'vault operator generate-root'.
- Ders: yanlislikla eski terminal kaydi yapistirildi; istenmeyen commit git revert ile geri alindi (force push yok).
- Ders: GitHub token sohbete yazildi -> hemen silindi ve yenilendi; token girisi artik bicim kontrollu (github_pat_ + uzunluk).

## Claude Code kurulumu ve dogrulama (2026-10-23)
- ss-mgmt kvm64 CPU tipindeydi (SSE4.2 yok), Claude Code (Bun) calismadi. ss-gitlab ile karsilastirilarak bulundu; pve1'de `qm set 104 --cpu host`.
- Claude Code: `.claude/settings.json` (deny/ask kurallari), `CLAUDE.md` (proje kurallari), `docs/ai-assisted-engineering.md`.
- Dogrulama: gizli dosya istegi talimat katmaninda reddedildi; Read ve `head` deny kuraliyla engellendi; onerilen ek Bash kurali testle gereksiz cikti.
- Sahte tfstate testi: Read/cat/jq engellendi, `python3 open()` okudu; proje disinda kural hic gecerli degil. Deny kurallari korkuluk, sandbox degil.
- force-push: asil kontrol GitLab'da korumali `main` (allow_force_push=false, push/merge Maintainers). Istemci kurallari genisletildi.
- Terraform state ss-mgmt'de sifresiz duruyordu ve 0664 izinliydi -> 0600.
- Terraform state GitLab managed state'e tasindi (http backend, GitLab Lockbox ile sifreli). Oncesinde ansible-vault ile sifreli yedek.
  Dogrulama: 9 instance, adres + ID'ler yedekle ayni, plan exit 0. Lineage degisti: bos remote backend'e tasimada Terraform yeni lineage uretir.
  Yeni betikler: tfstate-token.sh, tfstate-migrate.sh, tfstate-verify.sh, tfstate-cleanup.sh.
- Proxmox API TLS dogrulamasi aciktan kapaliydi (PROXMOX_VE_INSECURE=true). pve1 CA'si (SHA-256 83:0B:...:6B:92) ayri kanaldan
  dogrulandi; scripts/tf.sh yalnizca terraform'a SSL_CERT_FILE (sistem paketi + pve CA) verir. Endpoint SAN'daki ada tasindi
  (pve1.carkcioglu.local); ss-mgmt /etc/hosts'a elle eklendi (ss-mgmt IaC disinda, bilincli istisna). plan exit 0, yanlis CA reddedildi.
- Gunluk basliklarindaki "Gun 2/3" etiketleri kaldirildi; yeni basliklar isi ve tarihi anlatir. Eski commit mesajlarindaki "gun" ifadeleri degistirilmedi: main korumali, gecmis yeniden yazilmaz.

## Dokuman duzeni: engineering-log (2026-10-23)
- `docs/gunluk.md` -> `docs/engineering-log.md` (`git mv`, gecmis korunur); README ve CLAUDE.md referanslari guncellendi.
- `ai-assisted-engineering.md`: "Interview summary" bolumu "Summary" oldu. Kisisel e-posta adresi kayittan cikarildi.
  Yayinlanmis Git gecmisi yeniden yazilmadi.

## Salt okunur CI durum betigi (2026-10-23)
- `scripts/ci-status.sh <grup/proje> [is] [satir]`: son pipeline durumu ve is logu kuyrugu, yalnizca okuma.
  Claude Code'da `allow: Bash(scripts/ci-status.sh *)`; `ask: Bash(ssh *)` degismedi.
- Girdi siki dogrulanir (gitlab-rails runner root yetkisiyle Ruby calistirir); enjeksiyon denemeleri reddedildi.
- Cikti maskelenir: ilk denemede artifact yukleme satirinda job JWT oneki gorundu.
- Onayli kopya: `/usr/local/bin/ci-status` (root:root 0755, insan `sudo install` ile kurdu). Allow kurali yalnizca bu
  mutlak yol; `~/.local/bin` PATH'te once ve yazilabilir oldugu icin ciplak ad kurali kullanilmadi.
  `Edit/Write(scripts/ci-status.sh)` deny. Yazma denemeleri (test -w, python3) Permission denied.
- `scripts/catalog-admin-smoke.sh`: admin uc noktasi 401/401/200 testi; anahtar Vault'tan stdin ile curl'e, insan calistirir.

## Cok bulutlu IaC taramasi (2026-10-23)
- `infra/terraform/samples/{aws,azure,gcp}/{insecure,secure}`: yalnizca taranir; init/plan/apply yok, bulut hesabi yok.
- `scripts/iac-scan.sh gate|report` + CI isleri `iac-scan` (kapi) ve `iac-scan-insecure` (rapor). publish-github artik iac-scan'i bekler.
- Checkov 3.3.26 hatalari: Terraform'da `--skip-path` gecersiz regex; birden fazla `-d` ayni dizini tekrar tarar ve basarili gorunur.
  Cozum: dizin basina ayri calistirma + bos rapor kirmizi.
- Checkov'da bpg/proxmox icin kural yok (0 kontrol): `security/checkov` altinda ozel kurallar (18 kontrol).
- GCP default service account data source ile yakalanmiyordu: ozel Python kurali CKV_SS_3.
- Istisnalar: EXC-0101 (S3 cross-region replication), EXC-0102 (App Service Azure Files), 2027-01-21'e kadar.

## secret-scan kapi oldu (2026-10-23)
- securestream `secret-scan`: `allow_failure: true` kaldirildi (8c8c8a0'dan beri vardi). Tam gecmiste bulgu yok, allowlist eklenmedi.
- `scripts/check-vault-encrypted.sh`: sir yollarindaki her dosya `$ANSIBLE_VAULT` basligiyla baslamali (yalnizca baslik okunur).
- `publish-github` artik `needs: [secret-scan, iac-scan]`.

## Dal silme icin deny kurallari (2026-10-23)
- Iki repoda `.claude/settings.json` deny: `git push * --delete*`, `git push --delete*`, `git push * -d *`, `git push -d *`,
  `git push * :**`, `git branch -D *`. Zararsiz dry-run testleri: hepsi engellendi (`ai-assisted-engineering.md`, verification log).
- Istenen `git push * :*` kurali calismadi: sondaki `:*` Claude Code'da eski onek sozdizimi. `:**` ile degistirildi.
- Asil kontrol sunucu tarafinda: korumali dallar ve rol yetkileri (lessons learned #23).

## DefectDojo ve zafiyet yonetimi (2026-10-23)
- ss-sec: `playbooks/appsec.yml`, roller `appsec_host` (docker.io + compose v2 sabit, nginx yalnizca 443, TLS 1.2/1.3,
  bilinmeyen SNI reddedilir) ve `defectdojo` (3.3.300, resmi compose uyarlamasi, imajlar digest ile).
- DNS: `defectdojo.securestream.lab`. Sertifika `lab_cert` ile; rol yeni sunucuda check modunda temiz bitiyor.
- Gizli degerler pipe ile ansible-vault'a (`group_vars/security/vault.yml`); admin sifresi yalnizca initializer'da.
- API token'lari 90 gun; sifreyle token alma ucu (`api-token-auth`) kapali.
- Yapi (API, idempotent): SLA SecureStream 7/30/90/180, urunler catalog-api ve securestream-platform, engagement CI/CD,
  CI kullanicisi gitlab-ci (staff degil, sifresi kullanilamaz, authorized_users). DefectDojo 3.x OSS'te RBAC yok.
- CI: `exceptions-check` (iki repo), `defectdojo-upload` (main, when: always). catalog-api: trivy fs/image JSON
  ve ZAP XML raporlari eklendi. Istisnalar Risk Acceptance olarak aynalaniyor.
- `docs/vulnerability-management.md`.

## SonarQube ve Quality Gate (2026-10-23)
- ss-sec: `sonarqube` rolu (`playbooks/appsec.yml`): Community Build 26.9.0.129388 + PostgreSQL 16.14, imajlar digest ile,
  web yalnizca `127.0.0.1:9000`, nginx 443 (`sonar.securestream.lab`, lab CA), PostgreSQL disari acik degil.
  26.10 (6 gunluk) ve PostgreSQL 16.15 (digest'leri 2026-10-22'de yeniden basildi) bekleme suresini doldurmadi.
  Community Build'in LTA surumu yok.
- Gizli degerler pipe ile ansible-vault'a; admin sifresi ilk acilista API ile degisti (`admin/admin` artik gecersiz).
- `sonar-admin.py bootstrap` (idempotent): Standard Experience modu (API v2), `forceAuthentication`, varsayilan
  gorunurluk private, Quality Gate "SecureStream" varsayilan (new_bugs > 0, new_vulnerabilities > 0,
  new_security_hotspots_reviewed < 100, new_coverage < 70 kirmizi), yeni kod donemi 30 gun, CI kullanicisi
  `gitlab-ci` yalnizca catalog-api'de Browse + Execute Analysis; global scan hicbir grupta yok.
- `SONAR_TOKEN`: proje analiz token'i (sqp_, 90 gun), `scripts/sonarqube-ci-token.sh` ile pipe uzerinden GitLab'a.
- catalog-api: `sonarqube` isi (main, sonar-scanner-cli 12.2 digest ile, `sonar.qualitygate.wait=true`),
  `sign` artik `sonarqube`'u bekler: kirmizi kapi imza ve deploy'u durdurur. `unit-test` coverage.xml uretir
  (pytest-cov 7.1.0, goreli yollar).
- Yerel dogrulama: `scripts/sonarqube-local-scan.sh` (analiz ss-sec'te, ayri `catalog-api-local` projesi).
  Negatif test: TLSv1 + CERT_NONE yardimci fonksiyonu → `new_vulnerabilities=3`, kapi kirmizi; geri alininca yesil.
- Community Build sinirlari: yalnizca ana dal analiz edilir, dal/MR analizi yok; `SONAR_TOKEN` protected oldugu icin
  is de yalnizca main'de calisir.
