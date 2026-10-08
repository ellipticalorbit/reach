# Reach 2

Web-service-based replacement for the git/rsync Reach sync. See [docs/DESIGN.md](docs/DESIGN.md).

- `server/` – FastAPI + Postgres service (Docker Compose, Caddy for TLS)
- `plugin/` – REAPER Lua client (uses `curl` for HTTP)
- `docs/`   – design notes

The original git-based scripts in the parent directory are untouched until the plugin replaces them.
