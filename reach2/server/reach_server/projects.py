import secrets
import uuid

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .deps import current_user, get_db, project_access, rate_limit
from .models import Member, Project, User

router = APIRouter()
JOIN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def new_join_code() -> str:
    c = "".join(secrets.choice(JOIN_ALPHABET) for _ in range(16))  # ~80 bits
    return "-".join(c[i:i + 4] for i in range(0, 16, 4))


def project_json(p: Project, role: str, include_code: bool = False) -> dict:
    d = {"id": str(p.id), "name": p.name, "seq": p.seq, "role": role,
         "storage_bytes": p.storage_bytes, "created_at": p.created_at}
    if include_code:
        d["join_code"] = p.join_code
    return d


class ProjectCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)


@router.post("/projects", status_code=201)
def create_project(body: ProjectCreate, request: Request, user: User = Depends(current_user),
                   db: Session = Depends(get_db)):
    s = request.app.state.settings
    owned = db.scalar(select(func.count()).select_from(Member)
                      .where(Member.user_id == user.id, Member.role == "owner"))
    if owned >= s.max_projects_per_user:
        raise HTTPException(403, "project limit reached")
    p = Project(name=body.name.strip(), created_by=user.id, join_code=new_join_code())
    db.add(p)
    db.flush()
    db.add(Member(project_id=p.id, user_id=user.id, role="owner"))
    db.commit()
    return project_json(p, "owner", include_code=True)


@router.get("/projects")
def list_projects(user: User = Depends(current_user), db: Session = Depends(get_db)):
    rows = db.execute(select(Project, Member.role).join(Member, Member.project_id == Project.id)
                      .where(Member.user_id == user.id).order_by(Project.created_at)).all()
    return [project_json(p, role) for p, role in rows]


@router.get("/projects/{project_id}")
def get_project(m: Member = Depends(project_access("viewer")), db: Session = Depends(get_db)):
    p = db.get(Project, m.project_id)
    return project_json(p, m.role, include_code=m.role == "owner")


class JoinBody(BaseModel):
    code: str


@router.post("/join", dependencies=[Depends(rate_limit("join", 10, 60))])
def join(body: JoinBody, user: User = Depends(current_user), db: Session = Depends(get_db)):
    p = db.scalar(select(Project).where(Project.join_code == body.code.strip().upper()))
    if p is None:
        raise HTTPException(404, "invalid join code")
    m = db.get(Member, (p.id, user.id))
    if m is None:
        m = Member(project_id=p.id, user_id=user.id, role="editor")
        db.add(m)
        db.commit()
    return project_json(p, m.role)


@router.post("/projects/{project_id}/join-code/rotate")
def rotate_join_code(m: Member = Depends(project_access("owner")), db: Session = Depends(get_db)):
    p = db.get(Project, m.project_id)
    p.join_code = new_join_code()
    db.commit()
    return {"join_code": p.join_code}


@router.get("/projects/{project_id}/members")
def list_members(m: Member = Depends(project_access("viewer")), db: Session = Depends(get_db)):
    rows = db.execute(select(Member, User).join(User, User.id == Member.user_id)
                      .where(Member.project_id == m.project_id).order_by(Member.joined_at)).all()
    return [{"user_id": str(u.id), "display_name": u.display_name, "email": u.email if m.role == "owner" else None,
             "role": mem.role} for mem, u in rows]


class RoleBody(BaseModel):
    role: str = Field(pattern="^(editor|viewer)$")


@router.patch("/projects/{project_id}/members/{user_id}")
def set_role(user_id: uuid.UUID, body: RoleBody, m: Member = Depends(project_access("owner")),
             db: Session = Depends(get_db)):
    target = db.get(Member, (m.project_id, user_id))
    if target is None:
        raise HTTPException(404, "member not found")
    if target.role == "owner":
        raise HTTPException(400, "cannot change the owner's role")
    target.role = body.role
    db.commit()
    return {"user_id": str(user_id), "role": target.role}


@router.delete("/projects/{project_id}/members/{user_id}", status_code=204)
def remove_member(user_id: uuid.UUID, m: Member = Depends(project_access("viewer")),
                  db: Session = Depends(get_db)):
    """Owners can remove anyone but themselves; any member can leave (except the owner)."""
    if user_id != m.user_id and m.role != "owner":
        raise HTTPException(403, "requires owner role")
    target = db.get(Member, (m.project_id, user_id))
    if target is None:
        raise HTTPException(404, "member not found")
    if target.role == "owner":
        raise HTTPException(400, "the owner cannot be removed")
    db.delete(target)
    db.commit()
