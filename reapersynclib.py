# -*- coding: utf-8 -*-
# reapersynclib.py - Python port of reach Lua library for REAPER

from __future__ import annotations
import os
import sys
import time
import platform
import subprocess
from typing import Dict, Tuple, List, Optional

# REAPER Python API (RPR_*)
try:
    # REAPER embeds this into Python environment
    from reaper_python import *  # noqa: F401,F403
except Exception:
    # Allow basic linting outside REAPER
    def __getattr__(name):
        raise RuntimeError("This module must be run inside REAPER's Python with reaper_python available")


# -------- Globals and OS setup --------

def _get_os_info() -> Tuple[str, str, str]:
    os_name = RPR_GetOS()
    if os_name not in ("Win32", "Win64"):
        sep = "/"
        os_short = "linux"
        prefix = "xterm -e "
        if os_name in ("OSX32", "OSX64", "macOS-arm64"):
            prefix = "zsh -c "
            os_short = "mac"
    else:
        sep = "\\"
        os_short = "windows"
        prefix = "\"c:\\Program Files\\Git\\git-bash.exe\" -c "
    return sep, os_short, prefix


s, osShortName, prefix = _get_os_info()
basepath = RPR_GetProjectPath(0, "")[0]
scriptPath = RPR_GetResourcePath() + s + "scripts" + s + "reach"
bashScriptPath = "/" + scriptPath.replace("\\", "/").replace(":", "")
ctime = 0.0


# -------- Utilities --------

def println(msg: str) -> None:
    RPR_ShowConsoleMsg(str(msg) + "\n")


def print_(msg: str) -> None:
    RPR_ShowConsoleMsg(str(msg))


def trim(sv: str) -> str:
    return sv.strip()


def _endswith(sv: str, suffix: Optional[str]) -> bool:
    return bool(suffix) and sv.endswith(suffix)


def fix_windows_path(path: str) -> str:
    return "/" + path.replace(":", "").replace("\\", "/")


# -------- Preferences --------

def get_pref_file() -> str:
    kb = RPR_GetResourcePath()
    return kb + s + "Scripts" + s + "syncprefs.ini"


def setup() -> None:
    # Python lacks GetUserInputs directly; use RPR_GetUserInputs
    title = "Setup"
    capt = "Your name,Server,Username,Path"
    ok, vals, _ = RPR_GetUserInputs(title, 4, capt, "")[0:3]
    if not ok or trim(vals) == "":
        RPR_ShowConsoleMsg("Values Unchanged")
        return
    with open(get_pref_file(), "w", encoding="utf-8") as f:
        f.write(vals)


def get_prefs() -> Tuple[str, str, str, str]:
    name = get_pref_file()
    try:
        with open(name, "r", encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        setup()
        with open(name, "r", encoding="utf-8") as f:
            raw = f.read()
    parts = raw.split(",", 3)
    if len(parts) != 4:
        raise RuntimeError("syncprefs.ini is malformed; expected 4 comma-separated values")
    return parts[0], parts[1], parts[2], parts[3]


# -------- Repo and networking helpers (still using external tools) --------

def run_in_mac_terminal(cmd: str) -> int:
    # For parity with Lua: just execute the shell command
    println("Running in mac terminal: " + cmd)
    return os.system(cmd)


def _normalize_path_for_shell(path: str) -> str:
    if RPR_GetOS() in ("Win32", "Win64"):
        return "/" + path.replace(":", "").replace("\\", "/")
    return path


def run_in_path(path: str, cmd: str) -> int:
    if RPR_GetOS() in ("Win32", "Win64"):
        path = _normalize_path_for_shell(path)
    if not _endswith(cmd, ";"):
        cmd = cmd + ";"
    if osShortName == "mac":
        cmd2 = f"set +x;cd '{path}' ; {cmd}"
        return run_in_mac_terminal(cmd2)
    else:
        full = prefix + f"\"set +x;cd '{path}' ; {cmd} echo Press Enter...\""
        println(full)
        return int(RPR_ExecProcess(full, 0)[0])


def run(cmd: str) -> int:
    basepath = RPR_GetProjectPath(0, "")[0]
    return run_in_path(basepath, cmd)


def run_with_output(path: str, cmd: str) -> int:
    if RPR_GetOS() in ("Win32", "Win64"):
        path = _normalize_path_for_shell(path)
    full = prefix + f"\"cd '{path}' ; {cmd} ; echo Press Enter...;  read stuff\""
    println(full)
    return int(RPR_ExecProcess(full, 0)[0])


# -------- Project helpers --------

def get_song_name() -> str:
    name = RPR_GetProjectName(0, "", 2048)[1]
    return name.replace(".rpp", "").replace(".RPP", "")


def get_parts(dirpath: str) -> List[str]:
    out: List[str] = []
    idx = 0
    while True:
        rv, name = RPR_EnumerateSubdirectories(dirpath, idx)[0], RPR_EnumerateSubdirectories(dirpath, idx)[1]
        if name:
            out.append(name)
            idx += 1
        else:
            break
    return out


def exists(dirpath: str, name: str) -> bool:
    idx = 0
    while True:
        _, sub = RPR_EnumerateSubdirectories(dirpath, idx)[0:2]
        if sub:
            if sub == name:
                return True
            idx += 1
        else:
            return False


# -------- Track chunk IO (SWS + native) --------

def get_track_chunk(track) -> Optional[str]:
    if not track:
        return None
    ret, chunk = RPR_GetTrackStateChunk(track, "", False)
    if ret and chunk and len(chunk) < 4194303:
        return chunk
    # fallback to SWS fast string
    fs = RPR_SNM_CreateFastString("")
    ok = RPR_SNM_GetSetObjectState(track, fs, False, False)
    chunk2 = RPR_SNM_GetFastString(fs)
    RPR_SNM_DeleteFastString(fs)
    return chunk2 if ok else chunk2


def set_track_chunk(track, chunk: str) -> bool:
    if not track or chunk is None:
        return False
    return bool(RPR_SetTrackStateChunk(track, chunk, False))


# -------- Track structure helpers --------

def indent_home(index: int) -> None:
    if index > 0:
        track = RPR_GetTrack(0, index - 1)
        val = RPR_GetTrackDepth(track)
        RPR_SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", -1 * val)


def indent(index: int, level: int) -> None:
    if index > 1:
        track = RPR_GetTrack(0, index - 2)
        val = RPR_GetTrackDepth(track)
        RPR_SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", level - val)


def get_index(guid: str) -> int:
    for i in range(int(RPR_GetNumTracks())):
        tr = RPR_GetTrack(0, i)
        if RPR_GetTrackGUID(tr) == guid:
            return i
    return 0


def get_track_by_guid(guid: str):
    for i in range(int(RPR_GetNumTracks())):
        tr = RPR_GetTrack(0, i)
        if RPR_GetTrackGUID(tr) == guid:
            return tr
    return None


# -------- File scanning helpers --------

def get_track_files(basepath_: str, person: str) -> Dict[str, str]:
    idx = 0
    files: Dict[str, str] = {}
    folder = basepath_ + s + "parts" + s + person
    while True:
        _, file = RPR_EnumerateFiles(folder, idx)[0:2]
        if file:
            if file != "properties":
                files[file] = file
            idx += 1
        else:
            break
    return files


def get_tracks_in_part(person: str):
    found = False
    min_idx = -1
    tracks: Dict[str, object] = {}
    max_idx = int(RPR_GetNumTracks()) - 1
    for track_num in range(int(RPR_GetNumTracks())):
        tr = RPR_GetTrack(0, track_num)
        _, title = RPR_GetTrackName(tr, "", 1024)
        if not found:
            if title == person:
                found = True
                parent = tr
                min_idx = track_num
                max_idx = track_num
        else:
            if RPR_GetTrackDepth(tr) <= RPR_GetTrackDepth(parent):
                break
            else:
                max_idx = track_num
    if min_idx != -1:
        for to_delete in range(min_idx, max_idx + 1):
            tr = RPR_GetTrack(0, to_delete)
            tracks[RPR_GetTrackGUID(tr)] = tr
    return tracks, min_idx, max_idx


# -------- Properties (tempo) --------

def write_properties(user: str) -> str:
    base = RPR_GetProjectPath(0, "")[0]
    files = get_parts(base + s + "parts")
    owner: Optional[str] = None
    for file in files:
        path = base + s + "parts" + s + file + s + "properties"
        if os.path.isfile(path):
            owner = file
            break
    if owner is None or owner == user:
        tempo = RPR_Master_GetTempo()
        owner = user
        props_path = base + s + "parts" + s + user + s + "properties"
        os.makedirs(os.path.dirname(props_path), exist_ok=True)
        with open(props_path, "w", encoding="utf-8") as f:
            f.write(f"tempo={tempo}\n")
    return owner or user


def read_properties() -> None:
    base = RPR_GetProjectPath(0, "")[0]
    files = get_parts(base + s + "parts")
    owner: Optional[str] = None
    for file in files:
        path = base + s + "parts" + s + file + s + "properties"
        if os.path.isfile(path):
            owner = file
            break
    if owner:
        props_path = base + s + "parts" + s + owner + s + "properties"
        tempo = None
        try:
            with open(props_path, "r", encoding="utf-8") as f:
                for line in f:
                    if line.startswith("tempo="):
                        tempo = float(line.split("=", 1)[1].strip())
                        break
        except Exception:
            tempo = None
        if tempo is not None:
            RPR_SetCurrentBPM(0, tempo, False)


# -------- Repo ops (git/ssh/rsync) --------

def is_on_server() -> bool:
    name, server, username, root = get_prefs()
    cmd = f"ssh {username}@{server} \"cd {root};ls '{get_song_name()}'\""
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, _ = p.communicate()
    for line in out.decode(errors="ignore").splitlines():
        if line.strip() == "parts":
            return True
    return False


def create_remote_repo() -> None:
    base = RPR_GetProjectPath(0, "")[0]
    name, server, username, root = get_prefs()
    song = get_song_name()
    println(f"Setting up remote repo for {song}")
    cmd = (
        f"ssh {username}@{server} \\\"git config --global init.defaultBranch master;cd {root};"
        f"git init --shared --bare -b master '{song}/parts';"
        f"mkdir -p '{song}/ogg';chmod g+ws '{song}/ogg'\\\""
    )
    run_in_path(base, cmd)


def clone() -> None:
    base = RPR_GetProjectPath(0, "")[0]
    song = get_song_name()
    name, server, username, root = get_prefs()
    cmd = f"ssh {username}@{server} git config --global --add safe.directory {root}/{song}/parts"
    run_in_path(base, cmd)
    run_in_path(base, f"git clone ssh://{username}@{server}:{root}/{song}/parts;cd parts; git checkout master || git checkout -b master")
    println("Cloned repo")


def setup_local_repo() -> None:
    if is_on_server():
        println("Is on Server")
        clone()
    else:
        println("Is not on Server")
        create_remote_repo()
        clone()


def maybe_setup_repo() -> None:
    base = RPR_GetProjectPath(0, "")[0]
    if exists(base, "parts"):
        println("Parts exists")
    else:
        println("Setting up repo")
        setup_local_repo()


def sync_repo(user: str) -> None:
    script = "cd parts; git add . --all; git commit -m 'no message'; git pull --rebase --no-edit origin master; git commit -m 'Still no message'"
    run(script)
    write_properties(user)
    script = "cd parts; git add . --all; git commit -m 'no message';  git push --set-upstream origin master"
    run(script)


def refresh_audio(user: str) -> None:
    name, server, username, root = get_prefs()
    song = get_song_name()
    if osShortName == "mac":
        script = f"rsync -ai -r --chmod=g+rwx -p --progress {username}@{server}:{root}/{song}/ogg ."
    else:
        script = bashScriptPath + "/" + f"rsync -ai -r --chmod=g+rwx -p --progress {username}@{server}:{root}/{song}/ogg ."
    run(script)


def push_audio(user: str) -> None:
    name, server, username, root = get_prefs()
    song = get_song_name()
    if osShortName == "mac":
        script = f"rsync -ai -r --chmod=g+rwx -p --progress ./ogg/{name} {username}@{server}:{root}/{song}/ogg"
    else:
        script = bashScriptPath + "/" + f"rsync -ai -r --chmod=g+rwx -p --progress ./ogg/{name} {username}@{server}:{root}/{song}/ogg"
    run(script)


# -------- Track write/read and import --------

def magiclines(sv: str):
    if not sv.endswith("\n"):
        sv = sv + "\n"
    for line in sv.splitlines():
        yield line


def write_part(person: str) -> None:
    RPR_Main_SaveProject(0, False)
    projectPath = RPR_GetProjectPath(0, "")[0]
    tracks, min_idx, max_idx = get_tracks_in_part(person)
    if min_idx == -1:
        return
    run(f"rm -rf parts/{person}/*.trk")
    target_dir = projectPath + s + "parts" + s + person
    RPR_RecursiveCreateDirectory(target_dir, 0)
    prevguid = "-1"
    for index in range(min_idx, max_idx + 1):
        rtrack = RPR_GetTrack(0, index)
        result = get_track_chunk(rtrack) or ""
        output = ""
        for ln in magiclines(result):
            ln2 = ln.replace(f"FILE \".*{s}", "FILE \"")
            output += "\n" + ln2
        result = output
        filepath = target_dir + s + (RPR_GetTrackGUID(rtrack)) + ".trk"
        with open(filepath, "w", encoding="utf-8") as f:
            parent = RPR_GetParentTrack(rtrack)
            _, name = RPR_GetTrackName(rtrack, "", 1024)
            if parent:
                _, pname = RPR_GetTrackName(parent, "", 1024)
            else:
                pname = "None"
            print_(f"Wrote file {filepath}\n")
            print_(f"{name}'s -> parent is {pname}\n")
            if parent:
                f.write(RPR_GetTrackGUID(parent) + "\n")
                println(RPR_GetTrackGUID(rtrack) + "'s  previous is" + prevguid)
                f.write(prevguid + "\n")
            else:
                f.write("-1\n")
                f.write(prevguid + "\n")
            f.write(result)
        prevguid = RPR_GetTrackGUID(rtrack)


def read_part(person: str):
    projectPath = RPR_GetProjectPath(0, "")[0]
    tracks: Dict[str, str] = {}
    parents: Dict[str, str] = {}
    prevs: Dict[str, Dict[str, str]] = {}
    files = get_track_files(projectPath, person)
    for file in files:
        parentguid = "-1"
        prevguid = "-1"
        p = projectPath + s + "parts" + s + person + s + file
        with open(p, "rb") as f:
            parentguid = trim(f.readline().decode(errors="ignore"))
            prevguid = trim(f.readline().decode(errors="ignore"))
            _ = f.readline()
            lines = f.read().decode(errors="ignore")
        if trim(lines) != "":
            key = file.replace(".trk", "")
            tracks[key] = lines
            parents[key] = parentguid
            if prevs.get(prevguid) is None:
                prevs[prevguid] = {}
            prevs[prevguid][key] = key
    return tracks, parents, prevs


def add_track(guid: str, index: int, xml: str, parent_guid: Optional[str], do_indent_home: bool = False) -> int:
    cur = get_track_by_guid(guid)
    if cur is not None:
        result = get_track_chunk(cur) or ""
        output = ""
        for ln in magiclines(result):
            output += "\n" + ln.replace(f"FILE \".*{s}", "FILE \"")
        result = output.replace("\r", "")
        xml2 = xml.replace("\r", "")
        if trim(result) == trim(xml2):
            return 0
        else:
            RPR_DeleteTrack(cur)
            RPR_InsertTrackAtIndex(index, False)
            track = RPR_GetTrack(0, index)
            RPR_SetTrackStateChunk(track, xml2)
            parent = get_track_by_guid(parent_guid) if parent_guid else None
            if parent:
                val = RPR_GetTrackDepth(parent)
                indent(index + 1, int(val + 1))
            else:
                indent(index + 1, 0)
            return 0
    # create new
    RPR_InsertTrackAtIndex(index, False)
    track = RPR_GetTrack(0, index)
    RPR_SetTrackStateChunk(track, xml)
    parent = get_track_by_guid(parent_guid) if parent_guid else None
    if parent:
        val = RPR_GetTrackDepth(parent)
        indent(index + 1, int(val + 1))
    else:
        indent(index + 1, 0)
    return 0


def add_next(root_guid: str, parents: Dict[str, str], prevs: Dict[str, Dict[str, str]], tracks: Dict[str, str]) -> None:
    index = get_index(root_guid) + 1
    if prevs.get(root_guid):
        for k in list(prevs[root_guid].keys()):
            add_track(k, index, tracks[k], parents.get(k))
            add_next(k, parents, prevs, tracks)


def import_part(name: str) -> None:
    trackser, pos, _ = get_tracks_in_part(name)
    if pos == -1:
        pos = int(RPR_GetNumTracks())
    track_num = pos
    tracks, parents, prevs = read_part(name)
    for k in list(trackser.keys()):
        if tracks.get(k) is None:
            RPR_DeleteTrack(get_track_by_guid(k))
    root = prevs.get("-1")
    if root:
        RPR_InsertTrackAtIndex(track_num, False)
        empty = RPR_GetTrack(0, track_num)
        indent(track_num + 1, 0)
        for k in list(root.keys()):
            add_track(k, track_num, tracks[k], parents.get(k), True)
            add_next(k, parents, prevs, tracks)
        RPR_DeleteTrack(empty)


def refresh_part(person: str) -> None:
    import_part(person)


def get_indexed_files_in_all_tracks() -> Dict[str, str]:
    files_map: Dict[str, str] = {}
    basePath = RPR_GetProjectPath("")
    if not (basePath.endswith("/") or basePath.endswith("\\")):
        basePath = basePath + "/"
    trackCount = int(RPR_CountTracks(0))
    for i in range(trackCount):
        track = RPR_GetTrack(0, i)
        itemCount = int(RPR_CountTrackMediaItems(track))
        for j in range(itemCount):
            item = RPR_GetTrackMediaItem(track, j)
            takeCount = int(RPR_CountTakes(item))
            for t in range(takeCount):
                take = RPR_GetMediaItemTake(item, t)
                if take:
                    src = RPR_GetMediaItemTake_Source(take)
                    absFileName = RPR_GetMediaSourceFileName(src, "")[1]
                    if absFileName:
                        relativePath = absFileName
                        if absFileName.startswith(basePath):
                            relativePath = absFileName[len(basePath):]
                        fileName = os.path.basename(relativePath)
                        baseName, _ = os.path.splitext(fileName)
                        files_map[baseName] = relativePath
    return files_map


def get_files_in_folder(path_: str, extension: str) -> Dict[str, str]:
    base = RPR_GetProjectPath(0, "")[0]
    os.makedirs(path_, exist_ok=True)
    idx = 0
    files: Dict[str, str] = {}
    while True:
        _, file = RPR_EnumerateFiles(path_, idx)[0:2]
        if file:
            if file.endswith("." + extension):
                folderfile = file.replace("." + extension, "")
                files[folderfile] = folderfile
            idx += 1
        else:
            break
    return files


def get_new_files(total: Dict[str, str], old: Dict[str, str]) -> Dict[str, str]:
    output: Dict[str, str] = {}
    for k, v in total.items():
        check = k.split("/")[-1]
        if old.get(check) is None:
            output[k] = v
    return output


def get_matching_files(total: Dict[str, str], old: Dict[str, str]) -> Dict[str, str]:
    output: Dict[str, str] = {}
    for k, v in total.items():
        check = k.split("/")[-1]
        if old.get(check) is not None:
            output[k] = v
    return output


def encode_files_in_part(person: str) -> None:
    base = RPR_GetProjectPath(0, "")[0]
    firstfiles = get_files_in_part(person)
    existing = get_files_in_folder(base + s + "ogg" + s + person, "ogg")
    files = get_new_files(firstfiles, existing)
    cmd = ""
    for k, v in files.items():
        if osShortName == "mac":
            cmd += f"'{RPR_GetResourcePath()}/Scripts/reach/macos/ffmpeg' -i '{v}' 'ogg/{person}/{os.path.basename(k)}.ogg';"
        else:
            cmd += bashScriptPath + "/" + f"ffmpeg -i '{v}' 'ogg/{person}{s}{os.path.basename(k)}.ogg';"
    if cmd:
        println("Running command in path: " + base + s + "ogg" + s + person)
        run_in_path(base, cmd)


def decode_files_in_part(person: str) -> None:
    base = RPR_GetProjectPath(0, "")[0]
    needed = get_indexed_files_in_all_tracks()
    firstfiles = get_files_in_folder(base + s + "ogg" + s + person, "ogg")
    existing = get_files_in_folder(base, "wav")
    to_decode = get_new_files(needed, existing)
    for_decoding = get_matching_files(to_decode, firstfiles)
    cmd = ""
    for k, v in for_decoding.items():
        _, ext = os.path.splitext(v)
        ext = ext.lstrip(".") or "wav"
        if osShortName == "mac":
            cmd += f"'{RPR_GetResourcePath()}/Scripts/reach/macos/ffmpeg' -i '{k}'.ogg '../../{k}.{ext}';"
        else:
            cmd += bashScriptPath + "/" + f"ffmpeg -i '{k}'.ogg '../../{k}.{ext}';"
    if cmd:
        run_in_path(base + s + "ogg" + s + person, cmd)


def get_files_in_part(person: str) -> Dict[str, str]:
    files: Dict[str, str] = {}
    tracks, _, _ = get_tracks_in_part(person)
    for _, track in tracks.items():
        _collect_files_in_track(track, files)
    return files


def _collect_files_in_track(track, files: Dict[str, str]) -> None:
    numItems = int(RPR_CountTrackMediaItems(track))
    for item in range(numItems):
        mediaItem = RPR_GetTrackMediaItem(track, item)
        numTakes = int(RPR_CountTakes(mediaItem))
        for takeNum in range(numTakes):
            take = RPR_GetMediaItemTake(mediaItem, takeNum)
            if take:
                source = RPR_GetMediaItemTake_Source(take)
                val = RPR_GetMediaSourceFileName(source, "")[1]
                smaller = "/" + val.replace(".wav", "").replace(".mp3", "").replace(".ogg", "").replace(":", "").replace("\\", "/")
                original = "/" + val.replace(":", "").replace("\\", "/")
                files[smaller] = original


# -------- High-level flows --------

def self_update() -> None:
    kb = RPR_GetResourcePath()
    path = kb + s + "Scripts" + s + "reach"
    run_in_path(path, "git pull --rebase origin master")


def maybe_create_track(person: str) -> None:
    tracks, min_idx, _ = get_tracks_in_part(person)
    if min_idx == -1:
        index = int(RPR_GetNumTracks())
        RPR_InsertTrackAtIndex(index, False)
        track = RPR_GetTrack(0, index)
        RPR_GetSetMediaTrackInfo_String(track, "P_NAME", person, True)
        indent_home(index)


def reconnect_offline_media_items() -> None:
    trackCount = int(RPR_CountTracks(0))
    for i in range(trackCount):
        track = RPR_GetTrack(0, i)
        itemCount = int(RPR_CountTrackMediaItems(track))
        for j in range(itemCount):
            item = RPR_GetTrackMediaItem(track, j)
            take = RPR_GetMediaItemTake(item, 0)
            if take:
                bring_file_online(take)
    RPR_ShowConsoleMsg("Reconnected media items.\n")


def _get_media_path(originalPath: str) -> str:
    directory = os.path.dirname(originalPath)
    filename = os.path.basename(originalPath)
    if directory and filename:
        return os.path.join(directory, "Media", filename)
    return originalPath


def bring_file_online(take) -> bool:
    currentSource = RPR_GetMediaItemTake_Source(take)
    filePath = RPR_GetMediaSourceFileName(currentSource or 0, "")[1]
    if filePath == "":
        RPR_ShowConsoleMsg("No file associated with this take.\n")
        return False
    if not os.path.isfile(filePath):
        filePath = _get_media_path(filePath)
        if not os.path.isfile(filePath):
            RPR_ShowConsoleMsg("File does not exist: " + filePath + "\n")
            return False
    success = bool(RPR_BR_SetTakeSourceFromFile(take, filePath, False))
    if success:
        RPR_ShowConsoleMsg("File brought online: " + filePath + "\n")
    else:
        RPR_ShowConsoleMsg("Failed to bring file online for: " + filePath + "\n")
    return success


def refresh() -> None:
    name, server, username, _ = get_prefs()
    RPR_Undo_BeginBlock()
    user = name
    maybe_setup_repo()
    encode_files_in_part(user)
    refresh_audio(user)
    write_part(user)
    read_properties()
    sync_repo(user)
    push_audio(user)
    # reload tracks and housekeeping
    refresh_tracks()
    maybe_create_track(user)
    reconnect_offline_media_items()
    RPR_Main_OnCommand(40047, 0)  # rebuild peaks
    RPR_Main_OnCommand(40491, 0)  # unarm all tracks
    RPR_Undo_EndBlock("Sync", 0)


def pull() -> None:
    name, server, username, _ = get_prefs()
    RPR_Undo_BeginBlock()
    user = name
    maybe_setup_repo()
    refresh_audio(user)
    read_properties()
    sync_repo(user)
    refresh_tracks()
    maybe_create_track(user)
    RPR_Main_OnCommand(40047, 0)
    RPR_Main_OnCommand(40491, 0)
    RPR_Undo_EndBlock("Sync", 0)


def refresh_from_files() -> None:
    name, server, username, _ = get_prefs()
    RPR_Undo_BeginBlock()
    user = name
    read_properties()
    refresh_tracks()
    maybe_create_track(user)
    RPR_Main_OnCommand(40047, 0)
    RPR_Main_OnCommand(40491, 0)
    RPR_Undo_EndBlock("Sync", 0)


def refresh_with_override() -> None:
    name, server, username, _ = get_prefs()
    user = name
    ok, otherguy, _ = RPR_GetUserInputs("Refresh", 1, "Other Guy", "")[0:3]
    RPR_Undo_BeginBlock()
    write_part(user)
    if otherguy and otherguy.strip():
        write_part(otherguy)
    sync_repo(user)
    refresh_tracks()
    RPR_Main_OnCommand(40047, 0)
    RPR_Main_OnCommand(40491, 0)
    RPR_Undo_EndBlock("Sync", 0)


# -------- Refresh tracks orchestration --------

def refresh_tracks() -> None:
    base = RPR_GetProjectPath(0, "")[0]
    files = get_parts(base + s + "parts")
    for file in files:
        if file != ".git":
            refresh_part(file)
            decode_files_in_part(file) 