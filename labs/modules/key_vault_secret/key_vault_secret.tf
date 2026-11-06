resource "azurerm_key_vault_secret" "this" {
  for_each     = var.key_vault_secret
  name         = upper(replace(each.key, "_", "-"))
  value        = each.value
  key_vault_id = var.key_vault_id
}
