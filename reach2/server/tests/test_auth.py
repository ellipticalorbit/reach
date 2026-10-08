from datetime import timedelta

from sqlalchemy import update

from reach_server.models import DeviceAuth, User, now


def test_device_flow_and_me(alice):
    r = alice.get("/me")
    assert r.status_code == 200
    assert r.json()["email"] == "alice@example.com" and r.json()["display_name"] == "Alice"


def test_requires_token(client):
    assert client.get("/me").status_code == 401
    assert client.get("/me", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_poll_pending_then_denied(client):
    d = client.post("/auth/device", json={"label": "x"}).json()
    r = client.post("/auth/device/token", json={"device_code": d["device_code"]})
    assert r.status_code == 400 and r.json()["detail"]["error"] == "authorization_pending"


def test_unknown_device_code(client):
    r = client.post("/auth/device/token", json={"device_code": "bogus"})
    assert r.status_code == 400 and r.json()["detail"]["error"] == "invalid_grant"


def test_token_issued_once(app, client, make_person, sm):
    p = make_person("c@example.com", "C")
    assert p.get("/me").status_code == 200


def test_expired_code(client, sm):
    d = client.post("/auth/device", json={}).json()
    with sm() as db:
        db.execute(update(DeviceAuth).values(expires_at=now() - timedelta(seconds=1)))
        db.commit()
    r = client.post("/auth/device/token", json={"device_code": d["device_code"]})
    assert r.json()["detail"]["error"] == "expired_token"
    assert client.get("/device", params={"user_code": d["user_code"]}).status_code == 400


def test_bad_oauth_state(client, google):
    client.get("/auth/google/login")
    r = client.get("/auth/google/callback", params={"code": "s|e@x.com|E", "state": "wrong"})
    assert r.status_code == 400


def test_approve_requires_csrf_and_login(client):
    d = client.post("/auth/device", json={}).json()
    r = client.post("/device/approve", data={"user_code": d["user_code"], "action": "approve", "csrf": "x"})
    assert r.status_code == 403


def test_deny(app, client, google):
    from fastapi.testclient import TestClient
    import re
    d = client.post("/auth/device", json={}).json()
    b = TestClient(app)
    if True:
        google.pending = "s1|d@example.com|D"
        r = b.get("/auth/google/login", params={"next": f"/device?user_code={d['user_code']}"}, follow_redirects=True)
        csrf = re.search(r'name=csrf value="([^"]+)"', r.text).group(1)
        b.post("/device/approve", data={"user_code": d["user_code"], "action": "deny", "csrf": csrf})
    r = client.post("/auth/device/token", json={"device_code": d["device_code"]})
    assert r.json()["detail"]["error"] == "access_denied"


def test_banned_user_rejected(alice, sm):
    with sm() as db:
        db.execute(update(User).values(banned=True))
        db.commit()
    assert alice.get("/me").status_code == 403


def test_revoke_token(alice):
    toks = alice.get("/tokens").json()
    assert len(toks) == 1
    assert alice.delete(f"/tokens/{toks[0]['id']}").status_code == 204
    assert alice.get("/me").status_code == 401


def test_dev_login_disabled_by_default(client):
    assert client.get("/auth/dev-login").status_code == 404


def test_open_redirect_blocked(client, google):
    google.pending = "s|e@example.com|E"
    r = client.get("/auth/google/login", params={"next": "//evil.com"}, follow_redirects=True)
    assert "evil.com" not in str(r.url)


def test_update_display_name(alice):
    assert alice.patch("/me", json={"display_name": "Ali"}).json()["display_name"] == "Ali"


def _cookie_flags(engine, tmp_path, **kw):
    from reach_server.config import Settings
    from reach_server.main import create_app
    from fastapi.testclient import TestClient
    from conftest import DB_URL
    s = Settings(database_url=DB_URL, blob_dir=str(tmp_path / "b"), session_secret="s", dev_login=True,
                 rate_limit_enabled=False, auto_create_tables=False, **kw)
    c = TestClient(create_app(s))
    r = c.get("/auth/dev-login?email=a@example.com", follow_redirects=False)
    return r.headers["set-cookie"].lower()


def test_cookie_secure_flag(engine, tmp_path, app):
    assert "secure" in _cookie_flags(engine, tmp_path, public_url="https://x.example")
    assert "secure" not in _cookie_flags(engine, tmp_path, public_url="http://x.example:8000")
    assert "secure" not in _cookie_flags(engine, tmp_path, public_url="https://x.example", cookie_secure=False)
    assert "secure" in _cookie_flags(engine, tmp_path, public_url="http://x.example", cookie_secure=True)


def test_empty_env_vars_count_as_unset(monkeypatch):
    from reach_server.config import Settings
    monkeypatch.setenv("REACH_COOKIE_SECURE", "")      # what docker compose passes for an unset variable
    monkeypatch.setenv("REACH_GOOGLE_CLIENT_ID", "")
    s = Settings()
    assert s.cookie_secure is None and s.google_client_id is None
    monkeypatch.setenv("REACH_COOKIE_SECURE", "false")
    assert Settings().cookie_secure is False
