# Flexible オーケストレーションの仮想マシンスケールセット
# azurerm_linux_virtual_machine_scale_set は Uniform 専用のため、こちらを使う
resource "azurerm_orchestrated_virtual_machine_scale_set" "this" {
  name                = var.vmss.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # ゾーンを指定する構成では 1 にする
  platform_fault_domain_count = var.vmss.platform_fault_domain_count
  sku_name                    = var.vmss.sku_name
  instances                   = var.vmss.instances
  zones                       = var.vmss.zones

  # 単一の VM は Spot だが、こちらは従量課金にする
  # 退避で台数が勝手に減ると、振り分けを確認する場面で結果が読めなくなる
  priority = "Regular"

  os_profile {
    linux_configuration {
      admin_username = var.admin_username
      # 各インスタンスのホスト名はこの接頭辞から作られる
      # 画面下部の「実行環境」に出るため、どのインスタンスが応答したか分かる
      computer_name_prefix            = var.vmss.name
      disable_password_authentication = true

      admin_ssh_key {
        username   = var.admin_username
        public_key = var.ssh_public_key
      }
    }
  }

  network_interface {
    name                      = "nic-${var.vmss.name}"
    primary                   = true
    network_security_group_id = var.network_security_group_id

    ip_configuration {
      name      = "ipconfig1"
      primary   = true
      subnet_id = var.subnet_id
      # 各インスタンスにパブリック IP は付けない。ロードバランサ経由で公開する
      load_balancer_backend_address_pool_ids = var.load_balancer_backend_address_pool_ids
    }
  }

  os_disk {
    caching              = var.vmss.os_disk.os_disk_cache
    storage_account_type = var.vmss.os_disk.os_disk_type
    disk_size_gb         = var.vmss.os_disk.os_disk_size
  }

  source_image_reference {
    publisher = "canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}

  # アプリの配置・接続情報の書き込み・起動を 1 つの拡張機能で行う
  # custom_data（cloud-init）を使わないのは理由が 2 つある
  # 1. cloud-init は完了を待たずに VM を ready と報告するため、apply が終わってもアプリが起動していないことがある
  # 2. custom_data は /var/lib/waagent/CustomData に平文で残る
  # 拡張機能はプロビジョニングの完了まで Terraform が待つ
  # protected_settings は転送と設定ファイルが暗号化される。復号されたスクリプトは root 500 で残る
  extension {
    name                               = "setup-todo-app"
    publisher                          = "Microsoft.Azure.Extensions"
    type                               = "CustomScript"
    type_handler_version               = "2.1"
    auto_upgrade_minor_version_enabled = true

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
  }
}
