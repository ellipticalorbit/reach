-- Run external programs (curl, ffmpeg) without blocking REAPER: a small wrapper script runs the
-- command, captures stdout/stderr to files and writes the exit code last; a task polls for it.
local fs = require("reach.fs")
local async = require("reach.async")
local cancel = require("reach.cancel")

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

-- Fire-and-forget a single command line.
local function launch_command(cmd)
  local r = rawget(_G, "reaper")
  if r and r.ExecProcess then r.ExecProcess(cmd, -1)
  elseif platform.is_windows() then os.execute('start /B "" ' .. cmd .. " >NUL 2>&1")
  else os.execute(cmd .. " >/dev/null 2>&1 &") end
end

-- Command that stops a running job. POSIX: the wrapper script records the command's pid. Windows has no easy
-- pid from a batch file, so find the process by a string unique to its command line (`match`) via PowerShell.
function proc.kill_command(pid, match)
  if platform.is_windows() then
    if not match then return nil end
    local pattern = match:gsub("'", "''"):gsub("([%[%]%*%?])", "`%1")
    return 'powershell.exe -NoProfile -NonInteractive -Command "Get-CimInstance Win32_Process | Where-Object { ' ..
      "$_.CommandLine -like '*" .. pattern .. "*' -and $_.Name -notlike 'powershell*' } | ForEach-Object { " ..
      'Stop-Process -Id $_.ProcessId -Force }"'
  end
  if not pid then return nil end
  return '/bin/sh -c "kill ' .. pid .. '"'
end

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

-- Ask the job to stop. Safe to call repeatedly; the wrapper still writes its exit code, so finished() turns true.
function Job:kill()
  self._kill_wanted = true
  self:_poll_kill()
end

-- The pid file appears a moment after launch, so a kill requested very early is retried from the wait loop.
function Job:_poll_kill()
  if not self._kill_wanted or self._killed or self:finished() then return end
  local pid = self.pidfile and (fs.read(self.pidfile) or ""):match("%d+")
  local cmd = proc.kill_command(pid, self.match)
  if cmd then launch_command(cmd) self._killed = true end
end

-- Throw away a job we are not going to read the result of.
function Job:abandon()
  for _, p in ipairs({ self.script, self.out, self.err, self.rc, self.pidfile }) do if p then fs.remove(p) end end
end

-- The last `n` bytes of the job's stderr so far (curl writes its progress meter there while running).
function Job:stderr_tail(n)
  local f = io.open(self.err, "rb")
  if not f then return "" end
  local size = f:seek("end")
  f:seek("set", math.max(0, size - n))
  local data = f:read("a") or ""
  f:close()
  return data
end

-- Returns {code=, stdout=, stderr=} and removes the job's temp files. stderr is capped to its last 4 KB: a
-- long transfer's progress meter can be large and only the end holds the error message.
function Job:result()
  local res = { code = self.code, stdout = fs.read(self.out) or "", stderr = self:stderr_tail(4096) }
  self:abandon()
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
    cmd .. " > " .. proc.quote(files.out) .. " 2> " .. proc.quote(files.err) .. " &",
    "echo $! > " .. proc.quote(files.pid or (files.rc .. ".pid")),   -- so Cancel can stop it
    "wait $!",
    "echo $? > " .. proc.quote(files.rc .. ".tmp"),
    "mv " .. proc.quote(files.rc .. ".tmp") .. " " .. proc.quote(files.rc), "" }, "\n"), "sh"
end

-- Start argv (a list) in the background. Returns a Job. opts.match: a string unique to the command line (Windows
-- uses it to find the process when cancelling).
function proc.start(argv, opts)
  assert(proc.tmp, "proc.tmp not configured")
  fs.mkdir(proc.tmp)
  counter = counter + 1
  local base = string.format("%s/p%d_%d_%d", proc.tmp, os.time(), math.random(1000000), counter)
  local files = { out = base .. ".out", err = base .. ".err", rc = base .. ".rc", pid = base .. ".pid" }
  local body, ext = proc.script_for(argv, files)
  local job = setmetatable({ script = base .. "." .. ext, out = files.out, err = files.err, rc = files.rc,
                             pidfile = files.pid, match = opts and opts.match }, Job)
  assert(fs.write(job.script, body))
  launch(job.script)
  return job
end

-- Inside a task: wait for `job` to finish. opts: timeout (s), cancellable (stop the job and give up when the user
-- cancels), on_tick (called every scheduler tick). Returns true if it finished.
function proc.wait(job, opts)
  opts = opts or {}
  local deadline = opts.timeout and (async.clock() + opts.timeout)
  local give_up
  async.wait_until(function()
    if opts.on_tick then opts.on_tick() end
    if opts.cancellable and cancel.requested then
      job:kill()
      give_up = give_up or (async.clock() + 10)   -- if the kill never lands, don't wait forever
    end
    job:_poll_kill()
    if job:finished() then return true end
    local now = async.clock()
    return (deadline and now > deadline) or (give_up and now > give_up) or false
  end)
  return job:finished()
end

-- Inside a task: run argv to completion. Returns result table, or nil, "timeout".
-- opts.cancellable: raise cancel.error() (after stopping the process) if the user cancels. opts.match: see start().
function proc.run(argv, timeout, opts)
  opts = opts or {}
  local job = proc.start(argv, { match = opts.match })
  local done = proc.wait(job, { timeout = timeout, cancellable = opts.cancellable })
  if opts.cancellable and cancel.requested then
    job:abandon()
    error(cancel.error(), 0)
  end
  if not done then job:abandon() return nil, "timeout" end
  return job:result()
end

return proc
