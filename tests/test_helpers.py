"""日時変換・接続の再試行・接続 URL の検証"""

import logging
from datetime import datetime
from types import SimpleNamespace

import pytest
from sqlalchemy import make_url, text
from sqlalchemy.exc import DBAPIError

import app as todo_app

# pyodbc の例外は args が 2 要素で、(SQLSTATE, メッセージ本文)
# ネイティブのエラー番号は本文の末尾へ括弧付きで付く。以下は開発機から Azure SQL に対して実測した構造
# 1 引数にすると args[0] が本文になり、SQLSTATE で判定する実装を検証できない
#
# 停止した Azure SQL は 40613 を返す前に、ODBC のログインタイムアウトが先に切れる
LOGIN_TIMEOUT_ERROR = (
    "HYT00",
    "[HYT00] [Microsoft][ODBC Driver 18 for SQL Server]Login timeout expired (0) (SQLDriverConnect)",
)
# 40613 の SQLSTATE は HY000
# 停止中のデータベースに対し、接続タイムアウトを 60 秒まで延ばして実測した（10 秒では HYT00 が先に切れて捕まえられない）
# HY000 は「一般的なエラー」で 40613 以外にも使われるため、SQLSTATE では判定できない
# 本文の末尾に付く (40613) で判定していることを、この値で確かめる
DATABASE_UNAVAILABLE_ERROR = (
    "HY000",
    (
        "[HY000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Database 'tododb' on "
        "server 'todo-sql' is not currently available. (40613) (SQLDriverConnect)"
    ),
)
RESUMING_ERRORS = [LOGIN_TIMEOUT_ERROR, DATABASE_UNAVAILABLE_ERROR]
# 待っても解決しない誤り。資格情報の誤りは 18456、規則の不足は 40615 で即座に返る
LOGIN_FAILED_ERROR = (
    "28000",
    (
        "[28000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Login failed for user "
        "'todoadmin'. (18456) (SQLDriverConnect)"
    ),
)
FIREWALL_BLOCKED_ERROR = (
    "42000",
    (
        "[42000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Cannot open server "
        "'todo-sql' requested by the login. Client with IP address '203.0.113.10' is not "
        "allowed to access the server. (40615) (SQLDriverConnect)"
    ),
)
FATAL_ERRORS = [LOGIN_FAILED_ERROR, FIREWALL_BLOCKED_ERROR]
# ユーザー名に 40613 を含む受講者が、パスワードを間違えたときの認証失敗
LOGIN_FAILED_ERROR_WITH_40613_IN_USERNAME = (
    "28000",
    (
        "[28000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Login failed for user "
        "'student40613'. (18456) (SQLDriverConnect)"
    ),
)
# 存在確認と CREATE TABLE の間に、別のワーカーがテーブルを作成したときのエラー
# ネイティブの番号 2714 は、40613 と同じく本文の末尾へ括弧付きで付く
TABLE_ALREADY_EXISTS_ERROR = (
    "42S01",
    (
        "[42S01] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]There is already an "
        "object named 'todos' in the database. (2714) (SQLExecDirectW)"
    ),
)
# CREATE TABLE の権限を持たないユーザーで接続したときのエラー。待っても解決しない
CREATE_TABLE_DENIED_ERROR = (
    "42000",
    (
        "[42000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]CREATE TABLE permission "
        "denied in database 'tododb'. (262) (SQLExecDirectW)"
    ),
)
# 本文に (2714) を含むが、別のエラー
# データベース名やユーザー名は利用者が決めるため、本文の部分一致だけで判定すると、これを成功として扱ってしまう
LOGIN_FAILED_ERROR_WITH_2714_IN_USERNAME = (
    "28000",
    (
        "[28000] [Microsoft][ODBC Driver 18 for SQL Server][SQL Server]Login failed for user "
        "'todo(2714)'. (18456) (SQLDriverConnect)"
    ),
)
# conftest.py の db フィクスチャが差し替える前の実体
# 以下のテストは create_table_if_missing() そのものを検証するため、差し替え前の関数を呼ぶ
CREATE_TABLE_IF_MISSING = todo_app.create_table_if_missing


def make_failing_engine(error: tuple[str, str], attempts: list) -> SimpleNamespace:
    """connect() が必ず DBAPIError を投げる Engine を模す"""

    def connect():
        attempts.append(error)
        raise DBAPIError("SELECT 1", None, Exception(*error))

    return SimpleNamespace(connect=connect)


def test_naiveなUTCはJSTへ9時間進めて返る():
    # DATETIME2 は naive な datetime として返るため、意図的に tzinfo を付けない
    jst = todo_app.to_jst(datetime(2026, 7, 26, 15, 30, 0))
    assert jst.strftime("%Y/%m/%d %H:%M") == "2026/07/27 00:30"
    assert jst.utcoffset() == todo_app.JST.utcoffset(None)


@pytest.mark.parametrize("error", RESUMING_ERRORS, ids=["HYT00", "40613"])
def test_再開待ちのエラーは規定回数まで再接続を試みる(error, monkeypatch):
    attempts = []
    waits = []
    # 実時間を待たないよう sleep を差し替える
    monkeypatch.setattr(todo_app.time, "sleep", lambda seconds: waits.append(seconds))
    engine = make_failing_engine(error, attempts)
    with pytest.raises(DBAPIError):
        todo_app.connect_with_retry(engine)
    assert len(attempts) == todo_app.RETRY_ATTEMPTS
    assert waits == [todo_app.RETRY_WAIT_SECONDS] * (todo_app.RETRY_ATTEMPTS - 1)


@pytest.mark.parametrize("error", FATAL_ERRORS, ids=["18456", "40615"])
def test_再開待ち以外のエラーは再試行せず1回で送出する(error, monkeypatch):
    attempts = []
    monkeypatch.setattr(todo_app.time, "sleep", lambda seconds: pytest.fail("待機してはいけません"))
    engine = make_failing_engine(error, attempts)
    with pytest.raises(DBAPIError):
        todo_app.connect_with_retry(engine)
    assert len(attempts) == 1


def test_ユーザー名に40613を含む認証失敗は再試行しない(monkeypatch):
    # 認証失敗の SQLSTATE は 28000 で、40613 は本文のユーザー名の一部として現れる
    # メッセージ全体を部分一致で調べる実装では再開待ちと誤判定し、student40613 という名前の受講者がパスワードを間違えただけで 5 回 × 5 秒待たされる
    attempts = []
    monkeypatch.setattr(todo_app.time, "sleep", lambda seconds: pytest.fail("待機してはいけません"))
    engine = make_failing_engine(LOGIN_FAILED_ERROR_WITH_40613_IN_USERNAME, attempts)
    with pytest.raises(DBAPIError):
        todo_app.connect_with_retry(engine)
    assert len(attempts) == 1


def test_接続できた場合はその接続を返す():
    connection = object()
    engine = SimpleNamespace(connect=lambda: connection)
    assert todo_app.connect_with_retry(engine) is connection


def test_再開が完了した時点で接続でき残りの試行はしない(monkeypatch):
    connection = object()
    attempts = []
    waits = []
    monkeypatch.setattr(todo_app.time, "sleep", lambda seconds: waits.append(seconds))

    def connect():
        attempts.append(1)
        if len(attempts) == 1:  # 1 回目は再開待ち、2 回目で接続できる
            raise DBAPIError("SELECT 1", None, Exception(*LOGIN_TIMEOUT_ERROR))
        return connection

    assert todo_app.connect_with_retry(SimpleNamespace(connect=connect)) is connection
    assert len(attempts) == 2
    assert waits == [todo_app.RETRY_WAIT_SECONDS]


def make_failing_execute_sql(error: tuple[str, str]):
    """execute_sql() が必ず DBAPIError を投げる差し替えを作る"""

    def execute_sql(sql, params=None, *, fetch=False):
        raise DBAPIError(sql, None, Exception(*error))

    return execute_sql


def test_別のワーカーが先に作成した場合は成功として扱う(monkeypatch):
    # 存在確認と CREATE TABLE は原子的ではないため、複数の VM やワーカーが同時に起動すると後になった側が 2714 を受け取る
    # テーブルはできているため、ここで例外を投げると起動しただけで画面がエラーになる
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(
        todo_app, "execute_sql", make_failing_execute_sql(TABLE_ALREADY_EXISTS_ERROR)
    )
    CREATE_TABLE_IF_MISSING()
    assert todo_app._table_created is True


def test_作成に失敗した場合は送出し次の要求で作成し直す(monkeypatch):
    # 2714 以外は握りつぶさない
    # 権限不足を成功として覚えると、以降の要求がすべて「テーブルはある」前提で進み、原因の分からない失敗が続く
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(
        todo_app, "execute_sql", make_failing_execute_sql(CREATE_TABLE_DENIED_ERROR)
    )
    with pytest.raises(DBAPIError):
        CREATE_TABLE_IF_MISSING()
    assert todo_app._table_created is False


def test_SQLSTATEが違えば本文に2714を含んでも送出する(monkeypatch):
    # 判定を本文の部分一致だけで書くと、todo(2714) という名前の利用者がパスワードを間違えただけで「テーブルはある」と覚えてしまう
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(
        todo_app,
        "execute_sql",
        make_failing_execute_sql(LOGIN_FAILED_ERROR_WITH_2714_IN_USERNAME),
    )
    with pytest.raises(DBAPIError):
        CREATE_TABLE_IF_MISSING()
    assert todo_app._table_created is False


def test_発行するDDLはテーブル名を含み束縛変数を持たない(monkeypatch):
    # execute_sql() を差し替えるテストばかりだと、DDL の中身が一度も検証されない
    # text() は :name の形を束縛変数として拾う（コロンの前が空白などの区切りで、後ろが ASCII の英数字のとき）
    # DDL やそのコメントにこの形を書き足すと、初回アクセスだけが束縛変数エラーで 503 になる。ruff では検出できない
    captured = []
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(todo_app, "execute_sql", lambda sql, *args, **kwargs: captured.append(sql))
    CREATE_TABLE_IF_MISSING()
    sql = captured[0]
    assert "IF OBJECT_ID(N'dbo.todos', N'U') IS NULL" in sql
    # 末尾の括弧まで含める。前方一致だけだと dbo.todoss のような綴り誤りを通す
    assert "CREATE TABLE dbo.todos (" in sql
    assert text(sql).compile().params == {}


def test_発行するDDLは列の定義を固定する(monkeypatch):
    # 列の型や既定値が変わると、静かに壊れる
    # とくに created_at を GETDATE() にすると、to_jst() が UTC 前提で 9 時間足すため表示が二重にずれる
    # NVARCHAR の長さは TITLE_MAX_LENGTH と一致していなければならない
    captured = []
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(todo_app, "execute_sql", lambda sql, *args, **kwargs: captured.append(sql))
    CREATE_TABLE_IF_MISSING()
    # 桁揃えの空白に依存しないよう、連続する空白を 1 つに畳んでから調べる
    normalized = " ".join(captured[0].split())
    assert "id INT IDENTITY(1,1) PRIMARY KEY" in normalized
    assert f"title NVARCHAR({todo_app.TITLE_MAX_LENGTH}) NOT NULL" in normalized
    assert "completed BIT NOT NULL DEFAULT 0" in normalized
    assert "created_at DATETIME2(0) NOT NULL DEFAULT SYSUTCDATETIME()" in normalized


def test_INFOのログが有効になっている():
    # Flask は debug が無効のとき app.logger にレベルを設定せず、実効レベルは root の既定（WARNING）になる
    # gunicorn も --log-config を渡さない限り root を変えないため、setLevel を消すと journal から記録が消える
    # caplog は at_level でレベルを変えてしまうので、ここでは使わない
    # isEnabledFor だけだと、pytest の log_level 設定で root が INFO へ上がったときに素通りする
    # app.logger 自身のレベルも直接確かめる
    assert todo_app.app.logger.level == logging.INFO
    assert todo_app.app.logger.isEnabledFor(logging.INFO)


def test_確認したデータベース名をログに残す(monkeypatch, caplog):
    # DB_NAME を取り違えても、そちらにテーブルが作られて画面は正常に見える
    # 取り違えに気づける手掛かりはこのログだけ
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(todo_app, "execute_sql", lambda *args, **kwargs: None)
    with caplog.at_level(logging.INFO, logger=todo_app.app.logger.name):
        CREATE_TABLE_IF_MISSING()
    assert "tododb" in caplog.text


def test_一度作成できたら問い合わせない(monkeypatch):
    monkeypatch.setattr(todo_app, "_table_created", True)
    monkeypatch.setattr(
        todo_app, "execute_sql", lambda *args, **kwargs: pytest.fail("問い合わせてはいけません")
    )
    CREATE_TABLE_IF_MISSING()


def test_特殊文字を含むパスワードでも接続情報が復元できる(monkeypatch):
    password = "P@ss:w0rd/#?"
    monkeypatch.setenv("DB_USER", "todoadmin")
    monkeypatch.setenv("DB_PASSWORD", password)
    monkeypatch.setenv("DB_HOST", "todo-sql-example.database.windows.net")
    monkeypatch.setenv("DB_NAME", "tododb")
    url = todo_app.build_conn_url()
    # 文字列へ書き出して読み直しても、各要素が元の値に戻る
    restored = make_url(url.render_as_string(hide_password=False))
    assert restored.password == password
    assert restored.username == "todoadmin"
    assert restored.host == "todo-sql-example.database.windows.net"
    assert restored.port == 1433
    assert restored.database == "tododb"


def test_接続URLのクエリは暗号化を明示しODBC外のキーワードを含まない(monkeypatch):
    for name, value in [
        ("DB_USER", "todoadmin"),
        ("DB_PASSWORD", "P@ssW@rd"),
        ("DB_HOST", "todo-sql-example.database.windows.net"),
        ("DB_NAME", "tododb"),
    ]:
        monkeypatch.setenv(name, value)
    assert todo_app.build_conn_url().query == {
        "driver": "ODBC Driver 18 for SQL Server",
        "Authentication": "SqlPassword",
        "Encrypt": "yes",
        "TrustServerCertificate": "no",
    }
