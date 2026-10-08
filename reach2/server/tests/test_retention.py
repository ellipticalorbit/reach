from datetime import timedelta

from sqlalchemy import select, text, update

from conftest import make_chunk, new_guid, ogg_bytes, push, sha, upload, upsert
from reach_server.models import Blob, Project, Track, TrackRevision, now
_store_root = [None]


@__import__('pytest').fixture(autouse=True)
def _root(settings):
    _store_root[0] = settings.blob_dir


from reach_server.retention import RetentionPolicy, policy_for, purge


def age_everything(sm, hours):
    import os, time
    from pathlib import Path
    for f in Path(_store_root[0]).rglob("*.ogg"):
        os.utime(f, (time.time() - hours * 3600,) * 2)
    with sm() as db:
        db.execute(update(TrackRevision).values(created_at=now() - timedelta(hours=hours)))
        db.execute(update(Blob).values(created_at=now() - timedelta(hours=hours)))
        db.commit()


def setup_deleted_track(alice, pid, with_media=True):
    g = new_guid()
    h = upload(alice, pid, ogg_bytes()) if with_media else None
    push(alice, pid, upsert(g, make_chunk(g, "Gone", media=[h] if h else [])))
    push(alice, pid, {"guid": g, "op": "delete", "base_rev": 1})
    return g, h


def test_default_policy_keeps_everything(alice, joined, sm, app):
    pid = joined["id"]
    g, h = setup_deleted_track(alice, pid)
    age_everything(sm, 24 * 365 * 5)
    r = purge(sm, app.state.store, app.state.settings, dry_run=False)
    assert (r.tracks_deleted, r.revisions_deleted, r.blob_rows_deleted, r.files_deleted) == (0, 0, 0, 0)
    assert alice.post(f"/projects/{pid}/tracks/{g}/restore", json={}).json()["status"] == "accepted"
    assert app.state.store.exists(h)


def test_deleted_track_retention_dry_run_then_apply(alice, joined, sm, app):
    pid = joined["id"]
    app.state.settings.retention_deleted_track_days = 30
    g, h = setup_deleted_track(alice, pid)
    live = new_guid()
    push(alice, pid, upsert(live, make_chunk(live, "Keep")))
    age_everything(sm, 24 * 31)
    with sm() as db:
        before = db.get(Project, joined["id"] and __import__("uuid").UUID(pid)).storage_bytes

    r = purge(sm, app.state.store, app.state.settings, dry_run=True)
    assert r.tracks_deleted == 1 and r.blob_rows_deleted == 1 and r.dry_run
    assert alice.get(f"/projects/{pid}/tracks", params={"state": "deleted"}).json() != []  # untouched
    assert app.state.store.exists(h)

    r = purge(sm, app.state.store, app.state.settings, dry_run=False)
    assert r.tracks_deleted == 1 and r.revisions_deleted == 2 and r.files_deleted == 1
    assert alice.get(f"/projects/{pid}/tracks", params={"state": "deleted"}).json() == []
    assert [t["name"] for t in alice.get(f"/projects/{pid}/tracks").json()] == ["Keep"]
    assert not app.state.store.exists(h)
    with sm() as db:
        assert db.get(Project, __import__("uuid").UUID(pid)).storage_bytes < before


def test_recently_deleted_not_purged(alice, joined, sm, app):
    app.state.settings.retention_deleted_track_days = 30
    setup_deleted_track(alice, joined["id"])
    r = purge(sm, app.state.store, app.state.settings, dry_run=False)
    assert r.tracks_deleted == 0 and r.blob_rows_deleted == 0


def test_max_revisions_keeps_head_and_referenced_blobs(alice, joined, sm, app):
    pid, g = joined["id"], new_guid()
    h1, h2 = upload(alice, pid, ogg_bytes()), upload(alice, pid, ogg_bytes())
    push(alice, pid, upsert(g, make_chunk(g, "v1", media=[h1])))
    for i in range(2, 6):
        push(alice, pid, upsert(g, make_chunk(g, f"v{i}", media=[h2]), base_rev=i - 1))
    app.state.settings.retention_max_revisions_per_track = 2
    age_everything(sm, 48)
    r = purge(sm, app.state.store, app.state.settings, dry_run=False)
    assert r.revisions_deleted == 3 and r.blob_rows_deleted == 1  # h1 only referenced by purged v1
    revs = alice.get(f"/projects/{pid}/tracks/{g}/revisions").json()
    assert [x["rev"] for x in revs] == [4, 5]
    assert not app.state.store.exists(h1) and app.state.store.exists(h2)


def test_fresh_unreferenced_blob_survives_grace(alice, joined, sm, app):
    pid = joined["id"]
    h = upload(alice, pid, ogg_bytes())  # uploaded, push not yet sent
    app.state.settings.retention_deleted_track_days = 1  # any policy so GC logic is exercised
    assert purge(sm, app.state.store, app.state.settings, dry_run=False).blob_rows_deleted == 0
    assert app.state.store.exists(h)
    age_everything(sm, 48)
    assert purge(sm, app.state.store, app.state.settings, dry_run=False).blob_rows_deleted == 1


def test_project_override(alice, joined, sm, app):
    app.state.settings.retention_deleted_track_days = 30
    with sm() as db:
        p = db.scalar(select(Project))
        assert policy_for(p, app.state.settings) == RetentionPolicy(30, None)
        p.retention = {"deleted_track_days": None, "max_revisions_per_track": 10}
        assert policy_for(p, app.state.settings) == RetentionPolicy(None, 10)
