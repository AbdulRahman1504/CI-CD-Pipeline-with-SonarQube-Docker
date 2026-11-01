from app import add, app


def test_add():
    assert add(2, 3) == 5
    assert add(-1, 1) == 0


def test_index():
    resp = app.test_client().get("/")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_health():
    resp = app.test_client().get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "healthy"


def test_add_route():
    resp = app.test_client().get("/add/4/6")
    assert resp.get_json()["result"] == 10
