-- Persistence. Two implementations with the same interface: REAPER (ExtState / project ExtState) and an
-- in-memory one for tests.
--   cfg_get(k) / cfg_set(k, v)       user-level settings (server URL, tokens) - survive across projects
--   project_load() / project_save(t) per-project sync state, saved inside the .rpp
--   tmp_dir() / media_dir()          scratch dir and the project's downloaded/transcoded audio cache
--   media_index_path()               path->sha cache so unchanged recordings aren't re-transcoded
local json = require("reach.json")
local fs = require("reach.fs")

local store = {}

function store.reaper()
  local R = reaper
  local s = {}
  function s.cfg_get(k)
    local v = R.GetExtState("Reach", k)
    if v == "" then return nil end
    return v
  end
  function s.cfg_set(k, v)
    if v == nil or v == "" then R.DeleteExtState("Reach", k, true) else R.SetExtState("Reach", k, v, true) end
  end
  function s.project_load()
    local ok, v = R.GetProjExtState(0, "Reach", "state")
    if ok ~= 0 and v ~= "" then
      local good, t = pcall(json.decode, v)
      if good then return t end
    end
    return nil
  end
  function s.project_save(t)
    R.SetProjExtState(0, "Reach", "state", json.encode(t))
    R.MarkProjectDirty(0)
  end
  local function base() return fs.norm(R.GetResourcePath()) .. "/Reach" end
  function s.tmp_dir() local d = base() .. "/tmp" fs.mkdir(d) return d end
  function s.media_index_path() fs.mkdir(base()) return base() .. "/media-index.json" end
  function s.project_dir() return fs.norm(R.GetProjectPath("")) end
  function s.media_dir()
    local d = s.project_dir() .. "/reach-media"
    fs.mkdir(d)
    return d
  end
  -- Set (or replace) a single line in the project notes: the line starting with `prefix`.
  function s.update_notes(prefix, text)
    local notes = R.GetSetProjectNotes(0, false, "") or ""
    local line = prefix .. text
    if notes:find(prefix, 1, true) then
      local pat = "[^\n]*" .. prefix:gsub("%p", "%%%0") .. "[^\n]*"
      notes = notes:gsub(pat, (line:gsub("%%", "%%%%")), 1)
    else
      notes = (notes ~= "" and (notes:gsub("%s+$", "") .. "\n") or "") .. line
    end
    R.GetSetProjectNotes(0, true, notes)
    R.MarkProjectDirty(0)
  end
  function s.project_saved() return R.GetProjectName(0, "") ~= "" end
  function s.save_project() if s.project_saved() then R.Main_SaveProject(0, false) end end
  return s
end

function store.memory(dir)
  fs.mkdir(dir)
  local cfg, project = {}, nil
  local s = {}
  function s.cfg_get(k) return cfg[k] end
  function s.cfg_set(k, v) cfg[k] = v end
  function s.project_load() return project and json.decode(json.encode(project)) or nil end
  function s.project_save(t) project = json.decode(json.encode(t)) end -- round-trip like the real thing
  function s.tmp_dir() fs.mkdir(dir .. "/tmp") return dir .. "/tmp" end
  function s.media_index_path() return dir .. "/media-index.json" end
  function s.media_dir() fs.mkdir(dir .. "/reach-media") return dir .. "/reach-media" end
  s.notes = {}
  function s.update_notes(prefix, text) s.notes[prefix] = text end
  function s.project_saved() return true end
  function s.save_project() end
  return s
end

return store
