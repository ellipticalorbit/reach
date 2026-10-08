# Reach plugin (REAPER Lua scripts)

Syncs the tracks in a REAPER project with a Reach server. No git/rsync/Python: plain Lua, with `curl`
(built into macOS and Windows 10+) for HTTP and the bundled `ffmpeg` for transcoding to Ogg Vorbis.

## Install
Add the actions in this folder to REAPER (Actions > Show action list > New action > Load ReaScript...),
or have REAPER's action list import the `Reach_*.lua` files:

| Action | What it does |
|---|---|
| `Reach_Settings.lua` | Server URL and Ogg quality (do this first; default is `http://localhost:8000`) |
| `Reach_Login.lua` | Opens your browser for Google sign-in (also happens automatically when needed) |
| `Reach_Share_song.lua` | Creates the song on the server, links this project, copies the join code |
| `Reach_Show_join_code.lua` | Owner: shows/copies the join code and writes it into the project notes |
| `Reach_Join_song.lua` | In a new project: paste a join code, then pulls everything |
| `Reach_Add_selected_tracks_to_my_folder.lua` | Moves selected tracks into your Reach folder |
| `Reach_Sync.lua` | Pull, resolve conflicts, push |
| `Reach_Restore_deleted_tracks.lua` | Bring back a track deleted by anyone |

Needs the SWS extension for large tracks, the clipboard and opening the browser (falls back gracefully
where it can). The project must be saved: sync state lives in the project file.

## How it works
* Each person gets a top-level **Reach folder** (a folder track named after them). Everything inside a Reach
  folder is synced; tracks elsewhere are ignored. Use "Add selected tracks to my folder".
* Audio is transcoded to Ogg Vorbis (low bitrate), content-addressed by sha256 and uploaded once. Chunks sent
  to the server reference audio as `reach-media://<sha>.ogg`; pulled audio lands in `<project>/reach-media/`.
  Your own recordings stay untouched locally.
* For every track the plugin remembers what the server had at the last sync. A track changed both here and on
  the server is a **conflict**: keep mine / use theirs / keep both (a copy named "... (conflict - you)").
* Deleting a track removes it for everyone (after a confirmation) but it is kept forever and can be restored.
* Track order uses fractional keys, so moving one track only changes that track.

## Layout
`reach/engine.lua` sync algorithm (no REAPER calls) -- `reach/reaper_tracks.lua` the only code that touches
tracks -- `reach/media.lua` ffmpeg + cache -- `reach/api.lua`, `reach/http.lua`, `reach/proc.lua` curl and
background processes -- `reach/async.lua` coroutine scheduler -- `reach/canon.lua` chunk text helpers.

## Tests (outside REAPER)
```
brew install lua@5.4
tests/run.sh      # starts the dev server via docker compose, runs unit + integration tests
```
`tests/run.lua` runs the real engine against a real server with a simulated project;
`tests/run_fake_reaper.lua` drives the REAPER-facing code against a fake ReaScript API. Passing those is
necessary but not sufficient: see "Unverified in real REAPER" below.

## Unverified in real REAPER
Not testable without REAPER; check these first if something misbehaves:
1. `reaper.ExecProcess(cmd, -1)` returns immediately and leaves the process running (used for curl/ffmpeg).
2. `SetTrackStateChunk` adopts the GUID in the chunk header for a freshly inserted track.
3. `ReorderSelectedTracks(target, 0)` places the track so it ends at index `target`.
4. Track `P_EXT:reach_owner` marks survive in track chunks (they travel with the folder track to others).
5. Windows: `curl.exe` on PATH and the `cmd.exe /c` job scripts (macOS path is the most exercised).
