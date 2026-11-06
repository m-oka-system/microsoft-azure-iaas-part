variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "name" {
  type = string
}

variable "administrator_login" {
  type    = string
  default = "sqladmin"
}

variable "server_version" {
  type    = string
  default = "12.0"
}

variable "minimum_tls_version" {
  type    = string
  default = "1.2"
}

variable "public_network_access_enabled" {
  type    = bool
  default = true
}

variable "firewall_rule" {
  type = map(object({
    name             = string
    start_ip_address = string
    end_ip_address   = string
  }))
  default = {}
}
