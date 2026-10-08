-- Entry points invoked by the action scripts (Reach_*.lua). Builds the real REAPER environment and runs each
-- operation as an async task so REAPER stays responsive.
local actions = {}

local DEFAULT_SERVER = "http://localhost:8000"

local function build(plugin_dir)
  local fs = require("reach.fs")
  local proc = require("reach.proc")
  local store = require("reach.store").reaper()
  proc.tmp = store.tmp_dir()

  local api
  api = require("reach.api").new({
    base_url = function()
      local st = store.project_load()
      return (st and st.server) or store.cfg_get("server_url") or DEFAULT_SERVER
    end,
    token = function() return store.cfg_get("token@" .. api:base()) end,
  })
  local ui = require("reach.ui").reaper()
  local tracks = require("reach.reaper_tracks").new()
  local media = require("reach.media").new({
    store = store, api = api, ffmpeg = require("reach.media").find_ffmpeg(plugin_dir),
    project_id = function() return store.project_load().project_id end,
    quality = function() return tonumber(store.cfg_get("ogg_quality")) or 1 end,
  })
  local engine = require("reach.engine").new({
    api = api, store = store, tracks = tracks, media = media, ui = ui,
    new_guid = function() return reaper.genGuid("") end,
    device_label = "REAPER on " .. (reaper.GetOS and reaper.GetOS() or "?"),
  })
  return engine, ui, store, fs
end

-- Run fn(engine, ui, store) as a task with busy-guard and error reporting.
local function run(plugin_dir, name, fn)
  local busy = reaper.GetExtState("Reach", "busy")
  if busy ~= "" and (os.time() - (tonumber(busy) or 0)) < 600 then
    reaper.MB("Another Reach operation is still running.", "Reach", 0)
    return
  end
  local engine, ui, store = build(plugin_dir)
  reaper.SetExtState("Reach", "busy", tostring(os.time()), false)
  require("reach.async").start(function() fn(engine, ui, store) end, function(task)
    reaper.DeleteExtState("Reach", "busy", false)
    if not task.ok then
      local e = task.err or {}
      local msg = type(e) == "table" and (e.msg or "unknown error") or tostring(e)
      if type(e) == "table" and e.unauthorized then
        store.cfg_set("token@" .. engine.api:base(), nil)
        msg = "Your Reach login is no longer valid. Run 'Reach: Log in' (or just try again)."
      end
      ui:log(name .. " failed: " .. msg)
      if type(e) == "table" and e.trace and not e.user then ui:log(e.trace) end
      ui:info("Reach: " .. name .. " failed", msg)
    end
  end)
end

local function need_saved_project(store)
  if store.project_saved() then return true end
  reaper.MB("Please save this project first (Reach keeps its sync state inside the project file).", "Reach", 0)
  return false
end

function actions.login(dir)
  run(dir, "Log in", function(engine) engine:login() end)
end

function actions.sync(dir)
  run(dir, "Sync", function(engine, ui, store)
    if not need_saved_project(store) then return end
    local s = engine:sync()
    ui:log(string.format("Sync complete: %d pulled, %d pushed, %d deleted here by others, %d removed for everyone.",
      s.pulled, s.pushed, s.deleted_remote, s.removed_here))
    local notes = {}
    if s.conflicts > 0 then
      notes[#notes + 1] = s.conflicts .. " track(s) changed on the server while you were syncing: " ..
        table.concat(s.conflicted, ", ") .. "\nRun Sync again to resolve them."
    end
    for _, sk in ipairs(s.skipped) do
      notes[#notes + 1] = "Not pushed: \"" .. sk.name .. "\" - " .. sk.reason
    end
    if #notes > 0 then ui:info("Reach", table.concat(notes, "\n\n")) end
  end)
end

function actions.share(dir)
  run(dir, "Share song", function(engine, ui, store)
    if not need_saved_project(store) then return end
    engine:ensure_login()
    local default = reaper.GetProjectName(0, ""):gsub("%.[Rr][Pp][Pp]$", "")
    local name = ui:prompt("Share song", "Song name", default)
    if not name or name == "" then return end
    local code = engine:share(name)
    ui:clipboard(code)
    store.save_project()
    ui:info("Reach: song shared", "Share this code with your collaborators (copied to the clipboard):\n\n" .. code ..
      "\n\nThey use 'Reach: Join song' in a new project.\n\nNext: put your tracks inside your folder " ..
      "(select tracks and run 'Reach: Add selected tracks to my folder'), then run 'Reach: Sync'.")
  end)
end

function actions.join(dir)
  run(dir, "Join song", function(engine, ui, store)
    if not need_saved_project(store) then return end
    engine:ensure_login()
    local code = ui:prompt("Join song", "Join code", "")
    if not code or code == "" then return end
    local p = engine:join(code)
    ui:log("Joined \"" .. p.name .. "\"")
    local s = engine:sync()
    ui:log(string.format("Pulled %d track(s).", s.pulled))
  end)
end

function actions.join_code(dir)
  run(dir, "Show join code", function(engine, ui, store)
    local code = engine:show_join_code()
    ui:clipboard(code)
    store.save_project()
    ui:info("Reach: join code", "Join code (copied to the clipboard, and added to the project notes):\n\n" .. code)
  end)
end

function actions.add_selected(dir)
  run(dir, "Add tracks", function(engine, ui)
    local n = engine:adopt_selected()
    ui:info("Reach", n == 0 and "Select the tracks you want to share first." or
      (n .. " track(s) moved into your Reach folder. Run 'Reach: Sync' to upload them."))
  end)
end

function actions.restore(dir)
  run(dir, "Restore deleted tracks", function(engine, ui, store)
    local list = engine:deleted_tracks()
    if #list == 0 then ui:info("Reach", "There are no deleted tracks.") return end
    local lines = {}
    for i, t in ipairs(list) do
      lines[#lines + 1] = string.format("%d. %s  (%s, deleted by %s)", i, t.name ~= "" and t.name or t.guid,
        t.owner or "?", t.author or "?")
      if i >= 25 then lines[#lines + 1] = "..." break end
    end
    ui:log("Deleted tracks:\n" .. table.concat(lines, "\n"))
    local pick = ui:prompt("Restore deleted track", "Number to restore (see console list)", "1")
    local n = tonumber(pick or "")
    if not n or not list[n] then return end
    engine:restore(list[n].guid)
    local s = engine:sync()
    ui:info("Reach", "Restored \"" .. list[n].name .. "\".")
  end)
end

function actions.settings(dir)
  run(dir, "Settings", function(engine, ui, store)
    local cur = store.cfg_get("server_url") or DEFAULT_SERVER
    local url = ui:prompt("Reach settings", "Server URL", cur)
    if url and url ~= "" then store.cfg_set("server_url", (url:gsub("/+$", ""))) end
    local q = ui:prompt("Reach settings", "Audio quality (Ogg q, -1..10; 1 = small)", store.cfg_get("ogg_quality") or "1")
    if q and tonumber(q) then store.cfg_set("ogg_quality", q) end
  end)
end

actions._build = build
actions._run = run

return actions
