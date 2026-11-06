"""実 DB へ接続せずに Flask アプリを検証するための共通設定"""

from datetime import datetime
from types import SimpleNamespace

import pytest

import app as todo_app

# ODBC のエラーメッセージを模した文字列。画面に出てはいけない語を含める
DB_ERROR_DETAIL = (
    "[08001] Login failed for user 'todoadmin' on server 'todo-sql-example.database.windows.net'"
)
# created_at は DATETIME2 と同じく naive な UTC の datetime
# tzinfo を付けると本番と異なる経路を検証することになるため、意図的に付けない
CREATED_AT_UTC = datetime(2026, 7, 26, 15, 30)
OLDER_AT_UTC = datetime(2026, 7, 25, 1, 0)


def make_row(todo_id: int, title: str, completed: bool, created_at: datetime) -> SimpleNamespace:
    """fetch_todos() が返す 1 行を模す。属性アクセスの形を本物に合わせる"""
    return SimpleNamespace(id=todo_id, title=title, completed=completed, created_at=created_at)


@pytest.fixture(autouse=True)
def db_name_env(monkeypatch):
    """接続情報のうち DB_NAME を全テストへ与える"""
    # create_table_if_missing() は末尾のログで os.environ["DB_NAME"] を読む
    # 本番では build_conn_url() が先に読むため必ず存在するが、execute_sql() を差し替えるテストはそこを通らない
    # src/.env は .gitignore の対象のため、クローン直後の別の PC では存在しない。autouse にして付け忘れを防ぐ
    # 自前で setenv するテストは、この値をそのまま上書きできる
    monkeypatch.setenv("DB_NAME", "tododb")


@pytest.fixture
def client():
    """サーバーを起動せずにリクエストを送るクライアント"""
    todo_app.app.config.update(TESTING=True)
    return todo_app.app.test_client()


@pytest.fixture(autouse=True)
def db(monkeypatch):
    """DB アクセス関数を記録用の偽関数へ差し替える。全テストに自動で適用する"""
    calls = {
        "todos": [
            make_row(1, "牛乳を買う", False, CREATED_AT_UTC),
            make_row(2, "<script>alert(1)</script>", True, OLDER_AT_UTC),
        ],
        "added": [],
        "completed": [],
        "deleted": [],
    }
    # create_table_if_missing() の実行結果はモジュールグローバルに残るため、テストごとに戻す
    monkeypatch.setattr(todo_app, "_table_created", False)
    monkeypatch.setattr(todo_app, "create_table_if_missing", lambda: None)
    monkeypatch.setattr(todo_app, "fetch_todos", lambda: calls["todos"])
    monkeypatch.setattr(todo_app, "add_todo", lambda title: calls["added"].append(title))
    monkeypatch.setattr(
        todo_app,
        "set_completed",
        lambda todo_id, completed: calls["completed"].append((todo_id, completed)),
    )
    monkeypatch.setattr(todo_app, "delete_todo", lambda todo_id: calls["deleted"].append(todo_id))
    return calls


@pytest.fixture
def db_down(monkeypatch):
    """DB アクセスが必ず失敗する状態にする"""

    def raise_db_error(*args, **kwargs):
        raise RuntimeError(DB_ERROR_DETAIL)

    for name in (
        "create_table_if_missing",
        "fetch_todos",
        "add_todo",
        "set_completed",
        "delete_todo",
    ):
        monkeypatch.setattr(todo_app, name, raise_db_error)
