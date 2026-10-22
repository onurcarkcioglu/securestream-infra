terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Proxmox için en yaygın ve aktif geliştirilen provider
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66.0"
    }
    # Ansible envanter dosyasını üretmek için
    local = {
      source  = "hashicorp/local"
      version = ">= 2.5.0"
    }
  }
}
