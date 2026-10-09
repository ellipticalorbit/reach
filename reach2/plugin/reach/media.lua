-- Audio handling. Every audio source has one canonical copy: a low-bitrate Ogg Vorbis (ffmpeg, quality 5),
-- content-addressed by sha256; chunks always reference it. Lossless sources may also have a high-quality
-- companion, the original WAV bytes (no transcoding), which the server links to the Ogg. Audio fetched from
-- the server lives in the project's reach-media folder as <ogg sha>.ogg or <ogg sha>.hq.wav.
local fs = require("reach.fs")
local platform = require("reach.platform")
local proc = require("reach.proc")
local async = require("reach.async")
local sha256 = require("reach.sha256")
local cancel = require("reach.cancel")
local json = require("reach.json")

local Media = {}
Media.__index = Media

local media = {}

-- Ogg Vorbis quality used for the canonical copy (~160 kbps: very close to the original, ~12x smaller).
media.OGG_QUALITY = 5

-- Sources that are lossless and so are worth keeping as a high-quality companion.
local LOSSLESS_EXT = { wav = 1, aif = 1, aiff = 1, flac = 1, w64 = 1, caf = 1, wv = 1 }

local AUDIO_EXT = { wav = 1, aif = 1, aiff = 1, flac = 1, mp3 = 1, m4a = 1, aac = 1, wv = 1, w64 = 1, caf = 1,
                    opus = 1, ogg = 1, oga = 1, mp2 = 1, wma = 1 }

-- Pure-Lua SHA-256 manages ~5 MB/s; above this size ask the OS to hash instead.
local NATIVE_HASH_ABOVE = 4 * 1024 * 1024

-- env: store, api (Api), project_id (function), ffmpeg (path)
function media.new(env)
  return setmetatable({ env = env, sources = {} }, Media)
end

-- Look for the bundled ffmpeg for this OS next to the plugin (or in its legacy repo location), then PATH.
-- Linux has no bundled binary: install ffmpeg with your package manager, or drop one in bin/linux/.
function media.find_ffmpeg(plugin_dir)
  local o = platform.os()
  local candidates, fallback
  if o == "windows" then
    candidates, fallback = { plugin_dir .. "bin/windows/ffmpeg.exe", plugin_dir .. "../../ffmpeg.exe" }, "ffmpeg.exe"
  elseif o == "macos" then
    candidates, fallback = { plugin_dir .. "bin/macos/ffmpeg", plugin_dir .. "../../macos/ffmpeg" }, "ffmpeg"
  else
    candidates, fallback = { plugin_dir .. "bin/linux/ffmpeg" }, "ffmpeg"
  end
  for _, c in ipairs(candidates) do
    if fs.exists(c) then return c end
  end
  return fallback
end

-- A bundled ffmpeg that arrived via a download or zip can be non-executable and, on macOS, quarantined (Gatekeeper
-- then refuses to run it). It's the user's own file, so fix both once, before first use. Failures are harmless
-- (e.g. the attribute isn't there).
function Media:_ensure_ffmpeg_runnable()
  if self._ffmpeg_ready then return end
  self._ffmpeg_ready = true
  local path = self.env.ffmpeg
  local o = platform.os()
  if o == "windows" or not path:find("/", 1, true) or not fs.exists(path) then return end -- on PATH or missing
  proc.run({ "/bin/chmod", "+x", path }, 30)
  if o == "macos" then proc.run({ "/usr/bin/xattr", "-d", "com.apple.quarantine", path }, 30) end
end

---------------------------------------------------------------------------------------------------
-- Hashing
---------------------------------------------------------------------------------------------------

function media.hash_command(path)
  local o = platform.os()
  if o == "windows" then return { "certutil", "-hashfile", path, "SHA256" }
  elseif o == "macos" then return { "/usr/bin/shasum", "-a", "256", path }
  else return { "sha256sum", path } end
end

-- Pull the 64-hex digest out of shasum / sha256sum ("<hex>  <path>") or certutil (digest on its own line,
-- possibly space-separated) output.
function media.parse_hash(out)
  for line in ((out or "") .. "\n"):gmatch("(.-)\r?\n") do
    local token = line:match("^%s*(%x+)")
    if token and #token == 64 then return token:lower() end
    local squeezed = line:gsub("%s", "")
    if #squeezed == 64 and squeezed:match("^%x+$") then return squeezed:lower() end
  end
  return nil
end

-- sha256 of a file: natively for big files (fast), else (or if that fails) in Lua, yielding to the UI.
function Media:hash_file(path)
  local size = fs.size(path)
  if size and size > NATIVE_HASH_ABOVE then
    local res = proc.run(media.hash_command(path), 3600, { match = path, cancellable = true })
    if res and res.code == 0 then
      local h = media.parse_hash(res.stdout)
      if h then return h end
    end
  end
  return sha256.file(path, function() async.yield() cancel.check() end)
end

---------------------------------------------------------------------------------------------------
-- Paths and references
---------------------------------------------------------------------------------------------------

function Media:dir() return self.env.store.media_dir() end
function Media:path_for(sha) return self:dir() .. "/" .. sha .. ".ogg" end           -- canonical Ogg
function Media:hq_path(sha) return self:dir() .. "/" .. sha .. ".hq.wav" end         -- downloaded WAV companion (named by its OGG's sha)
function Media:_converted_wav_path(wav_sha) return self:dir() .. "/" .. wav_sha .. ".up.wav" end

-- Where to read the bytes to upload: kind "ogg" (sha of the Ogg) or "wav" (sha of the WAV companion).
function Media:upload_path(sha, kind)
  if kind == "wav" then return self.sources[sha] or self:_converted_wav_path(sha) end
  return self:path_for(sha)
end

-- If `path` is one of our cached files, the portable reference for it (always the Ogg's).
function Media:ref_for_local(path)
  local name = fs.basename(fs.norm(path))
  local sha = name:match("^(%x+)%.ogg$") or name:match("^(%x+)%.hq%.wav$")
  if sha and #sha == 64 then return "reach-media://" .. sha:lower() .. ".ogg" end
  return nil
end

function Media:classify(path)
  if AUDIO_EXT[fs.ext(path)] then return "audio" end
  return "unsupported"
end

function Media.is_lossless(path) return LOSSLESS_EXT[fs.ext(path)] ~= nil end

function Media:_index()
  if not self.index then
    local raw = fs.read(self.env.store.media_index_path())
    local ok, t = pcall(json.decode, raw or "{}")
    self.index = ok and type(t) == "table" and t or {}
  end
  return self.index
end

function Media:_save_index()
  fs.write(self.env.store.media_index_path(), json.encode(self:_index()))
end

-- The cache is keyed on path + size + Ogg quality, so changing the quality re-encodes.
local function index_key(path, size) return path .. "|" .. size .. "|q" .. media.OGG_QUALITY end

---------------------------------------------------------------------------------------------------
-- Preparing uploads
---------------------------------------------------------------------------------------------------

local function ffmpeg_failure(self, path, res)
  local msg = res.stderr ~= "" and res.stderr or ("exit code " .. tostring(res.code))
  msg = msg:gsub("%s+$", "")
  if res.code == 126 or res.code == 127 or res.code == 9009 then
    msg = msg .. "\n(ffmpeg could not be started from '" .. tostring(self.env.ffmpeg) .. "'. " ..
      (platform.os() == "linux" and "Install it, e.g. 'sudo apt install ffmpeg'." or
       "Check that the file exists and is allowed to run.") .. ")"
  end
  return "ffmpeg failed for " .. fs.basename(path) .. ": " .. msg
end

-- Run ffmpeg on `path`, writing to a temp file in the media dir. Returns the temp path, or nil, reason.
function Media:_transcode(path, ext, codec_args)
  local tmp = string.format("%s/.tmp-%d-%d.%s", self:dir(), os.time(), math.random(1000000), ext)
  self:_ensure_ffmpeg_runnable()
  local argv = { self.env.ffmpeg, "-nostdin", "-y", "-v", "error", "-i", path, "-vn", "-map_metadata", "-1" }
  for _, a in ipairs(codec_args) do argv[#argv + 1] = a end
  argv[#argv + 1] = "-f"
  argv[#argv + 1] = ext
  argv[#argv + 1] = tmp
  local ok, res, why = pcall(proc.run, argv, 3600, { match = tmp, cancellable = true })
  if not ok then fs.remove(tmp) error(res, 0) end        -- cancelled: remove the partial file and propagate
  if not res then fs.remove(tmp) return nil, "ffmpeg: " .. tostring(why) end
  if res.code ~= 0 or not fs.exists(tmp) then
    fs.remove(tmp)
    return nil, ffmpeg_failure(self, path, res)
  end
  return tmp
end

-- The canonical Ogg for a local source file: returns its sha256 (file left at path_for(sha)), or nil, reason.
-- Existing .ogg files are used as they are; everything else is transcoded. Must run inside a task.
function Media:prepare_upload(path)
  local size = fs.size(path)
  if not size then return nil, "file not found: " .. path end
  if self:classify(path) ~= "audio" then return nil, "unsupported media type: " .. fs.basename(path) end
  local key = index_key(path, size)
  local entry = self:_index()[key]
  if type(entry) == "table" and entry.ogg and fs.exists(self:path_for(entry.ogg)) then return entry.ogg end

  local sha
  local src_ext = fs.ext(path)
  if src_ext == "ogg" or src_ext == "oga" then
    sha = self:hash_file(path)
    if not fs.exists(self:path_for(sha)) then assert(fs.write(self:path_for(sha), fs.read(path))) end
  else
    local tmp, why = self:_transcode(path, "ogg", { "-c:a", "libvorbis", "-q:a", tostring(media.OGG_QUALITY) })
    if not tmp then return nil, why end
    sha = self:hash_file(tmp)
    if fs.exists(self:path_for(sha)) then fs.remove(tmp) else assert(fs.rename(tmp, self:path_for(sha))) end
  end
  local idx = self:_index()
  idx[key] = { ogg = sha, wav = entry and entry.wav, wav_src = entry and entry.wav_src }
  self:_save_index()
  return sha
end

-- The Ogg sha already known for this source (no work done), or nil. Used to attach companions to tracks that
-- were pushed earlier; we must not re-encode them, since that would produce a different Ogg.
function Media:cached_ogg(path)
  local size = fs.size(path)
  if not size then return nil end
  local entry = self:_index()[index_key(path, size)]
  if type(entry) == "table" and entry.ogg and fs.exists(self:path_for(entry.ogg)) then return entry.ogg end
  return nil
end

-- The high-quality companion for a lossless source: the original WAV bytes (no transcoding), or, for other
-- lossless formats, a lossless WAV conversion. Returns the WAV's sha256, or nil, reason.
function Media:prepare_wav(path)
  local size = fs.size(path)
  if not size then return nil, "file not found: " .. path end
  if not Media.is_lossless(path) then return nil, "not a lossless source" end
  local key = index_key(path, size)
  local idx = self:_index()
  local entry = idx[key]
  if type(entry) ~= "table" then return nil, "no Ogg prepared for this file yet" end
  if entry.wav then
    if entry.wav_src and fs.exists(entry.wav_src) then self.sources[entry.wav] = entry.wav_src return entry.wav end
    if not entry.wav_src and fs.exists(self:_converted_wav_path(entry.wav)) then return entry.wav end
  end
  local sha
  if fs.ext(path) == "wav" then
    sha = self:hash_file(path)
    self.sources[sha] = path
    entry.wav, entry.wav_src = sha, path
  else
    local tmp, why = self:_transcode(path, "wav", { "-c:a", "pcm_s24le" })
    if not tmp then return nil, why end
    sha = self:hash_file(tmp)
    if fs.exists(self:_converted_wav_path(sha)) then fs.remove(tmp) else assert(fs.rename(tmp, self:_converted_wav_path(sha))) end
    entry.wav, entry.wav_src = sha, nil
  end
  self:_save_index()
  return sha
end

---------------------------------------------------------------------------------------------------
-- Fetching
---------------------------------------------------------------------------------------------------

local function download(self, sha, dest, on_progress)
  if fs.exists(dest) then return dest end
  local tmp = dest .. ".part"
  self.env.api:get_blob(self.env.project_id(), sha, tmp, on_progress)
  assert(fs.rename(tmp, dest))
  return dest
end

-- Make sure the canonical <sha>.ogg is in the project's media folder. Returns its path.
function Media:ensure_local(sha, on_progress) return download(self, sha, self:path_for(sha), on_progress) end

-- Fetch the WAV companion (blob `wav_sha`) of the Ogg `ogg_sha` as <ogg_sha>.hq.wav. Returns its path.
function Media:ensure_hq(ogg_sha, wav_sha, on_progress)
  return download(self, wav_sha, self:hq_path(ogg_sha), on_progress)
end

return media
