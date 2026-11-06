# ラボ共通のネットワーク構成
resource "azurerm_virtual_network" "this" {
  name                = "vnet"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "vm" {
  name                              = "snet-vm"
  resource_group_name               = var.resource_group_name
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = ["10.0.1.0/24"]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm"
  resource_group_name = var.resource_group_name
  location            = var.location
}

resource "azurerm_network_security_rule" "http" {
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  name                        = "AllowHTTPInbound"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

resource "azurerm_network_security_rule" "ssh" {
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.vm.name
  name                        = "AllowSSHInbound"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.allowed_client_ips
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
