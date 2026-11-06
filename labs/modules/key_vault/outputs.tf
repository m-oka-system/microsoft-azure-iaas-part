output "key_vault" {
  value = {
    for k, v in azurerm_key_vault.this : k => {
      id   = v.id
      name = v.name
    }
  }
}
