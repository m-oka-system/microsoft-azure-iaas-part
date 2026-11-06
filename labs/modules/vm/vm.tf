resource "azurerm_public_ip" "this" {
  for_each = { for k, v in var.vm : k => v if v.public_ip }

  name                = "pip-${each.value.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  allocation_method   = "Static"
  zones               = ["1", "2", "3"]
}

resource "azurerm_network_interface" "this" {
  for_each = var.vm

  name                = "nic-${each.value.name}"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig1"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.subnet_id
    public_ip_address_id          = each.value.public_ip ? azurerm_public_ip.this[each.key].id : null
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  for_each = var.vm

  name                            = each.value.name
  computer_name                   = each.value.name
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = each.value.vm_size
  admin_username                  = var.admin_username
  zone                            = each.value.zone
  allow_extension_operations      = each.value.allow_extension_operations
  disable_password_authentication = each.value.disable_password_authentication
  encryption_at_host_enabled      = each.value.encryption_at_host_enabled
  patch_mode                      = each.value.patch_mode
  secure_boot_enabled             = each.value.secure_boot_enabled
  vtpm_enabled                    = each.value.vtpm_enabled

  # アプリを入れない構成では、nginx だけを導入して VM の疎通を確認できるようにする
  # install_app_enabled = true のときは deploy/setup.sh が nginx も入れるため使わない
  custom_data = var.install_app_enabled ? null : filebase64("${path.module}/cloud-init.yaml")

  network_interface_ids = [
    azurerm_network_interface.this[each.key].id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  boot_diagnostics {}

  os_disk {
    name                      = "osdisk-${each.value.name}"
    caching                   = each.value.os_disk.os_disk_cache
    storage_account_type      = each.value.os_disk.os_disk_type
    disk_size_gb              = each.value.os_disk.os_disk_size
    write_accelerator_enabled = each.value.os_disk.write_accelerator_enabled
  }

  source_image_reference {
    publisher = "canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

# アプリの配置・接続情報の書き込み・起動を 1 つの拡張機能で行う
# install_app_enabled = false のときは作らない。VM だけを作る使い方を壊さないため
#
# custom_data（cloud-init）ではなく拡張機能を使う理由は 2 つある
# 1. cloud-init は完了を待たずに VM を ready と報告するため、apply が終わってもアプリが起動していないことがある
# 2. custom_data は /var/lib/waagent/CustomData に平文で残る
# 拡張機能はプロビジョニングの完了まで Terraform が待つ
# protected_settings は転送と設定ファイルが暗号化される。復号されたスクリプトは root 500 で残る
resource "azurerm_virtual_machine_extension" "setup" {
  for_each = var.install_app_enabled ? var.vm : {}

  name                       = "setup-todo-app"
  virtual_machine_id         = azurerm_linux_virtual_machine.this[each.key].id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  # スクリプトに接続情報を含むため、settings ではなく protected_settings へ入れる
  # settings は平文で VM へ送られる
  protected_settings = jsonencode({
    script = base64encode(templatefile("${path.module}/setup.sh.tftpl", {
      app_repository_url = var.app_repository_url
      db_host            = var.db_host
      db_name            = var.db_name
      db_user            = var.db_user
      db_password        = var.db_password
    }))
  })

  # 接続情報の渡し忘れを apply の前に止める
  # 渡し忘れると .env が空欄のまま作られ、画面に出るのは 503 だけになる
  lifecycle {
    precondition {
      condition     = var.db_host != null && var.db_name != null && var.db_user != null && var.db_password != null
      error_message = "install_app_enabled = true のときは db_host・db_name・db_user・db_password をすべて指定する"
    }
  }
}
