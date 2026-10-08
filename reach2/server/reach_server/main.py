from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from starlette.middleware.sessions import SessionMiddleware

from . import auth_routes, projects, sync
from .config import DEFAULT_SECRET, Settings
from .deps import RateLimiter
from .google import GoogleProvider
from .models import Base
from .storage import FilesystemStore


def create_app(settings: Settings | None = None, google=None, store=None) -> FastAPI:
    s = settings or Settings()
    if s.session_secret == DEFAULT_SECRET and not s.dev_login:
        raise RuntimeError("Set REACH_SESSION_SECRET to a long random value")

    engine = create_engine(s.database_url, pool_pre_ping=True)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if s.auto_create_tables:
            Base.metadata.create_all(engine)
        yield
        engine.dispose()

    app = FastAPI(title="Reach", lifespan=lifespan)
    app.state.settings = s
    app.state.engine = engine
    app.state.sessionmaker = sessionmaker(engine, expire_on_commit=False)
    app.state.store = store or FilesystemStore(s.blob_dir)
    app.state.limiter = RateLimiter()
    if google is None and s.google_client_id and s.google_client_secret:
        google = GoogleProvider(s.google_client_id, s.google_client_secret,
                                f"{s.public_url}/auth/google/callback")
    app.state.google = google

    app.add_middleware(SessionMiddleware, secret_key=s.session_secret, same_site="lax",
                       https_only=(s.public_url.startswith("https") if s.cookie_secure is None else s.cookie_secure),
                       max_age=3600)
    app.include_router(auth_routes.router)
    app.include_router(projects.router)
    app.include_router(sync.router)

    @app.get("/healthz")
    def healthz():
        return {"ok": True}

    return app


def app_factory() -> FastAPI:  # uvicorn --factory reach_server.main:app_factory
    return create_app()
