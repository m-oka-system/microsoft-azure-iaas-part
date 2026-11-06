variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

# ロードバランサのバックエンドプール
# ロードバランサを作らない構成では空のままにする
variable "load_balancer_backend_address_pool_ids" {
  type    = list(string)
  default = []
}

variable "network_security_group_id" {
  type    = string
  default = null
}

variable "vmss" {
  type = object({
    name     = string
    sku_name = optional(string, "Standard_F1as_v7")
    # 振り分けを目で確認するため、既定で 2 台にする
    instances = optional(number, 2)
    zones     = optional(list(string), ["1", "2", "3"])
    # ゾーンを指定する構成では 1 にする
    platform_fault_domain_count = optional(number, 1)
    os_disk = optional(object({
      os_disk_cache = optional(string, "ReadWrite")
      os_disk_type  = optional(string, "StandardSSD_LRS")
      os_disk_size  = optional(number, 30)
    }), {})
  })
}

# アプリの取得元。公開リポジトリのため認証はいらない
variable "app_repository_url" {
  type    = string
  default = "https://github.com/m-oka-system/mssql-todo-app.git"
}

# 接続情報は拡張機能の protected_settings 経由で渡す
variable "db_host" {
  type = string
}

variable "db_name" {
  type = string
}

variable "db_user" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}
