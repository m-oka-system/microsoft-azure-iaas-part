# apply の直後に、次の手順で入力するコマンドを画面へ表示する
#
# terraform output はコメントを出せない。description を書いても Outputs には表示されない
# 並び順も名前のアルファベット順で固定される
# 値そのものを複数行にすれば、改行と補足を画面へ出せる（ヒアドキュメントとして表示される）

output "next_steps" {
  value = <<-EOT
    以下の手順に従って進めてください。

      1. ブラウザで Todo アプリを開く (データベースがないためエラー画面が表示)
         http://${module.vm.public_ip_address["vm01"]}
         http://${module.vm.public_ip_address["vm02"]}

      2. ヘルスチェック用の URL にアクセスして正常性を確認する
         curl http://${module.vm.public_ip_address["vm01"]}/health
         curl http://${module.vm.public_ip_address["vm02"]}/health
  EOT
}
