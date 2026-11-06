# apply の直後に、次の手順で入力するコマンドを画面へ表示する
#
# terraform output はコメントを出せない。description を書いても Outputs には表示されない
# 並び順も名前のアルファベット順で固定される
# 値そのものを複数行にすれば、改行と補足を画面へ出せる（ヒアドキュメントとして表示される）

output "next_steps" {
  value = <<-EOT
    以下の手順に従って進めてください。

      1. ブラウザで VM に接続する (nginx の Welcome 画面が表示)
         http://${module.vm.public_ip_address["vm01"]}

      2. DB 接続情報の定義ファイル (.env) を VM へ送る
         scp -i ${local_sensitive_file.ssh_private_key.filename} ${local_sensitive_file.env.filename} ${module.vm.admin_username}@${module.vm.public_ip_address["vm01"]}:~/

      3. VM へ SSH 接続する
         ssh -i ${local_sensitive_file.ssh_private_key.filename} ${module.vm.admin_username}@${module.vm.public_ip_address["vm01"]}

      4. アプリを取得して配置する（接続した VM 上で実行）
         git clone --depth 1 https://github.com/m-oka-system/mssql-todo-app.git
         cd mssql-todo-app
         sudo deploy/setup.sh --env-file ~/.env

      5. VM のパブリック IP アドレスを SQL サーバーのファイアウォール規則へ登録する（Azure ポータルで実行）
         VM の「概要」を開き、パブリック IP アドレスをコピーする
         SQL サーバーの「ネットワーク」を開き、コピーしたパブリック IP アドレスを登録する
         登録したら 1. のブラウザを再読み込みする
  EOT
}
