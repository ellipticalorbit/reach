import html
import secrets
import uuid
from datetime import timedelta
from urllib.parse import quote

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from .deps import current_user, get_db, hash_token, new_token, rate_limit
from .google import GoogleError
from .models import ApiToken, DeviceAuth, User, now

router = APIRouter()
USER_CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ23456789"


def page(title: str, body: str, status: int = 200) -> HTMLResponse:
    return HTMLResponse(f"""<!doctype html><meta charset=utf-8><title>{html.escape(title)}</title>
<body style="font-family:system-ui;max-width:32rem;margin:4rem auto;padding:0 1rem">
<h2>Reach</h2>{body}</body>""", status_code=status)


def safe_next(n: str | None) -> str:
    return n if n and n.startswith("/") and not n.startswith("//") else "/device"


def new_user_code() -> str:
    c = "".join(secrets.choice(USER_CODE_ALPHABET) for _ in range(8))
    return c[:4] + "-" + c[4:]


# ---- API (used by the REAPER plugin) -------------------------------------------------

class DeviceStart(BaseModel):
    label: str = Field("", max_length=100)


@router.post("/auth/device", dependencies=[Depends(rate_limit("device", 20, 60))])
def device_start(body: DeviceStart, request: Request, db: Session = Depends(get_db)):
    s = request.app.state.settings
    device_code = secrets.token_urlsafe(32)
    user_code = new_user_code()
    db.add(DeviceAuth(device_code_hash=hash_token(device_code), user_code=user_code, label=body.label,
                      expires_at=now() + timedelta(seconds=s.device_code_ttl_s)))
    db.commit()
    url = f"{s.public_url}/device"
    return {"device_code": device_code, "user_code": user_code, "verification_url": url,
            "verification_url_complete": f"{url}?user_code={user_code}",
            "interval": s.device_poll_interval_s, "expires_in": s.device_code_ttl_s}


class DevicePoll(BaseModel):
    device_code: str


@router.post("/auth/device/token", dependencies=[Depends(rate_limit("devpoll", 120, 60))])
def device_token(body: DevicePoll, db: Session = Depends(get_db)):
    d = db.scalar(select(DeviceAuth).where(DeviceAuth.device_code_hash == hash_token(body.device_code))
                  .with_for_update())
    if d is None or d.status == "consumed":
        raise HTTPException(400, {"error": "invalid_grant"})
    if d.expires_at < now():
        raise HTTPException(400, {"error": "expired_token"})
    if d.status == "pending":
        raise HTTPException(400, {"error": "authorization_pending"})
    if d.status == "denied":
        raise HTTPException(400, {"error": "access_denied"})
    token = new_token()
    db.add(ApiToken(user_id=d.user_id, token_hash=hash_token(token), label=d.label))
    d.status = "consumed"
    db.commit()
    return {"access_token": token, "token_type": "bearer"}


@router.get("/me")
def me(user: User = Depends(current_user)):
    return {"id": str(user.id), "email": user.email, "display_name": user.display_name}


class ProfileUpdate(BaseModel):
    display_name: str = Field(min_length=1, max_length=60)


@router.patch("/me")
def update_me(body: ProfileUpdate, user: User = Depends(current_user), db: Session = Depends(get_db)):
    user.display_name = body.display_name.strip()
    db.commit()
    return {"id": str(user.id), "email": user.email, "display_name": user.display_name}


@router.get("/tokens")
def list_tokens(user: User = Depends(current_user), db: Session = Depends(get_db)):
    toks = db.scalars(select(ApiToken).where(ApiToken.user_id == user.id, ApiToken.revoked_at.is_(None))
                      .order_by(ApiToken.created_at)).all()
    return [{"id": str(t.id), "label": t.label, "created_at": t.created_at, "last_used_at": t.last_used_at}
            for t in toks]


@router.delete("/tokens/{token_id}", status_code=204)
def revoke_token(token_id: uuid.UUID, user: User = Depends(current_user), db: Session = Depends(get_db)):
    t = db.get(ApiToken, token_id)
    if t is None or t.user_id != user.id:
        raise HTTPException(404, "token not found")
    t.revoked_at = now()
    db.commit()


# ---- Browser pages (device approval + Google sign-in) --------------------------------

def _session_user(request: Request, db: Session) -> User | None:
    uid = request.session.get("user_id")
    u = db.get(User, uuid.UUID(uid)) if uid else None
    return None if (u is None or u.banned) else u


def _pending(db: Session, code: str) -> DeviceAuth | None:
    d = db.scalar(select(DeviceAuth).where(DeviceAuth.user_code == code.strip().upper()))
    return d if d and d.status == "pending" and d.expires_at > now() else None


@router.get("/device", response_class=HTMLResponse)
def device_page(request: Request, user_code: str = "", db: Session = Depends(get_db)):
    if not user_code:
        return page("Connect REAPER", """<p>Enter the code shown in REAPER.</p>
<form method=get><input name=user_code placeholder="ABCD-1234" autofocus>
<button>Continue</button></form>""")
    d = _pending(db, user_code)
    if d is None:
        return page("Connect REAPER", "<p>That code is invalid or has expired.</p>"
                    "<p><a href=/device>Try again</a></p>", 400)
    user = _session_user(request, db)
    if user is None:
        nxt = quote(f"/device?user_code={d.user_code}")
        login = f"/auth/google/login?next={nxt}"
        dev = (f'<p><a href="/auth/dev-login?next={nxt}">Dev login</a></p>'
               if request.app.state.settings.dev_login else "")
        return page("Sign in", f"<p>Sign in to connect <b>{html.escape(d.label or 'REAPER')}</b>.</p>"
                    f'<p><a href="{login}">Sign in with Google</a></p>{dev}')
    csrf = request.session.setdefault("csrf", secrets.token_urlsafe(16))
    return page("Approve", f"""<p>Signed in as <b>{html.escape(user.email)}</b>.</p>
<p>Allow <b>{html.escape(d.label or 'REAPER')}</b> (code <code>{d.user_code}</code>) to sync as you?</p>
<form method=post action=/device/approve>
<input type=hidden name=user_code value="{d.user_code}"><input type=hidden name=csrf value="{csrf}">
<button name=action value=approve>Approve</button> <button name=action value=deny>Deny</button></form>""")


@router.post("/device/approve", response_class=HTMLResponse)
def device_approve(request: Request, user_code: str = Form(), action: str = Form(), csrf: str = Form(),
                   db: Session = Depends(get_db)):
    user = _session_user(request, db)
    if user is None or not secrets.compare_digest(csrf, request.session.get("csrf", "")):
        raise HTTPException(403, "not signed in")
    d = _pending(db, user_code)
    if d is None:
        return page("Connect REAPER", "<p>That code is invalid or has expired.</p>", 400)
    if action == "approve":
        d.status, d.user_id = "approved", user.id
        msg = "Approved. You can return to REAPER."
    else:
        d.status = "denied"
        msg = "Denied."
    db.commit()
    return page("Done", f"<p>{msg}</p>")


def _login_user(request: Request, db: Session, sub: str, email: str, name: str) -> User:
    u = db.scalar(select(User).where(User.google_sub == sub))
    if u is None:
        u = User(google_sub=sub, email=email, display_name=name[:60])
        db.add(u)
    else:
        u.email = email
    if u.banned:
        raise HTTPException(403, "account disabled")
    db.commit()
    request.session["user_id"] = str(u.id)
    return u


@router.get("/auth/google/login", dependencies=[Depends(rate_limit("glogin", 30, 60))])
def google_login(request: Request, next: str = "/device"):
    g = request.app.state.google
    if g is None:
        raise HTTPException(503, "Google sign-in is not configured")
    state = secrets.token_urlsafe(16)
    request.session["oauth_state"], request.session["oauth_next"] = state, safe_next(next)
    return RedirectResponse(g.authorization_url(state))


@router.get("/auth/google/callback")
def google_callback(request: Request, code: str = "", state: str = "", db: Session = Depends(get_db)):
    g = request.app.state.google
    expected = request.session.pop("oauth_state", None)
    if g is None or not expected or not secrets.compare_digest(state, expected):
        raise HTTPException(400, "invalid state")
    try:
        c = g.exchange(code)
    except GoogleError as e:
        raise HTTPException(400, str(e))
    _login_user(request, db, c["sub"], c["email"], c["name"])
    return RedirectResponse(safe_next(request.session.pop("oauth_next", None)))


@router.get("/auth/dev-login")
def dev_login(request: Request, email: str = "dev@example.com", name: str = "", next: str = "/device",
              db: Session = Depends(get_db)):
    """Local testing only (REACH_DEV_LOGIN=true): sign in as any email without Google."""
    if not request.app.state.settings.dev_login:
        raise HTTPException(404)
    _login_user(request, db, "dev:" + email.lower(), email, name or email.split("@")[0])
    return RedirectResponse(safe_next(next))
