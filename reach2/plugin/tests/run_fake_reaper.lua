-- Drives the real REAPER-facing code (actions, reaper_tracks, store, ui) against a fake ReaScript API,
-- with two "REAPER windows" talking to a real server.
package.path = "./?.lua;" .. package.path
math.randomseed(os.time())
local fs = require("reach.fs")
local new_world = require("tests.fake_reaper")

local URL = os.getenv("REACH_URL") or "http://localhost:8000"
local ROOT = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/reach-fake-reaper-" .. os.time()
fs.mkdir(ROOT)

local failures = 0
local function check(cond, msg) if not cond then failures = failures + 1 print("FAIL  " .. msg) else print("PASS  " .. msg) end end

local function browser_approve(url, email)
  local code = url:match("user_code=([%w%-]+)")
  local jar = ROOT .. "/jar" .. math.random(1e9)
  local function curl(a) local p = io.popen("curl -s -L -c '" .. jar .. "' -b '" .. jar .. "' " .. a) local o = p:read("a") p:close() return o end
  local page = curl("'" .. URL .. "/auth/dev-login?email=" .. email .. "&next=%2Fdevice%3Fuser_code%3D" .. code .. "'")
  local csrf = assert(page:match('name=csrf value="([^"]+)"'), page)
  assert(curl("-d 'user_code=" .. code .. "&action=approve&csrf=" .. csrf .. "' '" .. URL .. "/device/approve'"):find("Approved"))
end

local share_code
local function world(name)
  local email = name .. "-" .. os.time() .. math.random(1000, 9999) .. "@example.com"
  local w
  w = new_world(ROOT .. "/" .. name, {
    browser = function(url) browser_approve(url, email) end,
    mb_answer = function(msg, title, typ)
      if title:find("not synced") then return w.orphan_answer or 7 end -- default: leave them out
    end,
    input = function(title, caption, default)
      if title == "Share song" then return "Fake Song" end
      if title == "Join song" then return share_code end
      return default
    end,
  })
  w.name = name
  w.ext["Reach/server_url"] = URL
  fs.mkdir(ROOT .. "/" .. name .. "/project")
  return w
end

require("reach.progressui").delay = 0   -- show immediately in the test (quick syncs would otherwise never open it)
local PLUGIN = "./"
local actions = require("reach.actions")
local function act(w, fn)
  _G.reaper = w.R
  _G.gfx = w.gfx
  w.mb = {}
  fn()
  w.pump()
  for _, m in ipairs(w.mb) do
    if m.title:find("failed") then error(w.name .. ": " .. m.title .. ": " .. m.msg) end
  end
end

local function add_plain(w, name, wav)
  local R = w.R
  R.InsertTrackAtIndex(R.CountTracks())
  local tr = R.GetTrack(0, R.CountTracks() - 1)
  local g = tr.guid
  local item = wav and ('  <ITEM\n    POSITION 0\n    <SOURCE WAVE\n      FILE "' .. wav .. '"\n    >\n  >\n') or ""
  R.SetTrackStateChunk(tr, '<TRACK\n  NAME "' .. name .. '"\n  TRACKID ' .. g .. '\n' .. item .. '>')
  return tr
end

local function outline(w) return (table.concat(w.outline(), "|"):gsub("(%a+)%-%d+", "%1")) end

-- tiny wav
local wav = ROOT .. "/drums.wav"
do
  local parts = {}
  for i = 0, 7999 do parts[#parts + 1] = string.pack("<i2", math.floor(8000 * math.sin(2 * math.pi * 330 * i / 8000))) end
  local data = table.concat(parts)
  fs.write(wav, "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVEfmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, 8000, 16000, 2, 16) ..
    "data" .. string.pack("<I4", #data) .. data)
end

local ok, err = xpcall(function()
  local A, B = world("alice"), world("bob")

  act(A, function() actions.login(PLUGIN) end)
  check(A.ext["Reach/token@" .. URL] ~= nil, "alice logged in; token stored in ExtState")

  local drums = add_plain(A, "Drums", wav)
  local bass = add_plain(A, "Bass")
  add_plain(A, "Keys")

  act(A, function() actions.share(PLUGIN) end)
  share_code = A.clipboard
  check(share_code and share_code:match("^%w+%-%w+%-%w+%-%w+$"), "share put a join code on the clipboard: " .. tostring(share_code))
  check((A.notes or ""):find("Reach join code: " .. share_code, 1, true) ~= nil, "join code written to project notes")
  A.notes = "my own notes\nReach join code: OLD-OLD\nmore notes"
  act(A, function() actions.join_code(PLUGIN) end)
  check(A.notes == "my own notes\nReach join code: " .. share_code .. "\nmore notes", "show-join-code replaces only its own notes line: " .. A.notes:gsub("\n", " / "))
  check(A.proj_ext["Reach/state"] ~= nil, "project state saved in project ext state")

  A.R.SetOnlyTrackSelected(drums)
  A.R.SetTrackSelected(bass, true)
  act(A, function() actions.add_selected(PLUGIN) end)
  check(outline(A) == "alice|  Drums|  Bass|Keys", "selected tracks moved into alice's folder: " .. outline(A))
  check(A.tracks[2].folderdepth == 0 and A.tracks[3].folderdepth == -1 and A.tracks[1].folderdepth == 1,
    "folder depths: open/close set correctly")

  local first_sync = table.concat(A.console, ""):match("Sync complete[^\n]*")
  check(first_sync and first_sync:find("1 pushed", 1, true), "share synced automatically (pushed alice's folder): " .. tostring(first_sync))
  act(A, function() actions.sync_lq(PLUGIN) end)
  local last_sync
  for line in table.concat(A.console, ""):gmatch("Sync complete[^\n]*") do last_sync = line end
  check(last_sync and last_sync:find("2 pushed", 1, true), "sync after adding tracks pushed Drums + Bass: " .. tostring(last_sync))

  act(B, function() actions.login(PLUGIN) end)
  add_plain(B, "bob's old scratch track")
  B.project_name = "" -- not saved: join must not need the current project to be saved
  act(B, function() actions.join(PLUGIN) end)
  check(B.commands[1] == 40859 and B.commands[2] == 40022, "join opened a new project tab and the save-as dialog")
  check(B.project_name ~= "", "new project was saved")
  check(outline(B) == "alice|  Drums|  Bass|bob", "bob joined and pulled the song: " .. outline(B))
  check(not outline(B):find("scratch", 1, true), "bob's join happened in a fresh project")
  check(B.tracks[1].folderdepth == 1 and B.tracks[3].folderdepth == -1, "bob's folder depths correct")
  local dchunk = select(2, B.R.GetTrackStateChunk(B.tracks[2]))
  local path = dchunk:match('FILE "([^"]+)"')
  check(path and path:find("reach%-media/") and fs.exists(path), "bob's Drums points at downloaded ogg: " .. tostring(path))
  check(dchunk:find("<SOURCE VORBIS", 1, true) ~= nil, "bob's Drums source type is VORBIS")

  act(A, function() actions.sync_lq(PLUGIN) end)
  check(table.concat(A.console, ""):find("1 pulled, 0 pushed", 1, true) ~= nil, "alice picks up bob's folder, nothing to push")
  check(outline(A):find("alice|  Drums|  Bass|bob", 1, true) ~= nil, "alice outline: " .. outline(A))

  -- orphans: alice still has "Keys" outside her folder; the prompt appeared during her syncs and she said "leave out"
  local prompts = 0
  for _, m in ipairs(A.mb) do if m.title:find("not synced") then prompts = prompts + 1 end end
  check(outline(A):find("Keys", 1, true) ~= nil and A.tracks[#A.tracks].guid ~= nil, "orphan 'Keys' left outside the folder")
  A.orphan_answer = 6
  add_plain(A, "Loose")
  act(A, function() actions.sync_lq(PLUGIN) end)
  local sawprompt = false
  for _, m in ipairs(A.mb) do if m.title:find("not synced") then sawprompt = m.msg end end
  check(sawprompt and sawprompt:find("Loose", 1, true) and not sawprompt:find("Keys", 1, true),
    "prompt lists only the new orphan (Keys was dismissed earlier)")
  check(outline(A):find("alice|  Drums|  Bass|  Loose|", 1, true) ~= nil, "Loose adopted into alice's folder: " .. outline(A))
  act(B, function() actions.sync_lq(PLUGIN) end)
  check(outline(B):find("Loose", 1, true) ~= nil, "bob received the adopted track")
  A.orphan_answer = nil

  -- bob edits a track, alice receives it
  local bass_b = B.tracks[3]
  B.R.GetSetMediaTrackInfo_String(bass_b, "P_NAME", "Bass v2", true) -- a UI rename leaves folder state alone
  act(B, function() actions.sync_lq(PLUGIN) end)
  act(A, function() actions.sync_lq(PLUGIN) end)
  check(outline(A):find("alice|  Drums|  Bass v2|  Loose|bob", 1, true) ~= nil, "bob's rename reached alice: " .. outline(A))
  check(#A.tracks == 6 and #B.tracks == 5, "no duplicate tracks created: " .. #A.tracks .. "/" .. #B.tracks)

  -- the HQ action runs end to end through the real action code (alice's Drums is a lossless wav)
  act(A, function() actions.sync_hq(PLUGIN) end)
  local last_hq
  for line in table.concat(A.console, ""):gmatch("High quality:[^\n]*") do last_hq = line end
  check(last_hq and last_hq:find("1 uploaded", 1, true), "Sync HQ uploaded Drums' lossless original: " .. tostring(last_hq))
  act(B, function() actions.sync_hq(PLUGIN) end)
  local b_hq
  for line in table.concat(B.console, ""):gmatch("High quality:[^\n]*") do b_hq = line end
  check(b_hq and b_hq:find("1 downloaded", 1, true), "bob's Sync HQ downloaded it: " .. tostring(b_hq))
  local dchunk2 = select(2, B.R.GetTrackStateChunk(B.tracks[2]))
  check(dchunk2:find("%.hq%.wav") and dchunk2:find("<SOURCE WAVE", 1, true), "bob's Drums now plays the WAV")

  -- a cancelled operation is reported calmly, not as a failure
  A.mb = {}
  _G.reaper, _G.gfx = A.R, A.gfx
  actions._run(PLUGIN, "Sync", function() error({ cancelled = true, user = true, msg = "Cancelled." }, 0) end)
  A.pump()
  check(#A.mb == 1 and A.mb[1].msg:find("cancelled", 1, true) and not A.mb[1].title:find("failed", 1, true),
    "cancel shows a calm message: " .. tostring(A.mb[1] and A.mb[1].title))

  -- the progress window was opened and closed, and drew real text
  check(A.gfx_log.inits >= 1 and A.gfx_log.quits >= 1, "progress window opened and closed (alice): " .. A.gfx_log.inits .. "/" .. A.gfx_log.quits)
  check(B.gfx_log.inits >= 1 and B.gfx_log.quits >= 1, "progress window opened and closed (bob)")
  local drew = table.concat(B.gfx_log.strings, "|")
  check(drew:find("Downloading audio", 1, true) ~= nil or drew:find("Saving tracks", 1, true) ~= nil,
    "progress window showed phase labels: " .. drew:sub(1, 120))

  for _, w in ipairs({ A, B }) do
    for _, m in ipairs(w.mb) do if m.typ == 3 then check(false, "unexpected conflict dialog") end end
  end
end, debug.traceback)
if not ok then failures = failures + 1 print("ERROR " .. tostring(err)) end
print(failures == 0 and "\nall fake-REAPER checks passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
