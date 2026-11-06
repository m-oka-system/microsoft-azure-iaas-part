#!/usr/bin/env bash
# ハンズオン環境を構築する。各ラボの setup.sh から呼ばれる
# 引数はリポジトリルートから見たラボのパス（例: labs/sections/section08）
set -euo pipefail

# readonly では右辺のコマンド置換が失敗しても set -e が止めないため、代入と分ける
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

abort() {
  echo "エラー: $1" >&2
  shift
  local line
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

# az コマンドを実行し、失敗と「結果が false」を区別する
# if の条件内でコマンド置換を行うと set -e が働かず、CLI の失敗を「見つからない」と誤案内してしまう
#
# 標準エラーは戻り値へ混ぜない。az は成功時にも WARNING を出すことがあり、混ぜると結果の判定が壊れる
run_az() {
  local output status errors
  errors="$(mktemp)"
  set +e
  output="$("$@" 2> "$errors")"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    local detail
    detail="$(cat "$errors")"
    rm -f "$errors"
    abort "Azure CLI の実行に失敗しました（$*）。" \
      "未ログイン・権限不足・通信障害のいずれかが考えられます。" \
      "az login でサインインし直してから、もう一度お試しください。" \
      "" \
      "$detail"
  fi

  rm -f "$errors"
  printf '%s' "$output"
}

# 数値でなければ比較が終了コード 2 を返すが、if の条件内では set -e が止めない
# 判定を素通りして誤ったリソースグループへ apply するため、形式を先に検証する
require_number() {
  # $1: 値, $2: 何を取得しようとしたか
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    abort "$2 を取得できませんでした（応答: $1）。" \
      "az account show でサインインの状態を確認してください。"
  fi
}

if [ $# -ne 1 ]; then
  abort "引数の数が正しくありません。" "使い方: $0 <ラボのパス>"
fi

LAB_DIR="${REPO_ROOT}/$1"
readonly LAB_DIR

if [ ! -d "$LAB_DIR" ]; then
  abort "ラボのディレクトリが見つかりません: $1" \
    "リポジトリが古い可能性があります。次を実行して更新してから、もう一度お試しください。" \
    "" \
    "  git -C \"${REPO_ROOT}\" fetch --depth 1 origin main" \
    "  git -C \"${REPO_ROOT}\" reset --hard FETCH_HEAD"
fi

# リソースグループは事前に宣言させる。唯一のものを自動で検出することはしない
# 受講者のサブスクリプションには他のリソースグループが同居し得るため、唯一であることを前提にできない
if [ -z "${TF_VAR_resource_group_name:-}" ]; then
  abort "デプロイ先のリソースグループが指定されていません。" \
    "リソースグループ名を宣言してから、もう一度実行してください。" \
    "" \
    '  export TF_VAR_resource_group_name="rg-iaas"'
fi

# 代入で受ける。if の条件内でコマンド置換すると set -e が抑止され、run_az の abort がサブシェルで止まる
group_exists="$(run_az az group exists --name "$TF_VAR_resource_group_name")"

# az group create は既存のグループにも成功するが、場所が違うと失敗するため、無いときだけ作る
# 場所は variables.tf の location の既定値と揃える
if [ "$group_exists" != "true" ]; then
  echo "リソースグループ '${TF_VAR_resource_group_name}' を作成します。"
  run_az az group create \
    --name "$TF_VAR_resource_group_name" \
    --location japaneast \
    --output none
fi

subscription="$(run_az az account show --query "name" -o tsv)"

# state があれば、このラボが既にこのリソースグループへ適用している
# 同じ構成を同じ state へ当て直すだけになるため、そのまま進む。差分がなければ No changes で終わる
#
# state がなければ初回として扱う。既存のリソースがあれば中止する
# エフェメラルな Cloud Shell では、セッションが切れた時点で state も消える
#
# 確認を取って続ける選択肢は用意しない。yes と答えても、同じ名前で作ろうとして失敗するため
# 片付けはリソースグループごとの削除に統一しているため、他のリソースとも同居させない
if [ ! -s "${LAB_DIR}/terraform.tfstate" ]; then
  resource_count="$(run_az az resource list --resource-group "$TF_VAR_resource_group_name" --query "length(@)" -o tsv)"
  require_number "$resource_count" "リソースグループ '${TF_VAR_resource_group_name}' の中身"

  if [ "$resource_count" -gt 0 ]; then
    abort "リソースグループ '${TF_VAR_resource_group_name}' には既に ${resource_count} 個のリソースがあります。" \
      "空のリソースグループを指定してください。" \
      "" \
      "サブスクリプション: ${subscription}" \
      "" \
      "前のセクションで作ったリソースが残っている場合は、Azure ポータルでリソースグループごと削除してからやり直してください。" \
      "ラボは動画と同じ名前でリソースを作るため、残っていると作成に失敗します。" \
      "" \
      "このラボを実行済みの場合も、同じく削除してからやり直してください。" \
      "作成済みのリソースの記録（${LAB_DIR}/terraform.tfstate）が残っていないため、同じ名前で作り直そうとして失敗します。"
  fi
fi

echo "サブスクリプション: ${subscription}"
echo "リソースグループ: ${TF_VAR_resource_group_name}"

# 構築済みかどうかで動作を分けない
# 入口の setup.sh は取得済みのリポジトリを更新しないため、構成だけが新しくなることは起きない
# 2 回目以降は同じ構成を同じ state へ適用することになり、差分がなければ No changes で終わる
#
# -var は渡さない。Terraform が TF_VAR_resource_group_name を自動で読む
cd "$LAB_DIR"
terraform init -input=false
terraform apply -auto-approve -input=false
