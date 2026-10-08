import hashlib
import os
import re
import secrets
import uuid
from urllib.parse import urlencode

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text

from reach_server.config import Settings
from reach_server.main import create_app
from reach_server.models import Base

DB_URL = os.environ.get("TEST_DATABASE_URL", "postgresql+psycopg://reach:reach@localhost:55432/reach_test")


class FakeGoogle:
    """The 'authorization url' bounces straight back to our callback; code == 'sub|email|name'."""
    def __init__(self):
        self.pending = "sub-default|default@example.com|Default"

    def authorization_url(self, state):
        return "http://testserver/auth/google/callback?" + urlencode({"code": self.pending, "state": state})

    def exchange(self, code):
        sub, email, name = code.split("|")
        return {"sub": sub, "email": email, "name": name}


@pytest.fixture(scope="session")
def engine():
    e = create_engine(DB_URL)
    Base.metadata.drop_all(e)
    Base.metadata.create_all(e)
    yield e
    e.dispose()


@pytest.fixture
def settings(tmp_path):
    return Settings(database_url=DB_URL, blob_dir=str(tmp_path / "blobs"), session_secret="test-secret",
                    public_url="http://testserver", rate_limit_enabled=False, auto_create_tables=False)


@pytest.fixture
def google():
    return FakeGoogle()


@pytest.fixture
def app(engine, settings, google):
    with engine.begin() as c:
        c.execute(text("TRUNCATE users, api_tokens, device_auths, projects, members, tracks, "
                       "track_revisions, blobs CASCADE"))
    return create_app(settings, google=google)


@pytest.fixture
def client(app):
    return TestClient(app)


@pytest.fixture
def sm(app):
    return app.state.sessionmaker


class Person:
    def __init__(self, client, token, email):
        self.client, self.token, self.email = client, token, email
        self.h = {"Authorization": f"Bearer {token}"}

    def get(self, url, **kw): return self.client.get(url, headers=self.h, **kw)
    def post(self, url, **kw): return self.client.post(url, headers=self.h, **kw)
    def put(self, url, **kw): return self.client.put(url, headers=self.h, **kw)
    def patch(self, url, **kw): return self.client.patch(url, headers=self.h, **kw)
    def delete(self, url, **kw): return self.client.delete(url, headers=self.h, **kw)


@pytest.fixture
def make_person(app, client, google):
    """Full device flow: plugin starts it, 'browser' signs in via Google and approves, plugin polls."""
    def make(email="alice@example.com", name="Alice", label="test"):
        browser = TestClient(app)
        d = client.post("/auth/device", json={"label": label}).json()
        r = browser.get("/device", params={"user_code": d["user_code"]})
        assert "Sign in with Google" in r.text
        google.pending = f"sub-{email}|{email}|{name}"
        r = browser.get("/auth/google/login", params={"next": f"/device?user_code={d['user_code']}"},
                        follow_redirects=True)
        csrf = re.search(r'name=csrf value="([^"]+)"', r.text).group(1)
        r = browser.post("/device/approve", data={"user_code": d["user_code"], "action": "approve", "csrf": csrf})
        assert "Approved" in r.text
        tok = client.post("/auth/device/token", json={"device_code": d["device_code"]}).json()["access_token"]
        return Person(client, tok, email)
    return make


@pytest.fixture
def alice(make_person): return make_person("alice@example.com", "Alice")


@pytest.fixture
def bob(make_person): return make_person("bob@example.com", "Bob")


@pytest.fixture
def project(alice):
    r = alice.post("/projects", json={"name": "Song"})
    assert r.status_code == 201
    return r.json()


@pytest.fixture
def joined(project, bob):
    r = bob.post("/join", json={"code": project["join_code"]})
    assert r.status_code == 200
    return project


# ---- helpers ----

def new_guid() -> str:
    return "{" + str(uuid.uuid4()).upper() + "}"


def ogg_bytes(extra: bytes = b"") -> bytes:
    return b"OggS" + b"\x00" * 22 + b"\x01\x1e\x01vorbis" + secrets.token_bytes(64) + extra


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def make_chunk(guid: str, name: str = "Track", media: list[str] = (), volume: float = 1.0) -> str:
    """Shaped like REAPER's GetTrackStateChunk: bare <TRACK header, guid on a TRACKID line."""
    items = "".join(f'<ITEM\nPOSITION 0\n<SOURCE VORBIS\nFILE "reach-media://{h}.ogg"\n>\n>\n' for h in media)
    return f'<TRACK\nNAME "{name}"\nVOLPAN {volume} 0 -1 -1 1\nTRACKID {guid}\n{items}>'


def upload(person, project_id, data: bytes):
    r = person.put(f"/projects/{project_id}/blobs/{sha(data)}", content=data)
    assert r.status_code == 200, r.text
    return sha(data)


def push(person, project_id, *tracks):
    return person.post(f"/projects/{project_id}/push", json={"tracks": list(tracks)})


def upsert(guid, chunk, base_rev=0, parent=None, position=0):
    return {"guid": guid, "op": "upsert", "chunk": chunk, "base_rev": base_rev,
            "parent_guid": parent, "position": position}
