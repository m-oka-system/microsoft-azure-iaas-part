#!/usr/bin/env bash
#
# Azure VM（Ubuntu 24.04 LTS）に Todo アプリを配置して起動する
#
#   sudo ./deploy/setup.sh
#
# 何度実行しても同じ結果になるように書いている
# 記入済みの /opt/todo/src/.env は上書きしない
# ただしこれは「コピー元に .env がない」ことに依存する。src/ をディレクトリごとコピーするため
# VM 上の clone には .env がない（.gitignore の対象）
# Terraform を実行した端末の作業ツリーには .env ができるが、そこからこのスクリプトは実行しない

# 途中で失敗したら、その場で止める
#   -e          コマンドが失敗したら終了する
#   -u          未定義の変数を参照したら終了する
#   -o pipefail パイプの途中で失敗しても終了する
set -euo pipefail

UBUNTU_VERSION="24.04"
APP_USER="todo"
APP_DIR="/opt/todo"
SERVICE_NAME="todo"
UV_BIN="/usr/local/bin/uv"
# 開発環境と同じバージョンに固定する。uv.lock を作ったのもこのバージョン
# 最新版を取りに行くと、実行した日によって VM の状態が変わる
UV_VERSION="0.9.18"
# 2 秒間隔で 15 回試し、最大 30 秒待ってから失敗と判定する
HEALTH_CHECK_ATTEMPTS=15
HEALTH_CHECK_INTERVAL=2

# apt がライセンス同意などの対話プロンプトで止まらないようにする
export DEBIAN_FRONTEND=noninteractive

# このスクリプトが置かれた deploy/ の親が、リポジトリのルート
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

log() {
    echo "==> $*"
}

# Azure の Ubuntu イメージは、起動直後に複数のユニットが apt のロックを取り合う
# esm-cache と apt-news は Ubuntu 24.04 で追加されたもので、ブート直後に必ず走る
# apt-daily はタイマー起動のため、待っている最中に割り込むこともある
# 素の apt-get はロックを取れずに即座に失敗し、set -e でスクリプトがそこで止まる
#
# 「待つ」のではなく「走らせない」ことで、タイミングへの依存をなくす
APT_UNITS="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service esm-cache.service apt-news.service"

stop_apt_units() {
    # 停止済みや存在しないユニットでも失敗させない
    # shellcheck disable=SC2086
    systemctl stop $APT_UNITS 2>/dev/null || true
}

start_apt_units() {
    # 復元するのはタイマーだけ。サービスはタイマーから起動される
    systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
}

# 途中で失敗しても自動更新を止めたままにしない
trap start_apt_units EXIT

# 停止しても取りこぼす場合に備えて、失敗したら少し待って試し直す
# 上限は 3 回。ロック以外の失敗（ネットワーク断など）でも再試行するが、45 秒で打ち切る
apt-get() {
    local attempt
    for attempt in 1 2 3; do
        if command apt-get "$@"; then
            return 0
        fi
        log "apt-get が失敗しました。15 秒待って再試行します（${attempt}/3）"
        sleep 15
    done
    return 1
}

# 起動に失敗したときの案内
# 画面にはエラーの詳細を出さない設計のため、ログの見方を伝えないと受講者が行き詰まる
abort_with_log_hint() {
    echo "" >&2
    echo "$1" >&2
    echo "次のコマンドでログを確認してください。" >&2
    echo "  sudo journalctl -u $2 -n 50 --no-pager" >&2
    exit 1
}

# 応答を返すまで待つ。固定の sleep では、VM の性能や初回起動の差で足りない
wait_for_health() {
    local url="$1"
    local attempt=1
    while [ "$attempt" -le "$HEALTH_CHECK_ATTEMPTS" ]; do
        # アプリの /health は、要求を受け付けられる状態のとき 200 を返す
        # DB には触らないため、接続情報が未記入でも 200 が返る
        # 本文は実行環境の情報を載せた JSON のため、ステータスコードで判定する
        if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url")" = "200" ]; then
            return 0
        fi
        sleep "$HEALTH_CHECK_INTERVAL"
        attempt=$((attempt + 1))
    done
    return 1
}

#### 引数の解析

# --env-file <パス> で接続情報のファイルを渡せる
# 渡されたものを /opt/todo/src/.env へ配置する。配置先・所有者・パーミッションを利用者に打たせない
# サービスの起動より前に配置するため、渡した場合は再起動も要らない
#
# パスは呼び出し側のシェルが展開する
# スクリプトの中で ~ を書くと、sudo が入れ替えた HOME を指してしまう
ENV_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --env-file)
            if [ $# -lt 2 ]; then
                echo "--env-file にはファイルのパスが必要です。" >&2
                exit 1
            fi
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            echo "使い方: sudo $0 [--env-file <接続情報のファイル>]" >&2
            exit 1
            ;;
    esac
done

# 配置は後半のため、誤りに気づくのが数分後になる
# 読めないパスは、ここで止めて打ち直してもらう
if [ -n "$ENV_FILE" ] && [ ! -r "$ENV_FILE" ]; then
    echo "接続情報のファイルを読み取れません: ${ENV_FILE}" >&2
    exit 1
fi

#### 前提の確認

if [ "$(id -u)" -ne 0 ]; then
    echo "root 権限が必要です。sudo を付けて実行してください。" >&2
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release

# ODBC Driver 18 のリポジトリ URL は Ubuntu のバージョンごとに分かれている
# 対象外のバージョンで実行すると、存在しない URL を取得して失敗する
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "$UBUNTU_VERSION" ]; then
    echo "このスクリプトは Ubuntu ${UBUNTU_VERSION} 専用です（検出: ${PRETTY_NAME:-不明}）。" >&2
    exit 1
fi

#### 1. ODBC Driver 18 の導入

log "ODBC Driver 18 を導入します"
# 最初の apt の前に自動更新を止める。終了時に trap がタイマーを戻す
stop_apt_units
apt-get update
apt-get install -y curl ca-certificates

# Microsoft のリポジトリ定義と署名鍵を、1 つのパッケージでまとめて登録する
REPO_DEB="$(mktemp --suffix=.deb)"
curl -sSLf -o "$REPO_DEB" \
    "https://packages.microsoft.com/config/ubuntu/${UBUNTU_VERSION}/packages-microsoft-prod.deb"
# dpkg を直接呼ばず apt 経由で入れる。dpkg にはロックを待つ仕組みがない
apt-get install -y "$REPO_DEB"
rm -f "$REPO_DEB"

apt-get update
# ACCEPT_EULA=Y を付けないと、ライセンス同意のプロンプトで止まる
ACCEPT_EULA=Y apt-get install -y msodbcsql18

#### 2. nginx の導入

log "nginx を導入します"
apt-get install -y nginx

#### 3. エディタの導入

log "エディタ（micro）を導入します"
# 接続情報を記入するために使う
# vi や nano と違い、保存が Ctrl+S、終了が Ctrl+Q で、モードもメタキーの表記もない
# 受講者が最初につまずく箇所を減らすために入れる
#   --no-install-recommends  推奨パッケージの xclip（X11 一式を引き込む）を避ける
# 編集中の作業ファイルを対象のディレクトリに残さないため、中断しても次回そのまま開ける（vi や nano の .swp が残る問題が起きない）
apt-get install -y --no-install-recommends micro

#### 4. uv の導入

INSTALLED_UV_VERSION=""
if [ -x "$UV_BIN" ]; then
    # uv --version は「uv 0.9.18 (...)」の形で出力する
    INSTALLED_UV_VERSION="$("$UV_BIN" --version | awk '{print $2}')"
fi

if [ "$INSTALLED_UV_VERSION" = "$UV_VERSION" ]; then
    log "uv ${UV_VERSION} は導入済みです"
else
    log "uv ${UV_VERSION} を導入します"
    # UV_INSTALL_DIR で全ユーザーから使える場所に入れる
    # 既定の入れ先は実行ユーザーのホームで、systemd から起動するサービスからは見えない
    # UV_NO_MODIFY_PATH=1 は、インストーラが PATH 設定用の env スクリプトを /usr/local/bin/env に作り、/usr/bin/env を隠してしまうのを防ぐ
    curl -sSLf "https://astral.sh/uv/${UV_VERSION}/install.sh" |
        env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh
fi

#### 5. 実行ユーザーの作成

log "実行ユーザー ${APP_USER} を作成します"
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    # root では動かさないため、ログインシェルを持たないシステムユーザーを用意する
    # ホームをアプリのディレクトリに合わせ、uv のキャッシュもそこへ置く
    useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
fi

#### 6. アプリの配置

log "アプリを ${APP_DIR} に配置します"
mkdir -p "$APP_DIR/src"
# src/ はディレクトリごとコピーする
# 以前はファイルを 1 つずつ列挙していたが、テンプレートを追加したときに書き足し忘れ、VM でだけ 500 になった
# ローカル実行もテストも src/ を直接読むため、この漏れは実機でしか分からない
#
# 記入済みの .env は残る。コピー元は clone したリポジトリで、.gitignore の対象の .env を含まないため
# cp はコピー元にないファイルを消さない
cp -r "$REPO_DIR/src/." "$APP_DIR/src/"
# リポジトリ直下は列挙する。docs/ や labs/ など、アプリの実行に要らないものが混ざるため
cp "$REPO_DIR/pyproject.toml" "$REPO_DIR/uv.lock" "$REPO_DIR/.python-version" "$APP_DIR/"

# --env-file で渡されたものを優先する。既にある .env は置き換わる
# install は書き込みと所有者・パーミッションの指定を 1 つのコマンドで行う
#
# 渡されたファイルは消さない。何度実行しても同じ結果になる性質を保つため
# 削除は手順書で案内する
if [ -n "$ENV_FILE" ]; then
    log "接続情報を ${APP_DIR}/src/.env へ配置します"
    install -o "$APP_USER" -g "$APP_USER" -m 600 "$ENV_FILE" "$APP_DIR/src/.env"
# 既にある .env は上書きしない。接続情報を記入したあとに再実行しても消えない
elif [ ! -f "$APP_DIR/src/.env" ]; then
    cp "$REPO_DIR/src/.env.sample" "$APP_DIR/src/.env"
fi

chown -R "${APP_USER}:${APP_USER}" "$APP_DIR"
# 接続情報を含むため、所有者だけが読み書きできる権限にする
chmod 600 "$APP_DIR/src/.env"

#### 7. 依存パッケージのインストール

log "依存パッケージをインストールします"
# HOME を明示して、uv のキャッシュと仮想環境をアプリのディレクトリに収める
#   --frozen  uv.lock のバージョンをそのまま使う
#   --no-dev  ruff と pytest を入れない。VM では使わないため
#             todo.service の uv run 側にも同じ指定が必要。片方だけだと、
#             サービスの初回起動時に uv が入れ直し、ここで減らした意味がなくなる
sudo -u "$APP_USER" env HOME="$APP_DIR" "$UV_BIN" sync --frozen --no-dev --project "$APP_DIR"

#### 8. 旧バージョンの残骸の削除

log "旧バージョンの残骸を削除します"
# 消す対象は 1 つずつ列挙する
# rm -rf "$APP_DIR" のようなまとめ消しは、記入済みの .env や作成済みの .venv まで消してしまう
#
# .env.sample は src/ 配下へ移った
# 直下に残ると同じ内容が 2 か所に並び、受講者がどちらを使うのか迷う
rm -f "$APP_DIR/.env.sample"
# schema.sql は配布しない。アプリがテーブルを作成するようになったため
# 旧バージョンから更新した VM に残っていると、手で実行する手順があるように見える
rm -f "$APP_DIR/schema.sql" "$APP_DIR/src/schema.sql"
# $APP_DIR/.env（旧版）は消さない
# 接続情報を含むファイルを自動で消すと、受講者が控えを失う場合がある。不要になった旨は完了メッセージで案内する

#### 9. systemd サービスの設定

log "systemd サービスを設定します"
cp "$SCRIPT_DIR/todo.service" "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"
# 直前の起動が短時間に 5 回失敗していると start-limit-hit になり、restart そのものが拒否される
# daemon-reload では回数が消えないため、明示的に解除する
# これがないと、app.py を直して再実行しても復旧できない
systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true

# 再実行したときに更新後の src/app.py を読み込ませるため、start ではなく restart する
# 失敗したときは set -e でそのまま終わらせず、ログの見方を案内してから止める
systemctl restart "${SERVICE_NAME}.service" ||
    abort_with_log_hint "サービス ${SERVICE_NAME} を起動できませんでした。" "$SERVICE_NAME"

# restart の成功は、ExecStart のプロセスを起動できたことしか示さない
# 直後に終了しても Restart=always が 5 秒ごとに起動し直すため、失敗が再起動のループに隠れる
# 実際に応答するところまで確かめてから次へ進む
if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
    abort_with_log_hint "サービス ${SERVICE_NAME} が起動していません。" "$SERVICE_NAME"
fi

log "アプリの応答を待ちます（最大 $((HEALTH_CHECK_ATTEMPTS * HEALTH_CHECK_INTERVAL)) 秒）"
# 確認先は / ではなく /health
# / はデータベースに接続するため、この時点では .env が未記入で 503 が返り、正しくセットアップできてもここで失敗扱いになる
if ! wait_for_health "http://127.0.0.1:8000/health"; then
    abort_with_log_hint \
        "アプリが応答しません（http://127.0.0.1:8000/health）。" "$SERVICE_NAME"
fi

#### 10. nginx の設定

log "nginx を設定します"
cp "$SCRIPT_DIR/todo.nginx.conf" /etc/nginx/sites-available/todo.conf
ln -sfn /etc/nginx/sites-available/todo.conf /etc/nginx/sites-enabled/todo.conf
# 既定のサイトも default_server を宣言しているため、残すと設定検査で衝突する
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable nginx
systemctl restart nginx

if ! systemctl is-active --quiet nginx; then
    abort_with_log_hint "nginx が起動していません。" "nginx"
fi

log "nginx 経由の応答を確認します"
# 80 番から同じ /health に届けば、nginx から gunicorn への経路が通っている
# ここも / は使わない（.env 未記入の状態では 503 になる）
if ! wait_for_health "http://127.0.0.1/health"; then
    abort_with_log_hint \
        "nginx 経由でアプリに到達できません（http://127.0.0.1/health）。" "nginx"
fi

#### 完了

log "セットアップが完了しました"

# 残りの手順は案内しない。手順書とラボの手順書を正とする
# 両方に書くと、片方だけが古くなったときに受講者がどちらを信じるか分からなくなる

# 旧版が置いていった .env は、接続情報を含むため自動では消さない
if [ -f "$APP_DIR/.env" ]; then
    cat <<EOF

${APP_DIR}/.env は旧バージョンが使っていたファイルで、現在は参照されません。
接続情報を ${APP_DIR}/src/.env へ写したあと、次のコマンドで削除してください。
  sudo rm ${APP_DIR}/.env
EOF
fi

echo ""
