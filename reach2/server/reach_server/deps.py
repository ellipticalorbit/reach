import hashlib
import secrets
import threading
import time
import uuid
from collections import defaultdict, deque
from datetime import timedelta

from fastapi import Depends, HTTPException, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .models import ApiToken, Member, User, now

ROLE_RANK = {"viewer": 1, "editor": 2, "owner": 3}
bearer = HTTPBearer(auto_error=False)


def get_db(request: Request):
    session: Session = request.app.state.sessionmaker()
    try:
        yield session
    finally:
        session.close()


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def new_token() -> str:
    return "rch_" + secrets.token_urlsafe(32)


def current_user(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(bearer),
                 db: Session = Depends(get_db)) -> User:
    if creds is None:
        raise HTTPException(401, "missing bearer token", headers={"WWW-Authenticate": "Bearer"})
    tok = db.scalar(select(ApiToken).where(ApiToken.token_hash == hash_token(creds.credentials),
                                           ApiToken.revoked_at.is_(None)))
    if tok is None:
        raise HTTPException(401, "invalid token", headers={"WWW-Authenticate": "Bearer"})
    user = db.get(User, tok.user_id)
    if user is None or user.banned:
        raise HTTPException(403, "account disabled")
    if tok.last_used_at is None or now() - tok.last_used_at > timedelta(minutes=5):
        tok.last_used_at = now()
        db.commit()
    request.state.token_id = tok.id
    return user


def project_access(min_role: str):
    """Dependency factory. Non-members get 404 so project ids can't be probed."""
    def dep(project_id: uuid.UUID, user: User = Depends(current_user),
            db: Session = Depends(get_db)) -> Member:
        m = db.get(Member, (project_id, user.id))
        if m is None:
            raise HTTPException(404, "project not found")
        if ROLE_RANK[m.role] < ROLE_RANK[min_role]:
            raise HTTPException(403, f"requires {min_role} role")
        return m
    return dep


class RateLimiter:
    def __init__(self):
        self.hits: dict[str, deque] = defaultdict(deque)
        self.lock = threading.Lock()

    def check(self, key: str, limit: int, window_s: int) -> bool:
        t = time.monotonic()
        with self.lock:
            q = self.hits[key]
            while q and q[0] <= t - window_s:
                q.popleft()
            if len(q) >= limit:
                return False
            q.append(t)
            return True


def rate_limit(name: str, limit: int, window_s: int):
    def dep(request: Request):
        if not request.app.state.settings.rate_limit_enabled:
            return
        ip = request.client.host if request.client else "-"
        if not request.app.state.limiter.check(f"{name}:{ip}", limit, window_s):
            raise HTTPException(429, "too many requests", headers={"Retry-After": str(window_s)})
    return dep
