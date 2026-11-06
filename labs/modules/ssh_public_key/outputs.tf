output "public_key_openssh" {
  value = azurerm_ssh_public_key.this.public_key
}

output "private_key_pem" {
  value     = tls_private_key.this.private_key_pem
  sensitive = true
}

output "name" {
  value = azurerm_ssh_public_key.this.name
}
