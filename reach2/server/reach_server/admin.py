"""Admin CLI: python -m reach_server.admin <command>"""
import argparse
import json
from dataclasses import asdict

from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import sessionmaker

from .config import Settings
from .models import Project, User
from .retention import purge
from .storage import FilesystemStore


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(prog="reach-admin")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("ban", "unban"):
        sub.add_parser(name).add_argument("email")
    sub.add_parser("stats")
    pg = sub.add_parser("purge", help="apply retention policy + garbage-collect blobs (dry run by default)")
    pg.add_argument("--apply", action="store_true", help="actually delete")
    a = ap.parse_args(argv)

    s = Settings()
    sm = sessionmaker(create_engine(s.database_url))
    if a.cmd in ("ban", "unban"):
        with sm() as db:
            users = db.scalars(select(User).where(func.lower(User.email) == a.email.lower())).all()
            if not users:
                raise SystemExit("no such user")
            for u in users:
                u.banned = a.cmd == "ban"
            db.commit()
        print(f"{a.cmd}ned {a.email}" if a.cmd == "ban" else f"unbanned {a.email}")
    elif a.cmd == "stats":
        with sm() as db:
            print(json.dumps({"users": db.scalar(select(func.count()).select_from(User)),
                              "projects": db.scalar(select(func.count()).select_from(Project)),
                              "storage_bytes": db.scalar(select(func.coalesce(func.sum(Project.storage_bytes), 0)))}))
    elif a.cmd == "purge":
        report = purge(sm, FilesystemStore(s.blob_dir), s, dry_run=not a.apply)
        print(json.dumps(asdict(report), indent=2))


if __name__ == "__main__":
    main()
