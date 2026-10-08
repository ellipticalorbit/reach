-- In-memory stand-in for the REAPER project, implementing the same interface as reach/reaper_tracks.lua.
local FT = {}
FT.__index = FT

function FT.new() return setmetatable({ list = {}, byguid = {} }, FT) end

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
  local g = FT.guid()
  self:_add(g, string.format('<TRACK\n  NAME "%s"\n  P_EXT:reach_owner %s\n  TRACKID %s\n>', me.display_name, me.id, g), nil)
  return g, true
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

function FT:add_track(name, parent, wav)
  local g = FT.guid()
  local extra = wav and string.format('  <ITEM\n    POSITION 0\n    <SOURCE WAVE\n      FILE "%s"\n    >\n  >\n', wav) or ""
  self:_add(g, string.format('<TRACK\n  NAME "%s"\n  VOLPAN 1 0 -1 -1 1\n  TRACKID %s\n%s>', name, g, extra), parent)
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
