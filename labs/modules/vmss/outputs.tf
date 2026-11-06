output "id" {
  value = azurerm_orchestrated_virtual_machine_scale_set.this.id
}

output "name" {
  value = azurerm_orchestrated_virtual_machine_scale_set.this.name
}

output "admin_username" {
  value = var.admin_username
}
