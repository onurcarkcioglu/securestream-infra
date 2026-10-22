# Bağlantı bilgileri ortam değişkenlerinden okunur:
#   PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE
# Kaynak: ~/.config/securestream/pve.env (izin 600, Git'e girmez)
# Böylece token hiçbir .tf dosyasında ve repoda bulunmaz.
provider "proxmox" {}
