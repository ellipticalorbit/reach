# Reach plugin (REAPER Lua scripts)

Syncs the tracks in a REAPER project with a Reach server. No git/rsync/Python: plain Lua, with `curl`
(built into macOS and Windows 10+) for HTTP and the bundled `ffmpeg` for transcoding to Ogg Vorbis.

## Install
Add the actions in this folder to REAPER (Actions > Show action list > New action > Load ReaScript...),
or have REAPER's action list import the `Reach_*.lua` files:

| Action | What it does |
|---|---|
| `Reach_Settings.lua` | Server URL, Ogg quality, and (optionally) adds Sync / Join song / Share song buttons to your main toolbar when you next quit REAPER |
| `Reach_Login.lua` | Opens your browser for Google sign-in (also happens automatically when needed) |
| `Reach_Share_song.lua` | Creates the song on the server, links this project, copies the join code, then syncs (offering to move loose tracks into your folder) |
| `Reach_List_songs.lua` | Lists every song you're in, your role, and the join code for the ones you own |
| `Reach_Show_join_code.lua` | Owner: shows/copies the join code and writes it into the project notes |
| `Reach_Join_song.lua` | Paste a join code: opens a new project (you choose where to save it), links it and pulls everything |
| `Reach_Add_selected_tracks_to_my_folder.lua` | Moves selected tracks into your Reach folder |
| `Reach_Sync_LQ.lua` | Pull, resolve conflicts, push. Audio travels as small Ogg Vorbis (quality 5) |
| `Reach_Sync_HQ.lua` | The same, and also uploads your lossless originals and downloads other people's where they exist |
| `Reach_Restore_deleted_tracks.lua` | Bring back a track deleted by anyone |

Needs the SWS extension for large tracks, the clipboard and opening the browser (falls back gracefully
where it can). The project must be saved: sync state lives in the project file.

## Progress and timeouts
Sync shows a small progress window (drawn with REAPER's built-in `gfx`; no extensions needed) once a sync has run
for a second: the current step, a bar, bytes done, speed and time left. Uploads and downloads report real byte
progress from curl, summed across the transfers running in parallel. Closing the window only hides it; the sync
continues. The window has a **Cancel** button (Esc works too): it stops the running upload, download or ffmpeg
at once, removes any partial file, and ends the sync at the next safe point. Nothing is lost: running the sync again
carries on, because finished uploads/downloads are never repeated and the server ignores partial uploads.
Transfers have **no total time limit**: they are aborted only if they stall (under 1 KB/s for two
minutes) and are retried automatically on transient failures. Ordinary API calls are limited to 2 minutes.

## How it works
* Each person gets a top-level **Reach folder** (a folder track named after them). Everything inside a Reach
  folder is synced; tracks elsewhere are ignored. Use "Add selected tracks to my folder".
* **Audio, low and high quality.** Every audio source has one canonical copy: an Ogg Vorbis (ffmpeg, quality 5,
  about 160 kbps, roughly 12x smaller than a 24-bit WAV), content-addressed by sha256. Chunks on the server always
  reference that Ogg, so LQ and HQ users share identical tracks. *Sync LQ* uploads and downloads Ogg only.
  *Sync HQ* additionally uploads the original WAV (untouched bytes, no transcoding, no copy; FLAC/AIFF etc. are
  converted losslessly) as a linked companion, downloads the WAV for every Ogg that has one (the Ogg only where it
  doesn't), upgrades audio you already have, and attaches WAVs to tracks you pushed earlier in LQ. Lossy sources
  (mp3, m4a, ogg...) have no companion. WAVs count against the song's storage quota, so mind the size.
  Pulled audio lands in `<project>/reach-media/` as `<sha>.ogg` / `<sha>.hq.wav`; your own recordings stay untouched.
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

## Platforms
macOS, Windows and Linux are all supported by design; OS differences live in `reach/platform.lua`.

| | macOS | Windows | Linux |
|---|---|---|---|
| HTTP | system `curl` | `curl.exe` (built into Windows 10 1803+) | system `curl` (install if missing) |
| ffmpeg | bundled `macos/ffmpeg` | bundled `ffmpeg.exe` | none bundled: `apt install ffmpeg` (or put a binary in `plugin/bin/linux/`) |
| background jobs | `/bin/sh` scripts | `.bat` scripts via `cmd.exe` (UTF-8 code page) | `/bin/sh` scripts |
| open browser | SWS `CF_ShellExecute`, else `open` | SWS, else `start` | SWS, else `xdg-open` |
| toolbar watcher | waits for `REAPER` | waits for `reaper.exe` | waits for `reaper` (needs `pgrep`) |

The automated tests *execute* only on the machine they run on (macOS so far). For the other two OSes the
tests check the generated scripts and lookups (`platform.set()` forces an OS) but nothing has been run on a
real Windows or Linux box yet.

## Unverified in real REAPER
Not testable without REAPER; check these first if something misbehaves:
1. `reaper.ExecProcess(cmd, -1)` returns immediately and leaves the process running (used for curl/ffmpeg).
2. `SetTrackStateChunk` adopts the GUID in the chunk header for a freshly inserted track.
3. `ReorderSelectedTracks(target, 0)` places the track so it ends at index `target`.
4. Track `P_EXT:reach_owner` marks survive in track chunks (they travel with the folder track to others).
5. Windows: `curl.exe` on PATH and the `cmd.exe /c` job scripts (macOS path is the most exercised).
