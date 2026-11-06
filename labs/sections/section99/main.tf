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

  # 拡張機能でアプリの配置と .env の書き込みまで行う
  install_app_enabled = true
  db_host             = module.mssql_server.fully_qualified_domain_name
  db_name             = module.mssql_database.name
  db_user             = module.mssql_server.administrator_login
  db_password         = module.mssql_server.administrator_login_password

  vm = {
    vm01 = {
      name      = "vm01"
      public_ip = true
    }
  }
}

module "mssql_server" {
  source              = "../../modules/mssql_server"
  resource_group_name = data.azurerm_resource_group.this.name
  location            = var.location
  name                = "sql-${random_string.suffix.result}"

  # VM と SSH を許可した端末からの接続（ポータルのクエリエディター用）を許可する
  firewall_rule = merge(
    {
      vm = {
        name             = "vm01"
        start_ip_address = module.vm.public_ip_address["vm01"]
        end_ip_address   = module.vm.public_ip_address["vm01"]
      }
    },
    {
      for ip in local.allowed_client_ips : "client-${replace(ip, ".", "-")}" => {
        name             = "client-${replace(ip, ".", "-")}"
        start_ip_address = ip
        end_ip_address   = ip
      }
    }
  )
}

module "mssql_database" {
  source    = "../../modules/mssql_database"
  location  = var.location
  server_id = module.mssql_server.id
  name      = "todo"
}

# 接続情報を src/.env へ書き出す。このまま uv run python src/app.py で使える
resource "local_sensitive_file" "env" {
  filename        = abspath("${path.root}/../../../src/.env")
  file_permission = "0600"

  content = <<-EOT
    DB_HOST=${module.mssql_server.fully_qualified_domain_name}
    DB_NAME=${module.mssql_database.name}
    DB_USER=${module.mssql_server.administrator_login}
    DB_PASSWORD=${module.mssql_server.administrator_login_password}
  EOT
}
