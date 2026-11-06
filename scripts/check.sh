#!/usr/bin/env bash
# コミット前の検証をまとめて実行する。引数で 1 種類だけ実行できる
# CI は導入しない。実行の判断は作成者が行う（claudedocs/plan/2026-08-02-repository-structure.md 第 8 節）
set -uo pipefail

# readonly では右辺のコマンド置換が失敗しても set -e が止めないため、代入と分ける
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT" || exit 1

# モジュールの検証は一時ディレクトリごとに init する
# キャッシュがないとプロバイダを毎回取り直し、1 回の実行で数 GB を落とすことになる
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${HOME}/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

failed=0

report() {
  # $1: 種別, $2: 終了コード
  if [ "$2" -eq 0 ]; then
    echo "  OK: $1"
  else
    echo "  NG: $1" >&2
    failed=1
  fi
}

# git の追跡対象に加え、まだ追跡されていないファイルも対象にする
# 新しく足したファイルが、コミット前は検証されないという穴を防ぐ
#
# core.quotePath=false と -z が必須である
# 既定では非 ASCII のパスが "\343\202\265..." へ変換され、実在しないパスとして黙って検査から外れる
# reference/ は sectionNN.<日本語のセクション名>.md を使うため、既定のままだと丸ごと未検証になる
list_files() {
  git -c core.quotePath=false ls-files -z --cached --others --exclude-standard -- "$1"
}

# Terraform のルート（terraform.tf を持つディレクトリ）を列挙する
find_terraform_roots() {
  find labs/sections -name terraform.tf -not -path "*/.terraform/*" -exec dirname {} \; | sort
}

# モジュールを列挙する。ルートから参照されていないモジュールも検証の対象にする
find_terraform_modules() {
  find labs/modules -mindepth 1 -maxdepth 1 -type d | sort
}

# 受講者に配らない検証用のラボ。手順書を持たないため README を要求しない
readonly LABS_WITHOUT_README="labs/sections/base"

requires_readme() {
  case " ${LABS_WITHOUT_README} " in
    *" $1 "*) return 1 ;;
  esac
  return 0
}

check_terraform() {
  echo "[terraform]"
  terraform fmt -check -recursive labs > /dev/null
  report "fmt -check" $?

  local roots
  roots="$(find_terraform_roots)"

  # terraform.tf が消えるとルートが 0 件になり、ループが 1 度も回らないまま成功してしまう
  if [ -z "$roots" ]; then
    report "Terraform ルートの検出（0 件）" 1
    return
  fi

  local root
  while IFS= read -r root; do
    (cd "$root" && terraform init -backend=false -input=false > /dev/null && terraform validate > /dev/null)
    report "validate ${root}" $?
  done <<< "$roots"

  # 未参照のモジュールはルート経由では検証されない
  # プロバイダを完全固定しているため、破壊的変更に気づけないまま残り続ける
  #
  # モジュールを一時ディレクトリへ複製し、ラボと同じバージョン制約を持ち込んでから検証する
  # 制約なしで検証すると最新のプロバイダが使われ、固定した版に対する結果にならない
  local modules pin module tmp
  modules="$(find_terraform_modules)"

  if [ -z "$modules" ]; then
    report "モジュールの検出（0 件）" 1
    return
  fi

  pin="scripts/module-pin.tf"

  while IFS= read -r module; do
    if ! compgen -G "$module"/*.tf > /dev/null; then
      report "モジュールに *.tf がありません ${module}" 1
      continue
    fi

    tmp="$(mktemp -d)"
    # templatefile() が参照する *.tftpl や cloud-init.yaml も要るため、中身をすべて複製する
    cp -R "$module"/. "$tmp/"
    rm -rf "$tmp/.terraform" "$tmp/.terraform.lock.hcl"

    # 子モジュールは source だけを宣言し、バージョンを持たない（計画書 第 6 節）
    # そのままだとラボと違う版で検証されるため、モジュール側の terraform ブロックを外して pin を置く
    sed -i.bak '/^terraform {/,/^}/d' "$tmp"/*.tf && rm -f "$tmp"/*.bak
    cp "$pin" "$tmp/zz-provider-pin.tf"

    (cd "$tmp" && terraform init -backend=false -input=false > /dev/null && terraform validate > /dev/null)
    report "validate ${module}" $?
    rm -rf "$tmp"
  done <<< "$modules"
}

check_version() {
  echo "[version]"
  local root file found loose="" missing="" mismatch=""
  local pin="scripts/module-pin.tf"

  while IFS= read -r root; do
    file="${root}/terraform.tf"

    # = で始まらないバージョン指定を探す。~> や >= が残っていれば実行日で結果が変わる
    found="$(grep -n 'version *= *"[^=]' "$file" | sed "s|^|${file}:|" || true)"
    [ -n "$found" ] && loose="${loose}${found}"$'\n'

    # version 行そのものが消えると上の検査は素通りする
    # source の数と version の数が合わなければ、どれかが固定されていない
    local sources versions
    sources="$(grep -c 'source *= *"' "$file")"
    versions="$(grep -c 'version *= *"=' "$file")"
    if [ "$sources" -ne "$versions" ]; then
      missing="${missing}${file}: source ${sources} 件に対し完全固定は ${versions} 件"$'\n'
    fi

    # モジュール単体の検証は module-pin.tf を使う
    # ラボ側と版が食い違うと、モジュールだけ別の版で検証される
    local line
    while IFS= read -r line; do
      grep -qF "$line" "$pin" || mismatch="${mismatch}${file}: ${line} が ${pin} にありません"$'\n'
    done < <(grep -oE 'version *= *"=[^"]+"' "$file")
  done < <(find_terraform_roots)

  if [ -n "$loose" ] || [ -n "$missing" ] || [ -n "$mismatch" ]; then
    [ -n "$loose" ] && printf '%s\n' "$loose" >&2
    [ -n "$missing" ] && printf '%s' "$missing" >&2
    [ -n "$mismatch" ] && printf '%s' "$mismatch" >&2
    report "プロバイダの完全固定" 1
  else
    report "プロバイダの完全固定" 0
  fi
}

check_secrets() {
  echo "[secrets]"
  local tracked
  tracked="$(git ls-files | grep -E '(^|/)\.env$|\.pem$|\.tfstate' || true)"

  if [ -n "$tracked" ]; then
    echo "$tracked" >&2
    report "秘密を含むファイルが追跡されていないこと" 1
  else
    report "秘密を含むファイルが追跡されていないこと" 0
  fi
}

check_shell() {
  echo "[shell]"
  local script scripts=()

  # *.sh.tftpl は VM 上で Bash として実行される
  # 構文エラーは拡張機能の実行まで分からないため、ここで拾う
  while IFS= read -r -d '' script; do scripts+=("$script"); done < <(list_files '*.sh')
  while IFS= read -r -d '' script; do scripts+=("$script"); done < <(list_files '*.sh.tftpl')

  for script in "${scripts[@]}"; do
    bash -n "$script"
    report "bash -n ${script}" $?
  done

  # 実行ビットを失うと、setup.sh からの exec が Permission denied で全受講者に失敗する
  local nox=""
  while IFS= read -r -d '' script; do
    [ -x "$script" ] || nox="${nox}${script}"$'\n'
  done < <(list_files '*.sh')

  if [ -n "$nox" ]; then
    printf '%s' "$nox" >&2
    report "実行ビット" 1
  else
    report "実行ビット" 0
  fi

  if command -v shellcheck > /dev/null; then
    # *.sh.tftpl は先頭に shellcheck disable=SC2154 を持つ
    # ${...} を Terraform が展開するため、未代入の変数に見えることへの対処である
    shellcheck "${scripts[@]}"
    report "shellcheck" $?
  else
    # SKIP を成功と見分けられるよう、末尾のサマリでも警告する
    echo "  SKIP: shellcheck（未導入。brew install shellcheck で導入します）" >&2
    skipped=1
  fi
}

check_python() {
  echo "[python]"
  uvx ruff check . > /dev/null
  report "ruff check" $?

  uvx ruff format --check . > /dev/null
  report "ruff format --check" $?

  # tests/ は .gitignore の対象のため、クリーンな clone には存在しない
  # 無条件に実行すると収集ゼロ（終了コード 5）で必ず失敗する
  if [ -d tests ]; then
    uv run pytest -q > /dev/null
    report "pytest" $?
  else
    echo "  SKIP: pytest（tests/ がありません。git 管理外のため clone には含まれません）" >&2
    skipped=1
  fi
}

check_docs() {
  echo "[docs]"
  local broken="" file target resolved

  # リポジトリ内のリンクが実在するか確認する。外部 URL とアンカーだけの参照は対象外
  # タイトル付き [a](path "title")・山括弧 [a](<path>)・参照リンク [a][id] は扱わない
  # 教材の文書ではこれらの記法を使わない取り決めのため、使い始めたらここも直す
  while IFS= read -r -d '' file; do
    while IFS= read -r target; do
      [ -z "${target%%#*}" ] && continue
      resolved="$(dirname "$file")/${target%%#*}"
      [ -e "$resolved" ] || broken="${broken}${file}: ${target}"$'\n'
    done < <(grep -oE '\]\([^)#][^)]*\)' "$file" | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(https?|mailto):' || true)
  done < <(list_files '*.md')

  if [ -n "$broken" ]; then
    printf '%s' "$broken" >&2
    report "リポジトリ内リンク" 1
  else
    report "リポジトリ内リンク" 0
  fi

  # ラボの検出は Terraform ルート起点にする。README を持たないラボも拾える
  local root readme missing=""
  while IFS= read -r root; do
    requires_readme "$root" || continue
    readme="${root}/README.md"
    if [ ! -f "$readme" ]; then
      missing="${missing}${root}: README.md がありません"$'\n'
      continue
    fi
    local section
    for section in 注意事項 確認 片付け; do
      grep -q "^## ${section}" "$readme" || missing="${missing}${readme}: ${section}"$'\n'
    done
  done < <(find_terraform_roots)

  if [ -n "$missing" ]; then
    printf '%s' "$missing" >&2
    report "ラボの必須の節" 1
  else
    report "ラボの必須の節" 0
  fi

  # リポジトリ改名時の取りこぼしを防ぐ。旧名が残っていると curl と git clone が 404 になる
  # 対象は自リポジトリを取得する URL だけに絞る。他リポジトリへの参照リンクは対象外
  local expected old=""
  expected="$(basename "$(git remote get-url origin 2> /dev/null || echo unknown)" .git)"

  local found
  while IFS= read -r -d '' file; do
    found="$(grep -nE "raw\.githubusercontent\.com/m-oka-system/|github\.com/m-oka-system/[A-Za-z0-9._-]+\.git" "$file" \
      | grep -vE "(raw\.githubusercontent\.com|github\.com)/m-oka-system/${expected}[/.]" \
      | sed "s|^|${file}:|" || true)"
    [ -n "$found" ] && old="${old}${found}"$'\n'
  done < <(list_files '*')

  if [ -n "$old" ]; then
    printf '%s\n' "$old" >&2
    report "リポジトリ名の一致（remote: ${expected}）" 1
  else
    report "リポジトリ名の一致（remote: ${expected}）" 0
  fi

  # 受講者が最初に叩く 1 行が壊れていないか確かめる
  # 手順書の curl・setup.sh の LAB_PATH・実際のディレクトリの 3 つが揃っている必要がある
  local root lab_path url_path bad=""
  while IFS= read -r root; do
    lab_path="$(grep -oE '^readonly LAB_PATH="[^"]+"' "${root}/setup.sh" | sed 's/.*="//; s/"$//')"
    [ "$lab_path" = "$root" ] || bad="${bad}${root}/setup.sh: LAB_PATH=${lab_path}"$'\n'

    requires_readme "$root" || continue
    url_path="$(grep -oE 'refs/heads/main/[^ ]*/setup\.sh' "${root}/README.md" | sed 's|refs/heads/main/||; s|/setup\.sh$||' | head -1)"
    [ -z "$url_path" ] || [ "$url_path" = "$root" ] || bad="${bad}${root}/README.md: curl の URL が ${url_path}"$'\n'
  done < <(find_terraform_roots)

  if [ -n "$bad" ]; then
    printf '%s' "$bad" >&2
    report "ラボのパスの一致" 1
  else
    report "ラボのパスの一致" 0
  fi
}

skipped=0
target="${1:-all}"
case "$target" in
  terraform) check_terraform ;;
  version) check_version ;;
  secrets) check_secrets ;;
  shell) check_shell ;;
  python) check_python ;;
  docs) check_docs ;;
  all)
    check_terraform
    check_version
    check_secrets
    check_shell
    check_python
    check_docs
    ;;
  *)
    echo "使い方: $0 [terraform|version|secrets|shell|python|docs]" >&2
    exit 1
    ;;
esac

if [ "$failed" -ne 0 ]; then
  echo "" >&2
  echo "検証に失敗した項目があります。" >&2
  exit 1
fi

echo ""
if [ "$skipped" -ne 0 ]; then
  echo "通りましたが、実行できなかった検証があります（上の SKIP を確認してください）。"
else
  echo "すべて通りました。"
fi
