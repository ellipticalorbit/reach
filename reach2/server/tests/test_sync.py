from conftest import make_chunk, new_guid, ogg_bytes, push, sha, upload, upsert, wav_bytes


def test_push_create_and_pull(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    r = push(alice, pid, upsert(g, make_chunk(g, "Bass")))
    assert r.status_code == 200
    assert r.json()["results"] == [{"guid": g, "status": "accepted", "rev": 1, "seq": 1}]
    ch = bob.get(f"/projects/{pid}/changes", params={"since": 0}).json()
    assert ch["seq"] == 1 and len(ch["tracks"]) == 1
    t = ch["tracks"][0]
    assert (t["guid"], t["name"], t["owner"], t["rev"], t["deleted"]) == (g, "Bass", "Alice", 1, False)
    assert bob.get(f"/projects/{pid}/changes", params={"since": 1}).json()["tracks"] == []


def test_update_with_correct_base_and_hierarchy(alice, joined):
    pid, g, f = joined["id"], new_guid(), new_guid()
    push(alice, pid, upsert(f, make_chunk(f, "Alice folder")), upsert(g, make_chunk(g, "v1"), parent=f, position=1))
    r = push(alice, pid, upsert(g, make_chunk(g, "v2"), base_rev=1, parent=f, position=1)).json()
    assert r["results"][0]["rev"] == 2
    t = {x["guid"]: x for x in alice.get(f"/projects/{pid}/changes").json()["tracks"]}
    assert t[g]["parent_guid"] == f and t[g]["position"] == 1 and t[g]["name"] == "v2"


def test_stale_base_is_conflict_and_other_tracks_still_apply(alice, bob, joined):
    pid, g, h = joined["id"], new_guid(), new_guid()
    push(alice, pid, upsert(g, make_chunk(g, "orig")))
    push(alice, pid, upsert(g, make_chunk(g, "alice edit"), base_rev=1))
    r = push(bob, pid, upsert(g, make_chunk(g, "bob edit"), base_rev=1), upsert(h, make_chunk(h, "bobs new"))).json()
    assert r["results"][0]["status"] == "conflict" and r["results"][0]["head_rev"] == 2
    assert r["results"][1]["status"] == "accepted"
    cur = bob.get(f"/projects/{pid}/tracks/{g}/revisions").json()
    assert [x["name"] for x in cur] == ["orig", "alice edit"]  # bob's edit not applied


def test_conflict_resolved_by_keep_both(alice, bob, joined):
    pid, g, dup = joined["id"], new_guid(), new_guid()
    push(alice, pid, upsert(g, make_chunk(g, "orig")))
    push(alice, pid, upsert(g, make_chunk(g, "alice"), base_rev=1))
    assert push(bob, pid, upsert(g, make_chunk(g, "bob"), base_rev=1)).json()["results"][0]["status"] == "conflict"
    # bob keeps both: duplicate under a fresh guid, and rebases onto head
    r = push(bob, pid, upsert(dup, make_chunk(dup, "orig (conflict - Bob)")),
             upsert(g, make_chunk(g, "alice"), base_rev=2)).json()
    assert [x["status"] for x in r["results"]] == ["accepted", "unchanged"]


def test_identical_retry_is_idempotent(alice, joined):
    pid, g = joined["id"], new_guid()
    c = make_chunk(g)
    push(alice, pid, upsert(g, c))
    r = push(alice, pid, upsert(g, c)).json()  # response lost, client retries with base 0
    assert r["results"][0]["status"] == "unchanged" and r["results"][0]["rev"] == 1
    assert r["seq"] == 1


def test_unknown_track_with_base_rev_conflicts(alice, joined):
    g = new_guid()
    r = push(alice, joined["id"], upsert(g, make_chunk(g), base_rev=3)).json()
    assert r["results"][0]["status"] == "conflict"


def test_delete_and_restore(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g, make_chunk(g, "Vocals")))
    r = push(alice, pid, {"guid": g, "op": "delete", "base_rev": 1}).json()
    assert r["results"][0] == {"guid": g, "status": "accepted", "rev": 2, "seq": 2}
    assert alice.get(f"/projects/{pid}/tracks").json() == []
    dead = bob.get(f"/projects/{pid}/tracks", params={"state": "deleted"}).json()
    assert [(d["guid"], d["name"], d["deleted"]) for d in dead] == [(g, "Vocals", True)]
    pulled = bob.get(f"/projects/{pid}/changes", params={"since": 1}).json()["tracks"][0]
    assert pulled["deleted"] and pulled["op"] == "delete"

    r = bob.post(f"/projects/{pid}/tracks/{g}/restore", json={}).json()
    assert r["status"] == "accepted" and r["rev"] == 3
    live = alice.get(f"/projects/{pid}/tracks").json()
    assert [x["name"] for x in live] == ["Vocals"]
    assert [x["op"] for x in alice.get(f"/projects/{pid}/tracks/{g}/revisions").json()] == \
        ["create", "delete", "restore"]


def test_delete_vs_edit_conflicts_both_ways(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g, make_chunk(g, "a")))
    push(alice, pid, {"guid": g, "op": "delete", "base_rev": 1})
    r = push(bob, pid, upsert(g, make_chunk(g, "bob edit"), base_rev=1)).json()
    assert r["results"][0]["status"] == "conflict" and r["results"][0]["head_deleted"] is True
    g2 = new_guid()
    push(alice, pid, upsert(g2, make_chunk(g2, "a")))
    push(bob, pid, upsert(g2, make_chunk(g2, "b"), base_rev=1))
    r = push(alice, pid, {"guid": g2, "op": "delete", "base_rev": 1}).json()
    assert r["results"][0]["status"] == "conflict"


def test_restore_old_revision(alice, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g, make_chunk(g, "v1")))
    push(alice, pid, upsert(g, make_chunk(g, "v2"), base_rev=1))
    r = alice.post(f"/projects/{pid}/tracks/{g}/restore", json={"rev": 1}).json()
    assert r["rev"] == 3
    assert alice.get(f"/projects/{pid}/tracks/{g}/revisions/3").json()["name"] == "v1"
    assert alice.post(f"/projects/{pid}/tracks/{g}/restore", json={"rev": 1}).json()["status"] == "unchanged"
    assert alice.post(f"/projects/{pid}/tracks/{g}/restore", json={"rev": 99}).status_code == 404


def test_restore_requires_editor(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g, make_chunk(g)))
    bob_id = bob.get("/me").json()["id"]
    alice.patch(f"/projects/{pid}/members/{bob_id}", json={"role": "viewer"})
    assert bob.post(f"/projects/{pid}/tracks/{g}/restore", json={}).status_code == 403


# ---- media ----

def test_blob_flow_and_push_with_media(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    data = ogg_bytes()
    h = sha(data)
    assert alice.post(f"/projects/{pid}/blobs/missing", json={"hashes": [h]}).json() == {"missing": [h]}
    r = push(alice, pid, upsert(g, make_chunk(g, media=[h])))
    assert r.status_code == 422 and r.json()["detail"]["missing"] == [h]
    assert alice.put(f"/projects/{pid}/blobs/{h}", content=data).json() == {"status": "stored"}
    assert alice.put(f"/projects/{pid}/blobs/{h}", content=data).json() == {"status": "exists"}
    assert alice.post(f"/projects/{pid}/blobs/missing", json={"hashes": [h]}).json() == {"missing": []}
    assert push(alice, pid, upsert(g, make_chunk(g, media=[h]))).status_code == 200
    assert bob.get(f"/projects/{pid}/blobs/{h}").content == data
    t = bob.get(f"/projects/{pid}/changes").json()["tracks"][0]
    assert t["media_hashes"] == [h]
    assert bob.get(f"/projects/{pid}").json()["storage_bytes"] > len(data)


def test_blob_validation(alice, joined):
    pid = joined["id"]
    data = ogg_bytes()
    assert alice.put(f"/projects/{pid}/blobs/{'0' * 64}", content=data).status_code == 422  # hash mismatch
    junk = b"not an ogg file at all"
    assert alice.put(f"/projects/{pid}/blobs/{sha(junk)}", content=junk).status_code == 422
    assert alice.put(f"/projects/{pid}/blobs/{sha(b'')}", content=b"").status_code == 422
    assert alice.put(f"/projects/{pid}/blobs/zzz", content=data).status_code == 422
    flac = b"OggS" + b"\x00" * 30 + b"\x7fFLAC"
    assert alice.put(f"/projects/{pid}/blobs/{sha(flac)}", content=flac).status_code == 422


def test_blob_size_and_quota_limits(alice, joined, app):
    pid = joined["id"]
    app.state.settings.max_blob_bytes = 100
    big = ogg_bytes(b"x" * 200)
    assert alice.put(f"/projects/{pid}/blobs/{sha(big)}", content=big).status_code == 413
    app.state.settings.max_blob_bytes = 10_000
    app.state.settings.project_quota_bytes = 150
    a, b = ogg_bytes(), ogg_bytes()
    assert alice.put(f"/projects/{pid}/blobs/{sha(a)}", content=a).status_code == 200
    assert alice.put(f"/projects/{pid}/blobs/{sha(b)}", content=b).status_code == 413
    assert alice.post(f"/projects/{pid}/blobs/missing", json={"hashes": [sha(b)]}).json()["missing"] == [sha(b)]


def test_blobs_not_shared_across_projects(alice, bob, joined):
    other = bob.post("/projects", json={"name": "Other"}).json()["id"]
    data = ogg_bytes()
    h = upload(alice, joined["id"], data)
    assert bob.get(f"/projects/{other}/blobs/{h}").status_code == 404
    assert bob.post(f"/projects/{other}/blobs/missing", json={"hashes": [h]}).json()["missing"] == [h]
    assert alice.get(f"/projects/{other}/blobs/{h}").status_code == 404  # alice isn't a member


# ---- chunk validation ----

def test_chunk_validation(alice, joined):
    pid, g = joined["id"], new_guid()
    bad_path = f'<TRACK {g}\nNAME x\n<ITEM\n<SOURCE WAVE\nFILE "/Users/alice/secret.wav"\n>\n>\n>'
    assert push(alice, pid, upsert(g, bad_path)).status_code == 422
    assert push(alice, pid, upsert(g, make_chunk(new_guid()))).status_code == 422  # guid mismatch
    assert push(alice, pid, upsert(g, "<NOTATRACK>")).status_code == 422
    assert push(alice, pid, upsert("not-a-guid", make_chunk(g))).status_code == 422
    assert push(alice, pid, {"guid": g, "op": "upsert", "base_rev": 0}).status_code == 422
    assert push(alice, pid, upsert(g, make_chunk(g)), upsert(g, make_chunk(g))).status_code == 422
    assert alice.get(f"/projects/{pid}/changes").json()["tracks"] == []  # nothing applied


def test_guid_case_normalised(alice, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g.lower(), make_chunk(g)))
    assert alice.get(f"/projects/{pid}/changes").json()["tracks"][0]["guid"] == g


def test_limits(alice, joined, app):
    pid = joined["id"]
    app.state.settings.max_tracks_per_project = 1
    a, b = new_guid(), new_guid()
    assert push(alice, pid, upsert(a, make_chunk(a))).status_code == 200
    assert push(alice, pid, upsert(b, make_chunk(b))).status_code == 413
    app.state.settings.max_chunk_bytes = 10
    assert push(alice, pid, upsert(a, make_chunk(a), base_rev=1)).status_code == 422


def test_concurrent_pushes_get_distinct_seqs(alice, bob, joined):
    import threading
    pid = joined["id"]
    out = []
    def go(p):
        g = new_guid()
        out.append(push(p, pid, upsert(g, make_chunk(g))).json()["results"][0]["seq"])
    ts = [threading.Thread(target=go, args=(p,)) for p in [alice, bob] * 4]
    [t.start() for t in ts]; [t.join() for t in ts]
    assert sorted(out) == list(range(1, 9))


def test_fractional_position(alice, joined):
    pid, g = joined["id"], new_guid()
    push(alice, pid, upsert(g, make_chunk(g), position=1.5))
    push(alice, pid, upsert(g, make_chunk(g), base_rev=1, position=1.75))  # position-only change is a revision
    t = alice.get(f"/projects/{pid}/changes").json()["tracks"][0]
    assert t["position"] == 1.75 and t["rev"] == 2


def test_chunk_guid_forms(alice, joined):
    pid, g = joined["id"], new_guid()
    with_header = f'<TRACK {g}\nNAME "x"\n>'
    assert push(alice, pid, upsert(g, with_header)).status_code == 200            # project-file style
    h = new_guid()
    assert push(alice, pid, upsert(h, f'<TRACK\nNAME "y"\nTRACKID {h}\n>')).status_code == 200  # REAPER API style
    k = new_guid()
    assert push(alice, pid, upsert(k, '<TRACK\nNAME "z"\n>')).status_code == 422                # no guid anywhere
    assert push(alice, pid, upsert(k, f'<TRACK\nTRACKID {new_guid()}\n>')).status_code == 422    # wrong guid


def ogg_chunk(guid, h, name="Raw"):
    return (f'<TRACK\nNAME "{name}"\nTRACKID {guid}\n<ITEM\n<SOURCE VORBIS\nFILE "reach-media://{h}.ogg"\n>\n>\n>')


def test_chunks_cannot_reference_wav_directly(alice, joined):
    pid, g = joined["id"], new_guid()
    h = upload(alice, pid, wav_bytes())
    wav_ref = f'<TRACK\nTRACKID {g}\n<ITEM\n<SOURCE WAVE\nFILE "reach-media://{h}.wav"\n>\n>\n>'
    assert push(alice, pid, upsert(g, wav_ref)).status_code == 422          # only Ogg refs are allowed
    as_ogg = f'<TRACK\nTRACKID {g}\n<ITEM\n<SOURCE VORBIS\nFILE "reach-media://{h}.ogg"\n>\n>\n>'
    r = push(alice, pid, upsert(g, as_ogg))                                  # blob is a wav -> not a valid ogg ref
    assert r.status_code == 422 and r.json()["detail"]["missing"] == [h]


def test_audio_type_detection(alice, joined):
    pid = joined["id"]
    for ok in (wav_bytes(), wav_bytes(riff=b"RF64")):
        assert alice.put(f"/projects/{pid}/blobs/{sha(ok)}", content=ok).status_code == 200
    riff_not_wave = b"RIFF\x24\x00\x00\x00AVI LIST" + b"\x00" * 40
    for bad in (riff_not_wave, b"ID3\x03\x00\x00mp3 data here"):
        assert alice.put(f"/projects/{pid}/blobs/{sha(bad)}", content=bad).status_code == 422


def test_hq_companion_link_lookup_and_download(alice, bob, joined):
    pid, g = joined["id"], new_guid()
    ogg, wav = ogg_bytes(), wav_bytes(b"x" * 3000)
    ho, hw = upload(alice, pid, ogg), upload(alice, pid, wav)
    r = alice.post(f"/projects/{pid}/hq", json={"links": [{"ogg": ho, "wav": hw}]})
    assert r.json()["results"] == [{"ogg": ho, "status": "linked"}]
    assert push(alice, pid, upsert(g, ogg_chunk(g, ho))).status_code == 200
    # a collaborator can ask which of the Oggs in a chunk have a WAV, then fetch it byte-for-byte
    other = sha(b"nothing")
    v = bob.post(f"/projects/{pid}/hq/lookup", json={"hashes": [ho, other]}).json()["variants"]
    assert v == {ho: hw}
    r = bob.get(f"/projects/{pid}/blobs/{hw}")
    assert r.content == wav and r.headers["content-type"] == "audio/wav"
    assert bob.get(f"/projects/{pid}/blobs/{ho}").content == ogg
    # re-linking replaces the companion
    hw2 = upload(alice, pid, wav_bytes(b"y" * 10))
    alice.post(f"/projects/{pid}/hq", json={"links": [{"ogg": ho, "wav": hw2}]})
    assert bob.post(f"/projects/{pid}/hq/lookup", json={"hashes": [ho]}).json()["variants"] == {ho: hw2}


def test_hq_link_validation(alice, bob, joined):
    pid = joined["id"]
    ho, hw = upload(alice, pid, ogg_bytes()), upload(alice, pid, wav_bytes())
    ghost = sha(b"ghost")
    res = alice.post(f"/projects/{pid}/hq", json={"links": [
        {"ogg": ghost, "wav": hw}, {"ogg": ho, "wav": ghost}, {"ogg": hw, "wav": hw}, {"ogg": ho, "wav": ho}]}).json()["results"]
    assert [r["status"] for r in res] == ["unknown_ogg", "unknown_wav", "unknown_ogg", "unknown_wav"]
    assert alice.post(f"/projects/{pid}/hq", json={"links": [{"ogg": "zz", "wav": hw}]}).status_code == 422
    bob_id = bob.get("/me").json()["id"]
    alice.patch(f"/projects/{pid}/members/{bob_id}", json={"role": "viewer"})
    assert bob.post(f"/projects/{pid}/hq", json={"links": [{"ogg": ho, "wav": hw}]}).status_code == 403
    assert bob.post(f"/projects/{pid}/hq/lookup", json={"hashes": [ho]}).status_code == 200


def test_companions_live_and_die_with_their_ogg(alice, joined, sm, app):
    from datetime import timedelta
    from sqlalchemy import select, update
    from reach_server.models import Blob, BlobVariant, now
    from reach_server.retention import purge
    import os, time
    pid, g = joined["id"], new_guid()
    used_ogg, used_wav = upload(alice, pid, ogg_bytes()), upload(alice, pid, wav_bytes())
    lone_ogg, lone_wav = upload(alice, pid, ogg_bytes()), upload(alice, pid, wav_bytes())
    alice.post(f"/projects/{pid}/hq", json={"links": [{"ogg": used_ogg, "wav": used_wav}, {"ogg": lone_ogg, "wav": lone_wav}]})
    push(alice, pid, upsert(g, ogg_chunk(g, used_ogg)))            # only the first pair is referenced by a track
    app.state.settings.retention_deleted_track_days = 1             # any policy, so GC runs
    with sm() as db:
        db.execute(update(Blob).values(created_at=now() - timedelta(hours=48)))
        db.commit()
    for _, f in app.state.store.list_files():
        os.utime(f, (time.time() - 48 * 3600,) * 2)
    r = purge(sm, app.state.store, app.state.settings, dry_run=False)
    assert r.blob_rows_deleted == 2 and r.files_deleted == 2        # the unreferenced pair, nothing else
    assert app.state.store.exists(used_ogg, "ogg") and app.state.store.exists(used_wav, "wav")
    assert not app.state.store.exists(lone_ogg, "ogg") and not app.state.store.exists(lone_wav, "wav")
    with sm() as db:
        assert [v.ogg_sha for v in db.scalars(select(BlobVariant))] == [used_ogg]   # link rows cascaded away
