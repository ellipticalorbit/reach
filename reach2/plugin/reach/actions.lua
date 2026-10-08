-- Entry points invoked by the action scripts (Reach_*.lua). Builds the real REAPER environment and runs each
-- operation as an async task so REAPER stays responsive.
local actions = {}

local DEFAULT_SERVER = "http://localhost:8000"

local function build(plugin_dir, opts)
  opts = opts or {}
  local fs = require("reach.fs")
  local proc = require("reach.proc")
  local store = require("reach.store").reaper()
  proc.tmp = store.tmp_dir()

  local api
  api = require("reach.api").new({
    base_url = function()
      if opts.configured_server then return store.cfg_get("server_url") or DEFAULT_SERVER end
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
  })
  local engine = require("reach.engine").new({
    api = api, store = store, tracks = tracks, media = media, ui = ui,
    new_guid = function() return reaper.genGuid("") end,
    device_label = "REAPER on " .. (reaper.GetOS and reaper.GetOS() or "?"),
  })
  return engine, ui, store, fs
end

-- Run fn(engine, ui, store) as a task with busy-guard and error reporting.
local function run(plugin_dir, name, fn, build_opts)
  local busy = reaper.GetExtState("Reach", "busy")
  if busy ~= "" and (os.time() - (tonumber(busy) or 0)) < 600 then
    reaper.MB("Another Reach operation is still running.", "Reach", 0)
    return
  end
  local engine, ui, store = build(plugin_dir, build_opts)
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

local function report(ui, s)
  ui:log(string.format("Sync complete: %d pulled, %d pushed, %d deleted here by others, %d removed for everyone.",
    s.pulled, s.pushed, s.deleted_remote, s.removed_here))
  local notes = {}
  if s.adopted and s.adopted > 0 then notes[#notes + 1] = s.adopted .. " track(s) moved into your Reach folder." end
  if (s.hq_uploaded or 0) > 0 or (s.hq_downloaded or 0) > 0 then
    ui:log(string.format("High quality: %d uploaded, %d downloaded.", s.hq_uploaded, s.hq_downloaded))
  end
  for _, f in ipairs(s.hq_failed or {}) do
    notes[#notes + 1] = "No high-quality copy of \"" .. f.name .. "\" was uploaded: " .. tostring(f.reason)
  end
  if s.hq_error then notes[#notes + 1] = "High-quality upload problem: " .. s.hq_error end
  if s.conflicts > 0 then
    notes[#notes + 1] = s.conflicts .. " track(s) changed on the server while you were syncing: " ..
      table.concat(s.conflicted, ", ") .. "\nRun Sync again to resolve them."
  end
  for _, sk in ipairs(s.skipped) do
    notes[#notes + 1] = "Not pushed: \"" .. sk.name .. "\" - " .. sk.reason
  end
  return notes
end

-- hq = false: Ogg only (small, fast). hq = true: also uploads lossless originals and downloads them where they exist.
local function sync_action(dir, hq)
  run(dir, hq and "Sync (high quality)" or "Sync (low quality)", function(engine, ui, store)
    if not need_saved_project(store) then return end
    local notes = report(ui, engine:sync({ hq = hq }))
    if #notes > 0 then ui:info("Reach", table.concat(notes, "\n\n")) end
  end)
end

function actions.sync_lq(dir) sync_action(dir, false) end
function actions.sync_hq(dir) sync_action(dir, true) end

function actions.share(dir)
  run(dir, "Share song", function(engine, ui, store)
    if not need_saved_project(store) then return end
    engine:ensure_login()
    local default = reaper.GetProjectName(0, ""):gsub("%.[Rr][Pp][Pp]$", "")
    local name = ui:prompt("Share song", "Song name", default)
    if not name or name == "" then return end
    local code, s = engine:share_and_sync(name)
    ui:clipboard(code)
    store.save_project()
    local notes = report(ui, s)
    table.insert(notes, 1, "Share this join code with your collaborators (copied to the clipboard, and " ..
      "added to the project notes):\n\n" .. code .. "\n\nThey use 'Reach: Join song'.")
    ui:info("Reach: song shared", table.concat(notes, "\n\n"))
  end)
end

function actions.join(dir)
  run(dir, "Join song", function(engine, ui, store)
    engine:ensure_login()
    local code = ui:prompt("Join song", "Join code", "")
    if not code or code == "" then return end
    local p, s = engine:join_new(code)
    store.save_project()
    local notes = report(ui, s)
    if #notes > 0 then ui:info("Reach", table.concat(notes, "\n\n")) end
  end, { configured_server = true })
end

function actions.join_code(dir)
  run(dir, "Show join code", function(engine, ui, store)
    local code = engine:show_join_code()
    ui:clipboard(code)
    store.save_project()
    ui:info("Reach: join code", "Join code (copied to the clipboard, and added to the project notes):\n\n" .. code)
  end)
end

function actions.list_songs(dir)
  run(dir, "List songs", function(engine, ui)
    local songs = engine:list_songs()
    if #songs == 0 then ui:info("Reach", "You aren't in any songs yet.") return end
    local lines = {}
    for i, song in ipairs(songs) do
      lines[#lines + 1] = string.format("%d. %s%s  [%s]  %s  (%.1f MB)", i, song.name,
        song.linked and "  <- this project" or "", song.role,
        song.join_code and ("join code: " .. song.join_code) or "join code: ask the owner",
        (song.storage_bytes or 0) / 1048576)
    end
    local text = table.concat(lines, "\n")
    ui:log("Your songs:\n" .. text)
    local pick = ui:prompt("Your songs (see console for the full list)", "Number to copy its join code (or cancel)", "")
    local n = tonumber(pick or "")
    if n and songs[n] then
      if songs[n].join_code then
        ui:clipboard(songs[n].join_code)
        ui:info("Reach", "Join code for \"" .. songs[n].name .. "\" copied: " .. songs[n].join_code)
      else
        ui:info("Reach", "Only the owner can see the join code for \"" .. songs[n].name .. "\".")
      end
    end
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
    if url and url ~= "" then store.cfg_set("server_url", require("reach.api").normalise_url(url)) end
    local tb = require("reach.toolbar")
    local previous = tb.take_result(store.tmp_dir())
    if previous then ui:info("Reach: toolbar", "Last time, the toolbar change ended with: " .. previous) end
    if ui:confirm("Reach settings", "Add Reach buttons (Sync LQ, Sync HQ, Join song, Share song) to your main toolbar?\n\n" ..
        "REAPER only reads toolbar changes at startup, so they are added when you next quit REAPER. " ..
        "Nothing is changed if the buttons are already there.") then
      local res = tb.install(dir, store.tmp_dir(), function(explanation)
        return ui:confirm("Reach: toolbar", explanation .. "\n\nCreate a separate 'Reach' toolbar instead?")
      end)
      ui:info("Reach: toolbar", res.message)
    end
  end)
end

actions._build = build
actions._run = run

return actions
