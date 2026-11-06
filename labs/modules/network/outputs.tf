# VM を配置するサブネット。現時点で root module が必要とするのはこれだけ
output "subnet_id" {
  value = azurerm_subnet.vm.id
}
