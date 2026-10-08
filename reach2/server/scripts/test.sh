#!/usr/bin/env bash
# Runs the test suite against a throwaway Postgres container.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=reach-test-pg
docker rm -f $NAME >/dev/null 2>&1 || true
docker run -d --name $NAME -e POSTGRES_USER=reach -e POSTGRES_PASSWORD=reach -e POSTGRES_DB=reach_test \
  -p 55432:5432 --tmpfs /var/lib/postgresql/data postgres:16-alpine >/dev/null
trap 'docker rm -f $NAME >/dev/null 2>&1' EXIT
for _ in $(seq 1 40); do docker exec $NAME pg_isready -U reach -d reach_test >/dev/null 2>&1 && break; sleep 0.5; done
sleep 1
export TEST_DATABASE_URL="postgresql+psycopg://reach:reach@localhost:55432/reach_test"
${PYTHON:-.venv/bin/python} -m pytest "$@"
