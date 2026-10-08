-- Adds Reach buttons to a dedicated "Reach" floating toolbar.
--
-- REAPER has no API for editing toolbars. They live in reaper-menu.ini, which REAPER reads at startup and may
-- rewrite when it quits, so we never edit it while REAPER is running. Instead we (1) register the scripts as
-- actions through the API (immediate), and (2) start a tiny background script that waits for REAPER to exit,
-- backs the file up, and appends a new toolbar section. Append-only and idempotent: if the toolbar or the
-- buttons are already there nothing is written. We don't touch the main toolbar: a fresh REAPER has no
-- [Main toolbar] section, and creating one would replace the default toolbar.
local fs = require("reach.fs")
local proc = require("reach.proc")
local platform = require("reach.platform")

local toolbar = {}
local TITLE = "Reach"

-- items: { { cmd = "_RS...", label = "Reach: Sync" }, ... }
-- Returns { status = "already_there" | "append" | "manual" | "no_slot", missing = {...}, section = text, number = N }
function toolbar.plan(ini, items)
  ini = (ini or ""):gsub("\r\n?", "\n")
  local present = {}
  for line in ini:gmatch("[^\n]+") do
    local cmd = line:match("^item_%d+=(%S+)")
    if cmd then present[cmd] = true end
  end
  local missing = {}
  for _, it in ipairs(items) do if not present[it.cmd] then missing[#missing + 1] = it end end
  if #missing == 0 then return { status = "already_there", missing = {} } end

  local used, has_reach = {}, false
  local current
  for line in ini:gmatch("[^\n]+") do
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then
      current = sec
      local n = sec:match("^Floating toolbar (%d+)$")
      if n then used[tonumber(n)] = true end
    elseif current and current:match("^Floating toolbar") and line:match("^title=" .. TITLE .. "%s*$") then
      has_reach = true
    end
  end
  -- Some buttons exist or a Reach toolbar exists already: don't create a second one.
  if has_reach or #missing < #items then return { status = "manual", missing = missing } end

  local number
  for n = 16, 1, -1 do if not used[n] then number = n break end end
  if not number then return { status = "no_slot", missing = missing } end

  local lines = { "[Floating toolbar " .. number .. "]" }
  for i, it in ipairs(missing) do lines[#lines + 1] = string.format("item_%d=%s %s", i - 1, it.cmd, it.label) end
  lines[#lines + 1] = "title=" .. TITLE
  return { status = "append", missing = missing, number = number, section = table.concat(lines, "\n") .. "\n" }
end

-- Script that waits for REAPER to quit, then appends `add_file` to `ini` (once, with a backup).
-- Returns script text, extension.
function toolbar.watcher_script(opts) -- opts: ini, add_file, process_name (default: this OS's REAPER)
  local q = proc.quote
  if platform.is_windows() then
    local n = fs.native
    return table.concat({ "@echo off", "@chcp 65001 >NUL",
      ":wait",
      'tasklist /FI "IMAGENAME eq ' .. (opts.process_name or "reaper.exe") .. '" 2>NUL | find /I "' ..
        (opts.process_name or "reaper.exe") .. '" >NUL',
      "if not errorlevel 1 (",
      "  ping -n 3 127.0.0.1 >NUL",
      "  goto wait",
      ")",
      'find "title=' .. TITLE .. '" "' .. n(opts.ini) .. '" >NUL 2>&1 && goto done',
      'if exist "' .. n(opts.ini) .. '" if not exist "' .. n(opts.ini) .. '.reach-backup" copy /Y "' ..
        n(opts.ini) .. '" "' .. n(opts.ini) .. '.reach-backup" >NUL',
      'echo.>> "' .. n(opts.ini) .. '"',
      'type "' .. n(opts.add_file) .. '" >> "' .. n(opts.ini) .. '"',
      ":done",
      'del "' .. n(opts.add_file) .. '" >NUL 2>&1', "" }, "\r\n"), "bat"
  end
  local ini, add = q(opts.ini), q(opts.add_file)
  return table.concat({ "#!/bin/sh",
    "while pgrep -x " .. q(opts.process_name or platform.reaper_process()) .. " >/dev/null 2>&1; do sleep 2; done",
    "if grep -q '^title=" .. TITLE .. "$' " .. ini .. " 2>/dev/null; then rm -f " .. add .. "; exit 0; fi",
    "[ -f " .. ini .. " ] && cp -n " .. ini .. " " .. q(opts.ini .. ".reach-backup")  .. " 2>/dev/null",
    "{ [ -s " .. ini .. " ] && printf '\\n'; cat " .. add .. "; } >> " .. ini,
    "rm -f " .. add, "" }, "\n"), "sh"
end

-- Queue the append to run once REAPER has quit. Returns the script path.
function toolbar.queue_append(ini, section, tmp_dir, process_name)
  process_name = process_name or platform.reaper_process()
  fs.mkdir(tmp_dir)
  local add_file = tmp_dir .. "/reach-toolbar-section.txt"
  assert(fs.write(add_file, section))
  local text, ext = toolbar.watcher_script({ ini = ini, add_file = add_file, process_name = process_name })
  local script = tmp_dir .. "/reach-toolbar-watcher." .. ext
  assert(fs.write(script, text))
  proc.launch(script)
  return script
end

-- Main toolbar: insert the missing buttons into an existing [Main toolbar] section. REAPER only has that section
-- in the ini once the user has customised the toolbar; if it's absent we can't know the default layout and must
-- not invent one (that would replace the whole toolbar). Returns
-- { status = "already_there" | "patch" | "no_main", missing = {...}, patched = text }
function toolbar.plan_main(ini, items)
  ini = ini or ""
  local eol = ini:find("\r\n", 1, true) and "\r\n" or "\n"
  local lines = {}
  for line in (ini:gsub("\r\n", "\n") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end

  local present = {}
  for _, line in ipairs(lines) do
    local cmd = line:match("^item_%d+=(%S+)")
    if cmd then present[cmd] = true end
  end
  local missing = {}
  for _, it in ipairs(items) do if not present[it.cmd] then missing[#missing + 1] = it end end
  if #missing == 0 then return { status = "already_there", missing = {} } end

  local start
  for i, line in ipairs(lines) do if line:match("^%[Main toolbar%]%s*$") then start = i break end end
  if not start then return { status = "no_main", missing = missing } end

  local last, max_n = start, -1
  for i = start + 1, #lines do
    if lines[i]:match("^%[") then break end
    local n = lines[i]:match("^item_(%d+)=") or lines[i]:match("^icon_(%d+)=")
    if n then last = i if tonumber(n) > max_n then max_n = tonumber(n) end end
  end
  local out = {}
  for i = 1, last do out[#out + 1] = lines[i] end
  for k, it in ipairs(missing) do out[#out + 1] = string.format("item_%d=%s %s", max_n + k, it.cmd, it.label) end
  for i = last + 1, #lines do out[#out + 1] = lines[i] end
  return { status = "patch", missing = missing, patched = table.concat(out, eol) .. eol }
end

-- Waits for REAPER to quit, then swaps in the patched ini ONLY if the file is still byte-identical to what we
-- planned from (otherwise the user changed their toolbars meanwhile: leave it, and say so in the log).
function toolbar.replace_watcher_script(opts) -- ini, new_file, orig_file, log_file, process_name
  local msg_skip = "skipped: reaper-menu.ini changed while REAPER was running; run Reach Settings again"
  if platform.is_windows() then
    local n = fs.native
    return table.concat({ "@echo off", "@chcp 65001 >NUL", ":wait",
      'tasklist /FI "IMAGENAME eq ' .. (opts.process_name or "reaper.exe") .. '" 2>NUL | find /I "' ..
        (opts.process_name or "reaper.exe") .. '" >NUL',
      "if not errorlevel 1 (", "  ping -n 3 127.0.0.1 >NUL", "  goto wait", ")",
      'if not exist "' .. n(opts.new_file) .. '" exit /b',
      'fc /b "' .. n(opts.ini) .. '" "' .. n(opts.new_file) .. '" >NUL 2>&1',
      'if not errorlevel 1 (echo applied> "' .. n(opts.log_file) .. '" & goto done)',
      'fc /b "' .. n(opts.ini) .. '" "' .. n(opts.orig_file) .. '" >NUL 2>&1',
      "if errorlevel 1 (", '  echo ' .. msg_skip .. '> "' .. n(opts.log_file) .. '"', "  goto done", ")",
      'if not exist "' .. n(opts.ini) .. '.reach-backup" copy /Y "' .. n(opts.ini) .. '" "' .. n(opts.ini) ..
        '.reach-backup" >NUL',
      'copy /Y "' .. n(opts.new_file) .. '" "' .. n(opts.ini) .. '" >NUL',
      'echo applied> "' .. n(opts.log_file) .. '"',
      ":done", 'del "' .. n(opts.new_file) .. '" "' .. n(opts.orig_file) .. '" >NUL 2>&1', "" }, "\r\n"), "bat"
  end
  local q = proc.quote
  local ini, new, orig, log = q(opts.ini), q(opts.new_file), q(opts.orig_file), q(opts.log_file)
  return table.concat({ "#!/bin/sh",
    "while pgrep -x " .. q(opts.process_name or platform.reaper_process()) .. " >/dev/null 2>&1; do sleep 2; done",
    "[ -f " .. new .. " ] || exit 0   # another watcher already handled this",
    "if cmp -s " .. ini .. " " .. new .. "; then echo applied > " .. log .. "; rm -f " .. new .. " " .. orig .. "; exit 0; fi",
    "if cmp -s " .. ini .. " " .. orig .. "; then",
    "  cp -n " .. ini .. " " .. q(opts.ini .. ".reach-backup") .. " 2>/dev/null",
    "  cp " .. new .. " " .. ini .. " && echo applied > " .. log,
    "else", "  echo " .. q(msg_skip) .. " > " .. log, "fi",
    "rm -f " .. new .. " " .. orig, "" }, "\n"), "sh"
end

function toolbar.queue_replace(ini, original_text, patched_text, tmp_dir, process_name)
  fs.mkdir(tmp_dir)
  local files = { new_file = tmp_dir .. "/reaper-menu.reach-new", orig_file = tmp_dir .. "/reaper-menu.reach-orig",
                  log_file = tmp_dir .. "/toolbar-result.txt" }
  fs.remove(files.log_file)
  assert(fs.write(files.new_file, patched_text))
  assert(fs.write(files.orig_file, original_text))
  local text, ext = toolbar.replace_watcher_script({ ini = ini, new_file = files.new_file, orig_file = files.orig_file,
    log_file = files.log_file, process_name = process_name or platform.reaper_process() })
  local script = tmp_dir .. "/reach-toolbar-replace." .. ext
  assert(fs.write(script, text))
  proc.launch(script)
  return script
end

-- What happened the last time a queued toolbar change ran (nil if nothing is recorded). Clears the record.
function toolbar.take_result(tmp_dir)
  local path = tmp_dir .. "/toolbar-result.txt"
  local r = fs.read(path)
  if r then fs.remove(path) return (r:gsub("%s+$", "")) end
  return nil
end

-- REAPER side. Registers the scripts as actions and queues the toolbar. Returns { message = "..." }.
function toolbar.install(plugin_dir, tmp_dir, offer_separate_toolbar)
  local scripts = { { "Reach_Sync_LQ.lua", "Reach: Sync LQ" }, { "Reach_Sync_HQ.lua", "Reach: Sync HQ" },
                    { "Reach_Join_song.lua", "Reach: Join song" }, { "Reach_Share_song.lua", "Reach: Share song" } }
  local items = {}
  for _, s in ipairs(scripts) do
    local id = reaper.AddRemoveReaScript(true, 0, fs.native(plugin_dir .. s[1]), true)
    if not id or id == 0 then
      return { message = "Couldn't register " .. s[1] .. " as an action. Add it from the Action list (New action > Load ReaScript) first." }
    end
    items[#items + 1] = { cmd = "_" .. reaper.ReverseNamedCommandLookup(id), label = s[2] }
  end
  local ini = fs.norm(reaper.GetResourcePath()) .. "/reaper-menu.ini"
  local text = fs.read(ini)

  local main = toolbar.plan_main(text, items)
  if main.status == "already_there" then
    return { message = "The Reach buttons are already on a toolbar. Nothing to do." }
  elseif main.status == "patch" then
    toolbar.queue_replace(ini, text, main.patched, tmp_dir)
    return { message = "The Sync, Join song and Share song actions are now in your Action list, and the buttons " ..
      "will be added to your MAIN toolbar when you QUIT REAPER (REAPER only reads toolbars at startup).\n\n" ..
      "A backup is kept as reaper-menu.ini.reach-backup. If you change your toolbars before quitting, the edit " ..
      "is skipped to avoid overwriting your changes; run Reach Settings again afterwards." }
  end

  -- No customised main toolbar on disk: we can't see the default layout, so don't write one.
  local how = "Your main toolbar hasn't been customised yet, so REAPER has no copy of it on disk and I can't add " ..
    "to it safely. To add the buttons to the main toolbar: right-click the toolbar > Customize toolbar > OK " ..
    "(any change; this makes REAPER save it), then run Reach Settings again. The actions are already in the " ..
    "Action list, so you can also just Add them in that dialog."
  if not (offer_separate_toolbar and offer_separate_toolbar(how)) then return { message = how } end

  local plan = toolbar.plan(text, items)
  if plan.status == "append" then
    toolbar.queue_append(ini, plan.section, tmp_dir)
    return { message = "A separate 'Reach' toolbar with the three buttons will be added when you QUIT REAPER " ..
      "(backup: reaper-menu.ini.reach-backup). After restarting, show it from the toolbar right-click menu." }
  elseif plan.status == "manual" then
    return { message = "A Reach toolbar or some of the buttons already exist, so I left your toolbars alone." }
  end
  return { message = "All floating toolbar slots are in use. Add the actions to a toolbar manually." }
end

return toolbar
