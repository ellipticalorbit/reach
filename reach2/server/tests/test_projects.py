from conftest import make_chunk, new_guid, push, upsert


def test_create_list_get(alice, project):
    assert project["role"] == "owner" and len(project["join_code"]) == 19
    assert [p["id"] for p in alice.get("/projects").json()] == [project["id"]]
    assert alice.get(f"/projects/{project['id']}").json()["join_code"] == project["join_code"]


def test_join_and_roles(alice, bob, joined):
    pid = joined["id"]
    assert bob.get(f"/projects/{pid}").json()["role"] == "editor"
    assert "join_code" not in bob.get(f"/projects/{pid}").json()
    members = alice.get(f"/projects/{pid}/members").json()
    assert {m["display_name"] for m in members} == {"Alice", "Bob"}
    bob_id = next(m["user_id"] for m in members if m["display_name"] == "Bob")
    assert alice.patch(f"/projects/{pid}/members/{bob_id}", json={"role": "viewer"}).status_code == 200
    g = new_guid()
    assert push(bob, pid, upsert(g, make_chunk(g))).status_code == 403
    assert bob.get(f"/projects/{pid}/changes").status_code == 200


def test_join_is_idempotent_and_keeps_role(alice, bob, joined):
    members = alice.get(f"/projects/{joined['id']}/members").json()
    bob_id = next(m["user_id"] for m in members if m["display_name"] == "Bob")
    alice.patch(f"/projects/{joined['id']}/members/{bob_id}", json={"role": "viewer"})
    assert bob.post("/join", json={"code": joined["join_code"]}).json()["role"] == "viewer"


def test_bad_join_code(bob):
    assert bob.post("/join", json={"code": "AAAA-AAAA-AAAA-AAAA"}).status_code == 404


def test_non_member_sees_404(alice, bob, project):
    pid = project["id"]
    assert bob.get(f"/projects/{pid}").status_code == 404
    assert bob.get(f"/projects/{pid}/changes").status_code == 404
    g = new_guid()
    assert push(bob, pid, upsert(g, make_chunk(g))).status_code == 404


def test_rotate_join_code(alice, bob, project):
    new = alice.post(f"/projects/{project['id']}/join-code/rotate").json()["join_code"]
    assert new != project["join_code"]
    assert bob.post("/join", json={"code": project["join_code"]}).status_code == 404
    assert bob.post("/join", json={"code": new}).status_code == 200


def test_only_owner_manages(alice, bob, joined):
    pid = joined["id"]
    assert bob.post(f"/projects/{pid}/join-code/rotate").status_code == 403
    me = alice.get("/me").json()["id"]
    assert bob.patch(f"/projects/{pid}/members/{me}", json={"role": "viewer"}).status_code == 403
    assert alice.patch(f"/projects/{pid}/members/{me}", json={"role": "viewer"}).status_code == 400


def test_leave_and_remove(alice, bob, joined):
    pid = joined["id"]
    bob_id = bob.get("/me").json()["id"]
    assert bob.delete(f"/projects/{pid}/members/{bob_id}").status_code == 204
    assert bob.get(f"/projects/{pid}").status_code == 404
    bob.post("/join", json={"code": joined["join_code"]})
    assert alice.delete(f"/projects/{pid}/members/{bob_id}").status_code == 204
    assert alice.delete(f"/projects/{pid}/members/{alice.get('/me').json()['id']}").status_code == 400


def test_project_limit(alice, settings, app):
    app.state.settings.max_projects_per_user = 2
    assert alice.post("/projects", json={"name": "a"}).status_code == 201
    assert alice.post("/projects", json={"name": "b"}).status_code == 201
    assert alice.post("/projects", json={"name": "c"}).status_code == 403


def test_list_shows_join_code_only_to_owner(alice, bob, joined):
    mine = alice.get("/projects").json()
    assert [p["join_code"] for p in mine] == [joined["join_code"]]
    theirs = bob.get("/projects").json()
    assert len(theirs) == 1 and theirs[0]["role"] == "editor" and "join_code" not in theirs[0]


def test_song_settings_owner_only_with_revisions(alice, bob, joined):
    pid = joined["id"]
    assert bob.get(f"/projects/{pid}/settings").json() == {"rev": 0, "data": None}
    tempo = {"tempo": {"bpm": 100, "num": 4, "den": 4, "markers": []}}
    assert bob.put(f"/projects/{pid}/settings", json={"base_rev": 0, "data": tempo}).status_code == 403
    r = alice.put(f"/projects/{pid}/settings", json={"base_rev": 0, "data": tempo})
    assert r.json() == {"rev": 1, "data": tempo}
    assert bob.get(f"/projects/{pid}/settings").json()["data"] == tempo
    stale = alice.put(f"/projects/{pid}/settings", json={"base_rev": 0, "data": {"tempo": {"bpm": 90}}})
    assert stale.status_code == 409 and stale.json()["detail"]["rev"] == 1
    assert alice.put(f"/projects/{pid}/settings", json={"base_rev": 1, "data": {"x": "y" * 70000}}).status_code == 413


def test_transfer_ownership(alice, bob, make_person, joined):
    pid = joined["id"]
    bob_id, alice_id = bob.get("/me").json()["id"], alice.get("/me").json()["id"]
    assert bob.post(f"/projects/{pid}/transfer", json={"user_id": alice_id}).status_code == 403   # not the owner
    assert alice.post(f"/projects/{pid}/transfer", json={"user_id": alice_id}).status_code == 400  # already owner
    carol = make_person("carol@example.com", "Carol")
    carol_id = carol.get("/me").json()["id"]
    assert alice.post(f"/projects/{pid}/transfer", json={"user_id": carol_id}).status_code == 404  # not a member
    assert alice.post(f"/projects/{pid}/transfer", json={"user_id": bob_id}).json() == {"owner": bob_id}
    roles = {m["display_name"]: m["role"] for m in bob.get(f"/projects/{pid}/members").json()}
    assert roles == {"Alice": "editor", "Bob": "owner"}
    assert bob.get(f"/projects/{pid}").json()["join_code"] == joined["join_code"]   # the owner sees the code
    assert "join_code" not in alice.get(f"/projects/{pid}").json()
    assert bob.put(f"/projects/{pid}/settings", json={"base_rev": 0, "data": {"tempo": {"bpm": 90}}}).status_code == 200
    assert alice.put(f"/projects/{pid}/settings", json={"base_rev": 1, "data": {"tempo": {"bpm": 80}}}).status_code == 403
