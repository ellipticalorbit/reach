"""Retention policy and purge job.

Defaults keep everything forever (policy values None), in which case purge() does
nothing. Server-wide defaults come from settings; a project may override via
projects.retention, e.g. {"deleted_track_days": 90, "max_revisions_per_track": 50}.
A key present with a null value means "keep forever" for that project.
"""
import time
from dataclasses import dataclass, field
from datetime import timedelta

from sqlalchemy import and_, delete, exists, func, select, text
from sqlalchemy.orm import Session, sessionmaker

from .config import Settings
from .models import Blob, BlobVariant, Project, Track, TrackRevision, now


@dataclass(frozen=True)
class RetentionPolicy:
    deleted_track_days: int | None = None
    max_revisions_per_track: int | None = None

    @property
    def keeps_everything(self) -> bool:
        return self.deleted_track_days is None and self.max_revisions_per_track is None


def policy_for(project: Project, settings: Settings) -> RetentionPolicy:
    base = {"deleted_track_days": settings.retention_deleted_track_days,
            "max_revisions_per_track": settings.retention_max_revisions_per_track}
    base.update({k: v for k, v in (project.retention or {}).items() if k in base})
    return RetentionPolicy(**base)


@dataclass
class PurgeReport:
    dry_run: bool
    tracks_deleted: int = 0
    revisions_deleted: int = 0
    blob_rows_deleted: int = 0
    files_deleted: int = 0
    bytes_freed: int = 0
    projects_touched: list = field(default_factory=list)


def _purge_project(db: Session, p: Project, settings: Settings, report: PurgeReport) -> None:
    policy = policy_for(p, settings)
    freed = 0

    if policy.deleted_track_days is not None:
        cutoff = now() - timedelta(days=policy.deleted_track_days)
        doomed = db.scalars(select(Track.guid).join(
            TrackRevision, and_(TrackRevision.project_id == Track.project_id, TrackRevision.track_guid == Track.guid,
                                TrackRevision.rev == Track.head_rev))
            .where(Track.project_id == p.id, Track.deleted, TrackRevision.created_at < cutoff)).all()
        if doomed:
            where = and_(TrackRevision.project_id == p.id, TrackRevision.track_guid.in_(doomed))
            n, b = db.execute(select(func.count(), func.coalesce(func.sum(func.octet_length(TrackRevision.chunk)), 0))
                              .where(where)).one()
            report.revisions_deleted += n
            report.tracks_deleted += len(doomed)
            freed += b
            db.execute(delete(TrackRevision).where(where))
            db.execute(delete(Track).where(Track.project_id == p.id, Track.guid.in_(doomed)))

    if policy.max_revisions_per_track is not None:
        keep = policy.max_revisions_per_track
        for t in db.scalars(select(Track).where(Track.project_id == p.id, Track.head_rev > keep)).all():
            where = and_(TrackRevision.project_id == p.id, TrackRevision.track_guid == t.guid,
                         TrackRevision.rev <= t.head_rev - keep)
            n, b = db.execute(select(func.count(), func.coalesce(func.sum(func.octet_length(TrackRevision.chunk)), 0))
                              .where(where)).one()
            report.revisions_deleted += n
            freed += b
            db.execute(delete(TrackRevision).where(where))

    # Blob GC: unreferenced blobs past the grace period (uploads happen before the push that references them).
    db.flush()
    grace = now() - timedelta(hours=settings.blob_grace_hours)
    referenced = exists().where(TrackRevision.project_id == Blob.project_id,
                                Blob.sha256 == func.any(TrackRevision.media_hashes))
    companion_of_referenced = exists().where(
        BlobVariant.project_id == Blob.project_id, BlobVariant.wav_sha == Blob.sha256,
        exists().where(TrackRevision.project_id == BlobVariant.project_id,
                       BlobVariant.ogg_sha == func.any(TrackRevision.media_hashes)))
    orphans = db.scalars(select(Blob).where(Blob.project_id == p.id, Blob.created_at < grace, ~referenced,
                                            ~companion_of_referenced)).all()
    for blob in orphans:
        freed += blob.size
        report.blob_rows_deleted += 1
        db.delete(blob)

    if freed or orphans:
        p.storage_bytes = max(0, p.storage_bytes - freed)
        report.bytes_freed += freed
        report.projects_touched.append(str(p.id))


def purge(sm: sessionmaker, store, settings: Settings, dry_run: bool = True) -> PurgeReport:
    report = PurgeReport(dry_run=dry_run)
    with sm() as db:
        ids = db.scalars(select(Project.id)).all()
    for pid in ids:
        with sm() as db:
            p = db.scalar(select(Project).where(Project.id == pid).with_for_update())
            if p is None:
                continue
            _purge_project(db, p, settings, report)
            db.rollback() if dry_run else db.commit()

    # Physical sweep: files no project references any more.
    with sm() as db:
        known = set(db.scalars(select(Blob.sha256).distinct()))
    cutoff = time.time() - settings.blob_grace_hours * 3600
    for sha, path in store.list_files():
        if sha in known or path.stat().st_mtime > cutoff:
            continue
        report.files_deleted += 1
        if not dry_run:
            store.delete(sha)
    return report
