#!/usr/bin/env bash
# Starts the dev server (docker compose, dev login enabled) and runs the Lua integration tests against it.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/opt/lua@5.4/bin:$PATH"
if ! curl -sf localhost:8000/healthz >/dev/null; then
  (cd ../server && docker compose up -d --build)
  for _ in $(seq 1 60); do curl -sf localhost:8000/healthz >/dev/null && break; sleep 1; done
fi
lua5.4 tests/run.lua
lua5.4 tests/run_fake_reaper.lua
