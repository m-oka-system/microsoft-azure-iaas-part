locals {
  terraform_client_ip = chomp(data.http.my_ip.response_body)
  allowed_client_ips  = distinct(concat([local.terraform_client_ip], var.allowed_client_ip))

  # リソース名へ付ける一意な文字列
  # var.random_suffix が空なら random_string の値を使う
  suffix = var.random_suffix != "" ? var.random_suffix : random_string.suffix.result
}
