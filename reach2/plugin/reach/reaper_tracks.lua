-- Adapter between the sync engine and the REAPER project. Everything that touches REAPER's track API lives
-- here. "Synced" tracks are those inside a top-level folder track marked with P_EXT:reach_owner.
local OWNER_KEY = "P_EXT:reach_owner"
local EMAIL_KEY = "P_EXT:reach_owner_email" -- user ids differ per server; the email doesn't

local Tracks = {}
Tracks.__index = Tracks

local adapter = {}
function adapter.new() return setmetatable({}, Tracks) end

local function get_chunk(tr)
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if ok and chunk and #chunk < 4194303 then return chunk end
  if reaper.SNM_CreateFastString then -- very large chunks need SWS's fast string
    local fast = reaper.SNM_CreateFastString("")
    local res
    if reaper.SNM_GetSetObjectState(tr, fast, false, false) then res = reaper.SNM_GetFastString(fast) end
    reaper.SNM_DeleteFastString(fast)
    if res then return res end
  end
  return chunk
end

local function set_chunk(tr, chunk)
  if #chunk >= 4194303 and reaper.SNM_CreateFastString then
    local fast = reaper.SNM_CreateFastString("")
    local ret
    if reaper.SNM_SetFastString(fast, chunk) then ret = reaper.SNM_GetSetObjectState(tr, fast, true, false) end
    reaper.SNM_DeleteFastString(fast)
    return ret
  end
  return reaper.SetTrackStateChunk(tr, chunk, false)
end

local function owner_of(tr)
  local ok, v = reaper.GetSetMediaTrackInfo_String(tr, OWNER_KEY, "", false)
  if ok and v ~= "" then return v end
  return nil
end

local function owner_email_of(tr)
  local ok, v = reaper.GetSetMediaTrackInfo_String(tr, EMAIL_KEY, "", false)
  if ok and v ~= "" then return v:lower() end
  return nil
end

local function guid_map()
  local map = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    map[reaper.GetTrackGUID(tr)] = tr
  end
  return map
end

local function index_of(tr) return math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1 end

function Tracks:new_guid() return reaper.genGuid("") end

-- Tempo map of the current project, as conversions between seconds and quarter notes.
function Tracks:tempo_map()
  return { qn = function(t) return reaper.TimeMap2_timeToQN(0, t) end,
           time = function(q) return reaper.TimeMap2_QNToTime(0, q) end,
           bpm = function(t) return reaper.TimeMap2_GetDividedBpmAtTime(0, t) end }
end

-- Project timebase settings (items, envelopes). There's no API for these, so read them from the saved project
-- file; REAPER's default is beats (1) for both.
function Tracks:timebase()
  local tb = { items = 1, env = 1 }
  local _, path = reaper.EnumProjects(-1, "")
  local f = path and path ~= "" and io.open(path, "r")
  if f then
    local text = f:read("a")
    f:close()
    tb.items = tonumber(text:match("\n%s*TIMELOCKMODE (%-?%d+)") or "") or 1
    tb.env = tonumber(text:match("\n%s*TEMPOENVLOCKMODE (%-?%d+)") or "") or 1
  end
  return tb
end

-- The project's tempo map as plain data: base tempo / time signature and the tempo/time-signature markers.
-- Markers are kept in musical position (measure, beat) so they mean the same thing on every machine.
function Tracks:read_tempo()
  local bpm = reaper.GetProjectTimeSignature2(0)
  local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  local markers = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
    local _, _, measure, beat, mbpm, mnum, mden, linear = reaper.GetTempoTimeSigMarker(0, i)
    markers[#markers + 1] = { measure = measure, beat = beat, bpm = mbpm, num = mnum, den = mden, linear = linear }
  end
  return { bpm = bpm, num = num, den = den, markers = markers }
end

-- Replace the project's tempo map. REAPER retimes items according to their timebase as it does for a manual
-- tempo change.
function Tracks:write_tempo(t)
  reaper.Undo_BeginBlock()
  for i = reaper.CountTempoTimeSigMarkers(0) - 1, 0, -1 do reaper.DeleteTempoTimeSigMarker(0, i) end
  reaper.SetCurrentBPM(0, t.bpm, false)
  local has_start = false
  for _, m in ipairs(t.markers or {}) do if (m.measure or 0) == 0 and (m.beat or 0) == 0 then has_start = true end end
  local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  if not has_start and t.num and (t.num ~= num or t.den ~= den) then
    reaper.SetTempoTimeSigMarker(0, -1, -1, 0, 0, t.bpm, t.num, t.den, false)
  end
  for _, m in ipairs(t.markers or {}) do
    reaper.SetTempoTimeSigMarker(0, -1, -1, m.measure, m.beat, m.bpm, m.num or 0, m.den or 0, m.linear and true or false)
  end
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock("Reach: song tempo", -1)
end

-- Ordered list of synced tracks: { guid, chunk, parent (guid or nil) }
function Tracks:snapshot()
  local list, synced = {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(tr)
    local parent = reaper.GetParentTrack(tr)
    local pguid = parent and reaper.GetTrackGUID(parent) or nil
    local is_synced
    if parent then is_synced = synced[pguid] else is_synced = owner_of(tr) ~= nil end
    if is_synced then
      synced[guid] = true
      list[#list + 1] = { guid = guid, chunk = get_chunk(tr), parent = pguid }
    end
  end
  return list
end

-- Finds (or creates) this user's top-level Reach folder. Returns guid, created.
function Tracks:ensure_folder(me)
  local nested
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if owner_of(tr) == me.id then
      if not reaper.GetParentTrack(tr) then return reaper.GetTrackGUID(tr), false end
      nested = nested or reaper.GetTrackGUID(tr)
    end
  end
  if nested then return nested, false end -- never create a second folder just because it got nested
  -- Same person, different server (new user id): recognise the folder by email and re-tag it.
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if me.email and owner_email_of(tr) == me.email:lower() and not reaper.GetParentTrack(tr) then
      reaper.GetSetMediaTrackInfo_String(tr, OWNER_KEY, me.id, true)
      return reaper.GetTrackGUID(tr), false
    end
  end
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", me.display_name, true)
  reaper.GetSetMediaTrackInfo_String(tr, OWNER_KEY, me.id, true)
  if me.email then reaper.GetSetMediaTrackInfo_String(tr, EMAIL_KEY, me.email:lower(), true) end
  -- stable per-user colour derived from the id
  local n = 0
  for c in me.id:gmatch("%x") do n = (n * 31 + tonumber(c, 16)) % 360 end
  local h, s, v = n / 360, 0.5, 0.75
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  local rgb = ({ { v, t, p }, { q, v, p }, { p, v, t }, { p, q, v }, { t, p, v }, { v, p, q } })[i % 6 + 1]
  reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR",
    reaper.ColorToNative(math.floor(rgb[1] * 255), math.floor(rgb[2] * 255), math.floor(rgb[3] * 255)) | 0x1000000)
  return reaper.GetTrackGUID(tr), true
end

-- After moving to another server: folders tagged with my old user id get my new one (and my email).
function Tracks:retag_owner(old_id, me)
  local n = 0
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if owner_of(tr) == old_id then
      reaper.GetSetMediaTrackInfo_String(tr, OWNER_KEY, me.id, true)
      if me.email then reaper.GetSetMediaTrackInfo_String(tr, EMAIL_KEY, me.email:lower(), true) end
      n = n + 1
    end
  end
  return n
end

-- Owner of each top-level Reach folder: guid -> { id, email }.
function Tracks:folder_owners()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not reaper.GetParentTrack(tr) then
      local id = owner_of(tr)
      if id then out[reaper.GetTrackGUID(tr)] = { id = id, email = owner_email_of(tr) } end
    end
  end
  return out
end

function Tracks:chunk(guid)
  local tr = guid_map()[guid]
  return tr and get_chunk(tr) or nil
end

-- items: { guid, chunk } to create/replace, or { guid, deleted = true }
function Tracks:apply(items)
  local map = guid_map()
  for _, it in ipairs(items) do
    local tr = map[it.guid]
    if it.deleted then
      if tr then reaper.DeleteTrack(tr) map[it.guid] = nil end
    else
      if not tr then
        local idx = reaper.CountTracks(0)
        reaper.InsertTrackAtIndex(idx, false)
        tr = reaper.GetTrack(0, idx)
      end
      set_chunk(tr, it.chunk)
      map[it.guid] = tr
    end
  end
end

-- order: full desired order of synced tracks as { guid, parent }. Places them contiguously (starting
-- where the first one currently sits) and rebuilds folder nesting from the parent links.
function Tracks:arrange(order)
  local map = guid_map()
  local selected = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do selected[#selected + 1] = reaper.GetSelectedTrack(0, i) end

  -- only tracks that exist in the project take part
  local present, in_present, parent_of = {}, {}, {}
  local start = math.huge
  for _, o in ipairs(order) do
    local tr = map[o.guid]
    if tr then
      present[#present + 1] = o
      in_present[o.guid] = true
      parent_of[o.guid] = o.parent
      start = math.min(start, index_of(tr))
    end
  end
  if #present == 0 then return end

  local depth = {}
  local function depth_of(g)
    if depth[g] then return depth[g] end
    local p = parent_of[g]
    depth[g] = (p and in_present[p]) and (depth_of(p) + 1) or 0
    return depth[g]
  end

  for i, o in ipairs(present) do
    local tr, target = map[o.guid], start + i - 1
    if index_of(tr) ~= target then
      reaper.SetOnlyTrackSelected(tr)
      reaper.ReorderSelectedTracks(target, 0)
    end
  end
  for i, o in ipairs(present) do
    local nextd = present[i + 1] and depth_of(present[i + 1].guid) or 0
    reaper.SetMediaTrackInfo_Value(map[o.guid], "I_FOLDERDEPTH", nextd - depth_of(o.guid))
  end

  for i = 0, reaper.CountTracks(0) - 1 do reaper.SetTrackSelected(reaper.GetTrack(0, i), false) end
  for _, tr in ipairs(selected) do if reaper.ValidatePtr(tr, "MediaTrack*") then reaper.SetTrackSelected(tr, true) end end
end

-- Tracks that are not inside any Reach folder: { guid, name }
function Tracks:orphans()
  local synced = {}
  for _, t in ipairs(self:snapshot()) do synced[t.guid] = true end
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local g = reaper.GetTrackGUID(tr)
    if not synced[g] then
      local _, name = reaper.GetTrackName(tr)
      out[#out + 1] = { guid = g, name = name }
    end
  end
  return out
end

-- Move the not-yet-synced tracks in `wanted` (set of guids) plus their children into the folder
-- `folder_guid`, after the folder's existing contents. Returns how many tracks were moved.
function Tracks:adopt(folder_guid, wanted)
  local snap = self:snapshot()
  local synced = {}
  for _, t in ipairs(snap) do synced[t.guid] = true end
  local adopt, adopting = {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local g = reaper.GetTrackGUID(tr)
    if not synced[g] then
      local p = reaper.GetParentTrack(tr)
      local pg = p and reaper.GetTrackGUID(p)
      if pg and adopting[pg] then
        adopting[g] = true
        adopt[#adopt + 1] = { guid = g, parent = pg }
      elseif wanted[g] then
        adopting[g] = true
        adopt[#adopt + 1] = { guid = g, parent = folder_guid }
      end
    end
  end
  if #adopt == 0 then return 0 end

  local in_folder, last = {}, nil
  for i, t in ipairs(snap) do
    if t.guid == folder_guid or (t.parent and in_folder[t.parent]) then in_folder[t.guid] = true last = i end
  end
  local order = {}
  for i, t in ipairs(snap) do
    order[#order + 1] = { guid = t.guid, parent = t.parent }
    if i == last then for _, a in ipairs(adopt) do order[#order + 1] = a end end
  end
  self:begin_batch()
  self:arrange(order)
  self:end_batch()
  return #adopt
end

-- Same, for the currently selected tracks.
function Tracks:adopt_selected(folder_guid)
  local wanted = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    wanted[reaper.GetTrackGUID(reaper.GetSelectedTrack(0, i))] = true
  end
  return self:adopt(folder_guid, wanted)
end

function Tracks:begin_batch()
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
end

function Tracks:end_batch()
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Reach sync", -1)
end

return adapter
