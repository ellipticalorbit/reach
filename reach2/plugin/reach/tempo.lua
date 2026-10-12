-- Tempo-independent ("musical") form of track chunks.
--
-- REAPER stores item positions in seconds, and when the tempo changes it moves/stretches items according to
-- their timebase. So the same song sits at different seconds on different machines, and a tempo change would
-- make every track look modified. In the form we sync and fingerprint, beat-timebase items are written in
-- quarter notes (QN) instead, which a tempo change doesn't alter:
--   timebase 1 "beats (position, length, rate)":  POSITION -> REACH_QPOS, LENGTH -> REACH_QLEN,
--       SNAPOFFS -> REACH_QSNAP, and each PLAYRATE rate -> "@<rate per BPM>" (REAPER keeps rate/BPM constant)
--   timebase 2 "beats (position only)":           POSITION -> REACH_QPOS
--   timebase 0 "time":                            unchanged
-- Track automation points (PT lines in track envelopes) are converted too when envelopes are beat-locked.
-- localize() turns the musical form back into seconds using the local tempo map.
--
-- map: { qn = f(seconds) -> QN, time = f(QN) -> seconds, bpm = f(seconds) -> BPM }
local tempo = {}

local function lines(s)
  if s:sub(-1) ~= "\n" then s = s .. "\n" end
  return s:gmatch("(.-)\n")
end

local function q6(x) return string.format("%.6f", x) end      -- 1e-6 QN: well under a sample
local function r12(x) return string.format("%.12g", x) end      -- rate per BPM
local function sec(x) return string.format("%.14g", x) end

local function trim(line) return line:match("^%s*(.-)%s*$") end

-- Timebase of a chunk's track (BEAT line directly in the <TRACK> block); -1 = project default.
local function track_mode(chunk)
  local depth = 0
  for line in lines(chunk) do
    local t = trim(line)
    if t:sub(1, 1) == "<" then depth = depth + 1
    elseif t == ">" then depth = depth - 1
    elseif depth == 1 then
      local m = t:match("^BEAT%s+(%-?%d+)")
      if m then return tonumber(m) end
    end
  end
  return -1
end

-- Split the chunk into a list of entries, grouping each <ITEM> block's direct lines so they can be rewritten
-- together. Returns list of { line } or { item = { lines... } }.
local function parse(chunk)
  local out, depth, item, item_depth = {}, 0, nil, nil
  local env_depth = nil
  for line in lines(chunk:gsub("\r\n?", "\n")) do
    local t = trim(line)
    local opens, closes = t:sub(1, 1) == "<", t == ">"
    if item then
      item[#item + 1] = line
      if opens then depth = depth + 1 elseif closes then depth = depth - 1 end
      if depth < item_depth then out[#out + 1] = { item = item } item = nil end
    else
      if opens then
        depth = depth + 1
        if t:match("^<ITEM") then
          item, item_depth = { line }, depth
        else
          -- an envelope block outside items (track/FX automation)
          if not env_depth and t:match("^<[%w_]*ENV") then env_depth = depth end
          out[#out + 1] = { line = line, env = env_depth ~= nil }
        end
      elseif closes then
        out[#out + 1] = { line = line, env = env_depth ~= nil }
        if env_depth and depth == env_depth then env_depth = nil end
        depth = depth - 1
      else
        out[#out + 1] = { line = line, env = env_depth ~= nil }
      end
    end
  end
  if item then out[#out + 1] = { item = item } end
  return out
end

-- Rewrite one item's direct lines (depth 1 inside the item) with fn(key, rest, line) -> new line or nil.
local function each_direct(item, fn)
  local depth = 0
  for i, line in ipairs(item) do
    local t = trim(line)
    if i == 1 then depth = 1
    elseif t:sub(1, 1) == "<" then depth = depth + 1
    elseif t == ">" then depth = depth - 1
    elseif depth == 1 then
      local key, rest = t:match("^(%S+)%s*(.-)$")
      local new = fn(key, rest, line)
      if new then item[i] = line:match("^(%s*)") .. new end
    end
  end
end

local function item_value(item, key)
  local v
  each_direct(item, function(k, rest) if k == key and not v then v = rest end end)
  return v
end

-- chunk (seconds) -> musical form. ctx: { map, items = project item timebase, env = envelope lock (1 = beats) }
function tempo.musicalize(chunk, ctx)
  if not ctx or not ctx.map then return chunk end
  local map = ctx.map
  local tmode = track_mode(chunk)
  local out = {}
  for _, e in ipairs(parse(chunk)) do
    if e.item then
      local item = e.item
      local imode = tonumber((item_value(item, "BEAT") or ""):match("^(%-?%d+)") or "") or -1
      local mode = imode ~= -1 and imode or (tmode ~= -1 and tmode or (ctx.items or 1))
      local pos = tonumber((item_value(item, "POSITION") or ""):match("^(%S+)") or "")
      if pos and (mode == 1 or mode == 2) then
        local q0 = map.qn(pos)
        local bpm = map.bpm(pos)
        each_direct(item, function(key, rest)
          if key == "POSITION" then return "REACH_QPOS " .. q6(q0) end
          if mode == 1 then
            local first, tail = rest:match("^(%S+)%s*(.-)$")
            local v = tonumber(first or "")
            if key == "LENGTH" and v then return "REACH_QLEN " .. q6(map.qn(pos + v) - q0) end
            if key == "SNAPOFFS" and v then return "REACH_QSNAP " .. q6(map.qn(pos + v) - q0) end
            if key == "PLAYRATE" and v and bpm and bpm > 0 then
              return "PLAYRATE @" .. r12(v / bpm) .. (tail ~= "" and (" " .. tail) or "")
            end
          end
        end)
      end
      for _, l in ipairs(item) do out[#out + 1] = l end
    elseif e.env and (ctx.env or 1) == 1 then
      local indent, t, rest = e.line:match("^(%s*)PT%s+(%S+)(.*)$")
      local tv = tonumber(t or "")
      out[#out + 1] = tv and (indent .. "PT @" .. q6(map.qn(tv)) .. rest) or e.line
    else
      out[#out + 1] = e.line
    end
  end
  return table.concat(out, "\n")
end

-- Musical form -> seconds, using the local tempo map. Lines that weren't converted are left as they are.
function tempo.localize(chunk, map)
  if not map or not chunk:find("REACH_Q", 1, true) and not chunk:find("PT @", 1, true) and not chunk:find("PLAYRATE @", 1, true) then
    return chunk
  end
  local out = {}
  for _, e in ipairs(parse(chunk)) do
    if e.item then
      local item = e.item
      local q0 = tonumber(item_value(item, "REACH_QPOS") or "")
      if q0 then
        local pos = map.time(q0)
        local bpm = map.bpm(pos)
        each_direct(item, function(key, rest)
          local v = tonumber((rest:match("^(%S+)")) or "")
          if key == "REACH_QPOS" then return "POSITION " .. sec(pos) end
          if key == "REACH_QLEN" and v then return "LENGTH " .. sec(map.time(q0 + v) - pos) end
          if key == "REACH_QSNAP" and v then return "SNAPOFFS " .. sec(map.time(q0 + v) - pos) end
          if key == "PLAYRATE" then
            local per, tail = rest:match("^@(%S+)%s*(.-)$")
            if per then return "PLAYRATE " .. sec(tonumber(per) * bpm) .. (tail ~= "" and (" " .. tail) or "") end
          end
        end)
      end
      for _, l in ipairs(item) do out[#out + 1] = l end
    else
      local indent, q, rest = e.line:match("^(%s*)PT%s+@(%S+)(.*)$")
      out[#out + 1] = q and (indent .. "PT " .. sec(map.time(tonumber(q))) .. rest) or e.line
    end
  end
  return table.concat(out, "\n")
end

-- Canonical text of song tempo settings, for change detection.
function tempo.settings_fp(data)
  local t = data and data.tempo
  if not t then return "none" end
  local parts = { ("bpm=%.6f;sig=%s/%s"):format(t.bpm or 0, tostring(t.num), tostring(t.den)) }
  for _, m in ipairs(t.markers or {}) do
    parts[#parts + 1] = ("m=%s:%.6f:%.6f:%s/%s:%s"):format(tostring(m.measure), m.beat or 0, m.bpm or 0,
      tostring(m.num), tostring(m.den), tostring(m.linear and true or false))
  end
  return table.concat(parts, "|")
end

-- A constant-tempo map (used by tests and as a fallback).
function tempo.constant_map(bpm)
  return { qn = function(t) return t * bpm / 60 end, time = function(q) return q * 60 / bpm end,
           bpm = function() return bpm end }
end

return tempo
