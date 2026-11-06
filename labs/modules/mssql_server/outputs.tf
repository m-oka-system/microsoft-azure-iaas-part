output "id" {
  value = azurerm_mssql_server.this.id
}

output "fully_qualified_domain_name" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "administrator_login" {
  value = azurerm_mssql_server.this.administrator_login
}

output "administrator_login_password" {
  value     = random_password.this.result
  sensitive = true
}
