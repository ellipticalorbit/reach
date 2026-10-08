"""Validation of track chunks and uploaded audio. Chunks are REAPER XML that other
users will load into their sessions, so be strict about what they may reference."""
import hashlib
import re

GUID_RE = re.compile(r"^\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
MEDIA_PREFIX = "reach-media://"
MEDIA_RE = re.compile(r"^reach-media://([0-9a-f]{64})\.ogg$")
_FILE_RE = re.compile(r'^\s*FILE\s+(?:"([^"]*)"|(\S+))', re.MULTILINE)
# REAPER's GetTrackStateChunk writes a bare "<TRACK" and puts the guid on a TRACKID line; project files
# use "<TRACK {guid}". Accept both.
_HEADER_RE = re.compile(r"^<TRACK(?:[ \t]+(\{[0-9A-Fa-f-]{36}\}))?[ \t]*(?:\r?\n|$)")
_TRACKID_RE = re.compile(r"^[ \t]*TRACKID[ \t]+(\{[0-9A-Fa-f-]{36}\})", re.MULTILINE)
_NAME_RE = re.compile(r'^\s*NAME\s+(?:"([^"]*)"|(\S+))', re.MULTILINE)


class ChunkError(ValueError):
    pass


def normalise_guid(guid: str) -> str:
    g = guid.strip().upper()
    if not GUID_RE.match(g):
        raise ChunkError(f"invalid track guid: {guid!r}")
    return g


def chunk_hash(chunk: str) -> str:
    return hashlib.sha256(chunk.encode("utf-8")).hexdigest()


def track_name(chunk: str) -> str:
    m = _NAME_RE.search(chunk)
    return (m.group(1) if m and m.group(1) is not None else (m.group(2) if m else "")) or ""


def validate_chunk(chunk: str, guid: str, max_bytes: int) -> list[str]:
    """Returns the sorted media sha256s the chunk references. Raises ChunkError."""
    if len(chunk.encode("utf-8")) > max_bytes:
        raise ChunkError("chunk too large")
    if "\x00" in chunk:
        raise ChunkError("chunk contains NUL")
    stripped = chunk.strip()
    m = _HEADER_RE.match(stripped)
    if not m or not stripped.endswith(">"):
        raise ChunkError("chunk must be a <TRACK ...> block")
    found = m.group(1) or (_TRACKID_RE.search(stripped).group(1) if _TRACKID_RE.search(stripped) else None)
    if found is None:
        raise ChunkError("chunk has no track guid (expected '<TRACK {guid}' or a TRACKID line)")
    if found.upper() != guid:
        raise ChunkError("chunk guid does not match track guid")
    hashes = set()
    for fm in _FILE_RE.finditer(chunk):
        path = fm.group(1) if fm.group(1) is not None else fm.group(2)
        mm = MEDIA_RE.match(path)
        if not mm:
            raise ChunkError(f"media must be a {MEDIA_PREFIX}<sha256>.ogg reference, got {path!r}")
        hashes.add(mm.group(1))
    return sorted(hashes)


def check_ogg(head: bytes) -> None:
    """Cheap sanity check on the first bytes of an upload (Ogg Vorbis/Opus only)."""
    if not head.startswith(b"OggS"):
        raise ChunkError("not an Ogg file")
    if b"vorbis" not in head[:128] and b"OpusHead" not in head[:128]:
        raise ChunkError("only Ogg Vorbis/Opus audio is accepted")
