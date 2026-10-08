-- Run external programs (curl, ffmpeg) without blocking REAPER: a small wrapper script runs the
-- command, captures stdout/stderr to files and writes the exit code last; a task polls for it.
local fs = require("reach.fs")
local async = require("reach.async")

local proc = { tmp = nil }
local is_win = package.config:sub(1, 1) == "\\"
proc.is_windows = is_win
local counter = 0
math.randomseed(os.time())

function proc.quote(s)
  s = tostring(s)
  if is_win then return '"' .. s:gsub("%%", "%%%%") .. '"' end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function launch(script)
  local r = rawget(_G, "reaper")
  if r and r.ExecProcess then
    if is_win then r.ExecProcess('cmd.exe /c ""' .. script .. '""', -1)
    else r.ExecProcess('/bin/sh "' .. script .. '"', -1) end
  elseif is_win then
    os.execute('start /B "" cmd.exe /c ""' .. script .. '"" >NUL 2>&1')
  else
    os.execute("/bin/sh '" .. script .. "' >/dev/null 2>&1 &")
  end
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

-- Returns {code=, stdout=, stderr=} and removes the job's temp files.
function Job:result()
  local res = { code = self.code, stdout = fs.read(self.out) or "", stderr = fs.read(self.err) or "" }
  for _, p in ipairs({ self.script, self.out, self.err, self.rc }) do fs.remove(p) end
  return res
end

-- Start argv (a list) in the background. Returns a Job.
function proc.start(argv)
  assert(proc.tmp, "proc.tmp not configured")
  fs.mkdir(proc.tmp)
  counter = counter + 1
  local base = string.format("%s/p%d_%d_%d", proc.tmp, os.time(), math.random(1000000), counter)
  local job = setmetatable({ script = base .. (is_win and ".bat" or ".sh"), out = base .. ".out",
                             err = base .. ".err", rc = base .. ".rc" }, Job)
  local parts = {}
  for i, a in ipairs(argv) do parts[i] = proc.quote(a) end
  local cmd = table.concat(parts, " ")
  local body
  if is_win then
    local n = fs.native
    body = table.concat({ "@echo off",
      cmd .. ' > "' .. n(job.out) .. '" 2> "' .. n(job.err) .. '"',
      'echo %errorlevel% > "' .. n(job.rc) .. '"', "" }, "\r\n")
  else
    body = table.concat({
      cmd .. " > " .. proc.quote(job.out) .. " 2> " .. proc.quote(job.err),
      "echo $? > " .. proc.quote(job.rc .. ".tmp"),
      "mv " .. proc.quote(job.rc .. ".tmp") .. " " .. proc.quote(job.rc), "" }, "\n")
  end
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
