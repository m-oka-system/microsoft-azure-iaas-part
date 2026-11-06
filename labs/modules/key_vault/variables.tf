variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "random" {
  type = string
}

variable "key_vault" {
  type = map(object({
    name                       = string
    sku_name                   = optional(string, "standard")
    rbac_authorization_enabled = optional(bool, true)
    purge_protection_enabled   = optional(bool, false)
    soft_delete_retention_days = optional(number, 7)
  }))
}
