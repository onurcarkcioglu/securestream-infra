# State GitLab'da tutulur (GitLab managed Terraform state: diskte sifreli, kilitli, surumlu).
# Kimlik bilgileri ve CA ortam degiskenlerinden gelir, hicbir .tf dosyasina yazilmaz:
#   TF_HTTP_USERNAME, TF_HTTP_PASSWORD   -> ~/.config/securestream/tfstate.env (izin 600)
#   TF_HTTP_CLIENT_CA_CERTIFICATE_PEM    -> lab CA (TLS dogrulamasi acik kalir)
# Ilk tasima: scripts/tfstate-token.sh, sonra scripts/tfstate-migrate.sh
terraform {
  backend "http" {
    address        = "https://gitlab.securestream.lab/api/v4/projects/1/terraform/state/proxmox"
    lock_address   = "https://gitlab.securestream.lab/api/v4/projects/1/terraform/state/proxmox/lock"
    unlock_address = "https://gitlab.securestream.lab/api/v4/projects/1/terraform/state/proxmox/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}
