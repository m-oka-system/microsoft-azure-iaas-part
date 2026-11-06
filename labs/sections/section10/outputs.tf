# カスタム データを取り出すコマンドを出力
output "show_custom_data" {
  value = "cd ${abspath(path.root)} && terraform output -raw vmss_custom_data"
}

# VMSS のカスタム データ欄へ貼り付ける内容
# DB のパスワードを含むため sensitive にする
# apply の画面には <sensitive> としか出ないため、取り出すには terraform output -raw が要る
output "vmss_custom_data" {
  value     = local.vmss_custom_data
  sensitive = true

  precondition {
    condition     = alltrue([for placeholder in local.vmss_custom_data_placeholders : strcontains(local.vmss_setup_script, placeholder)])
    error_message = "deploy/vmss-portal-setup.sh に想定したプレースホルダがありません。表記を変えた場合は locals.tf の置換も直してください。"
  }
}
