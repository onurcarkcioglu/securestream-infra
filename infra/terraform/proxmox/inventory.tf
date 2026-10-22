resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/../../ansible/inventory/hosts.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    vms   = local.vms
    roles = distinct([for v in local.vms : v.role])
  })

  # Envanter, VM'ler gerçekten oluştuktan sonra yazılsın
  depends_on = [proxmox_virtual_environment_vm.vm]
}

output "vm_ips" {
  description = "Sunucu adı -> IP"
  value       = { for k, v in local.vms : k => v.ip }
}
