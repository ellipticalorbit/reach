-- A small fake of REAPER's ReaScript API, enough to drive reach/reaper_tracks.lua, reach/store.lua (reaper),
-- reach/ui.lua (reaper) and reach/actions.lua outside REAPER. Models documented REAPER behaviour; it is not
-- REAPER, so passing here is necessary but not sufficient.
local fs = require("reach.fs")

local function new_world(root, opts)
  opts = opts or {}
  local W = { tracks = {}, ext = {}, proj_ext = {}, console = {}, mb = {}, deferred = {}, browser = opts.browser }
  local R = {}

  local function find(tr) for i, t in ipairs(W.tracks) do if t == tr then return i end end end
  local function guid_of(chunk) return chunk:match("^%s*<TRACK[ \t]+(%b{})") or chunk:match("\n%s*TRACKID%s+(%b{})") end

  function R.genGuid() return string.format("{%08X-%04X-%04X-%04X-%012X}", math.random(0, 0xffffffff), math.random(0, 0xffff),
    math.random(0, 0xffff), math.random(0, 0xffff), math.random(0, 0xffffffffffff)) end

  function R.CountTracks() return #W.tracks end
  function R.GetTrack(_, i) return W.tracks[i + 1] end
  function R.GetTrackGUID(tr) return tr.guid end
  function R.ValidatePtr(tr) return find(tr) ~= nil end

  function R.GetParentTrack(tr)
    local stack, depth = {}, 0
    for _, t in ipairs(W.tracks) do
      local parent = stack[#stack]
      if t == tr then return parent end
      local d = t.folderdepth
      if d == 1 then stack[#stack + 1] = t
      elseif d < 0 then for _ = 1, -d do stack[#stack] = nil end end
    end
  end

  function R.InsertTrackAtIndex(i)
    local t = { guid = R.genGuid(), chunk = nil, folderdepth = 0, selected = false, ext = {}, name = "" }
    table.insert(W.tracks, i + 1, t)
  end
  function R.DeleteTrack(tr) table.remove(W.tracks, find(tr)) end

  function R.GetTrackStateChunk(tr)
    local body = tr.chunk or ("<TRACK\n  TRACKID " .. tr.guid .. "\n>")
    body = body:gsub("\n%s*P_EXT:[^\n]*", "")
    local lines = {}
    for k, v in pairs(tr.ext) do lines[#lines + 1] = "  P_EXT:" .. k .. " " .. v end
    table.sort(lines)
    local out = body:gsub("\n>%s*$", "\n" .. table.concat(lines, "\n") .. (#lines > 0 and "\n" or "") .. ">")
    if tr.folderdepth ~= 0 then out = out:gsub("\n>%s*$", "\n  ISBUS 1 1\n>") end
    if tr.selected then out = out:gsub("\n>%s*$", "\n  SEL 1\n>") end
    return true, out
  end
  function R.SetTrackStateChunk(tr, chunk)
    local g = guid_of(chunk)
    if g then tr.guid = g end
    tr.ext = {}
    for k, v in chunk:gmatch("P_EXT:(%S+)%s+([^\n]+)") do tr.ext[k] = v end
    tr.chunk = chunk
    tr.folderdepth = chunk:find("ISBUS 1 1", 1, true) and 1 or 0
    return true
  end

  function R.GetSetMediaTrackInfo_String(tr, key, val, set)
    local ek = key:match("^P_EXT:(.+)")
    if set then
      if ek then tr.ext[ek] = val elseif key == "P_NAME" then tr.name = val
        tr.chunk = '<TRACK\n  NAME "' .. val .. '"\n  TRACKID ' .. tr.guid .. '\n>' end
      return true, val
    end
    if ek then return tr.ext[ek] ~= nil, tr.ext[ek] or "" end
    if key == "P_NAME" then return true, tr.name end
    return false, ""
  end
  function R.GetMediaTrackInfo_Value(tr, key)
    if key == "IP_TRACKNUMBER" then return find(tr) end
    if key == "I_FOLDERDEPTH" then return tr.folderdepth end
    return 0
  end
  function R.SetMediaTrackInfo_Value(tr, key, v) if key == "I_FOLDERDEPTH" then tr.folderdepth = v end return true end
  function R.ColorToNative(r, g, b) return r | (g << 8) | (b << 16) end

  function R.CountSelectedTracks() local n = 0 for _, t in ipairs(W.tracks) do if t.selected then n = n + 1 end end return n end
  function R.GetSelectedTrack(_, i) local n = 0 for _, t in ipairs(W.tracks) do if t.selected then if n == i then return t end n = n + 1 end end end
  function R.SetOnlyTrackSelected(tr) for _, t in ipairs(W.tracks) do t.selected = (t == tr) end end
  function R.SetTrackSelected(tr, v) tr.selected = v end
  function R.ReorderSelectedTracks(before)
    local moving, rest, shift = {}, {}, 0
    for i, t in ipairs(W.tracks) do
      if t.selected then moving[#moving + 1] = t if i - 1 < before then shift = shift + 1 end else rest[#rest + 1] = t end
    end
    local pos = before - shift
    for i, t in ipairs(moving) do table.insert(rest, pos + i, t) end
    W.tracks = rest
  end

  function R.Undo_BeginBlock() end
  function R.Undo_EndBlock() end
  function R.PreventUIRefresh() end
  function R.TrackList_AdjustWindows() end
  function R.UpdateArrange() end

  function R.GetExtState(s, k) return W.ext[s .. "/" .. k] or "" end
  function R.SetExtState(s, k, v) W.ext[s .. "/" .. k] = v end
  function R.DeleteExtState(s, k) W.ext[s .. "/" .. k] = nil end
  function R.GetProjExtState(_, s, k) local v = W.proj_ext[s .. "/" .. k] if v then return 1, v end return 0, "" end
  function R.SetProjExtState(_, s, k, v) W.proj_ext[s .. "/" .. k] = v end
  function R.MarkProjectDirty() end
  function R.GetSetProjectNotes(_, set, notes)
    if set then W.notes = notes end
    return W.notes or ""
  end
  function R.GetResourcePath() return root .. "/resource" end
  function R.GetProjectPath() return root .. "/project" end
  function R.GetProjectName() return W.project_name end
  W.project_name, W.commands = "song.rpp", {}
  function R.Main_OnCommand(id)
    W.commands[#W.commands + 1] = id
    if id == 40859 then -- new project tab: empty, unsaved
      W.tracks, W.proj_ext, W.notes, W.project_name = {}, {}, nil, ""
    elseif id == 40022 then -- save as
      W.project_name = (W.name or "new") .. "-song.rpp"
    end
  end
  function R.GetTrackName(tr) return true, (tr.chunk and tr.chunk:match('NAME "([^"]*)"')) or tr.name or "" end
  function R.Main_SaveProject() end
  function R.GetOS() return "OSX64" end
  function R.RecursiveCreateDirectory(p) os.execute("mkdir -p '" .. p .. "'") return 1 end

  function R.ShowConsoleMsg(m) W.console[#W.console + 1] = m end
  function R.MB(msg, title, typ)
    W.mb[#W.mb + 1] = { msg = msg, title = title, typ = typ }
    local f = opts.mb_answer
    return f and f(msg, title, typ) or (typ == 3 and 6 or typ == 4 and 6 or 1)
  end
  function R.GetUserInputs(title, n, caption, default) local f = opts.input return true, (f and f(title, caption, default) or default) end
  function R.CF_ShellExecute(url) if W.browser then W.browser(url) end end
  function R.CF_SetClipboard(t) W.clipboard = t end
  function R.ExecProcess(cmd, timeout)
    assert(timeout == -1, "only fire-and-forget ExecProcess is used")
    os.execute(cmd .. " >/dev/null 2>&1 &")
    return "0\n"
  end
  function R.time_precise() return os.time() end
  function R.defer(fn) W.deferred[#W.deferred + 1] = fn end

  -- minimal gfx: records what the progress window does
  W.gfx_log = { inits = 0, quits = 0, strings = {}, updates = 0 }
  local G = { w = 500, h = 150, x = 0, y = 0, mouse_x = 0, mouse_y = 0, mouse_cap = 0, char = 0 }
  function G.init() W.gfx_log.inits = W.gfx_log.inits + 1 return 1 end
  function G.quit() W.gfx_log.quits = W.gfx_log.quits + 1 end
  function G.getchar() return G.char end
  function G.measurestr(str) return #str * 8, 16 end
  function G.update() W.gfx_log.updates = W.gfx_log.updates + 1 end
  function G.drawstr(str) W.gfx_log.strings[#W.gfx_log.strings + 1] = str end
  G.set, G.rect, G.setfont = function() end, function() end, function() end
  W.gfx = G
  function R.GetMousePosition() return 100, 100 end

  W.R = R
  -- run deferred callbacks until none remain
  function W.pump()
    local guard = 0
    while #W.deferred > 0 do
      local batch = W.deferred
      W.deferred = {}
      for _, f in ipairs(batch) do f() end
      os.execute("sleep 0.02")
      guard = guard + 1
      assert(guard < 5000, "deferred loop did not finish")
    end
  end
  function W.outline()
    local out, depth = {}, 0
    for _, t in ipairs(W.tracks) do
      local name = (t.chunk and t.chunk:match('NAME "([^"]*)"')) or t.name
      out[#out + 1] = string.rep("  ", depth) .. name
      if t.folderdepth == 1 then depth = depth + 1 elseif t.folderdepth < 0 then depth = math.max(0, depth + t.folderdepth) end
    end
    return out
  end
  return W
end

return new_world
