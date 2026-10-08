# Reach server

FastAPI + Postgres. Audio blobs live on the filesystem (`REACH_BLOB_DIR`) behind the `BlobStore` interface in
`reach_server/storage.py` (an S3 backend can be added without touching the routes).

## Run locally
```
docker compose up --build        # http://localhost:8000  (API docs at /docs); needs Docker Compose v2
```
Local mode enables `REACH_DEV_LOGIN`, so on the device-approval page you can use "Dev login" instead of Google.
Never enable it on a public server.

## Tests
```
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
scripts/test.sh            # starts a throwaway Postgres container, runs pytest
```

## Deploy
1. Create a Google OAuth client (Web application). Authorised redirect URI: `https://<domain>/auth/google/callback`.
2. `cp .env.example .env` and fill it in (`openssl rand -hex 32` for the session secret).
3. `docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build`
   (Caddy gets the TLS certificate automatically; point DNS at the server first.)

Migrations run automatically on container start (`alembic upgrade head`). After changing models:
`REACH_DATABASE_URL=... alembic revision --autogenerate -m "..."`.

## Admin
```
docker compose exec api python -m reach_server.admin stats
docker compose exec api python -m reach_server.admin ban someone@example.com
docker compose exec api python -m reach_server.admin purge            # dry run
docker compose exec api python -m reach_server.admin purge --apply
```
Retention defaults to keep-everything-forever. To change it, set `REACH_RETENTION_DELETED_TRACK_DAYS` and/or
`REACH_RETENTION_MAX_REVISIONS_PER_TRACK`, or set `projects.retention` JSON per project; then run `purge`
(e.g. from cron). Unreferenced blobs are garbage-collected after `REACH_BLOB_GRACE_HOURS`.

## API summary
| | |
|---|---|
| `POST /auth/device`, `POST /auth/device/token` | plugin login (device flow); user approves at `/device` via Google |
| `GET/PATCH /me`, `GET/DELETE /tokens` | profile, device tokens |
| `POST /projects`, `GET /projects[/{id}]`, `POST /join` | create (returns join code), list, join |
| `GET/PATCH/DELETE /projects/{id}/members...`, `POST .../join-code/rotate` | membership |
| `POST .../blobs/missing`, `PUT/GET .../blobs/{sha256}` | content-addressed OGG upload/download |
| `POST .../push` | per-track `{guid, base_rev, op, chunk, parent_guid, position}`; result per track: accepted / unchanged / conflict |
| `GET .../changes?since=N` | head state of every track changed since seq N (incl. deletions) |
| `GET .../tracks?state=live\|deleted\|all`, `.../tracks/{guid}/revisions[/{rev}]`, `POST .../tracks/{guid}/restore` | history and undelete |

## Troubleshooting
* `KeyError: 'ContainerConfig'` from `/usr/bin/docker-compose`: that is the old Python Compose 1.29 (note the
  hyphen) failing against a newer Docker. Install Compose v2 (`apt install docker-compose-plugin` from Docker's
  apt repo) and use `docker compose` (with a space). Quick workaround on v1: `docker-compose down` (never
  `-v`, that deletes the database) and then `up -d --build` again.
