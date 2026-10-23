# Bağlantı bilgileri ortam değişkenlerinden okunur:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE (false olmali)
# Terraform scripts/tf.sh ile calistirilir: pve1'in CA'si (pve-root-ca.pem) yalnizca bu surece verilir.
# Kaynak: ~/.config/securestream/pve.env (izin 600, Git'e girmez)
# Böylece token hiçbir .tf dosyasında ve repoda bulunmaz.
provider "proxmox" {}
