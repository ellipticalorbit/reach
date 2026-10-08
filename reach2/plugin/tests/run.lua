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
local platform = require("reach.platform")
local function write_wav_early(path)
  local rate, parts = 8000, {}
  for i = 0, 3999 do parts[#parts + 1] = string.pack("<i2", math.floor(8000 * math.sin(2 * math.pi * 300 * i / rate))) end
  local data = table.concat(parts)
  fs.write(path, "RIFF" .. string.pack("<I4", 36 + #data) .. "WAVEfmt " .. string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, rate, rate * 2, 2, 16) ..
    "data" .. string.pack("<I4", #data) .. data)
end

local function on(os_name, fn)
  platform.set(os_name)
  local ok, err = pcall(fn)
  platform.set(nil)
  if not ok then error(err, 0) end
end

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
-- Toolbar (pure logic + the watcher script, run for real)
-------------------------------------------------------------------------------------------------
local toolbar = require("reach.toolbar")
local TB_ITEMS = { { cmd = "_RSaaa", label = "Reach: Sync" }, { cmd = "_RSbbb", label = "Reach: Join song" },
                   { cmd = "_RSccc", label = "Reach: Share song" } }

test("toolbar.plan: fresh ini -> new Reach toolbar in the highest free slot", function()
  local plan = toolbar.plan("[Main toolbar]\nitem_0=40026 Save\n[Floating toolbar 16]\nitem_0=40001 x\n", TB_ITEMS)
  eq(plan.status, "append"); eq(plan.number, 15)
  truthy(plan.section:find("[Floating toolbar 15]", 1, true)); truthy(plan.section:find("item_2=_RSccc Reach: Share song", 1, true))
  truthy(plan.section:find("title=Reach\n", 1, true))
  eq(toolbar.plan("", TB_ITEMS).number, 16, "empty ini")
end)

test("toolbar.plan: buttons already present anywhere -> nothing to do", function()
  local ini = "[Main toolbar]\nitem_0=_RSaaa Reach: Sync\nitem_1=_RSbbb x\nitem_2=_RSccc y\n"
  eq(toolbar.plan(ini, TB_ITEMS).status, "already_there")
end)

test("toolbar.plan: partial / existing Reach toolbar -> left alone, missing reported", function()
  local p = toolbar.plan("[Main toolbar]\nitem_0=_RSaaa Reach: Sync\n", TB_ITEMS)
  eq(p.status, "manual"); eq(#p.missing, 2)
  eq(toolbar.plan("[Floating toolbar 3]\nitem_0=40001 a\ntitle=Reach\n", TB_ITEMS).status, "manual")
end)

test("toolbar.plan: no free slot", function()
  local parts = {}
  for n = 1, 16 do parts[#parts + 1] = "[Floating toolbar " .. n .. "]\nitem_0=40001 a\n" end
  eq(toolbar.plan(table.concat(parts), TB_ITEMS).status, "no_slot")
end)

test("toolbar watcher script appends once, backs up, and never clobbers", function()
  if proc.is_windows then return end
  local dir = ROOT .. "/tb"
  fs.mkdir(dir)
  local ini = dir .. "/reaper-menu.ini"
  local original = "[Main toolbar]\nitem_0=40026 Save\n"          -- note: no title=Reach yet
  fs.write(ini, original)
  local plan = toolbar.plan(original, TB_ITEMS)
  local function run_watcher()
    local script = toolbar.queue_append(ini, plan.section, dir, "reach-no-such-process-xyz")
    for _ = 1, 100 do os.execute("sleep 0.1") if not fs.exists(dir .. "/reach-toolbar-section.txt") then break end end
    return script
  end
  run_watcher()
  local after = fs.read(ini)
  truthy(after:sub(1, #original) == original, "existing content untouched")
  truthy(after:find("[Floating toolbar 16]", 1, true) and after:find("title=Reach", 1, true), "section appended")
  eq(fs.read(ini .. ".reach-backup"), original, "backup of the original")
  local once = fs.read(ini)
  run_watcher()   -- second run: idempotent
  eq(fs.read(ini), once, "second run changes nothing")
  eq(select(2, once:gsub("title=Reach", "")), 1, "exactly one Reach toolbar")
end)

local MAIN_INI = "[Main toolbar]\nitem_0=40026 Save\nicon_0=toolbar_save\nitem_1=40001 Other\nicon_1=toolbar_x\n"
  .. "[Floating toolbar 1]\nitem_0=40009 z\n"

test("toolbar.plan_main inserts after the last item/icon of [Main toolbar] with continued numbering", function()
  local p = toolbar.plan_main(MAIN_INI, TB_ITEMS)
  eq(p.status, "patch")
  local want = "[Main toolbar]\nitem_0=40026 Save\nicon_0=toolbar_save\nitem_1=40001 Other\nicon_1=toolbar_x\n"
    .. "item_2=_RSaaa Reach: Sync\nitem_3=_RSbbb Reach: Join song\nitem_4=_RSccc Reach: Share song\n"
    .. "[Floating toolbar 1]\nitem_0=40009 z\n"
  eq(p.patched, want)
end)

test("toolbar.plan_main: only missing buttons are added; none missing -> already there; no section -> no_main", function()
  local ini = "[Main toolbar]\nitem_0=_RSbbb Reach: Join song\n"
  local p = toolbar.plan_main(ini, TB_ITEMS)
  eq(#p.missing, 2); truthy(p.patched:find("item_1=_RSaaa", 1, true) and p.patched:find("item_2=_RSccc", 1, true))
  truthy(select(2, p.patched:gsub("_RSbbb", "")) == 1, "existing button not duplicated")
  eq(toolbar.plan_main("[Main toolbar]\nitem_0=_RSaaa a\nitem_1=_RSbbb b\nitem_2=_RSccc c\n", TB_ITEMS).status, "already_there")
  eq(toolbar.plan_main("[Floating toolbar 1]\nitem_0=40009 z\n", TB_ITEMS).status, "no_main")
  eq(toolbar.plan_main("", TB_ITEMS).status, "no_main")
end)

test("toolbar.plan_main preserves CRLF files and handles an empty section", function()
  local p = toolbar.plan_main("[Main toolbar]\r\nitem_0=40026 Save\r\n[Other]\r\nx=1\r\n", TB_ITEMS)
  truthy(p.patched:find("\r\n", 1, true) and not p.patched:find("[^\r]\n"), "line endings kept")
  eq(toolbar.plan_main("[Main toolbar]\n", TB_ITEMS).patched:match("item_0=_RSaaa"), "item_0=_RSaaa")
end)

test("toolbar replace-watcher: applies when ini unchanged, skips (and says so) when changed, idempotent", function()
  if platform.is_windows() then return end
  local function wait_for(path) for _ = 1, 100 do if fs.exists(path) then return true end os.execute("sleep 0.1") end end
  local function scenario(name, mutate)
    local dir = ROOT .. "/" .. name
    fs.mkdir(dir)
    local ini = dir .. "/reaper-menu.ini"
    fs.write(ini, MAIN_INI)
    local patched = toolbar.plan_main(MAIN_INI, TB_ITEMS).patched
    local queued = fs.write(ini, MAIN_INI)
    if mutate then mutate(ini) end
    toolbar.queue_replace(ini, MAIN_INI, patched, dir, "reach-no-such-process-xyz")
    truthy(wait_for(dir .. "/toolbar-result.txt"), "watcher finished")
    os.execute("sleep 0.3")
    return dir, ini, patched
  end
  local dir, ini, patched = scenario("tbr1")
  eq(fs.read(ini), patched, "patched file installed"); eq(fs.read(ini .. ".reach-backup"), MAIN_INI, "backup")
  eq(toolbar.take_result(dir), "applied"); eq(toolbar.take_result(dir), nil, "result is cleared once read")

  local dir2, ini2 = scenario("tbr2", function(f) fs.write(f, MAIN_INI .. "[Extra]\nuser_change=1\n") end)
  eq(fs.read(ini2), MAIN_INI .. "[Extra]\nuser_change=1\n", "user's newer file left untouched")
  truthy(toolbar.take_result(dir2):find("skipped", 1, true))
  truthy(not fs.exists(ini2 .. ".reach-backup"), "no backup needed when nothing was changed")
end)

test("toolbar replace-watcher: a second watcher (files already consumed) stays silent", function()
  if platform.is_windows() then return end
  local dir = ROOT .. "/tbr3"
  fs.mkdir(dir)
  local ini = dir .. "/reaper-menu.ini"
  fs.write(ini, MAIN_INI)
  local patched = toolbar.plan_main(MAIN_INI, TB_ITEMS).patched
  local script = toolbar.queue_replace(ini, MAIN_INI, patched, dir, "reach-no-such-process-xyz")
  for _ = 1, 100 do if fs.exists(dir .. "/toolbar-result.txt") then break end os.execute("sleep 0.1") end
  os.execute("sleep 0.3")
  eq(toolbar.take_result(dir), "applied")
  proc.launch(script)            -- a duplicate watcher fires after the first finished
  os.execute("sleep 1")
  eq(toolbar.take_result(dir), nil, "no misleading 'skipped' message"); eq(fs.read(ini), patched, "file still patched")
end)

test("toolbar replace-watcher script text for Windows", function()
  on("windows", function()
    local t, ext = toolbar.replace_watcher_script({ ini = "C:/R/reaper-menu.ini", new_file = "C:/t/new", orig_file = "C:/t/orig",
      log_file = "C:/t/log" })
    eq(ext, "bat"); truthy(t:find("tasklist", 1, true)); truthy(t:find('fc /b "C:\\R\\reaper-menu.ini" "C:\\t\\orig"', 1, true))
    truthy(t:find('copy /Y "C:\\t\\new" "C:\\R\\reaper-menu.ini"', 1, true)); truthy(t:find(".reach-backup", 1, true))
  end)
end)

test("toolbar watcher waits while REAPER is running", function()
  if proc.is_windows then return end
  local dir = ROOT .. "/tb2"
  fs.mkdir(dir)
  local ini = dir .. "/reaper-menu.ini"
  fs.write(ini, "[Main toolbar]\n")
  os.execute("sleep 6 >/dev/null 2>&1 &") -- stand-in for a running REAPER (process named "sleep")
  os.execute("sleep 1")
  truthy(io.popen("pgrep -x sleep"):read("a") ~= "", "stand-in process is running")
  toolbar.queue_append(ini, toolbar.plan("", TB_ITEMS).section, dir, "sleep")
  os.execute("sleep 3")
  eq(fs.read(ini), "[Main toolbar]\n", "not modified while the watched process is alive")
  os.execute("pkill -f reach-toolbar-watcher >/dev/null 2>&1")
  os.remove(dir .. "/reach-toolbar-section.txt")
end)

-------------------------------------------------------------------------------------------------
-- Cross-platform: the per-OS pieces are pure and are checked for every OS from here. (Only the host OS is
-- actually executed by these tests.)
-------------------------------------------------------------------------------------------------

test("platform: process names and browser commands per OS", function()
  on("windows", function()
    eq(platform.reaper_process(), "reaper.exe"); truthy(platform.open_command("http://x"):find("start", 1, true))
  end)
  on("macos", function() eq(platform.reaper_process(), "REAPER"); truthy(platform.open_command("http://x"):find("/usr/bin/open", 1, true)) end)
  on("linux", function() eq(platform.reaper_process(), "reaper"); truthy(platform.open_command("http://x"):find("xdg-open", 1, true)) end)
end)

test("proc.script_for: Windows batch (CRLF, UTF-8 code page, backslashes, % escaped, rc written last)", function()
  on("windows", function()
    local text, ext = proc.script_for({ "C:/Program Files/curl.exe", "-K", "C:/Users/Zoë/cfg 100%.txt" },
      { out = "C:/t/a.out", err = "C:/t/a.err", rc = "C:/t/a.rc" })
    eq(ext, "bat"); truthy(text:find("\r\n", 1, true)); truthy(text:find("chcp 65001", 1, true))
    truthy(text:find('"C:/Program Files/curl.exe"', 1, true), "argv quoted")
    truthy(text:find("100%%%.txt") or text:find("100%%.txt", 1, true) or text:find("100%%%%", 1, true), "percent doubled")
    truthy(text:find('> "C:\\t\\a.out"', 1, true), "redirects use backslashes")
    truthy(text:find("%errorlevel%", 1, true))
    truthy(text:find("a.rc", 1, true) > text:find("a.out", 1, true), "rc after the command")
  end)
end)

test("proc.script_for: POSIX script quotes args and writes rc atomically, last", function()
  for _, os_name in ipairs({ "macos", "linux" }) do
    on(os_name, function()
      local text, ext = proc.script_for({ "/usr/bin/curl", "-K", "/tmp/it's here/cfg" },
        { out = "/t/a.out", err = "/t/a.err", rc = "/t/a.rc" })
      eq(ext, "sh"); truthy(text:find("'it'\\''s here'", 1, true) or text:find("it'\\''s here", 1, true), "single quote escaped")
      truthy(text:find("mv '/t/a.rc.tmp' '/t/a.rc'", 1, true)); truthy(not text:find("\r", 1, true))
    end)
  end
end)

test("toolbar.watcher_script waits for the right REAPER process on each OS", function()
  local o = { ini = "/home/u/.config/REAPER/reaper-menu.ini", add_file = "/tmp/add.txt" }
  on("linux", function() local t = toolbar.watcher_script(o) truthy(t:find("pgrep -x 'reaper'", 1, true)); truthy(t:find("cp -n", 1, true)) end)
  on("macos", function() truthy(toolbar.watcher_script(o):find("pgrep -x 'REAPER'", 1, true)) end)
  on("windows", function()
    local w = { ini = "C:/Users/u/AppData/Roaming/REAPER/reaper-menu.ini", add_file = "C:/t/add.txt" }
    local t, ext = toolbar.watcher_script(w)
    eq(ext, "bat"); truthy(t:find('tasklist /FI "IMAGENAME eq reaper.exe"', 1, true))
    truthy(t:find('type "C:\\t\\add.txt" >> "C:\\Users\\u\\AppData\\Roaming\\REAPER\\reaper-menu.ini"', 1, true))
    truthy(t:find(".reach-backup", 1, true))
  end)
end)

test("media.find_ffmpeg picks the right binary per OS (never a macOS binary on Linux)", function()
  local d = ROOT .. "/ffm/plugin/"
  fs.mkdir(d .. "bin/windows"); fs.mkdir(d .. "bin/macos"); fs.mkdir(ROOT .. "/ffm/macos")
  fs.write(d .. "bin/windows/ffmpeg.exe", "x"); fs.write(d .. "bin/macos/ffmpeg", "x")
  on("windows", function() eq(media_mod.find_ffmpeg(d), d .. "bin/windows/ffmpeg.exe") end)
  on("macos", function() eq(media_mod.find_ffmpeg(d), d .. "bin/macos/ffmpeg") end)
  on("linux", function() eq(media_mod.find_ffmpeg(d), "ffmpeg", "falls back to PATH") end)
  fs.mkdir(d .. "bin/linux"); fs.write(d .. "bin/linux/ffmpeg", "x")
  on("linux", function() eq(media_mod.find_ffmpeg(d), d .. "bin/linux/ffmpeg", "bundled linux binary preferred") end)
  on("windows", function() eq(media_mod.find_ffmpeg(ROOT .. "/nowhere/"), "ffmpeg.exe") end)
end)

test("ffmpeg: made executable and un-quarantined before first use (macOS)", function()
  if proc.is_windows and false then return end
  if platform.os() == "windows" then return end
  local dir = ROOT .. "/ffq"
  fs.mkdir(dir)
  local fake = dir .. "/ffmpeg"
  fs.write(fake, "#!/bin/sh\nfor a; do last=$a; done\nprintf 'OggS-fake-vorbis' > \"$last\"\n")   -- NOT executable yet
  local quarantined = false
  if platform.os() == "macos" then
    quarantined = os.execute("xattr -w com.apple.quarantine '0081;00000000;Safari;' '" .. fake .. "'") == true
  end
  local wav = dir .. "/in.wav"
  write_wav_early(wav)
  local st = store_mod.memory(dir .. "/store")
  local m = media_mod.new({ store = st, ffmpeg = fake, quality = function() return 0 end, project_id = function() return "p" end })
  local sha = async.run(function() return m:prepare_upload(wav) end)
  truthy(sha and #sha == 64, "transcode ran, so the binary was made executable")
  if quarantined then
    eq(os.execute("xattr -p com.apple.quarantine '" .. fake .. "' >/dev/null 2>&1"), nil, "quarantine flag removed")
  end
end)

test("ffmpeg missing: the error says how to fix it", function()
  local dir = ROOT .. "/ffm2"
  fs.mkdir(dir)
  local wav = dir .. "/in.wav"
  write_wav_early(wav)
  local m = media_mod.new({ store = store_mod.memory(dir .. "/store"), ffmpeg = dir .. "/no/such/ffmpeg",
                            quality = function() return 0 end, project_id = function() return "p" end })
  local sha, why = async.run(function() return m:prepare_upload(wav) end)
  eq(sha, nil); truthy(why:find("could not be started", 1, true), why)
end)

test("media.parse_hash understands shasum, sha256sum and certutil output", function()
  local h = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  eq(media_mod.parse_hash(h .. "  /tmp/some file.wav\n"), h, "shasum / sha256sum")
  eq(media_mod.parse_hash("SHA256 hash of C:\\a.wav:\r\n" .. h .. "\r\nCertUtil: -hashfile command completed successfully.\r\n"), h, "certutil")
  local spaced = h:gsub("(%x%x)", "%1 "):gsub(" $", "")
  eq(media_mod.parse_hash("SHA256 hash of file:\r\n" .. spaced .. "\r\nCertUtil: done\r\n"), h, "older certutil (spaced bytes)")
  eq(media_mod.parse_hash("sha256sum: x: No such file or directory\n"), nil)
  on("windows", function() eq(media_mod.hash_command("C:/a.wav")[1], "certutil") end)
  on("macos", function() eq(media_mod.hash_command("/a.wav")[1], "/usr/bin/shasum") end)
  on("linux", function() eq(media_mod.hash_command("/a.wav")[1], "sha256sum") end)
end)

test("media:hash_file: native hashing of a big file matches the Lua implementation", function()
  if platform.os() == "windows" then return end
  local dir = ROOT .. "/hash"
  fs.mkdir(dir)
  local big = dir .. "/big.bin"
  local chunk = string.rep("0123456789abcdef", 4096)       -- 64 KiB
  local f = io.open(big, "wb")
  for _ = 1, 80 do f:write(chunk) end                      -- 5 MiB > native threshold
  f:close()
  local m = media_mod.new({ store = store_mod.memory(dir .. "/s") })
  local native = async.run(function() return m:hash_file(big) end)
  local expected = sha256.new()
  for _ = 1, 80 do expected:update(chunk) end
  eq(native, expected:hex())
end)

test("fs.native only converts slashes on Windows", function()
  on("windows", function() eq(fs.native("C:/a/b"), "C:\\a\\b") end)
  on("linux", function() eq(fs.native("/a/b"), "/a/b") end)
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
                           confirm_deletes = function(names) m.deleted_names = names return m.allow_deletes ~= false end,
                           orphans = function(names) return m.orphan_choice or "later" end,
                           new_project = function(song) m.new_project_for = song m.tracks.list, m.tracks.byguid = {}, {}
                             m.store.reset_project() return m.new_project_saved ~= false end })
  m.media = media_mod.new({ store = m.store, api = api, ffmpeg = opts.ffmpeg or FFMPEG,
                            project_id = function() return m.store.project_load().project_id end })
  m.eng = engine_mod.new({ api = api, store = m.store, tracks = m.tracks, media = m.media, ui = m.ui, new_guid = FT.guid })
  function m:run(fn) return async.run(fn) end
  function m:sync(o) return async.run(function() return m.eng:sync(o) end) end
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

test("api.normalise_url adds a scheme and trims slashes", function()
  eq(api_mod.normalise_url("quake.example.com"), "https://quake.example.com")
  eq(api_mod.normalise_url(" https://quake.example.com/ "), "https://quake.example.com")
  eq(api_mod.normalise_url("localhost:8000"), "http://localhost:8000")
  eq(api_mod.normalise_url("192.168.1.5:8000/"), "http://192.168.1.5:8000")
end)

test("login opens the browser at *our* server, not the host the server reports", function()
  local opened
  local stub = { base = function() return "https://quake.example.com" end,
                 device_start = function() return { device_code = "d", user_code = "ABCD-1234", expires_in = 30,
                   interval = 0, verification_url = "http://localhost:8000/device",
                   verification_url_complete = "http://localhost:8000/device?user_code=ABCD-1234" } end,
                 device_poll = function() return "tok" end,
                 me = function() return { display_name = "x", email = "x@y" } end }
  local st = store_mod.memory(ROOT .. "/stub")
  local ui = ui_mod.headless({ open_url = function(u) opened = u end })
  local e = engine_mod.new({ api = stub, store = st, ui = ui, tracks = {}, media = {}, new_guid = FT.guid })
  async.run(function() e:login() end)
  eq(opened, "https://quake.example.com/device?user_code=ABCD-1234")
  eq(st.cfg_get("token@https://quake.example.com"), "tok")
end)

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

test("list_songs shows my songs; join codes only for the ones I own", function()
  local mine = alice:run(function() return alice.eng:list_songs() end)
  local found
  for _, song in ipairs(mine) do if song.id == pid then found = song end end
  truthy(found, "song listed"); eq(found.name, "Test Song"); eq(found.role, "owner")
  eq(found.join_code, join_code); eq(found.linked, true, "flags the linked project")
  local theirs = bob:run(function() return bob.eng:list_songs() end)
  eq(theirs[1].role, "editor"); eq(theirs[1].join_code, nil, "collaborators don't get the code")
end)

test("a non-owner collaborator cannot see the join code", function()
  local ok, err = pcall(function() return bob:run(function() return bob.eng:show_join_code() end) end)
  truthy(not ok and tostring(err):find("owner"), tostring(err))
end)

test("orphan tracks: prompt once, 'ignore' is remembered, 'later' asks again, 'adopt' moves and syncs them", function()
  alice.tracks:add_track("Loose1", nil)
  alice.tracks:add_track("Loose2", nil)
  alice.orphan_choice = "ignore"
  local s = alice:sync()
  eq(#alice.ui.orphan_prompts, 1); eq(#alice.ui.orphan_prompts[1], 2, "both listed")
  eq(s.pushed, 0); eq(s.adopted, 0)
  alice:sync()
  eq(#alice.ui.orphan_prompts, 1, "ignored tracks are not asked about again")

  alice.tracks:add_track("Loose3", nil)
  alice.orphan_choice = "later"
  alice:sync(); alice:sync()
  eq(#alice.ui.orphan_prompts, 3, "'later' asks every sync")
  eq(alice.ui.orphan_prompts[3][1], "Loose3"); eq(#alice.ui.orphan_prompts[3], 1, "only the new one")

  alice.orphan_choice = "adopt"
  local s2 = alice:sync()
  eq(s2.adopted, 1); eq(s2.pushed, 1)
  eq(alice.tracks:find("Loose3").parent, alice.tracks:find("alice").guid, "now inside alice's folder")
  truthy(alice.tracks:find("Loose1").parent == nil, "ignored ones stay outside")
  eq(bob:sync().pulled >= 1, true)
  truthy(bob.tracks:find("Loose3"), "bob receives the adopted track")
  truthy(not bob.tracks:find("Loose1"), "ignored track never synced")
end)

test("share_and_sync links the song, offers existing tracks, and pushes them in one go", function()
  local carol = machine("carol")
  carol:run(function() carol.eng:login() end)
  carol.tracks:add_track("Existing1", nil)
  carol.tracks:add_track("Existing2", nil)
  carol.orphan_choice = "adopt"
  local code, s = carol:run(function() return carol.eng:share_and_sync("Song Two") end)
  truthy(code:match("^%w+%-%w+%-%w+%-%w+$"))
  eq(s.adopted, 2); eq(s.pushed, 3, "folder + 2 adopted tracks")
  eq(carol.store.notes["Reach join code: "], code)
  local live = carol:run(function() return carol.api:tracks(carol.store.project_load().project_id) end)
  eq(#live, 3)

  -- join in a brand-new project, from a project that is already linked to something else
  local dave = machine("dave")
  dave:run(function() dave.eng:login() end)
  dave:run(function() dave.eng:share("Dave's own song") end)
  dave.tracks:add_track("Leftover from old project", nil)
  local p, s2 = dave:run(function() return dave.eng:join_new(code) end)
  eq(dave.new_project_for, "Song Two", "new project requested for the joined song")
  eq(dave.store.project_load().project_id, p.id, "linked to the joined song, not the old one")
  eq(s2.pulled, 3)
  truthy(not dave.tracks:find("Leftover from old project"), "worked in a fresh project")
  eq(outline(dave.tracks), "carol|  Existing1|  Existing2|dave")

  -- a typo'd code must not create a project
  local erin = machine("erin")
  erin:run(function() erin.eng:login() end)
  local ok, err = pcall(function() return erin:run(function() return erin.eng:join_new("AAAA-AAAA-AAAA-AAAA") end) end)
  truthy(not ok and tostring(err):find("invalid join code"), tostring(err))
  eq(erin.new_project_for, nil, "no project created for a bad code")

  -- cancelling the save dialog aborts cleanly
  local fred = machine("fred")
  fred:run(function() fred.eng:login() end)
  fred.new_project_saved = false
  local ok2, err2 = pcall(function() return fred:run(function() return fred.eng:join_new(code) end) end)
  truthy(not ok2 and tostring(err2):find("cancelled"), tostring(err2))
  eq(fred.store.project_load(), nil, "not linked after cancel")
end)

-- ---- LQ / HQ sync ---------------------------------------------------------------------------------
local hq_song = {}   -- shared by the following tests: one song, three kinds of user

local function lookup_variants(m, oggs)
  return m:run(function() return m.api:hq_lookup(m.store.project_load().project_id, oggs) end)
end

local function track_ogg(m, name)   -- the canonical Ogg sha the server's chunk for `name` references
  local feed = m:run(function() return m.api:changes(m.store.project_load().project_id, 0) end)
  for _, x in ipairs(feed.tracks) do
    if x.name == name then return x.chunk:match("reach%-media://(%x+)%.ogg"), x end
  end
end

test("quality 5 Ogg is what gets encoded", function()
  local dir = ROOT .. "/q5"
  fs.mkdir(dir)
  local logf = dir .. "/args.txt"
  local fake = dir .. "/ffmpeg"
  fs.write(fake, "#!/bin/sh\necho \"$@\" > '" .. logf .. "'\nfor a; do last=$a; done\nprintf 'OggS-fake' > \"$last\"\n")
  os.execute("chmod +x '" .. fake .. "'")
  write_wav(dir .. "/in.wav", 1, 200)
  local m = media_mod.new({ store = store_mod.memory(dir .. "/s"), ffmpeg = fake, project_id = function() return "p" end })
  async.run(function() return m:prepare_upload(dir .. "/in.wav") end)
  local args = fs.read(logf)
  truthy(args:find("-c:a libvorbis -q:a 5", 1, true), args)
end)

test("LQ sync uploads only the Ogg", function()
  hq_song.lq = machine("lqa")
  local m = hq_song.lq
  m:run(function() m.eng:login() end)
  hq_song.code = m:run(function() return m.eng:share("HQ Song") end)
  hq_song.wav2 = ROOT .. "/lq-take.wav"
  write_wav(hq_song.wav2, 1, 261)
  m.tracks:add_track("LQ take", m:folder(), hq_song.wav2)
  local s = m:sync()
  eq(s.pushed, 2); eq(s.hq_uploaded, 0)
  local ogg = track_ogg(m, "LQ take")
  truthy(ogg, "track references an Ogg")
  eq(next(lookup_variants(m, { ogg })), nil, "no WAV companion exists")
end)

test("HQ sync uploads the Ogg and the untouched original WAV; chunks still reference only the Ogg", function()
  hq_song.hq = machine("hqa")
  local m = hq_song.hq
  m:run(function() m.eng:login() end)
  m:run(function() m.eng:join(hq_song.code) end)
  hq_song.wav1 = ROOT .. "/hq-take.wav"
  write_wav(hq_song.wav1, 1, 440)
  local original = fs.read(hq_song.wav1)
  m.tracks:add_track("HQ take", m:folder(), hq_song.wav1)
  local s = m:sync({ hq = true })
  eq(s.hq_failed[1], nil); eq(s.hq_error, nil)
  eq(s.hq_uploaded, 1)
  local ogg, t = track_ogg(m, "HQ take")
  truthy(ogg and not t.chunk:find("%.wav"), "server chunk references only the Ogg")
  truthy(t.chunk:find("<SOURCE VORBIS", 1, true))
  local wav_sha = lookup_variants(m, { ogg })[ogg]
  eq(wav_sha, sha256.hex(original), "companion is the original bytes' hash")
  local pid2 = m.store.project_load().project_id
  local blob = m:run(function()
    local dest = ROOT .. "/dl-hq.wav"
    m.api:get_blob(pid2, wav_sha, dest)
    return fs.read(dest)
  end)
  eq(blob, original, "byte-for-byte the original recording")
  truthy(not fs.exists(m.media:path_for(wav_sha)) and not fs.exists(m.media:dir() .. "/" .. wav_sha .. ".up.wav"),
    "the raw WAV was not copied anywhere")
  truthy(m.tracks:find("HQ take").chunk:find(hq_song.wav1, 1, true), "owner still points at the original file")
end)

test("HQ sync pulls the WAV where one exists and the Ogg where it doesn't", function()
  local m = machine("hql")
  hq_song.hql = m
  m:run(function() m.eng:login() end)
  m:run(function() m.eng:join(hq_song.code) end)
  local s = m:sync({ hq = true })
  eq(s.hq_downloaded, 1, "one WAV companion available")
  local hq_path = m.tracks:find("HQ take").chunk:match('FILE "([^"]+)"')
  local lq_path = m.tracks:find("LQ take").chunk:match('FILE "([^"]+)"')
  truthy(hq_path:match("%.hq%.wav$"), hq_path); truthy(lq_path:match("%.ogg$"), lq_path)
  eq(fs.read(hq_path), fs.read(hq_song.wav1), "the HQ track is the original WAV")
  truthy(m.tracks:find("HQ take").chunk:find("<SOURCE WAVE", 1, true), "source type matches the file")
  truthy(m.tracks:find("LQ take").chunk:find("<SOURCE VORBIS", 1, true))
  -- the Ogg of the HQ track was not downloaded at all
  local ogg = track_ogg(m, "HQ take")
  truthy(not fs.exists(m.media:path_for(ogg)), "no needless Ogg download when the WAV exists")
  local again = m:sync({ hq = true })
  eq(again.pushed, 0); eq(again.pulled, 0); eq(again.conflicts, 0, "HQ vs LQ forms of a track are not 'changes'")
end)

test("LQ sync only ever downloads the Ogg", function()
  local m = machine("lql")
  m:run(function() m.eng:login() end)
  m:run(function() m.eng:join(hq_song.code) end)
  local s = m:sync()
  eq(s.hq_downloaded, 0)
  for _, name in ipairs({ "HQ take", "LQ take" }) do
    truthy(m.tracks:find(name).chunk:match('FILE "([^"]+)"'):match("%.ogg$"), name .. " uses the Ogg")
  end
  hq_song.lql = m
end)

test("HQ sync upgrades audio already pulled in LQ, without creating any changes", function()
  local m = hq_song.lql
  local s = m:sync({ hq = true })
  eq(s.hq_downloaded, 1)
  truthy(m.tracks:find("HQ take").chunk:match('FILE "([^"]+)"'):match("%.hq%.wav$"), "upgraded to the WAV")
  truthy(m.tracks:find("HQ take").chunk:find("<SOURCE WAVE", 1, true))
  truthy(m.tracks:find("LQ take").chunk:match('FILE "([^"]+)"'):match("%.ogg$"), "no companion for this one yet")
  eq(s.pushed, 0); eq(s.conflicts, 0)
  eq(m:sync().pushed, 0, "a following LQ sync sees nothing modified")
end)

test("HQ sync attaches companions to tracks that were pushed earlier in LQ", function()
  local m = hq_song.lq                              -- pushed "LQ take" in an LQ sync earlier; unchanged since
  local s = m:sync({ hq = true })
  eq(s.pushed, 0, "nothing to push"); eq(s.hq_uploaded, 1, "but its WAV is uploaded now")
  local ogg = track_ogg(m, "LQ take")
  truthy(lookup_variants(m, { ogg })[ogg], "companion now exists")
  eq(m:sync({ hq = true }).hq_uploaded, 0, "and it is only uploaded once")
  -- a listener in HQ mode now gets it too
  local s2 = hq_song.lql:sync({ hq = true })
  eq(s2.hq_downloaded, 1)
  truthy(hq_song.lql.tracks:find("LQ take").chunk:match('FILE "([^"]+)"'):match("%.hq%.wav$"))
end)

test("other lossless formats get a WAV companion; lossy sources get none", function()
  local m = machine("fmt")
  m:run(function() m.eng:login() end)
  m:run(function() m.eng:share("Formats") end)
  local src = ROOT .. "/fmt.wav"
  write_wav(src, 1, 300)
  local flac, lossy = ROOT .. "/fmt.flac", ROOT .. "/fmt-lossy.ogg"
  os.execute("'" .. FFMPEG .. "' -nostdin -y -v error -i '" .. src .. "' '" .. flac .. "'")
  os.execute("'" .. FFMPEG .. "' -nostdin -y -v error -i '" .. src .. "' -c:a libvorbis '" .. lossy .. "'")
  local f = m:folder()
  m.tracks:add_track("FlacTrack", f, flac)
  m.tracks:add_track("OggTrack", f, lossy)
  local s = m:sync({ hq = true })
  eq(s.pushed, 3); eq(s.hq_uploaded, 1, "only the FLAC has a lossless companion"); eq(#s.hq_failed, 0)
  local ogg = track_ogg(m, "FlacTrack")
  local wav_sha = lookup_variants(m, { ogg })[ogg]
  truthy(wav_sha, "FLAC companion exists")
  local dest = ROOT .. "/fmt-dl.wav"
  m:run(function() m.api:get_blob(m.store.project_load().project_id, wav_sha, dest) end)
  local bytes = fs.read(dest)
  eq(bytes:sub(1, 4), "RIFF"); eq(bytes:sub(9, 12), "WAVE", "FLAC converted to a real WAV")
  eq(next(lookup_variants(m, { (track_ogg(m, "OggTrack")) })), nil, "lossy source: no companion")
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
