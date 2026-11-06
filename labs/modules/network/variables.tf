variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "allowed_client_ips" {
  type = list(string)
}
