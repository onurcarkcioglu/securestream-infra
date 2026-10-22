locals {
  # Tek doğruluk kaynağı (single source of truth): tüm lab sunucuları burada.
  # memory MB, disk GB. role hem Proxmox etiketi hem Ansible grubu olur.
  vms = {
    "ss-infra"  = { vm_id = 101, ip = "10.10.10.5", cores = 2, memory = 3072, disk = 10, role = "infra" }
    "ss-gitlab" = { vm_id = 110, ip = "10.10.10.10", cores = 8, memory = 16384, disk = 100, role = "cicd" }
    "ss-runner" = { vm_id = 111, ip = "10.10.10.11", cores = 8, memory = 12288, disk = 100, role = "runner" }
    "ss-sec"    = { vm_id = 112, ip = "10.10.10.12", cores = 8, memory = 16384, disk = 120, role = "security" }
    "ss-vault"  = { vm_id = 113, ip = "10.10.10.13", cores = 2, memory = 4096, disk = 20, role = "vault" }
    "ss-k3s-cp" = { vm_id = 120, ip = "10.10.10.20", cores = 4, memory = 8192, disk = 50, role = "k3s_server" }
    "ss-k3s-w1" = { vm_id = 121, ip = "10.10.10.21", cores = 10, memory = 16384, disk = 80, role = "k3s_agent" }
    "ss-k3s-w2" = { vm_id = 122, ip = "10.10.10.22", cores = 10, memory = 16384, disk = 80, role = "k3s_agent" }
  }

  ssh_keys = [for f in var.ssh_public_key_files : trimspace(file(pathexpand(f)))]
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  name      = each.key
  node_name = var.node_name
  vm_id     = each.value.vm_id
  tags      = sort(["ss", each.value.role])

  on_boot         = true # Proxmox yeniden başlarsa VM de açılsın
  started         = true
  stop_on_destroy = true

  # Golden image'dan tam (bağımsız) kopya
  clone {
    vm_id = var.template_id
    full  = true
  }

  # Terraform IP'yi ve VM'in hazır olduğunu buradan öğrenir
  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
    floating  = each.value.memory
  }

  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    size         = each.value.disk
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = var.bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # cloud-init: ilk açılışta IP, DNS, kullanıcı ve SSH anahtarı ayarlanır
  initialization {
    datastore_id = var.datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = "ubuntu"
      keys     = local.ssh_keys
    }
  }
}
