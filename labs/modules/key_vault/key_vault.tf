data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  for_each                   = var.key_vault
  name                       = "${each.value.name}-${var.random}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  sku_name                   = each.value.sku_name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled = each.value.rbac_authorization_enabled
  purge_protection_enabled   = each.value.purge_protection_enabled
  soft_delete_retention_days = each.value.soft_delete_retention_days
  access_policy              = []
}
