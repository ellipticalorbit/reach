-- Integration tests: real engine + real curl/ffmpeg against a running Reach server (REACH_URL).
package.path = "./?.lua;" .. package.path
math.randomseed(os.time())

local fs = require("reach.fs")
local proc = require("reach.proc")
local async = require("reach.async")
local json = require("reach.json")
local sha256 = require("reach.sha256")
local canon = require("reach.canon")
local keys = require("reach.keys")
local api_mod = require("reach.api")
local store_mod = require("reach.store")
local media_mod = require("reach.media")
local engine_mod = require("reach.engine")
local ui_mod = require("reach.ui")
local FT = require("tests.fake_tracks")

local URL = os.getenv("REACH_URL") or "http://localhost:8000"
local ROOT = os.getenv("TMPDIR") or "/tmp"
ROOT = ROOT:gsub("/$", "") .. "/reach-lua-tests-" .. os.time()
fs.mkdir(ROOT)
proc.tmp = ROOT .. "/procs"

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 print("PASS  " .. name)
  else failed = failed + 1 print("FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      ")) end
end
local function eq(a, b, msg)
  if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected truthy", 2) end end
local function outline(t) return table.concat(t:outline(), "|") end

-------------------------------------------------------------------------------------------------
-- Unit tests (no server)
-------------------------------------------------------------------------------------------------
test("sha256 vectors", function()
  eq(sha256.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(sha256.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

test("json roundtrip keeps floats and unicode", function()
  local t = json.decode(json.encode({ a = 1.5, b = "é\n\"x\"", c = { 1, 2 } }))
  eq(t.a, 1.5); eq(t.b, "é\n\"x\""); eq(#t.c, 2)
end)

test("keys.assign: move re-keys only the moved item", function()
  local r = keys.assign({ "a", "b", "c", "d" }, { a = 1, b = 5, c = 2, d = 3 })
  eq(r.a, 1); eq(r.c, 2); eq(r.d, 3); truthy(r.b > 1 and r.b < 2)
end)

test("keys.assign: new items at start, middle, end", function()
  local r = keys.assign({ "n1", "a", "n2", "b", "n3" }, { a = 1, b = 2 })
  truthy(r.n1 < r.a and r.a < r.n2 and r.n2 < r.b and r.b < r.n3)
end)

test("keys.assign: renumbers when precision is exhausted", function()
  local known, order = { x = 1, y = 1 + 1e-12 }, { "x", "n", "y" }
  local r = keys.assign(order, known)
  truthy(r.x < r.n and r.n < r.y)
end)

test("canon: file refs, map_files, source type rewrite", function()
  local c = '<TRACK {A}\n  <ITEM\n    <SOURCE WAVE\n      FILE "/a b/c.wav"\n    >\n  >\n>'
  eq(canon.file_refs(c)[1], "/a b/c.wav")
  local out = canon.map_files(c, function() return "reach-media://x.ogg", "VORBIS" end)
  truthy(out:find('<SOURCE VORBIS', 1, true)); truthy(out:find('FILE "reach-media://x.ogg"', 1, true))
end)

test("canon: volatile lines are ignored in fingerprints", function()
  local a = '<TRACK {A}\n  NAME "x"\n  SEL 1\n  ISBUS 1 1\n>'
  local b = '<TRACK {A}\n  NAME "x"\n  SEL 0\n  ISBUS 0 0\n>'
  eq(canon.strip_volatile(a), canon.strip_volatile(b))
end)

-------------------------------------------------------------------------------------------------
-- Integration helpers
-------------------------------------------------------------------------------------------------
local function write_wav(path, seconds, freq)
  local rate, n = 8000, math.floor(8000 * (seconds or 1))
  local samples = {}
  for i = 0, n - 1 do samples[#samples + 1] = string.pack("<i2", math.floor(8000 * math.sin(2 * math.pi * (freq or 440) * i / rate))) end
  local data = table.concat(samples)
  fs.write(path, "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVEfmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16) ..
    "data" .. string.pack("<I4", #data) .. data)
end

-- Plays the role of the user's browser: signs in with the server's dev login and approves the device code.
local function browser_approve(url, email, name)
  local code = url:match("user_code=([%w%-]+)")
  local jar = ROOT .. "/jar-" .. math.random(1e9)
  local function curl(args) local p = io.popen("curl -s -L -c '" .. jar .. "' -b '" .. jar .. "' " .. args) local o = p:read("a") p:close() return o end
  local page = curl("'" .. URL .. "/auth/dev-login?email=" .. email .. "&name=" .. name ..
    "&next=" .. "%2Fdevice%3Fuser_code%3D" .. code .. "'")
  local csrf = page:match('name=csrf value="([^"]+)"')
  assert(csrf, "no approval page: " .. page)
  local done = curl("-d 'user_code=" .. code .. "&action=approve&csrf=" .. csrf .. "' '" .. URL .. "/device/approve'")
  assert(done:find("Approved"), done)
end

local FFMPEG = media_mod.find_ffmpeg("./")

local function machine(name, opts)
  opts = opts or {}
  local email = opts.email or (name .. "-" .. os.time() .. math.random(1000, 9999) .. "@example.com")
  local m = { name = name, email = email, tracks = FT.new() }
  m.store = store_mod.memory(ROOT .. "/" .. name .. math.random(1e6))
  local api
  api = api_mod.new({ base_url = URL, token = function() return m.store.cfg_get("token@" .. api:base()) end })
  m.api = api
  m.ui = ui_mod.headless({ open_url = function(url) browser_approve(url, email, name) end,
                           conflict = function(c) return m.conflict_choice or "theirs" end,
                           confirm_deletes = function(names) m.deleted_names = names return m.allow_deletes ~= false end })
  m.media = media_mod.new({ store = m.store, api = api, ffmpeg = FFMPEG, quality = function() return 0 end,
                            project_id = function() return m.store.project_load().project_id end })
  m.eng = engine_mod.new({ api = api, store = m.store, tracks = m.tracks, media = m.media, ui = m.ui, new_guid = FT.guid })
  function m:run(fn) return async.run(fn) end
  function m:sync() return async.run(function() return m.eng:sync() end) end
  function m:folder()
    return async.run(function()
      local me = api:me()
      return (m.tracks:ensure_folder(me)), me
    end)
  end
  return m
end

-------------------------------------------------------------------------------------------------
-- Integration scenarios
-------------------------------------------------------------------------------------------------
local alice, bob, pid, join_code, a_folder, a_guitar, a_vocals, wav

test("login (device flow via dev-login) + whoami", function()
  alice = machine("alice")
  alice:run(function() alice.eng:login() end)
  local me = alice:run(function() return alice.api:me() end)
  eq(me.display_name, "alice")
  truthy(alice.eng:has_token())
end)

test("share creates the song and links the project", function()
  join_code = alice:run(function() return alice.eng:share("Test Song") end)
  truthy(join_code:match("^%w%w%w%w%-%w%w%w%w%-%w%w%w%w%-%w%w%w%w$"), "join code format")
  pid = alice.store.project_load().project_id
  truthy(pid)
end)

test("owner can recover the join code (and it lands in the project notes); others can't", function()
  eq(alice.store.notes["Reach join code: "], join_code, "written on share")
  alice.store.notes["Reach join code: "] = nil
  eq(alice:run(function() return alice.eng:show_join_code() end), join_code)
  eq(alice.store.notes["Reach join code: "], join_code, "written by show_join_code")
end)

test("first sync pushes folder + tracks, transcoding audio to Ogg", function()
  wav = ROOT .. "/guitar.wav"
  write_wav(wav, 1, 440)
  a_folder = alice:folder()
  a_guitar = alice.tracks:add_track("Guitar", a_folder, wav)
  a_vocals = alice.tracks:add_track("Vocals", a_folder)
  local s = alice:sync()
  eq(s.pushed, 3, "pushed"); eq(#s.skipped, 0)
  local on_server = alice:run(function() return alice.api:tracks(pid) end)
  eq(#on_server, 3)
  local g = alice:run(function() return alice.api:changes(pid, 0) end)
  local guitar
  for _, t in ipairs(g.tracks) do if t.name == "Guitar" then guitar = t end end
  eq(#guitar.media_hashes, 1)
  truthy(guitar.chunk:find("reach-media://" .. guitar.media_hashes[1] .. ".ogg", 1, true), "chunk uses media ref")
  truthy(guitar.chunk:find("<SOURCE VORBIS", 1, true), "source type rewritten")
  truthy(not guitar.chunk:find("guitar.wav", 1, true), "no local path leaked")
  local ogg = fs.read(alice.media:path_for(guitar.media_hashes[1]))
  eq(ogg:sub(1, 4), "OggS"); truthy(#ogg < fs.size(wav), "ogg smaller than wav")
end)

test("second sync with no changes does nothing", function()
  local s = alice:sync()
  eq(s.pushed, 0); eq(s.pulled, 0); eq(s.conflicts, 0)
end)

test("a collaborator joins and pulls the song with audio", function()
  bob = machine("bob")
  bob:run(function() bob.eng:login() end)
  bob:run(function() bob.eng:join(join_code) end)
  local s = bob:sync()
  eq(s.pulled, 3, "pulled"); eq(s.pushed, 1, "bob's own folder")
  eq(outline(bob.tracks), "alice|  Guitar|  Vocals|bob")
  local rec = bob.tracks:find("Guitar")
  local path = rec.chunk:match('FILE "([^"]+)"')
  truthy(path and path:find("reach-media/", 1, true), "local media path: " .. tostring(path))
  eq(fs.read(path):sub(1, 4), "OggS")
  eq(rec.parent, bob.tracks:find("alice").guid, "parent restored")
end)

test("owner keeps original wav locally; pulling bob's folder changes nothing else", function()
  local s = alice:sync()
  eq(s.pulled, 1, "bob's folder"); eq(s.pushed, 0)
  truthy(alice.tracks:find("Guitar").chunk:find("guitar.wav", 1, true), "still the wav")
  eq(outline(alice.tracks), "alice|  Guitar|  Vocals|bob")
  eq(bob:sync().pulled, 0)
end)

test("edits propagate to collaborators", function()
  bob.tracks:edit(bob.tracks:find("Vocals").guid, function(c) return c:gsub("VOLPAN 1 0", "VOLPAN 0.5 0") end)
  local s = bob:sync()
  eq(s.pushed, 1)
  eq(alice:sync().pulled, 1)
  truthy(alice.tracks:find("Vocals").chunk:find("VOLPAN 0.5 0", 1, true))
end)

test("collaborator adds a track under their folder; others receive it", function()
  local bf = bob.tracks:find("bob").guid
  bob.tracks:add_track("Bass", bf)
  eq(bob:sync().pushed, 1)
  eq(alice:sync().pulled, 1)
  eq(outline(alice.tracks), "alice|  Guitar|  Vocals|bob|  Bass")
end)

test("conflict: keep both makes a duplicate and loses nothing", function()
  local av, bv = alice.tracks:find("Vocals").guid, bob.tracks:find("Vocals").guid
  alice.tracks:edit(av, function(c) return c:gsub("VOLPAN 0.5 0", "VOLPAN 0.9 0") end)
  bob.tracks:edit(bv, function(c) return c:gsub("VOLPAN 0.5 0", "VOLPAN 0.1 0") end)
  eq(alice:sync().pushed, 1)
  bob.conflict_choice = "both"
  local s = bob:sync()
  eq(#bob.ui.conflicts_seen, 1); eq(bob.ui.conflicts_seen[1].kind, "both_edited")
  truthy(bob.tracks:find("Vocals").chunk:find("VOLPAN 0.9 0", 1, true), "original now has alice's edit")
  local dup = bob.tracks:find("Vocals (conflict - bob)")
  truthy(dup, "duplicate exists"); truthy(dup.chunk:find("VOLPAN 0.1 0", 1, true), "duplicate has bob's edit")
  truthy(dup.guid ~= bv, "new guid")
  eq(s.pushed, 1, "duplicate pushed")
  eq(alice:sync().pulled, 1)
  truthy(alice.tracks:find("Vocals (conflict - bob)"), "alice sees the duplicate")
end)

test("conflict: keep mine overrides on the server", function()
  local av, bv = alice.tracks:find("Guitar").guid, bob.tracks:find("Guitar").guid
  alice.tracks:edit(av, function(c) return c:gsub("VOLPAN 1 0", "VOLPAN 0.7 0") end)
  bob.tracks:edit(bv, function(c) return c:gsub("VOLPAN 1 0", "VOLPAN 0.3 0") end)
  alice:sync()
  bob.conflict_choice = "mine"
  eq(bob:sync().pushed, 1)
  eq(alice:sync().pulled, 1)
  truthy(alice.tracks:find("Guitar").chunk:find("VOLPAN 0.3 0", 1, true), "bob's version won")
end)

test("conflict: take theirs discards local edit", function()
  local av, bv = alice.tracks:find("Bass").guid, bob.tracks:find("Bass").guid
  alice.tracks:edit(av, function(c) return c:gsub("VOLPAN 1 0", "VOLPAN 0.2 0") end)
  bob.tracks:edit(bv, function(c) return c:gsub("VOLPAN 1 0", "VOLPAN 0.8 0") end)
  bob:sync()
  alice.conflict_choice = "theirs"
  eq(alice:sync().pushed, 0)
  truthy(alice.tracks:find("Bass").chunk:find("VOLPAN 0.8 0", 1, true))
  eq(bob:sync().pulled, 0)
end)

test("reordering a track pushes only that track", function()
  local before = outline(alice.tracks)
  alice.tracks:move_before(alice.tracks:find("Vocals").guid, alice.tracks:find("Guitar").guid)
  local s = alice:sync()
  eq(s.pushed, 1, "only the moved track")
  eq(bob:sync().pulled, 1)
  eq(outline(bob.tracks):match("^alice|  Vocals|  Guitar") ~= nil, true, outline(bob.tracks))
end)

test("deleting a track asks first; declining keeps it on the server", function()
  local g = alice.tracks:find("Vocals (conflict - bob)").guid
  alice.tracks:remove(g)
  alice.allow_deletes = false
  local s = alice:sync()
  eq(s.removed_here, 0); eq(alice.deleted_names[1], "Vocals (conflict - bob)")
  local live = alice:run(function() return alice.api:tracks(pid) end)
  local found = false
  for _, t in ipairs(live) do if t.name == "Vocals (conflict - bob)" then found = true end end
  truthy(found, "still on server")
end)

test("delete propagates, and can be restored from history", function()
  alice.allow_deletes = true
  eq(alice:sync().removed_here, 1)
  local s = bob:sync()
  eq(s.deleted_remote, 1)
  eq(bob.tracks:find("Vocals (conflict - bob)"), nil)
  local deleted = alice:run(function() return alice.eng:deleted_tracks() end)
  eq(#deleted, 1); eq(deleted[1].name, "Vocals (conflict - bob)")
  alice:run(function() alice.eng:restore(deleted[1].guid) end)
  eq(alice:sync().pulled, 1)
  truthy(alice.tracks:find("Vocals (conflict - bob)"), "restored for alice")
  eq(bob:sync().pulled, 1)
  truthy(bob.tracks:find("Vocals (conflict - bob)"), "restored for bob")
end)

test("delete vs edit conflicts are surfaced", function()
  local bg = bob.tracks:find("Bass").guid
  bob.tracks:remove(bg)
  bob:sync()
  local ag = alice.tracks:find("Bass").guid
  alice.tracks:edit(ag, function(c) return c:gsub("VOLPAN 0.8 0", "VOLPAN 0.6 0") end)
  alice.conflict_choice = "mine"
  local n = #alice.ui.conflicts_seen
  alice:sync()
  eq(alice.ui.conflicts_seen[n + 1].kind, "remote_deleted")
  eq(bob:sync().pulled, 1)
  truthy(bob.tracks:find("Bass").chunk:find("VOLPAN 0.6 0", 1, true), "undeleted with alice's edit")
end)

test("unsyncable media is reported and skipped; other tracks still push", function()
  local f = alice:folder()
  alice.tracks:add_track("Missing", f, ROOT .. "/does-not-exist.wav")
  alice.tracks:add_track("Fine", f)
  local s = alice:sync()
  eq(s.pushed, 1); eq(#s.skipped, 1); eq(s.skipped[1].name, "Missing")
  truthy(s.skipped[1].reason:find("not found"))
end)

test("a non-owner collaborator cannot see the join code", function()
  local ok, err = pcall(function() return bob:run(function() return bob.eng:show_join_code() end) end)
  truthy(not ok and tostring(err):find("owner"), tostring(err))
end)

test("same user in a second project reuses their existing folder instead of creating another", function()
  local again = machine("alice-second", { email = alice.email })
  again:run(function() again.eng:login() end)
  again:run(function() again.eng:join(join_code) end)
  local s = again:sync()
  local roots = 0
  for _, r in ipairs(again.tracks.list) do
    if not r.parent and r.chunk:find("reach_owner " .. again:run(function() return again.api:me() end).id, 1, true) then roots = roots + 1 end
  end
  eq(roots, 1, "exactly one folder for this user")
  eq(s.pushed, 0, "nothing new to push")
  local names = outline(again.tracks)
  truthy(names:find("^alice%-?[%w]*|") or names:find("alice", 1, true), names)
end)

test("a 401 surfaces as unauthorized", function()
  alice.store.cfg_set("token@" .. alice.api:base(), "rch_bogus")
  local ok, err = pcall(function() return alice:run(function() return alice.api:me() end) end)
  truthy(not ok)
  truthy(tostring(err):find("invalid token") or tostring(err):find("401"), tostring(err))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
