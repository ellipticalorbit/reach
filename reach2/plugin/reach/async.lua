-- Tiny coroutine scheduler so long operations (HTTP, ffmpeg) never block REAPER's UI.
-- Inside a task, call async.wait_until(pred) to suspend until pred() is true.
local async = { tasks = {}, running = false }

-- Resolve `reaper` at call time (it is absent when running outside REAPER).
local function R() return rawget(_G, "reaper") end
function async.clock()
  local r = R()
  return (r and r.time_precise) and r.time_precise() or os.time()
end

local function finish(task, r)
  task.done = true
  task.ok = r[1]
  if r[1] then task.value = r[2] task.values = r else task.err = r[2] end
  if task.on_done then task.on_done(task) end
end

local function step(task)
  local ok, a = coroutine.resume(task.co)
  if not ok then finish(task, { false, { msg = tostring(a) } }) return end
  if coroutine.status(task.co) == "dead" then
    finish(task, a)
  else
    task.wait = a
  end
end

function async.spawn(fn, ...)
  local args = table.pack(...)
  local task = { done = false }
  task.co = coroutine.create(function()
    return table.pack(xpcall(fn, function(e)
      if type(e) == "table" then e.trace = e.trace or debug.traceback("", 2) return e end
      return { msg = tostring(e), trace = debug.traceback("", 2) }
    end, table.unpack(args, 1, args.n)))
  end)
  async.tasks[#async.tasks + 1] = task
  step(task)
  return task
end

function async.tick()
  local snapshot = { table.unpack(async.tasks) }
  for _, task in ipairs(snapshot) do
    if not task.done and (task.wait == nil or task.wait()) then
      task.wait = nil
      step(task)
    end
  end
  local alive = {}
  for _, t in ipairs(async.tasks) do if not t.done then alive[#alive + 1] = t end end
  async.tasks = alive
end

function async.wait_until(pred)
  if pred() then return end
  if not coroutine.isyieldable() then error("async.wait_until called outside a task") end
  coroutine.yield(pred)
end

-- Give the UI a turn; resumes on the next tick.
function async.yield()
  if coroutine.isyieldable() then coroutine.yield(function() return true end) end
end

function async.sleep(seconds)
  local deadline = async.clock() + seconds
  async.wait_until(function() return async.clock() >= deadline end)
end

-- Wait for another task and return its value (re-raises its error).
function async.join(task)
  async.wait_until(function() return task.done end)
  if not task.ok then error(task.err, 0) end
  return task.value
end

-- Run fns concurrently (at most `limit` at once); returns results in order. Raises the first error.
function async.parallel(fns, limit)
  limit = limit or 4
  local results, first_err = {}, nil
  local next_i, active = 1, {}
  local function launch()
    while next_i <= #fns and #active < limit and not first_err do
      local t = async.spawn(fns[next_i])
      t.index = next_i
      next_i = next_i + 1
      active[#active + 1] = t
    end
  end
  launch()
  while #active > 0 do
    async.wait_until(function()
      for _, t in ipairs(active) do if t.done then return true end end
      return false
    end)
    local still = {}
    for _, t in ipairs(active) do
      if t.done then
        if t.ok then results[t.index] = t.value elseif not first_err then first_err = t.err end
      else
        still[#still + 1] = t
      end
    end
    active = still
    launch()
  end
  if first_err then error(first_err, 0) end
  return results
end

-- REAPER: run `fn` as a task driven by reaper.defer. on_done(task) gets the outcome.
function async.start(fn, on_done)
  local task = async.spawn(fn)
  task.on_done = on_done
  if task.done and on_done then on_done(task) end
  if not async.running and not task.done then
    async.running = true
    local function loop()
      async.tick()
      if #async.tasks > 0 then R().defer(loop) else async.running = false end
    end
    R().defer(loop)
  end
  return task
end

-- Tests / scripts outside REAPER: drive the scheduler until the task finishes.
function async.run(fn, ...)
  local task = async.spawn(fn, ...)
  while not task.done do
    async.tick()
    if not task.done then os.execute("sleep 0.02") end
  end
  if not task.ok then
    local e = task.err
    error(type(e) == "table" and ((e.msg or "error") .. "\n" .. (e.trace or "")) or tostring(e), 0)
  end
  return table.unpack(task.values, 2, task.values.n)
end

return async
