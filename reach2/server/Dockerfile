FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY pyproject.toml alembic.ini ./
COPY reach_server ./reach_server
COPY migrations ./migrations
RUN pip install . && useradd -r -u 1000 reach && mkdir -p /data/blobs && chown -R reach /data
USER reach
EXPOSE 8000
# Apply migrations, then serve. --proxy-headers so rate limits see the real client IP behind Caddy.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn --factory reach_server.main:app_factory --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips='*'"]
