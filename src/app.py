"""Flask と Azure SQL Database で作る Todo アプリ"""

import logging
import os
import socket
import time
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path

import pyodbc
from dotenv import load_dotenv
from flask import (
    Flask,
    Response,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)
from sqlalchemy import URL, Connection, Engine, create_engine, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.pool import NullPool

# 最初の接続より前に無効化する
# pyodbc 既定のプールが実接続を保持すると、Azure SQL のセッション数が 0 にならず、自動一時停止が働かない
pyodbc.pooling = False

BASE_DIR = Path(__file__).resolve().parent
# 実際に読み込む .env の場所。VM では /opt/todo/src/.env、手元ではリポジトリの src/.env になる
# 読み込みと画面の案内で同じ値を使い、案内だけが実態とずれることを防ぐ
ENV_PATH = BASE_DIR / ".env"
JST = timezone(timedelta(hours=9))
TITLE_MAX_LENGTH = 255  # DB の列長 NVARCHAR(255) と一致させる
# 経路表を引くためだけに使う宛先。文書用に予約されたアドレスで実在しない（RFC 5737）
PRIVATE_IP_PROBE_ADDRESS = ("192.0.2.1", 1)
# 1 接続あたりの最悪の待ち時間は 5 × 10 秒（試行）+ 4 × 5 秒（待機）= 70 秒
# 一覧の表示は接続を 2 回張ることがあるため、1 リクエストでは 140 秒を見込む
# gunicorn の --timeout 150 はこの 140 秒より長くしてある
# 試行を細かく刻むのは、再開した瞬間をできるだけ早く捉えるため
# 回数を減らして 1 回あたりを長くすると、再開済みなのに前の試行の待ち時間が残る時間が増える
CONNECT_TIMEOUT_SECONDS = 10
RETRY_ATTEMPTS = 5
RETRY_WAIT_SECONDS = 5
# 停止した Azure SQL Database が再開する間に返るエラー。どちらも待てば解決する
# HYT00 はログインのタイムアウトを表す SQLSTATE
# 再開中の接続はすぐエラーにならず応答しないまま待たされるため、CONNECT_TIMEOUT_SECONDS が先に切れてこちらになる
# サーバー名の誤りやネットワークの不達も同じ HYT00 で、区別できないため待つ
RESUMING_SQLSTATE = "HYT00"
# 40613（データベースが利用できない）は SQLSTATE ではなく、pyodbc が本文の末尾へ括弧付きで付けるネイティブのエラー番号
# 括弧ごと一致させる
# このときの SQLSTATE は HY000（一般的なエラー）で、他の障害とも共通するため使えない
RESUMING_ERROR_NUMBER = "(40613)"
# 同名のオブジェクトが既にあるときに返る
# SQLSTATE は 42S01 で、エラー番号は 40613 と同じく本文の末尾へ括弧付きで付く
# どちらも実機で確認した
TABLE_ALREADY_EXISTS_SQLSTATE = "42S01"
TABLE_ALREADY_EXISTS_ERROR_NUMBER = "(2714)"
DB_ERROR_MESSAGE = "データベースに接続できません。次の内容を確認してください。"
# 頻度の高い順に並べる。どちらも受講者がその場で直せる
#
# 無料 vCore 秒の枯渇には触れない
# ラボはセクションごとに使い捨ての環境を作るため、作り直せば新しい無料枠のデータベースになる
# 復旧の手順が「リソースグループごと削除して作り直す」で片付けと同じになり、案内を分ける意味がない
DB_ERROR_CHECKS = (
    f"{ENV_PATH} の接続情報が正しく設定されているか",
    "Azure SQL Database のファイアウォール規則に、VM の送信元 IP が登録されているか",
)

# 引数なしの load_dotenv() はカレントディレクトリから上へ探索するため、起動場所によって .env を読めない
# app.py からの相対で指定する
load_dotenv(ENV_PATH)

app = Flask(__name__)
# debug が無効のとき、Flask は app.logger にレベルを設定しない
# 実効レベルは root の既定（WARNING）になり、info() は捨てられる
# gunicorn も --log-config を渡さない限り root を変えないため、明示しないと journal に 1 行も残らない
app.logger.setLevel(logging.INFO)
# 既定は True で、jsonify がキーをアルファベット順に並べ替える
# /health で先に読みたいのは hostname のため、build_debug_info() の記述順のまま出す
app.json.sort_keys = False

_engine: Engine | None = None
_table_created = False


@app.before_request
def reject_cross_site_write() -> None:
    """他のサイトから送られた POST を拒否する"""
    # 認証も Cookie もないため、CSRF トークンを結び付ける先がない
    # Sec-Fetch-Site はブラウザだけが付けられる禁止ヘッダ名でスクリプトから偽装できないため、依存を増やさずにクロスサイトの書き込みを弾ける
    # ヘッダを送らない古いブラウザや curl は通す（移植元と同じ挙動）
    if request.method == "POST" and request.headers.get("Sec-Fetch-Site") == "cross-site":
        abort(403)


def build_conn_url() -> URL:
    """環境変数から接続 URL を組み立てる"""
    # f-string で組み立てると、パスワードに含まれる @ や : がホストの区切りと解釈されて接続に失敗する
    # URL.create() は各要素をエスケープする
    return URL.create(
        "mssql+pyodbc",
        username=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        host=os.environ["DB_HOST"],
        port=1433,
        database=os.environ["DB_NAME"],
        query={
            "driver": "ODBC Driver 18 for SQL Server",
            "Authentication": "SqlPassword",
            "Encrypt": "yes",
            "TrustServerCertificate": "no",
        },
    )


def get_engine() -> Engine:
    """Engine を生成する。実接続は SQL を実行するときに張られる"""
    global _engine
    # import 時ではなくリクエストの処理中に生成する
    # import 時に生成すると、.env が未記入のときにワーカーが起動できず、案内ではなく 502 が出る
    if _engine is None:
        _engine = create_engine(
            build_conn_url(),
            # 接続を保持するとセッション数が 0 にならず、自動一時停止が働かない
            poolclass=NullPool,
            # ODBC の SQL_ATTR_LOGIN_TIMEOUT に設定される
            # 接続文字列の Connection Timeout は ODBC のキーワードではないため使えない
            connect_args={"timeout": CONNECT_TIMEOUT_SECONDS},
        )
    return _engine


def is_resuming_error(error: DBAPIError) -> bool:
    """データベースの再開を待てば解決するエラーかどうかを判定する"""
    # 例外型はドライバ依存で一定しないため、SQLSTATE とエラー番号で判定する
    # メッセージ全体を部分一致で調べてはいけない
    # 認証の失敗（SQLSTATE 28000）の本文にはユーザー名が入るため、student40613 のような名前の受講者がパスワードを間違えたときに、待っても解決しないエラーを待ってしまう
    sqlstate = error.orig.args[0] if error.orig.args else ""
    return sqlstate == RESUMING_SQLSTATE or RESUMING_ERROR_NUMBER in str(error.orig)


def is_table_already_exists_error(error: DBAPIError) -> bool:
    """同名のオブジェクトが既にあるエラーかどうかを判定する"""
    # 両方が一致したときだけ真にする
    # is_resuming_error() がどちらか一方で真になるのは、HYT00 と 40613 が別々のエラーだから
    # こちらは 1 つのエラーが持つ 2 つの属性なので、両方を確かめる
    # 本文だけで判定すると、括弧付きの数字を名前に含む利用者の別のエラーまで拾ってしまう
    sqlstate = error.orig.args[0] if error.orig.args else ""
    return sqlstate == TABLE_ALREADY_EXISTS_SQLSTATE and TABLE_ALREADY_EXISTS_ERROR_NUMBER in str(
        error.orig
    )


def connect_with_retry(engine: Engine) -> Connection:
    """接続の確立だけを再試行する。SQL の実行後は再試行しない"""
    # SQL の実行まで再試行すると、INSERT がコミット済みで応答だけ失われた場合に 2 回目の INSERT が走り、Todo が重複する
    # 重複を検出する手段はない
    for attempt in range(RETRY_ATTEMPTS):
        try:
            return engine.connect()
        except DBAPIError as e:
            # 再開待ち以外（認証やファイアウォールの誤り）は待っても解決しないため、すぐに投げる
            # 誤った資格情報は 18456、規則の不足は 40615 で即座に返る
            if not is_resuming_error(e):
                raise
            if attempt == RETRY_ATTEMPTS - 1:
                raise
            time.sleep(RETRY_WAIT_SECONDS)


def execute_sql(sql: str, params: dict | None = None, *, fetch: bool = False) -> list | None:
    """SQL を実行する。停止中のデータベースは再開を待って接続し直す"""
    # 参照系も conn.begin() で囲む
    # 明示的にコミットしない限りロールバックされるため、すべて同じ形にすることでコミット忘れが原理的に起きない
    with connect_with_retry(get_engine()) as conn, conn.begin():
        result = conn.execute(text(sql), params or {})
        return result.all() if fetch else None


def create_table_if_missing() -> None:
    """dbo.todos がなければ作成する"""
    global _table_created
    # 接続をプールしないため、実行のたびに ODBC のログインが 1 回増える
    # 一度作成できたら、以降は問い合わせない
    if _table_created:
        return
    try:
        # SQL Server には CREATE TABLE IF NOT EXISTS がないため、OBJECT_ID で存在を確認する
        # 第 2 引数の N'U' は「ユーザーテーブル」を意味する
        execute_sql("""
            IF OBJECT_ID(N'dbo.todos', N'U') IS NULL
            CREATE TABLE dbo.todos (
                id         INT IDENTITY(1,1) PRIMARY KEY,
                title      NVARCHAR(255) NOT NULL,
                completed  BIT NOT NULL DEFAULT 0,
                -- SYSUTCDATETIME() は UTC を返す。表示するときに JST へ変換する
                created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()
            )
        """)
    except DBAPIError as e:
        # 存在確認と CREATE TABLE は原子的ではない
        # 複数の VM やワーカーが同時に起動すると、両方が「ない」と判断して作成へ進む
        # 後になった側は 2714 を受け取るが、テーブルはできているため成功として扱う
        if not is_table_already_exists_error(e):
            raise
    # 既にテーブルがある場合もここを通る。目的は「どのデータベースに対して確認したか」を残すこと
    # DB_NAME を取り違えても、そちらにテーブルが作られて画面は正常に見える
    # 画面にも DB 名を出すが（F-7）、ログは接続先を変えた前後が時系列で残る点が違う
    app.logger.info("テーブル dbo.todos を確認しました（データベース: %s）", os.environ["DB_NAME"])
    _table_created = True


def fetch_todos() -> list:
    """Todo を作成日時の降順で取得する"""
    # created_at は秒単位のため同時刻になり得る。id を第 2 キーにして順序を一定にする
    return execute_sql(
        "SELECT id, title, completed, created_at FROM dbo.todos ORDER BY created_at DESC, id DESC",
        fetch=True,
    )


def add_todo(title: str) -> None:
    """Todo を追加する"""
    execute_sql("INSERT INTO dbo.todos (title) VALUES (:title)", {"title": title})


def set_completed(todo_id: int, completed: bool) -> None:
    """完了状態を指定した値に変更する"""
    execute_sql(
        "UPDATE dbo.todos SET completed = :completed WHERE id = :id",
        {"completed": completed, "id": todo_id},
    )


def delete_todo(todo_id: int) -> None:
    """Todo を削除する"""
    execute_sql("DELETE FROM dbo.todos WHERE id = :id", {"id": todo_id})


def to_jst(dt: datetime) -> datetime:
    """UTC で保存された日時を JST に変換する"""
    # DATETIME2 はタイムゾーンを持たないため、UTC と解釈してから変換する
    return dt.replace(tzinfo=UTC).astimezone(JST)


def to_display_todos(rows: list) -> list[dict]:
    """取得した行を、テンプレートへ渡す形に整える"""
    # JST への変換はここで済ませる
    # Jinja2 は辞書のキーも todo.created_at_jst の記法で解決するため、移植元のテンプレートをそのまま使える
    return [
        {
            "id": row.id,
            "title": row.title,
            "completed": row.completed,
            "created_at_jst": to_jst(row.created_at),
        }
        for row in rows
    ]


def get_hostname() -> str:
    """この VM 自身のホスト名を取得する"""
    # context processor はエラー画面の描画でも走る
    # ここで例外が出ると、案内を出すはずの 503 が汎用の 500 になる
    try:
        return socket.gethostname()
    except OSError:
        return "-"


def get_private_ip() -> str:
    """この VM 自身のプライベート IP を取得する"""
    # socket.gethostbyname(socket.gethostname()) は使えない
    # Ubuntu の /etc/hosts はホスト名へ 127.0.1.1 を割り当てるため、ループバックが返る
    # UDP の connect() はパケットを送らない。経路表を引いて送信元アドレスが決まるだけ
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(PRIVATE_IP_PROBE_ADDRESS)
            return sock.getsockname()[0]
    except OSError:
        # 経路がない環境でも画面は出す。表示できないことより、Todo が見えないことのほうが困る
        return "-"


def build_debug_info() -> dict:
    """画面の下部に出す実行環境の情報を組み立てる"""
    # DB のサーバー名・ユーザー名・パスワードは含めない
    # HTTP 80 はインターネットへ公開しており、画面に出した値は誰でも読める
    # DB 名だけは残す。取り違えても画面は正常に見えるため、ここが気づける手掛かりになる
    return {
        "hostname": get_hostname(),
        "private_ip": get_private_ip(),
        # .env が未記入でもエラー画面は描画するため、値がない場合を "-" で通す
        # get() の既定値では足りない。DB_NAME= の行がある .env を読むと、キーは空文字で存在する
        "db_name": os.environ.get("DB_NAME") or "-",
    }


@app.context_processor
def inject_debug_info() -> dict:
    """すべてのテンプレートへ実行環境の情報を渡す"""
    # 一覧とエラー画面の両方で使う
    # render_template() の引数で渡すと、呼び出しは 5 か所あるため、いずれかへの追加を忘れる
    return {"debug": build_debug_info()}


def render_db_error() -> tuple[str, int]:
    """データベースに接続できないときの画面を返す"""
    # 200 で返すと curl の戻り値や監視から異常を検出できないため 503 にする
    page = render_template("error.html", message=DB_ERROR_MESSAGE, checks=DB_ERROR_CHECKS)
    return page, 503


def render_todo_list(error: str | None = None, status: int = 200) -> tuple[str, int]:
    """Todo の一覧を描画する。入力を拒否したときはメッセージと HTTP 400 を渡す"""
    try:
        create_table_if_missing()
        todos = to_display_todos(fetch_todos())
    except Exception:
        # 例外の詳細はサーバーログにだけ記録する
        # ODBC のエラーメッセージにはサーバー名やユーザー名が含まれるため
        app.logger.exception("データベースへの接続に失敗しました")
        return render_db_error()
    return render_template("index.html", todos=todos, error=error), status


@app.get("/")
def index() -> tuple[str, int]:
    """Todo の一覧を表示する"""
    return render_todo_list()


@app.post("/add")
def add() -> Response | tuple[str, int]:
    """Todo を追加する。入力を拒否したときは一覧を HTTP 400 で再描画する"""
    # テンプレートの required と maxlength はブラウザの支援でしかないため、curl や開発者ツールから回避できる
    # サーバー側でも検証する
    title = request.form.get("title", "").strip()
    if not title:
        return render_todo_list(error="タスク名を入力してください。", status=400)
    # 黙って切り詰めると、保存された内容が入力と違うことに利用者が気づけない
    # NVARCHAR(255) が数えるのは UTF-16 の単位
    # 絵文字のような BMP 外の文字は 1 文字で 2 単位を使うため、len() では列長を超える入力を通してしまう
    if len(title.encode("utf-16-le")) // 2 > TITLE_MAX_LENGTH:
        return render_todo_list(
            error=f"タスク名は {TITLE_MAX_LENGTH} 文字以内で入力してください。", status=400
        )
    try:
        add_todo(title)
    except Exception:
        app.logger.exception("タスクの追加に失敗しました")
        return render_db_error()
    # 結果を直接描画すると、ブラウザの再読み込みで同じ追加が再送される
    return redirect(url_for("index"))


@app.post("/complete/<int:todo_id>")
def complete(todo_id: int) -> Response | tuple[str, int]:
    """完了状態を変更し、一覧へリダイレクトする"""
    # 反転ではなくフォームから受けた値にする
    # 反転は現在値に依存するため、二重クリックやリロードで意図せず再反転する
    completed = request.form.get("completed") == "1"
    try:
        set_completed(todo_id, completed)
    except Exception:
        app.logger.exception("完了状態の変更に失敗しました")
        return render_db_error()
    return redirect(url_for("index"))


@app.post("/delete/<int:todo_id>")
def delete(todo_id: int) -> Response | tuple[str, int]:
    """Todo を削除し、一覧へリダイレクトする"""
    try:
        delete_todo(todo_id)
    except Exception:
        app.logger.exception("削除に失敗しました")
        return render_db_error()
    return redirect(url_for("index"))


@app.get("/health")
def health() -> Response:
    """死活確認に応答し、画面下部と同じ実行環境の情報を返す"""
    # DB に触らない。deploy/setup.sh は .env の記入前に起動を確認するため
    # 画面と同じ情報を JSON でも返す。負荷分散の確認では、HTML を読むより curl 1 回のほうが速い
    return jsonify(build_debug_info())


if __name__ == "__main__":
    # デバッグモードは使わない。Werkzeug のデバッガは画面から任意のコードを実行できる
    # macOS で Address already in use になる場合は、AirPlay レシーバーが 5000 番を使っている
    # システム設定の「一般 > AirDrop と Handoff」でオフにする
    app.run(host="127.0.0.1", port=5000)
