import uuid
from datetime import datetime, timezone

from sqlalchemy import (BigInteger, Boolean, DateTime, ForeignKey, ForeignKeyConstraint,
                        Float, Index, Integer, String, Text, UniqueConstraint, Uuid)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


def now() -> datetime:
    return datetime.now(timezone.utc)


class Base(DeclarativeBase):
    pass


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    google_sub: Mapped[str] = mapped_column(String, unique=True)
    email: Mapped[str] = mapped_column(String)
    display_name: Mapped[str] = mapped_column(String)
    banned: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class ApiToken(Base):
    __tablename__ = "api_tokens"
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    token_hash: Mapped[str] = mapped_column(String, unique=True)
    label: Mapped[str] = mapped_column(String, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


class DeviceAuth(Base):
    """RFC 8628-style device authorisation: plugin polls, user approves in browser."""
    __tablename__ = "device_auths"
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    device_code_hash: Mapped[str] = mapped_column(String, unique=True)
    user_code: Mapped[str] = mapped_column(String, unique=True)
    label: Mapped[str] = mapped_column(String, default="")
    status: Mapped[str] = mapped_column(String, default="pending")  # pending|approved|denied|consumed
    user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Project(Base):
    __tablename__ = "projects"
    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String)
    created_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    seq: Mapped[int] = mapped_column(BigInteger, default=0)  # last assigned change sequence
    join_code: Mapped[str] = mapped_column(String, unique=True)
    storage_bytes: Mapped[int] = mapped_column(BigInteger, default=0)  # chunks + blobs
    # None = inherit server defaults. Otherwise e.g.
    # {"deleted_track_days": 90, "max_revisions_per_track": 50} (null value = keep forever)
    retention: Mapped[dict | None] = mapped_column(JSONB, nullable=True)


class Member(Base):
    __tablename__ = "members"
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    role: Mapped[str] = mapped_column(String)  # owner|editor|viewer
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class Track(Base):
    """Current state of a track; history lives in track_revisions."""
    __tablename__ = "tracks"
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id", ondelete="CASCADE"), primary_key=True)
    guid: Mapped[str] = mapped_column(String, primary_key=True)
    owner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    head_rev: Mapped[int] = mapped_column(Integer)
    head_seq: Mapped[int] = mapped_column(BigInteger)
    deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    __table_args__ = (Index("ix_tracks_project_head_seq", "project_id", "head_seq"),)


class TrackRevision(Base):
    """Append-only. Deletes and restores are revisions too, so nothing is ever lost."""
    __tablename__ = "track_revisions"
    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id", ondelete="CASCADE"))
    track_guid: Mapped[str] = mapped_column(String)
    rev: Mapped[int] = mapped_column(Integer)
    seq: Mapped[int] = mapped_column(BigInteger)
    op: Mapped[str] = mapped_column(String)  # create|update|delete|restore
    chunk: Mapped[str] = mapped_column(Text)
    chunk_hash: Mapped[str] = mapped_column(String)
    parent_guid: Mapped[str | None] = mapped_column(String, nullable=True)
    position: Mapped[float] = mapped_column(Float, default=0.0)
    author_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    media_hashes: Mapped[list[str]] = mapped_column(ARRAY(String), default=list)
    __table_args__ = (
        UniqueConstraint("project_id", "track_guid", "rev"),
        ForeignKeyConstraint(["project_id", "track_guid"], ["tracks.project_id", "tracks.guid"],
                             ondelete="CASCADE", deferrable=True, initially="DEFERRED"),
        Index("ix_revisions_project_seq", "project_id", "seq"),
    )


class Blob(Base):
    __tablename__ = "blobs"
    project_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("projects.id", ondelete="CASCADE"), primary_key=True)
    sha256: Mapped[str] = mapped_column(String(64), primary_key=True)
    size: Mapped[int] = mapped_column(BigInteger)
    ext: Mapped[str] = mapped_column(String, default="ogg", server_default="ogg")  # detected type: ogg | wav
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)


class BlobVariant(Base):
    """High-quality companion: the lossless WAV (wav_sha) of the Ogg (ogg_sha) that chunks reference.
    Both rows must exist in `blobs`; deleting either blob removes the link."""
    __tablename__ = "blob_variants"
    project_id: Mapped[uuid.UUID] = mapped_column(primary_key=True)
    ogg_sha: Mapped[str] = mapped_column(String(64), primary_key=True)
    wav_sha: Mapped[str] = mapped_column(String(64))
    __table_args__ = (
        ForeignKeyConstraint(["project_id", "ogg_sha"], ["blobs.project_id", "blobs.sha256"], ondelete="CASCADE"),
        ForeignKeyConstraint(["project_id", "wav_sha"], ["blobs.project_id", "blobs.sha256"], ondelete="CASCADE"),
        Index("ix_blob_variants_wav", "project_id", "wav_sha"),
    )
