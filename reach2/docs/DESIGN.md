# Reach 2 design

## Decisions
- Client: Lua inside REAPER, HTTP via `curl` (`reaper.ExecProcess`; detached + polled for uploads). No Python.
- Server: FastAPI + Postgres, in Docker Compose with Caddy for HTTPS.
- Blobs (transcoded OGG): behind a storage interface. Filesystem backend first, S3-compatible (presigned URLs) later. Never stored in Postgres.
- Auth: Google sign-in via device-style flow. Plugin gets a Reach API token (stored hashed server-side, revocable, per device); Google tokens never reach the plugin. Users keyed on Google `sub`.
- Sharing: project join code; redeeming requires sign-in and adds the user as a member (owner/editor/read-only).

## Data model
- Project: id, name, monotonically increasing `seq`.
- Track: REAPER track GUID, owner, parent folder GUID, index, current revision pointer.
- `track_revisions`: append-only (track_guid, rev, chunk, hash, author, seq, created_at, op = create|update|delete|restore).
- Media blobs: sha256 of OGG, size; dedupe within a project only; chunk media refs rewritten to `reach-media://<sha256>.ogg`.
- Local state in the .rpp ext-state: server URL, project_id, join code, last_pulled_seq, per-track base_rev/base_hash. Token lives in user config, not the project.

## Sync
- Push: send changed tracks with `base_rev`; server reports missing blobs, client uploads them, then atomic push. Per-track accept or conflict (409-style result per track).
- Pull: `changes?since=seq`, download missing blobs, apply chunks, relink media.
- Conflicts are per track via a three-way compare (base/local/remote). Both-changed => prompt: keep mine / take theirs / keep both (duplicate track "Name (conflict - user)" with new GUID). Delete vs edit counts as conflict.

## History and undelete
- Deletes are revisions, not removals. Restore creates a new `restore` revision (optionally from a specific rev). Restore flows through normal sync.
- Retention is a single `RetentionPolicy` (None = keep forever, the current default), server-wide env defaults with optional per-project override. Purge/blob-GC job exists but is a no-op under the default; has a dry-run mode.
- Per-project storage bytes are tracked from day one; quotas enforced later.

## Public-facing hardening
Quotas and rate limits, Ogg magic-byte/size validation, server-side sha256 verification, chunk validation (reject absolute paths / non reach-media sources), no cross-project dedupe leakage, admin CLI for bans/deletes.

## Build order
1. Server with tests (real Postgres, Google stubbed)
2. Lua client library + tests against the server
3. REAPER integration (chunk extract/apply, media relink, UI)
4. Conflict UI and keep-both flow, deleted-tracks / history UI

## Needed from owner (non-blocking)
Google OAuth client ID/secret and a domain name for the redirect URI.
