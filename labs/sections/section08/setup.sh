#!/usr/bin/env bash
# Cloud Shell から curl でパイプ実行する入口。処理の本体は scripts/lab-setup.sh にある
set -euo pipefail

readonly LAB_PATH="labs/sections/section08"
readonly REPO_URL="https://github.com/m-oka-system/mssql-todo-app.git"
# 改名したときに直す箇所を 1 つに保つため、置き場所は URL から導く
REPO_DIR="${HOME}/$(basename "$REPO_URL" .git)"
readonly REPO_DIR

# 永続ストレージを使う Cloud Shell では $HOME が残る
# 既にあるものには手を触れず、そのまま terraform apply へ進む
# terraform.tfstate も残るため、差分がなければ No changes で終わる
if [ ! -d "$REPO_DIR" ]; then
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
fi

exec "${REPO_DIR}/scripts/lab-setup.sh" "$LAB_PATH"
