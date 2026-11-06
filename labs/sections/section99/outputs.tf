output "ssh_command" {
  value = "ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.public_ip_address["vm01"]}"
}

# ブラウザで開く URL。そのまま貼り付けられる形にする
output "app_url" {
  value = "http://${module.vm.public_ip_address["vm01"]}"
}
