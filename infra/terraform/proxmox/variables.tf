variable "node_name" {
  description = "VM'lerin oluşturulacağı Proxmox düğümü"
  type        = string
  default     = "pve1"
}

variable "template_id" {
  description = "Klonlanacak golden image şablonunun ID'si"
  type        = number
  default     = 9000
}

variable "datastore" {
  description = "Disklerin oluşturulacağı depolama"
  type        = string
  default     = "local-lvm"
}

variable "bridge" {
  description = "Lab ağı köprüsü (izole, NAT ile internete çıkar)"
  type        = string
  default     = "vmbr1"
}

variable "gateway" {
  description = "Lab ağının çıkış kapısı (pve1 üzerindeki vmbr1 adresi)"
  type        = string
  default     = "10.10.10.1"
}

variable "dns_servers" {
  description = "Geçici DNS; Sprint 1'in ikinci yarısında ss-infra (10.10.10.5) olacak"
  type        = list(string)
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "ssh_public_key_files" {
  description = "VM'lere yüklenecek açık anahtarlar: ss-mgmt otomasyon anahtarı ve Mac"
  type        = list(string)
  default     = ["~/.ssh/id_ed25519.pub", "~/.ssh/mac.pub"]
}
