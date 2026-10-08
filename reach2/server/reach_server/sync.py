import hashlib
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .deps import current_user, get_db, project_access
from .models import Blob, Member, Project, Track, TrackRevision, User, now
from .validation import (SHA_RE, ChunkError, check_ogg, chunk_hash, normalise_guid, track_name,
                         validate_chunk)

router = APIRouter()


def _lock_project(db: Session, project_id: uuid.UUID) -> Project:
    return db.scalar(select(Project).where(Project.id == project_id).with_for_update())


def _check_quota(s, p: Project, add: int):
    if s.project_quota_bytes is not None and p.storage_bytes + add > s.project_quota_bytes:
        raise HTTPException(413, "project storage quota exceeded")


# ---- Blobs ---------------------------------------------------------------------------

class MissingBody(BaseModel):
    hashes: list[str] = Field(max_length=2000)


@router.post("/projects/{project_id}/blobs/missing")
def blobs_missing(body: MissingBody, m: Member = Depends(project_access("editor")),
                  db: Session = Depends(get_db)):
    if any(not SHA_RE.match(h) for h in body.hashes):
        raise HTTPException(422, "invalid sha256")
    have = set(db.scalars(select(Blob.sha256).where(Blob.project_id == m.project_id,
                                                    Blob.sha256.in_(body.hashes))))
    return {"missing": [h for h in dict.fromkeys(body.hashes) if h not in have]}


@router.put("/projects/{project_id}/blobs/{sha256}")
async def put_blob(sha256: str, request: Request, m: Member = Depends(project_access("editor")),
                   db: Session = Depends(get_db)):
    s, store = request.app.state.settings, request.app.state.store
    if not SHA_RE.match(sha256):
        raise HTTPException(422, "invalid sha256")
    declared = request.headers.get("content-length")
    if declared and int(declared) > s.max_blob_bytes:
        raise HTTPException(413, "blob too large")
    if await run_in_threadpool(db.get, Blob, (m.project_id, sha256)):
        return {"status": "exists"}
    p = await run_in_threadpool(db.get, Project, m.project_id)
    if declared:
        _check_quota(s, p, int(declared))

    up, h, size, head = store.new_upload(), hashlib.sha256(), 0, b""
    try:
        async for part in request.stream():
            size += len(part)
            if size > s.max_blob_bytes:
                raise HTTPException(413, "blob too large")
            if len(head) < 128:
                head = (head + part)[:128]
            h.update(part)
            up.write(part)
        if size == 0:
            raise HTTPException(422, "empty upload")
        try:
            check_ogg(head)
        except ChunkError as e:
            raise HTTPException(422, str(e))
        if h.hexdigest() != sha256:
            raise HTTPException(422, "sha256 mismatch")
        up.commit(sha256)
    except BaseException:
        up.abort()
        raise

    def record():
        proj = _lock_project(db, m.project_id)
        if db.get(Blob, (m.project_id, sha256)):
            return "exists"
        _check_quota(s, proj, size)
        db.add(Blob(project_id=m.project_id, sha256=sha256, size=size))
        proj.storage_bytes += size
        db.commit()
        return "stored"

    return {"status": await run_in_threadpool(record)}


@router.get("/projects/{project_id}/blobs/{sha256}")
def get_blob(sha256: str, request: Request, m: Member = Depends(project_access("viewer")),
             db: Session = Depends(get_db)):
    if not SHA_RE.match(sha256) or db.get(Blob, (m.project_id, sha256)) is None:
        raise HTTPException(404, "blob not found")
    path = request.app.state.store.path(sha256)
    if path is None or not path.exists():
        raise HTTPException(404, "blob data missing")
    return FileResponse(path, media_type="audio/ogg")


# ---- Push / pull ---------------------------------------------------------------------

class TrackPush(BaseModel):
    guid: str
    base_rev: int = Field(0, ge=0)  # the rev this edit was based on (0 = new track)
    op: Literal["upsert", "delete"] = "upsert"
    chunk: str | None = None
    parent_guid: str | None = None
    position: float = Field(0.0, allow_inf_nan=False)  # sibling ordering key (fractional)


class PushBody(BaseModel):
    tracks: list[TrackPush]


def _head(db: Session, t: Track) -> TrackRevision:
    return db.scalar(select(TrackRevision).where(
        TrackRevision.project_id == t.project_id, TrackRevision.track_guid == t.guid,
        TrackRevision.rev == t.head_rev))


def _new_revision(db: Session, p: Project, t: Track, *, op: str, chunk: str, parent, position, hashes,
                  author: User) -> TrackRevision:
    p.seq += 1
    t.head_rev += 1
    t.head_seq = p.seq
    t.deleted = op == "delete"
    rev = TrackRevision(project_id=p.id, track_guid=t.guid, rev=t.head_rev, seq=p.seq, op=op, chunk=chunk,
                        chunk_hash=chunk_hash(chunk), parent_guid=parent, position=position,
                        author_id=author.id, media_hashes=hashes)
    p.storage_bytes += len(chunk.encode("utf-8"))
    db.add(rev)
    return rev


@router.post("/projects/{project_id}/push")
def push(body: PushBody, request: Request, m: Member = Depends(project_access("editor")),
         user: User = Depends(current_user), db: Session = Depends(get_db)):
    s = request.app.state.settings
    if len(body.tracks) > s.max_push_tracks:
        raise HTTPException(413, "too many tracks in one push")

    # Validate everything up front: a malformed push changes nothing.
    items = []
    seen = set()
    for tp in body.tracks:
        try:
            guid = normalise_guid(tp.guid)
            parent = normalise_guid(tp.parent_guid) if tp.parent_guid else None
            hashes = []
            if tp.op == "upsert":
                if tp.chunk is None:
                    raise ChunkError("upsert requires a chunk")
                hashes = validate_chunk(tp.chunk, guid, s.max_chunk_bytes)
        except ChunkError as e:
            raise HTTPException(422, f"{tp.guid}: {e}")
        if guid in seen:
            raise HTTPException(422, f"duplicate track in push: {guid}")
        seen.add(guid)
        items.append((tp, guid, parent, hashes))

    p = _lock_project(db, m.project_id)
    wanted = {h for *_, hashes in items for h in hashes}
    if wanted:
        have = set(db.scalars(select(Blob.sha256).where(Blob.project_id == p.id, Blob.sha256.in_(wanted))))
        if wanted - have:
            raise HTTPException(422, {"error": "missing_blobs", "missing": sorted(wanted - have)})

    results = []
    track_count = None
    for tp, guid, parent, hashes in items:
        t = db.get(Track, (p.id, guid))
        if t is None:
            if tp.op == "delete":
                results.append({"guid": guid, "status": "unchanged", "rev": 0})
                continue
            if tp.base_rev != 0:
                results.append({"guid": guid, "status": "conflict", "reason": "unknown_track", "head_rev": 0})
                continue
            if track_count is None:
                track_count = len(db.scalars(select(Track.guid).where(Track.project_id == p.id)).all())
            if track_count >= s.max_tracks_per_project:
                raise HTTPException(413, "track limit reached")
            track_count += 1
            _check_quota(s, p, len(tp.chunk.encode("utf-8")))
            t = Track(project_id=p.id, guid=guid, owner_id=user.id, head_rev=0, head_seq=0)
            db.add(t)
            db.flush()
            r = _new_revision(db, p, t, op="create", chunk=tp.chunk, parent=parent, position=tp.position,
                              hashes=hashes, author=user)
            results.append({"guid": guid, "status": "accepted", "rev": r.rev, "seq": r.seq})
            continue

        head = _head(db, t)
        same_content = (tp.op == "upsert" and not t.deleted and head.chunk_hash == chunk_hash(tp.chunk)
                        and head.parent_guid == parent and head.position == tp.position)
        same_delete = tp.op == "delete" and t.deleted
        if same_content or same_delete:  # already converged (also covers retries of a lost response)
            results.append({"guid": guid, "status": "unchanged", "rev": t.head_rev})
            continue
        if tp.base_rev != t.head_rev:
            results.append({"guid": guid, "status": "conflict", "reason": "stale_base",
                            "head_rev": t.head_rev, "head_deleted": t.deleted})
            continue
        if tp.op == "delete":
            r = _new_revision(db, p, t, op="delete", chunk=head.chunk, parent=head.parent_guid,
                              position=head.position, hashes=head.media_hashes, author=user)
        else:
            _check_quota(s, p, len(tp.chunk.encode("utf-8")))
            r = _new_revision(db, p, t, op="update", chunk=tp.chunk, parent=parent, position=tp.position,
                              hashes=hashes, author=user)
        results.append({"guid": guid, "status": "accepted", "rev": r.rev, "seq": r.seq})

    db.commit()
    return {"seq": p.seq, "results": results}


def _rev_json(r: TrackRevision, authors: dict, full: bool) -> dict:
    d = {"rev": r.rev, "seq": r.seq, "op": r.op, "name": track_name(r.chunk), "chunk_hash": r.chunk_hash,
         "parent_guid": r.parent_guid, "position": r.position, "author": authors.get(r.author_id),
         "created_at": r.created_at, "media_hashes": r.media_hashes}
    if full:
        d["chunk"] = r.chunk
    return d


def _names(db: Session, ids) -> dict:
    ids = set(ids)
    if not ids:
        return {}
    return {u.id: u.display_name for u in db.scalars(select(User).where(User.id.in_(ids)))}


@router.get("/projects/{project_id}/changes")
def changes(since: int = 0, m: Member = Depends(project_access("viewer")), db: Session = Depends(get_db)):
    """Head state of every track changed after `since` (deletions included)."""
    p = db.get(Project, m.project_id)
    rows = db.execute(select(Track, TrackRevision).join(
        TrackRevision, (TrackRevision.project_id == Track.project_id) & (TrackRevision.track_guid == Track.guid)
        & (TrackRevision.rev == Track.head_rev))
        .where(Track.project_id == p.id, Track.head_seq > since).order_by(Track.head_seq)).all()
    names = _names(db, [t.owner_id for t, _ in rows] + [r.author_id for _, r in rows])
    return {"seq": p.seq, "tracks": [
        {"guid": t.guid, "deleted": t.deleted, "owner": names.get(t.owner_id), "owner_id": str(t.owner_id),
         **_rev_json(r, names, full=True)} for t, r in rows]}


@router.get("/projects/{project_id}/tracks")
def list_tracks(state: Literal["live", "deleted", "all"] = "live", m: Member = Depends(project_access("viewer")),
                db: Session = Depends(get_db)):
    q = select(Track, TrackRevision).join(
        TrackRevision, (TrackRevision.project_id == Track.project_id) & (TrackRevision.track_guid == Track.guid)
        & (TrackRevision.rev == Track.head_rev)).where(Track.project_id == m.project_id).order_by(Track.created_at)
    if state != "all":
        q = q.where(Track.deleted == (state == "deleted"))
    rows = db.execute(q).all()
    names = _names(db, [t.owner_id for t, _ in rows] + [r.author_id for _, r in rows])
    return [{"guid": t.guid, "deleted": t.deleted, "owner": names.get(t.owner_id), "head_rev": t.head_rev,
             **{k: v for k, v in _rev_json(r, names, full=False).items() if k != "rev"}} for t, r in rows]


@router.get("/projects/{project_id}/tracks/{guid}/revisions")
def revisions(guid: str, m: Member = Depends(project_access("viewer")), db: Session = Depends(get_db)):
    revs = db.scalars(select(TrackRevision).where(TrackRevision.project_id == m.project_id,
                                                  TrackRevision.track_guid == guid.upper())
                      .order_by(TrackRevision.rev)).all()
    if not revs:
        raise HTTPException(404, "track not found")
    names = _names(db, [r.author_id for r in revs])
    return [_rev_json(r, names, full=False) for r in revs]


@router.get("/projects/{project_id}/tracks/{guid}/revisions/{rev}")
def get_revision(guid: str, rev: int, m: Member = Depends(project_access("viewer")),
                 db: Session = Depends(get_db)):
    r = db.scalar(select(TrackRevision).where(TrackRevision.project_id == m.project_id,
                                              TrackRevision.track_guid == guid.upper(), TrackRevision.rev == rev))
    if r is None:
        raise HTTPException(404, "revision not found")
    return _rev_json(r, _names(db, [r.author_id]), full=True)


class RestoreBody(BaseModel):
    rev: int | None = None  # default: latest non-delete revision


@router.post("/projects/{project_id}/tracks/{guid}/restore")
def restore(guid: str, body: RestoreBody, request: Request, m: Member = Depends(project_access("editor")),
            user: User = Depends(current_user), db: Session = Depends(get_db)):
    """Undelete a track, or roll a live track back to an earlier revision. Creates a new revision."""
    guid = guid.upper()
    p = _lock_project(db, m.project_id)
    t = db.get(Track, (p.id, guid))
    if t is None:
        raise HTTPException(404, "track not found")
    q = select(TrackRevision).where(TrackRevision.project_id == p.id, TrackRevision.track_guid == guid)
    if body.rev is not None:
        src = db.scalar(q.where(TrackRevision.rev == body.rev))
    else:
        src = db.scalar(q.where(TrackRevision.op != "delete").order_by(TrackRevision.rev.desc()).limit(1))
    if src is None:
        raise HTTPException(404, "revision not found")
    head = _head(db, t)
    if not t.deleted and head.chunk_hash == src.chunk_hash and head.parent_guid == src.parent_guid \
            and head.position == src.position:
        return {"status": "unchanged", "rev": t.head_rev, "seq": p.seq}
    if src.media_hashes:
        have = set(db.scalars(select(Blob.sha256).where(Blob.project_id == p.id,
                                                        Blob.sha256.in_(src.media_hashes))))
        if set(src.media_hashes) - have:
            raise HTTPException(409, {"error": "media_purged", "missing": sorted(set(src.media_hashes) - have)})
    _check_quota(request.app.state.settings, p, len(src.chunk.encode("utf-8")))
    r = _new_revision(db, p, t, op="restore", chunk=src.chunk, parent=src.parent_guid, position=src.position,
                      hashes=src.media_hashes, author=user)
    db.commit()
    return {"status": "accepted", "rev": r.rev, "seq": r.seq}
