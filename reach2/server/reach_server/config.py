from pydantic_settings import BaseSettings, SettingsConfigDict

MiB = 1024 * 1024
GiB = 1024 * MiB
DEFAULT_SECRET = "dev-insecure-change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="REACH_", env_file=".env", extra="ignore", env_ignore_empty=True)

    database_url: str = "postgresql+psycopg://reach:reach@localhost:5432/reach"
    blob_dir: str = "./data/blobs"
    public_url: str = "http://localhost:8000"
    session_secret: str = DEFAULT_SECRET
    # Secure flag on the login cookie. None = automatic (on when public_url is https). Browsers drop Secure
    # cookies over plain http, so set this to false only if you serve over http (testing).
    cookie_secure: bool | None = None

    # Google sign-in. Leave unset to disable (use dev_login locally).
    google_client_id: str | None = None
    google_client_secret: str | None = None
    # Local testing only: lets you "sign in" as any email without Google.
    dev_login: bool = False

    # Limits (public-facing hardening)
    max_blob_bytes: int = 2 * GiB  # raw WAV recordings can be large
    max_chunk_bytes: int = 2 * MiB
    project_quota_bytes: int | None = 5 * GiB  # None = unlimited
    max_projects_per_user: int = 20
    max_tracks_per_project: int = 500
    max_push_tracks: int = 200
    rate_limit_enabled: bool = True

    device_code_ttl_s: int = 600
    device_poll_interval_s: int = 3

    # Retention. None = keep forever (current default). Per-project override lives
    # in projects.retention.
    retention_deleted_track_days: int | None = None
    retention_max_revisions_per_track: int | None = None
    # Blobs younger than this are never garbage collected (uploads race pushes).
    blob_grace_hours: int = 24

    # Normally the schema is managed by Alembic (see entrypoint); this is a dev convenience.
    auto_create_tables: bool = False
