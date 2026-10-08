-- Pure functions over REAPER track chunks (the text of a <TRACK ...> block).
local sha256 = require("reach.sha256")

local canon = {}

-- UI/selection state that changes without the user editing the track.
local VOLATILE = {
  "^%s*SEL%s+%d+%s*$", "^%s*LASTSEL%s+%-?%d+%s*$", "^%s*ISBUS%s+%-?%d+%s+%-?%d+%s*$",
  "^%s*TRACKHEIGHT%s+.*$",
}

local function lines(s)
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  return s:gmatch("(.-)\n")
end

function canon.normalise_newlines(chunk) return (chunk:gsub("\r\n?", "\n")) end

-- Remove volatile lines, normalise newlines, trim.
function canon.strip_volatile(chunk)
  local out = {}
  for line in lines(canon.normalise_newlines(chunk)) do
    local drop = false
    for _, pat in ipairs(VOLATILE) do
      if line:match(pat) then drop = true break end
    end
    if not drop then out[#out + 1] = line end
  end
  return (table.concat(out, "\n"):gsub("%s+$", ""))
end

-- Same structural rules the server enforces. Returns nil if fine, else a description incl. a snippet
-- of the chunk's start and end (so odd real-world chunks can be diagnosed from the console).
function canon.problem(chunk, guid)
  local t = chunk:gsub("^%s+", ""):gsub("%s+$", "")
  local function snip() return string.format("starts %q ... ends %q (%d bytes)", t:sub(1, 80), t:sub(-40), #t) end
  if not t:match("^<TRACK[%s]") and t ~= "<TRACK" then return "chunk does not start with '<TRACK': " .. snip() end
  local g = canon.header_guid(t)
  if not g then return "chunk has no track guid (no '<TRACK {guid}' header or TRACKID line): " .. snip() end
  if g:upper() ~= guid:upper() then return "chunk guid " .. g .. " differs from track guid " .. guid end
  if t:sub(-1) ~= ">" then return "chunk does not end with '>': " .. snip() end
  return nil
end

function canon.fingerprint(chunk) return sha256.hex(chunk) end

-- REAPER's GetTrackStateChunk writes a bare "<TRACK" with the guid on a TRACKID line; project files use
-- "<TRACK {guid}". Handle both.
function canon.header_guid(chunk)
  local g = chunk:match("^%s*<TRACK[ \t]+(%b{})")
  if g then return g end
  for line, d in canon._depth_lines(chunk) do
    if d == 1 then
      local id = line:match("^%s*TRACKID%s+(%b{})")
      if id then return id end
    end
  end
  return nil
end

local function file_line(line)
  local pre, path, post = line:match('^(%s*FILE%s+)"([^"]*)"(.*)$')
  if pre then return pre, path, post, true end
  pre, path, post = line:match("^(%s*FILE%s+)(%S+)(.*)$")
  return pre, path, post, false
end

-- All FILE paths referenced by the chunk, in order.
function canon.file_refs(chunk)
  local refs = {}
  for line in lines(canon.normalise_newlines(chunk)) do
    local _, path = file_line(line)
    if path then refs[#refs + 1] = path end
  end
  return refs
end

-- Rewrite each FILE path. fn(path) returns newpath [, newSourceType]; return nil to leave unchanged.
-- A new source type rewrites the nearest preceding "<SOURCE X" line (e.g. WAVE -> VORBIS).
function canon.map_files(chunk, fn)
  local out, last_source = {}, nil
  for line in lines(canon.normalise_newlines(chunk)) do
    local src = line:match("^%s*<SOURCE%s+(%S+)")
    if src then last_source = #out + 1 end
    local pre, path, post, quoted = file_line(line)
    if path then
      local newpath, newtype = fn(path)
      if newpath then
        line = pre .. '"' .. newpath .. '"' .. post
        if newtype and last_source then
          out[last_source] = out[last_source]:gsub("(<SOURCE%s+)%S+", "%1" .. newtype, 1)
        end
      end
    end
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

-- Iterate lines with their block depth (1 = direct property of the <TRACK> block).
local function depth_lines(chunk)
  local depth = 0
  local it = lines(canon.normalise_newlines(chunk))
  return function()
    local line = it()
    if line == nil then return nil end
    local trimmed = line:match("^%s*(.-)%s*$")
    local d = depth
    if trimmed:sub(1, 1) == "<" then depth = depth + 1 d = depth - 0
    elseif trimmed == ">" then depth = depth - 1 d = depth + 1 end
    return line, d, trimmed
  end
end

canon._depth_lines = depth_lines

-- The track's own NAME (not a take name inside an item).
function canon.get_name(chunk)
  for line, d in depth_lines(chunk) do
    if d == 1 then
      local q = line:match('^%s*NAME%s+"([^"]*)"') or line:match("^%s*NAME%s+(%S+)")
      if q then return q end
    end
  end
  return ""
end

-- Set the track's own NAME, inserting one if absent.
function canon.set_name(chunk, name)
  name = name:gsub('"', "'")
  local out, done = {}, false
  for line, d in depth_lines(chunk) do
    if not done and d == 1 and line:match("^%s*NAME%s") then
      line = '  NAME "' .. name .. '"'
      done = true
    end
    out[#out + 1] = line
  end
  if not done then table.insert(out, 2, '  NAME "' .. name .. '"') end
  return table.concat(out, "\n")
end

-- Give a copy of a track a new identity: new track guid everywhere, new item/take guids.
function canon.clone_chunk(chunk, old_guid, new_guid, genguid)
  chunk = canon.normalise_newlines(chunk):gsub(old_guid:gsub("%p", "%%%0"), (new_guid:gsub("%%", "%%%%")))
  local out = {}
  for line in lines(chunk) do
    line = line:gsub("^(%s*I?GUID%s+)%b{}", function(pre) return pre .. genguid() end)
    out[#out + 1] = line
  end
  return table.concat(out, "\n")
end

return canon
