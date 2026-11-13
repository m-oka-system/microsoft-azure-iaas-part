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

variable "random_suffix" {
  type    = string
  default = ""

  validation {
    condition     = can(regex("^[a-z0-9]*$", var.random_suffix))
    error_message = "random_suffix に使えるのは英小文字と数字だけです。"
  }
}
