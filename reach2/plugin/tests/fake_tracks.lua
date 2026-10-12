-- In-memory stand-in for the REAPER project, implementing the same interface as reach/reaper_tracks.lua.
local FT = {}
FT.__index = FT

function FT.new()
  return setmetatable({ list = {}, byguid = {}, tempo = { bpm = 120, num = 4, den = 4, markers = {} },
                        tb = { items = 1, env = 1 } }, FT)
end

-- ---- tempo (constant tempo only) ----
local function copy(t) local r = {} for k, v in pairs(t) do r[k] = type(v) == "table" and copy(v) or v end return r end

function FT:tempo_map()
  local bpm = self.tempo.bpm
  return { qn = function(t) return t * bpm / 60 end, time = function(q) return q * 60 / bpm end, bpm = function() return bpm end }
end
function FT:timebase() return { items = self.tb.items, env = self.tb.env } end
function FT:read_tempo() return copy(self.tempo) end

-- What REAPER does on a tempo change (as measured with the tempo diagnostic), written independently of
-- reach/tempo.lua: beat-timebase items move (and, for "pos, len, rate", stretch); time items stay put;
-- beat-locked envelope points move.
local function retime(chunk, f, tb)          -- f = old_bpm / new_bpm (factor on seconds)
  local out, track_mode, depth = {}, -1, 0
  local item, item_mode, env = nil, nil, nil
  local raw = {}
  for line in (chunk .. "\n"):gmatch("(.-)\n") do raw[#raw + 1] = line end
  -- item modes need a look-ahead: collect each item's BEAT first
  local modes, cur, d = {}, nil, 0
  for i, line in ipairs(raw) do
    local t = line:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "<" then d = d + 1 if t:match("^<ITEM") then cur = i modes[cur] = -1 end
    elseif t == ">" then if cur and d == 2 then cur = nil end d = d - 1
    elseif d == 1 then local m = t:match("^BEAT (%-?%d+)") if m then track_mode = tonumber(m) end
    elseif cur and d == 2 then local m = t:match("^BEAT (%-?%d+)") if m then modes[cur] = tonumber(m) end end
  end
  d = 0
  local mode
  for i, line in ipairs(raw) do
    local t = line:match("^%s*(.-)%s*$")
    local indent = line:match("^(%s*)")
    if t:sub(1, 1) == "<" then
      d = d + 1
      if t:match("^<ITEM") then
        local m = modes[i]
        mode = m ~= -1 and m or (track_mode ~= -1 and track_mode or tb.items)
      elseif d == 2 and t:match("^<[%w_]*ENV") then env = true end
      out[#out + 1] = line
    elseif t == ">" then
      if d == 2 then mode, env = nil, nil end
      d = d - 1
      out[#out + 1] = line
    elseif mode and d == 2 then
      local key, v, rest = t:match("^(%S+)%s+(%S+)(.*)$")
      v = tonumber(v or "")
      if key == "POSITION" and v and (mode == 1 or mode == 2) then line = indent .. "POSITION " .. (v * f)
      elseif key == "LENGTH" and v and mode == 1 then line = indent .. "LENGTH " .. (v * f)
      elseif key == "SNAPOFFS" and v and mode == 1 then line = indent .. "SNAPOFFS " .. (v * f)
      elseif key == "PLAYRATE" and v and mode == 1 then line = indent .. "PLAYRATE " .. (v / f) .. rest end
      out[#out + 1] = line
    elseif env and tb.env == 1 then
      local v, rest = t:match("^PT%s+(%S+)(.*)$")
      out[#out + 1] = v and (indent .. "PT " .. (tonumber(v) * f) .. rest) or line
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end
FT.retime = retime

function FT:write_tempo(t)
  local old = self.tempo.bpm
  self.tempo = copy(t)
  if old ~= t.bpm then
    for _, r in ipairs(self.list) do r.chunk = retime(r.chunk, old / t.bpm, self.tb) end
  end
end

-- test helper: the user changes the tempo
function FT:set_tempo(bpm) self:write_tempo({ bpm = bpm, num = 4, den = 4, markers = {} }) end

-- test helper: an item's timing on a track
function FT:item_timing(name)
  local c = self:find(name).chunk
  return { pos = tonumber(c:match("\n%s*POSITION (%S+)")), len = tonumber(c:match("\n%s*LENGTH (%S+)")),
           rate = tonumber(c:match("\n%s*PLAYRATE (%S+)")) }
end

local function owner_mark(chunk) return chunk:match("P_EXT:reach_owner%s+(%S+)") end

function FT:_root_synced(rec)
  local r = rec
  while r.parent do r = self.byguid[r.parent] or { chunk = "" } if r == nil then break end end
  return owner_mark(r.chunk) ~= nil
end

function FT:snapshot()
  local out = {}
  for _, r in ipairs(self.list) do
    if self:_root_synced(r) then out[#out + 1] = { guid = r.guid, chunk = r.chunk, parent = r.parent } end
  end
  return out
end

function FT:orphans()
  local out = {}
  for _, r in ipairs(self.list) do
    if not self:_root_synced(r) then out[#out + 1] = { guid = r.guid, name = r.chunk:match('NAME "([^"]*)"') or "?" } end
  end
  return out
end

-- Move wanted (set of guids) unsynced tracks + their children under the folder, after its contents.
function FT:adopt(folder_guid, wanted)
  local adopting, moved = {}, {}
  for _, r in ipairs(self.list) do
    if not self:_root_synced(r) and (wanted[r.guid] or (r.parent and adopting[r.parent])) then
      if not (r.parent and adopting[r.parent]) then r.parent = folder_guid end
      adopting[r.guid] = true
      moved[#moved + 1] = r
    end
  end
  if #moved == 0 then return 0 end
  local is_moved = {}
  for _, r in ipairs(moved) do is_moved[r.guid] = true end
  local rest = {}
  for _, r in ipairs(self.list) do if not is_moved[r.guid] then rest[#rest + 1] = r end end
  local in_sub, last = {}, nil
  for i, r in ipairs(rest) do
    if r.guid == folder_guid or (r.parent and in_sub[r.parent]) then in_sub[r.guid] = true last = i end
  end
  for i, r in ipairs(moved) do table.insert(rest, (last or #rest) + i, r) end
  self.list = rest
  return #moved
end

function FT:ensure_folder(me)
  for _, r in ipairs(self.list) do
    if not r.parent and owner_mark(r.chunk) == me.id then return r.guid, false end
  end
  for _, r in ipairs(self.list) do   -- same person on another server: recognise by email, re-tag
    if not r.parent and me.email and r.chunk:match("P_EXT:reach_owner_email%s+(%S+)") == me.email:lower() then
      r.chunk = r.chunk:gsub("P_EXT:reach_owner %S+", "P_EXT:reach_owner " .. me.id)
      return r.guid, false
    end
  end
  local g = FT.guid()
  self:_add(g, string.format('<TRACK\n  NAME "%s"\n  P_EXT:reach_owner %s\n  P_EXT:reach_owner_email %s\n  TRACKID %s\n>',
    me.display_name, me.id, (me.email or ""):lower(), g), nil)
  return g, true
end

function FT:retag_owner(old_id, me)
  local n = 0
  for _, r in ipairs(self.list) do
    if owner_mark(r.chunk) == old_id then
      r.chunk = r.chunk:gsub("P_EXT:reach_owner %S+", "P_EXT:reach_owner " .. me.id)
      n = n + 1
    end
  end
  return n
end

function FT:_add(guid, chunk, parent)
  local rec = { guid = guid, chunk = chunk, parent = parent }
  self.list[#self.list + 1] = rec
  self.byguid[guid] = rec
  return rec
end

function FT:chunk(guid) return self.byguid[guid] and self.byguid[guid].chunk end
function FT:begin_batch() end
function FT:end_batch() end

function FT:apply(items)
  for _, it in ipairs(items) do
    local rec = self.byguid[it.guid]
    if it.deleted then
      if rec then
        for i, r in ipairs(self.list) do if r == rec then table.remove(self.list, i) break end end
        self.byguid[it.guid] = nil
      end
    elseif rec then rec.chunk = it.chunk
    else self:_add(it.guid, it.chunk, nil) end
  end
end

function FT:arrange(order)
  local index = {}
  for i, r in ipairs(self.list) do index[r.guid] = i end
  local present, in_present, start = {}, {}, math.huge
  for _, o in ipairs(order) do
    if index[o.guid] then
      present[#present + 1] = o
      in_present[o.guid] = true
      start = math.min(start, index[o.guid])
    end
  end
  if #present == 0 then return end
  local moving = {}
  for _, o in ipairs(present) do moving[o.guid] = true end
  local rest = {}
  for _, r in ipairs(self.list) do if not moving[r.guid] then rest[#rest + 1] = r end end
  local result, inserted = {}, false
  local idx = 0
  for _, r in ipairs(self.list) do
    idx = idx + 1
    if idx == start and not inserted then
      for _, o in ipairs(present) do
        local rec = self.byguid[o.guid]
        rec.parent = (o.parent and in_present[o.parent]) and o.parent or nil
        result[#result + 1] = rec
      end
      inserted = true
    end
    if not moving[r.guid] then result[#result + 1] = r end
  end
  self.list = result
end

-- ---- test helpers ----

function FT.guid()
  return string.format("{%08X-%04X-%04X-%04X-%012X}", math.random(0, 0xffffffff), math.random(0, 0xffff),
    math.random(0, 0xffff), math.random(0, 0xffff), math.random(0, 0xffffffffffff))
end

-- opts: pos, len (seconds), beat (item timebase), track_beat (track timebase), env (list of automation times)
function FT:add_track(name, parent, wav, opts)
  opts = opts or {}
  local g = FT.guid()
  local extra = ""
  if wav or opts.pos then
    extra = string.format('  <ITEM\n    POSITION %s\n    SNAPOFFS 0\n    LENGTH %s\n%s    PLAYRATE 1 1 0 -1 0 0.0025\n' ..
      '    <SOURCE WAVE\n      FILE "%s"\n    >\n  >\n', tostring(opts.pos or 0), tostring(opts.len or 2),
      opts.beat and ("    BEAT " .. opts.beat .. "\n") or "", wav or "none.wav")
  end
  if opts.env then
    local pts = {}
    for _, t in ipairs(opts.env) do pts[#pts + 1] = "    PT " .. t .. " 1 0" end
    extra = "  <VOLENV2\n    ACT 1 -1\n" .. table.concat(pts, "\n") .. "\n  >\n" .. extra
  end
  local beat = opts.track_beat and ("  BEAT " .. opts.track_beat .. "\n") or ""
  self:_add(g, string.format('<TRACK\n  NAME "%s"\n%s  VOLPAN 1 0 -1 -1 1\n  TRACKID %s\n%s>', name, beat, g, extra), parent)
  return g
end

function FT:edit(guid, fn) self.byguid[guid].chunk = fn(self.byguid[guid].chunk) end

function FT:remove(guid) self:apply({ { guid = guid, deleted = true } }) end

function FT:move_before(guid, before_guid)
  local rec = self.byguid[guid]
  for i, r in ipairs(self.list) do if r == rec then table.remove(self.list, i) break end end
  for i, r in ipairs(self.list) do if r.guid == before_guid then table.insert(self.list, i, rec) return end end
end

-- "Name" lines with indentation, e.g. { "alice", "  Guitar", "  Vocals" }
function FT:outline()
  local out = {}
  for _, r in ipairs(self.list) do
    local depth, p = 0, r.parent
    while p do depth = depth + 1 p = self.byguid[p] and self.byguid[p].parent end
    out[#out + 1] = string.rep("  ", depth) .. (r.chunk:match('NAME "([^"]*)"') or "?")
  end
  return out
end

function FT:find(name)
  for _, r in ipairs(self.list) do if r.chunk:match('NAME "([^"]*)"') == name then return r end end
end

return FT
