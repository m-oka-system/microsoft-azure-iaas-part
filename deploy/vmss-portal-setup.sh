#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(mktemp -d)"
git clone --depth 1 https://github.com/m-oka-system/mssql-todo-app.git "$repo_dir"
cd "$repo_dir"

env_file="$(mktemp)"
cat > "$env_file" <<'ENVFILE'
DB_HOST=<server-name>.database.windows.net
DB_NAME=todo
DB_USER=<admin-user>
DB_PASSWORD=<password>
ENVFILE

"$repo_dir/deploy/setup.sh" --env-file "$env_file"

rm -f "$env_file"

cd /
rm -rf "$repo_dir"
