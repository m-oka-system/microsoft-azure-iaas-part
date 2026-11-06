"""ルーティング・入力検証・表示の検証"""

import socket

import pytest

import app as todo_app

# U+1F600 は BMP の外にあるため、UTF-16 ではサロゲートペア（2 単位）で表される
# len() では 1 文字と数えるので、コードポイント数で検証すると列長を超えて保存に失敗する
EMOJI = "😀"


def test_一覧は200を返しタスク名を含む(client, db):
    response = client.get("/")
    assert response.status_code == 200
    assert "牛乳を買う" in response.get_data(as_text=True)


def test_完了済みは取り消し線と未完了に戻す値で描画される(client, db):
    body = client.get("/").get_data(as_text=True)
    assert "line-through" in body
    assert 'name="completed" value="0"' in body  # 完了済みは 0 を送る
    assert 'name="completed" value="1"' in body  # 未完了は 1 を送る


def test_作成日時はJSTで表示される(client, db):
    body = client.get("/").get_data(as_text=True)
    # UTC の 2026-07-26 15:30 は JST では翌日の 00:30
    assert "2026/07/27 00:30" in body
    assert "2026/07/26 15:30" not in body


def test_タスク名のHTMLはエスケープされる(client, db):
    body = client.get("/").get_data(as_text=True)
    assert "<script>alert(1)</script>" not in body
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in body


@pytest.mark.parametrize(
    ("sent", "stored"),
    [("牛乳を買う", "牛乳を買う"), ("  牛乳を買う  ", "牛乳を買う"), ("あ" * 255, "あ" * 255)],
)
def test_追加は入力値でadd_todoを呼びトップへリダイレクトする(client, db, sent, stored):
    response = client.post("/add", data={"title": sent})
    assert db["added"] == [stored]
    assert response.status_code == 302
    assert response.headers["Location"] == "/"


@pytest.mark.parametrize("data", [{"title": ""}, {"title": "   "}, {}, {"title": "あ" * 256}])
def test_不正な入力は400で拒否しadd_todoを呼ばない(client, db, data):
    response = client.post("/add", data=data)
    assert response.status_code == 400
    assert db["added"] == []
    assert "タスク名" in response.get_data(as_text=True)


@pytest.mark.parametrize(
    ("title", "units", "expected"),
    [
        ("あ" * 255, 255, 302),  # BMP 内は 1 文字 1 単位。上限ちょうどなので通る
        (EMOJI * 127, 254, 302),  # 絵文字は 1 文字 2 単位。上限の 1 単位手前
        (EMOJI * 128, 256, 400),  # len() では 128 文字でも 256 単位で上限を超える
    ],
)
def test_長さの上限はNVARCHARと同じUTF16の単位で判定する(client, db, title, units, expected):
    assert len(title.encode("utf-16-le")) // 2 == units  # 表の単位数が正しいことを示す
    response = client.post("/add", data={"title": title})
    assert response.status_code == expected
    assert db["added"] == ([title] if expected == 302 else [])


@pytest.mark.parametrize(
    ("data", "expected"),
    [({"completed": "1"}, True), ({"completed": "0"}, False), ({}, False)],
)
def test_完了状態は送られた値のまま反映される(client, db, data, expected):
    response = client.post("/complete/7", data=data)
    assert db["completed"] == [(7, expected)]
    assert response.status_code == 302
    assert response.headers["Location"] == "/"


def test_削除は該当IDでdelete_todoを呼ぶ(client, db):
    response = client.post("/delete/3")
    assert db["deleted"] == [3]
    assert response.status_code == 302
    assert response.headers["Location"] == "/"


@pytest.mark.parametrize("path", ["/add", "/complete/1", "/delete/1"])
def test_更新系のGETは405になる(client, path):
    assert client.get(path).status_code == 405


@pytest.mark.parametrize(
    ("headers", "expected"),
    [
        ({"Sec-Fetch-Site": "cross-site"}, 403),
        ({"Sec-Fetch-Site": "same-origin"}, 302),
        ({}, 302),  # ヘッダを送らないクライアント（curl など）は通す
    ],
)
def test_クロスサイトのPOSTだけ403で拒否する(client, db, headers, expected):
    response = client.post("/delete/1", headers=headers)
    assert response.status_code == expected
    assert db["deleted"] == ([] if expected == 403 else [1])


def test_一覧の表示前にテーブルの作成を試みる(client, db, monkeypatch):
    calls = []
    monkeypatch.setattr(todo_app, "create_table_if_missing", lambda: calls.append(1))
    assert client.get("/").status_code == 200
    assert calls == [1]


@pytest.mark.parametrize(
    ("method", "path"),
    [("get", "/"), ("post", "/add"), ("post", "/complete/1"), ("post", "/delete/1")],
)
def test_DB障害は503を返し例外の詳細を画面に出さない(client, db_down, method, path):
    response = getattr(client, method)(path, data={"title": "牛乳を買う"})
    assert response.status_code == 503
    body = response.get_data(as_text=True)
    for detail in ("todoadmin", "database.windows.net", "08001", "Traceback"):
        assert detail not in body
    assert "ファイアウォール規則" in body


def test_エラー画面に実際に読み込む_env_のパスを表示する(client, db_down):
    # VM では /opt/todo/src/.env、手元ではリポジトリの src/.env になる
    # 固定の文字列を書くと、配置先を変えたときに画面の案内だけが実態とずれる
    response = client.get("/")
    assert response.status_code == 503
    assert str(todo_app.ENV_PATH) in response.get_data(as_text=True)


def test_一覧に実行環境の情報を表示する(client, db, monkeypatch):
    # 実際の IP は環境によって変わるため、既知の値へ差し替えて検証する
    monkeypatch.setattr(todo_app, "get_private_ip", lambda: "10.0.0.4")
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_data(as_text=True)
    assert socket.gethostname() in body
    assert "10.0.0.4" in body
    assert "tododb" in body  # conftest が与える DB_NAME


def test_エラー画面にも実行環境の情報を表示する(client, db_down, monkeypatch):
    # 接続できないときこそ、どのホストがどの DB を見に行ったかが要る
    monkeypatch.setattr(todo_app, "get_private_ip", lambda: "10.0.0.4")
    response = client.get("/")
    # 状態コードを確かめないと、一覧が描画された場合も通ってしまう
    # ホスト名も DB 名も両方の画面に出るため、値の検証だけでは区別できない
    assert response.status_code == 503
    body = response.get_data(as_text=True)
    assert socket.gethostname() in body
    assert "10.0.0.4" in body
    assert "tododb" in body


def test_画面にHTMLコメントを出さない(client, db):
    # 受講者は curl やブラウザのソース表示で本文を読む
    # 設計の理由は Jinja のコメント（{# #}）で書く。HTML のコメントは配信される
    assert "<!--" not in client.get("/").get_data(as_text=True)


def test_エラー画面にHTMLコメントを出さない(client, db_down):
    assert "<!--" not in client.get("/").get_data(as_text=True)


def test_ホスト名を取得できないときも一覧は表示される(client, db, monkeypatch):
    # 診断のための表示が本体を壊さないことを固定する
    # context processor はエラー画面の描画でも走るため、ここで例外が出ると 503 が 500 になる
    def raise_os_error():
        raise OSError

    monkeypatch.setattr(todo_app.socket, "gethostname", raise_os_error)
    response = client.get("/")
    assert response.status_code == 200
    body = response.get_data(as_text=True)
    # ハイフン 1 文字では検証にならない。class 名や meta タグに無数に現れる
    assert "<dd>-</dd>" in body


def test_DBのサーバー名とユーザー名とパスワードは画面に出さない(client, db, monkeypatch):
    # HTTP 80 はインターネットへ公開しており、画面に出した値は誰でも読める
    monkeypatch.setenv("DB_HOST", "todo-sql-example.database.windows.net")
    monkeypatch.setenv("DB_USER", "todoadmin")
    monkeypatch.setenv("DB_PASSWORD", "P@ssw0rd-example")
    body = client.get("/").get_data(as_text=True)
    for secret in ("todo-sql-example", "database.windows.net", "todoadmin", "P@ssw0rd-example"):
        assert secret not in body


def test_healthはDBに触らず実行環境の情報を返す(client, monkeypatch):
    def fail_if_called():
        pytest.fail("health は DB に触ってはいけません")

    monkeypatch.setattr(todo_app, "create_table_if_missing", fail_if_called)
    monkeypatch.setattr(todo_app, "fetch_todos", fail_if_called)
    monkeypatch.setenv("DB_NAME", "tododb")
    response = client.get("/health")
    assert response.status_code == 200
    # 画面と同じ情報を返す。負荷分散の確認では curl だけでホスト名を読めるほうが速い
    payload = response.get_json()
    assert payload["hostname"] == socket.gethostname()
    assert payload["db_name"] == "tododb"
    # プライベート IP は実行環境ごとに変わるため、キーがあることだけを固定する
    assert "private_ip" in payload


def test_healthの応答はホスト名から始まる(client):
    # app.json.sort_keys = False を消すと、既定のアルファベット順に戻って db_name が先頭になる
    # どの VM が応答したかを最初に読めるようにするための設定なので、順序で固定する
    assert list(client.get("/health").get_json()) == ["hostname", "private_ip", "db_name"]


def test_DB名が空欄でも未設定でもハイフンで表示する(client, monkeypatch):
    # DB_NAME= の行がある .env を load_dotenv が読むと、キーは空文字で存在する
    # 接続情報を空欄で配置するラボ（labs/sections/section08）がこの経路を通る
    monkeypatch.setenv("DB_NAME", "")
    assert client.get("/health").get_json()["db_name"] == "-"
    assert "<dd>-</dd>" in client.get("/").get_data(as_text=True)
    # .env に行そのものがない場合も同じ表示にする
    monkeypatch.delenv("DB_NAME")
    assert client.get("/health").get_json()["db_name"] == "-"


def test_healthはDBのサーバー名とユーザー名とパスワードを出さない(client, monkeypatch):
    # 死活確認の URL は認証なしで公開されており、画面と同じ制約がかかる
    monkeypatch.setenv("DB_HOST", "todo-sql-example.database.windows.net")
    monkeypatch.setenv("DB_USER", "todoadmin")
    monkeypatch.setenv("DB_PASSWORD", "P@ssw0rd-example")
    body = client.get("/health").get_data(as_text=True)
    for secret in ("todo-sql-example", "database.windows.net", "todoadmin", "P@ssw0rd-example"):
        assert secret not in body
