-- Progress tracking for a sync. A sync is a series of phases ("Downloading audio", "Uploading audio", ...);
-- each is measured either in bytes (transfers, with several running in parallel) or in items (preparing files).
-- The tracker turns that into { label, fraction, detail } snapshots and hands them to ui:progress().
local async = require("reach.async")
local cancel = require("reach.cancel")

local progress = {}

function progress.human_bytes(n)
  n = n or 0
  local units, i = { "B", "KB", "MB", "GB", "TB" }, 1
  while n >= 1024 and i < #units do n = n / 1024 i = i + 1 end
  return (i == 1 and "%d %s" or "%.1f %s"):format(n, units[i])
end

function progress.human_duration(s)
  s = math.max(0, math.floor(s + 0.5))
  if s < 60 then return s .. "s" end
  if s < 3600 then return ("%dm %02ds"):format(s // 60, s % 60) end
  return ("%dh %02dm"):format(s // 3600, (s % 3600) // 60)
end

local Tracker = {}
Tracker.__index = Tracker

local SPEED_WINDOW = 6   -- seconds over which speed is averaged
local PUSH_EVERY = 0.2   -- don't redraw more often than this

function progress.new(ui) return setmetatable({ ui = ui }, Tracker) end

function Tracker:_push(force)
  if not (self.ui and self.ui.progress) then return end
  local now = async.clock()
  if not force and self.p and now - (self.p.last_push or 0) < PUSH_EVERY then return end
  if self.p then self.p.last_push = now end
  self.ui:progress(self:snapshot())
end

-- Start a new phase. opts: total_bytes (byte-measured), items (item-measured), both optional.
function Tracker:phase(label, opts)
  cancel.check()   -- phase boundaries are safe places to stop
  opts = opts or {}
  self.p = { label = label, total = opts.total_bytes, items = opts.items, items_done = 0, done = 0,
             active = {}, samples = {}, t0 = async.clock(), last_push = 0 }
  self.p.samples[1] = { t = self.p.t0, b = 0 }   -- baseline, so speed counts time spent before the first byte moved
  self:_push(true)
end

function Tracker:_bytes()
  local b = self.p.done
  for job in pairs(self.p.active) do b = b + job.got end
  return b
end

function Tracker:_sample()
  local now, p = async.clock(), self.p
  p.samples[#p.samples + 1] = { t = now, b = self:_bytes() }
  while #p.samples > 2 and now - p.samples[1].t > SPEED_WINDOW do table.remove(p.samples, 1) end
end

-- One transfer of `size` bytes. Returns { update = function(fraction), finish = function() }.
function Tracker:job(size)
  local job = { size = size or 0, got = 0 }
  if not self.p then self:phase("Working") end
  self.p.active[job] = true
  local tracker = self
  function job.update(fraction)
    job.got = math.floor(job.size * math.max(0, math.min(1, fraction)))
    tracker:_sample()
    tracker:_push(false)
  end
  function job.finish()
    if tracker.p.active[job] then
      tracker.p.active[job] = nil
      tracker.p.done = tracker.p.done + job.size
      tracker.p.items_done = tracker.p.items_done + 1
      tracker:_sample()
      tracker:_push(false)
    end
  end
  return job
end

-- One unit of item-measured work finished.
function Tracker:item_done()
  cancel.check()
  if not self.p then return end
  self.p.items_done = self.p.items_done + 1
  self:_push(false)
end

function Tracker:snapshot()
  local p = self.p
  if not p then return { label = "Working", fraction = nil, detail = "" } end
  local bytes = self:_bytes()
  local fraction, detail
  if p.total and p.total > 0 then
    fraction = math.min(1, bytes / p.total)
    local speed
    local first, last = p.samples[1], p.samples[#p.samples]
    if first and last and last.t > first.t then speed = (last.b - first.b) / (last.t - first.t) end
    detail = progress.human_bytes(bytes) .. " of " .. progress.human_bytes(p.total)
    if speed and speed > 1 then
      detail = detail .. "  -  " .. progress.human_bytes(speed) .. "/s"
      if bytes < p.total then detail = detail .. "  -  " .. progress.human_duration((p.total - bytes) / speed) .. " left" end
    end
    if p.items and p.items > 1 then detail = detail .. "  (file " .. math.min(p.items, p.items_done + 1) .. " of " .. p.items .. ")" end
  elseif p.items and p.items > 0 then
    fraction = math.min(1, p.items_done / p.items)
    detail = p.items_done .. " of " .. p.items .. " file(s)"
  end
  return { label = p.label, fraction = fraction, detail = detail or "" }
end

function Tracker:finish()
  if self.ui and self.ui.progress_end then self.ui:progress_end() end
  self.p = nil
end

return progress
