-- Run external programs (curl, ffmpeg) without blocking REAPER: a small wrapper script runs the
-- command, captures stdout/stderr to files and writes the exit code last; a task polls for it.
local fs = require("reach.fs")
local async = require("reach.async")

local proc = { tmp = nil }
local platform = require("reach.platform")
local counter = 0
math.randomseed(os.time())

function proc.quote(s)
  s = tostring(s)
  if platform.is_windows() then return '"' .. s:gsub("%%", "%%%%") .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function launch(script)
  local r = rawget(_G, "reaper")
  local is_win = platform.is_windows()
  if r and r.ExecProcess then
    if is_win then r.ExecProcess('cmd.exe /c ""' .. script .. '""', -1)
    else r.ExecProcess('/bin/sh "' .. script .. '"', -1) end
  elseif is_win then
    os.execute('start /B "" cmd.exe /c ""' .. script .. '"" >NUL 2>&1')
  else
    os.execute("/bin/sh '" .. script .. "' >/dev/null 2>&1 &")
  end
end

proc.launch = launch -- run a script file in the background (used for one-off helper scripts)

local Job = {}
Job.__index = Job

function Job:finished()
  if self._done then return true end
  local s = fs.read(self.rc)
  if s and s:match("%d") then
    self._done = true
    self.code = tonumber(s:match("%-?%d+"))
    return true
  end
  return false
end

-- Returns {code=, stdout=, stderr=} and removes the job's temp files.
function Job:result()
  local res = { code = self.code, stdout = fs.read(self.out) or "", stderr = fs.read(self.err) or "" }
  for _, p in ipairs({ self.script, self.out, self.err, self.rc }) do fs.remove(p) end
  return res
end

-- Wrapper script text for running argv with stdout/stderr redirected and the exit code written LAST (so its
-- appearance means "done"). Pure, so it can be tested for any platform. Returns text, extension.
function proc.script_for(argv, files)
  local parts = {}
  for i, a in ipairs(argv) do parts[i] = proc.quote(a) end
  local cmd = table.concat(parts, " ")
  if platform.is_windows() then
    local n = fs.native
    return table.concat({ "@echo off", "@chcp 65001 >NUL", -- UTF-8 so non-ASCII paths survive
      cmd .. ' > "' .. n(files.out) .. '" 2> "' .. n(files.err) .. '"',
      'echo %errorlevel% > "' .. n(files.rc) .. '"', "" }, "\r\n"), "bat"
  end
  return table.concat({
    cmd .. " > " .. proc.quote(files.out) .. " 2> " .. proc.quote(files.err),
    "echo $? > " .. proc.quote(files.rc .. ".tmp"),
    "mv " .. proc.quote(files.rc .. ".tmp") .. " " .. proc.quote(files.rc), "" }, "\n"), "sh"
end

-- Start argv (a list) in the background. Returns a Job.
function proc.start(argv)
  assert(proc.tmp, "proc.tmp not configured")
  fs.mkdir(proc.tmp)
  counter = counter + 1
  local base = string.format("%s/p%d_%d_%d", proc.tmp, os.time(), math.random(1000000), counter)
  local files = { out = base .. ".out", err = base .. ".err", rc = base .. ".rc" }
  local body, ext = proc.script_for(argv, files)
  local job = setmetatable({ script = base .. "." .. ext, out = files.out, err = files.err, rc = files.rc }, Job)
  assert(fs.write(job.script, body))
  launch(job.script)
  return job
end

-- Inside a task: run argv to completion. Returns result table, or nil, "timeout".
function proc.run(argv, timeout)
  local job = proc.start(argv)
  local deadline = timeout and (async.clock() + timeout)
  async.wait_until(function() return job:finished() or (deadline and async.clock() > deadline) end)
  if not job:finished() then return nil, "timeout" end
  return job:result()
end

return proc
