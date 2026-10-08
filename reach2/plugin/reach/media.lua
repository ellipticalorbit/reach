-- Audio handling: transcode local recordings to low-bitrate Ogg Vorbis (ffmpeg), content-address them by
-- sha256, and fetch other people's audio into the project's reach-media folder.
local fs = require("reach.fs")
local proc = require("reach.proc")
local async = require("reach.async")
local sha256 = require("reach.sha256")
local json = require("reach.json")

local Media = {}
Media.__index = Media

local media = {}

local AUDIO_EXT = { wav = 1, aif = 1, aiff = 1, flac = 1, mp3 = 1, m4a = 1, aac = 1, wv = 1, w64 = 1, caf = 1,
                    opus = 1, ogg = 1, oga = 1, mp2 = 1, wma = 1 }

-- env: store, api (Api), project_id (function), ffmpeg (path), quality (function -> number)
function media.new(env)
  return setmetatable({ env = env }, Media)
end

-- Look for the bundled ffmpeg next to the plugin, then the legacy location, then PATH.
function media.find_ffmpeg(plugin_dir)
  local win = package.config:sub(1, 1) == "\\"
  local candidates = win and { plugin_dir .. "bin/windows/ffmpeg.exe", plugin_dir .. "../../ffmpeg.exe" }
                         or { plugin_dir .. "bin/macos/ffmpeg", plugin_dir .. "../../macos/ffmpeg" }
  for _, c in ipairs(candidates) do
    if fs.exists(c) then return c end
  end
  return win and "ffmpeg.exe" or "ffmpeg"
end

function Media:dir() return self.env.store.media_dir() end
function Media:path_for(sha) return self:dir() .. "/" .. sha .. ".ogg" end

-- If `path` is one of our cached files (<sha256>.ogg), the portable reference for it.
function Media:ref_for_local(path)
  local sha = fs.basename(fs.norm(path)):match("^(%x+)%.ogg$")
  if sha and #sha == 64 then return "reach-media://" .. sha:lower() .. ".ogg" end
  return nil
end

function Media:classify(path)
  if AUDIO_EXT[fs.ext(path)] then return "audio" end
  return "unsupported"
end

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

-- Returns sha256 of the uploadable Ogg for a local source file (transcoding if needed), or nil, reason.
-- The Ogg is left at path_for(sha). Must run inside a task.
function Media:prepare_upload(path)
  local size = fs.size(path)
  if not size then return nil, "file not found: " .. path end
  if self:classify(path) ~= "audio" then return nil, "unsupported media type: " .. fs.basename(path) end
  local key = path .. "|" .. size
  local cached = self:_index()[key]
  if cached and fs.exists(self:path_for(cached)) then return cached end

  local sha
  if fs.ext(path) == "ogg" or fs.ext(path) == "oga" then
    sha = sha256.file(path, async.yield)
    if not fs.exists(self:path_for(sha)) then
      local data = fs.read(path)
      assert(fs.write(self:path_for(sha), data))
    end
  else
    local tmp = string.format("%s/.tmp-%d-%d.ogg", self:dir(), os.time(), math.random(1000000))
    local q = self.env.quality and self.env.quality() or 1
    local res, why = proc.run({ self.env.ffmpeg, "-nostdin", "-y", "-v", "error", "-i", path, "-vn",
                                "-map_metadata", "-1", "-c:a", "libvorbis", "-q:a", tostring(q), "-f", "ogg", tmp },
                              3600)
    if not res then fs.remove(tmp) return nil, "ffmpeg: " .. tostring(why) end
    if res.code ~= 0 or not fs.exists(tmp) then
      fs.remove(tmp)
      local msg = res.stderr ~= "" and res.stderr or ("exit code " .. tostring(res.code))
      return nil, "ffmpeg failed for " .. fs.basename(path) .. ": " .. msg:gsub("%s+$", "")
    end
    sha = sha256.file(tmp, async.yield)
    if fs.exists(self:path_for(sha)) then fs.remove(tmp) else assert(fs.rename(tmp, self:path_for(sha))) end
  end
  self:_index()[key] = sha
  self:_save_index()
  return sha
end

-- Make sure <sha>.ogg is in the project's media folder, downloading it if needed. Returns its path.
function Media:ensure_local(sha)
  local dest = self:path_for(sha)
  if fs.exists(dest) then return dest end
  local tmp = dest .. ".part"
  self.env.api:get_blob(self.env.project_id(), sha, tmp)
  assert(fs.rename(tmp, dest))
  return dest
end

return media
