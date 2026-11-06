data "http" "my_ip" {
  url                = "https://api.ipify.org"
  request_timeout_ms = 10000

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "グローバル IP を取得できませんでした（HTTP ${self.status_code}）。"
    }
  }
}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  numeric = true
  upper   = false
  special = false
}

data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

module "network" {
  source              = "../../modules/network"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  allowed_client_ips  = local.allowed_client_ips
}

module "ssh_public_key" {
  source              = "../../modules/ssh_public_key"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sshkey-vm"
}

# SSH 秘密鍵をローカルへ保存する
resource "local_sensitive_file" "ssh_private_key" {
  content         = module.ssh_public_key.private_key_pem
  filename        = pathexpand("~/.ssh/${module.ssh_public_key.name}.pem")
  file_permission = "0400"
}

module "vm" {
  source              = "../../modules/vm"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  ssh_public_key      = module.ssh_public_key.public_key_openssh
  subnet_id           = module.network.subnet_id

  # 拡張機能でアプリを配置する。2 台とも同じものが動く
  install_app_enabled = true

  # このラボはデータベースを作らないため、接続情報は空欄で渡す
  db_host     = ""
  db_name     = ""
  db_user     = ""
  db_password = ""

  vm = {
    vm01 = {
      name      = "vm01"
      public_ip = true
    }
    vm02 = {
      name      = "vm02"
      public_ip = true
    }
  }
}
