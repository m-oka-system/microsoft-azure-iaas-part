variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "japaneast"
}

variable "allowed_client_ip" {
  type    = list(string)
  default = []
}
