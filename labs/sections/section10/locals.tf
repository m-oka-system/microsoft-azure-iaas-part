locals {
  terraform_client_ip = chomp(data.http.my_ip.response_body)
  allowed_client_ips  = distinct(concat([local.terraform_client_ip], var.allowed_client_ip))

  # リソース名へ付ける一意な文字列
  # var.random_suffix が空なら random_string の値を使う
  suffix = var.random_suffix != "" ? var.random_suffix : random_string.suffix.result

  # VMSS 向けカスタムデータに埋め込む DB 接続情報を組み立てる
  vmss_setup_script             = file("${path.root}/../../../deploy/vmss-portal-setup.sh")
  vmss_custom_data_placeholders = ["<server-name>.database.windows.net", "<admin-user>", "<password>"]
  vmss_custom_data = replace(
    replace(
      replace(local.vmss_setup_script, "<server-name>.database.windows.net", module.mssql_server.fully_qualified_domain_name),
      "<admin-user>", module.mssql_server.administrator_login
    ),
    "<password>", module.mssql_server.administrator_login_password
  )
}
