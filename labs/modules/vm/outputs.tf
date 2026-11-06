output "public_ip_address" {
  value = { for k, v in azurerm_public_ip.this : k => v.ip_address }
}

output "admin_username" {
  value = var.admin_username
}
