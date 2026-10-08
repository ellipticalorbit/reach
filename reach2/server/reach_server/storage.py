"""Blob storage behind a small interface. Filesystem backend now; an S3 backend (presigned URLs) can implement
the same methods later. Files are stored as <aa>/<bb>/<sha256>.<ext> where ext is the detected media type."""
import os
import tempfile
from pathlib import Path
from typing import Protocol


class Upload(Protocol):
    def write(self, data: bytes) -> None: ...
    def commit(self, sha256: str, ext: str) -> None: ...
    def abort(self) -> None: ...


class BlobStore(Protocol):
    def exists(self, sha256: str, ext: str = "ogg") -> bool: ...
    def new_upload(self) -> Upload: ...
    def path(self, sha256: str, ext: str = "ogg") -> Path | None: ...  # local file, if backend has one
    def delete(self, sha256: str) -> None: ...  # every extension
    def list_files(self) -> list[tuple[str, Path]]: ...


class _FsUpload:
    def __init__(self, store: "FilesystemStore"):
        self.store = store
        fd, self.tmp = tempfile.mkstemp(dir=store.tmp_dir)
        self.f = os.fdopen(fd, "wb")

    def write(self, data: bytes) -> None:
        self.f.write(data)

    def commit(self, sha256: str, ext: str) -> None:
        self.f.close()
        dest = self.store.path(sha256, ext)
        if dest.exists():
            os.unlink(self.tmp)
            return
        dest.parent.mkdir(parents=True, exist_ok=True)
        os.replace(self.tmp, dest)

    def abort(self) -> None:
        self.f.close()
        try:
            os.unlink(self.tmp)
        except FileNotFoundError:
            pass


class FilesystemStore:
    def __init__(self, root: str):
        self.root = Path(root)
        self.tmp_dir = self.root / ".tmp"
        self.tmp_dir.mkdir(parents=True, exist_ok=True)

    def path(self, sha256: str, ext: str = "ogg") -> Path:
        return self.root / sha256[:2] / sha256[2:4] / f"{sha256}.{ext}"

    def exists(self, sha256: str, ext: str = "ogg") -> bool:
        return self.path(sha256, ext).exists()

    def new_upload(self) -> Upload:
        return _FsUpload(self)

    def delete(self, sha256: str) -> None:
        for p in self.root.glob(f"{sha256[:2]}/{sha256[2:4]}/{sha256}.*"):
            p.unlink(missing_ok=True)

    def list_files(self) -> list[tuple[str, Path]]:
        return [(p.stem, p) for p in self.root.glob("??/??/*") if p.is_file()]
