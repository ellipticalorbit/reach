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

local PLUGIN = "./"
local actions = require("reach.actions")
local function act(w, fn)
  _G.reaper = w.R
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

  act(A, function() actions.sync(PLUGIN) end)
  local out = table.concat(A.console, "")
  check(out:find("3 pushed", 1, true) ~= nil, "alice sync pushed folder + 2 tracks: " .. (out:match("Sync complete[^\n]*") or out))

  act(B, function() actions.login(PLUGIN) end)
  act(B, function() actions.join(PLUGIN) end)
  check(outline(B) == "alice|  Drums|  Bass|bob", "bob joined and pulled the song: " .. outline(B))
  check(B.tracks[1].folderdepth == 1 and B.tracks[3].folderdepth == -1, "bob's folder depths correct")
  local dchunk = select(2, B.R.GetTrackStateChunk(B.tracks[2]))
  local path = dchunk:match('FILE "([^"]+)"')
  check(path and path:find("reach%-media/") and fs.exists(path), "bob's Drums points at downloaded ogg: " .. tostring(path))
  check(dchunk:find("<SOURCE VORBIS", 1, true) ~= nil, "bob's Drums source type is VORBIS")

  act(A, function() actions.sync(PLUGIN) end)
  check(table.concat(A.console, ""):find("1 pulled, 0 pushed", 1, true) ~= nil, "alice picks up bob's folder, nothing to push")
  check(outline(A) == "alice|  Drums|  Bass|bob|Keys", "alice outline: " .. outline(A))

  -- bob edits a track, alice receives it
  local bass_b = B.tracks[3]
  B.R.GetSetMediaTrackInfo_String(bass_b, "P_NAME", "Bass v2", true) -- a UI rename leaves folder state alone
  act(B, function() actions.sync(PLUGIN) end)
  act(A, function() actions.sync(PLUGIN) end)
  check(outline(A) == "alice|  Drums|  Bass v2|bob|Keys", "bob's rename reached alice: " .. outline(A))
  check(#A.tracks == 5 and #B.tracks == 4, "no duplicate tracks created")

  for _, w in ipairs({ A, B }) do
    for _, m in ipairs(w.mb) do if m.typ == 3 then check(false, "unexpected conflict dialog") end end
  end
end, debug.traceback)
if not ok then failures = failures + 1 print("ERROR " .. tostring(err)) end
print(failures == 0 and "\nall fake-REAPER checks passed" or ("\n" .. failures .. " failure(s)"))
os.exit(failures == 0 and 0 or 1)
