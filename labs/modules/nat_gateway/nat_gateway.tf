resource "azurerm_public_ip" "this" {
  name                = "pip-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "StandardV2"
  allocation_method   = "Static"
}

# SKU は StandardV2 (ゾーン冗長をサポート) 固定
resource "azurerm_nat_gateway" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "StandardV2"
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.this.id
}

resource "azurerm_subnet_nat_gateway_association" "this" {
  subnet_id      = var.subnet_id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
