variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

# アプリの取得元。公開リポジトリのため認証はいらない
variable "app_repository_url" {
  type    = string
  default = "https://github.com/m-oka-system/mssql-todo-app.git"
}

# アプリを配置するかどうか
# 接続情報の有無では判定できない。db_host などは apply まで値が決まらず、for_each の条件に使えないため
variable "install_app_enabled" {
  type    = bool
  default = false
}

# 接続情報。install_app_enabled = true のときに必要になる
# 拡張機能の protected_settings 経由で渡す
variable "db_host" {
  type    = string
  default = null
}

variable "db_name" {
  type    = string
  default = null
}

variable "db_user" {
  type    = string
  default = null
}

variable "db_password" {
  type      = string
  default   = null
  sensitive = true
}

variable "vm" {
  type = map(object({
    name                            = string
    vm_size                         = optional(string, "Standard_B1s")
    zone                            = optional(string, "1")
    allow_extension_operations      = optional(bool, true)
    disable_password_authentication = optional(bool, true)
    encryption_at_host_enabled      = optional(bool, false)
    patch_mode                      = optional(string, "ImageDefault")
    secure_boot_enabled             = optional(bool, true)
    vtpm_enabled                    = optional(bool, true)
    os_disk = optional(object({
      os_disk_cache             = optional(string, "ReadWrite")
      os_disk_type              = optional(string, "StandardSSD_LRS")
      os_disk_size              = optional(number, 30)
      write_accelerator_enabled = optional(bool, false)
    }), {})
    public_ip = optional(bool, false)
  }))
}
