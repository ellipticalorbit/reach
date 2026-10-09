-- A small progress window drawn with REAPER's built-in gfx (no extensions needed). It redraws from its own
-- defer loop, so it stays alive while the sync tasks wait on network or disk. Closing it only hides the
-- window; the sync carries on. The Cancel button (or Esc) asks everything to stop.
local cancel = require("reach.cancel")
local win = { open = false, active = false, dismissed = false, state = nil, t0 = 0, first = 0,
              delay = 1.0 } -- only appear if the sync is still going after this many seconds

local W, H = 500, 150
local BTN = { w = 96, h = 26 }

local function bar(x, y, w, h, fraction)
  gfx.set(0.22, 0.22, 0.24, 1)
  gfx.rect(x, y, w, h, true)
  if fraction then
    gfx.set(0.25, 0.62, 0.95, 1)
    gfx.rect(x, y, math.floor(w * fraction), h, true)
  else -- unknown length: a sliding block
    local t = (reaper.time_precise() - win.t0) % 1.6 / 1.6
    local bw = math.floor(w * 0.25)
    gfx.set(0.25, 0.62, 0.95, 1)
    gfx.rect(x + math.floor((w - bw) * (t < 0.5 and t * 2 or (1 - t) * 2)), y, bw, h, true)
  end
  gfx.set(0.45, 0.45, 0.48, 1)
  gfx.rect(x, y, w, h, false)
end

local function draw()
  if not win.active then if win.open then gfx.quit() win.open = false end return end
  if not win.open then
    -- not shown yet: wait out the delay so quick syncs never flash a window
    if win.dismissed then return end
    if reaper.time_precise() - win.first < win.delay then reaper.defer(draw) return end
    local mx, my = reaper.GetMousePosition()
    gfx.init("Reach sync", W, H, 0, math.max(0, mx - W // 2), math.max(0, my - H // 2))
    win.open, win.t0 = true, reaper.time_precise()
  end
  local ch = gfx.getchar()
  if ch < 0 then win.open, win.dismissed = false, true return end -- user closed it
  local s = win.state or {}
  gfx.set(0.12, 0.12, 0.13, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, true)
  gfx.setfont(1, "Arial", 17)
  gfx.set(0.95, 0.95, 0.96, 1)
  gfx.x, gfx.y = 20, 18
  gfx.drawstr(s.label or "Working...")
  bar(20, 52, gfx.w - 40, 20, s.fraction)
  gfx.setfont(2, "Arial", 14)
  gfx.set(0.75, 0.75, 0.78, 1)
  gfx.x, gfx.y = 20, 84
  local pct = s.fraction and ("%d%%   "):format(math.floor(s.fraction * 100)) or ""
  gfx.drawstr(pct .. (s.detail or ""))
  -- Cancel button (bottom right). Fires on mouse release inside it; Esc works too.
  local bx, by = gfx.w - BTN.w - 20, gfx.h - BTN.h - 14
  local inside = gfx.mouse_x >= bx and gfx.mouse_x <= bx + BTN.w and gfx.mouse_y >= by and gfx.mouse_y <= by + BTN.h
  local down = (gfx.mouse_cap & 1) == 1
  if cancel.requested then
    gfx.set(0.3, 0.3, 0.32, 1)
  elseif inside then
    gfx.set(down and 0.65 or 0.8, 0.28, 0.28, 1)
  else
    gfx.set(0.55, 0.22, 0.22, 1)
  end
  gfx.rect(bx, by, BTN.w, BTN.h, true)
  gfx.set(1, 1, 1, 1)
  local label = cancel.requested and "Cancelling..." or "Cancel"
  local tw, th = gfx.measurestr(label)
  gfx.x, gfx.y = bx + (BTN.w - tw) // 2, by + (BTN.h - th) // 2
  gfx.drawstr(label)
  if win.was_down and not down and inside and not cancel.requested then cancel.request() end
  win.was_down = down and inside
  if ch == 27 and not cancel.requested then cancel.request() end

  gfx.update()
  reaper.defer(draw)
end

function win.show(state)
  win.state = state
  if win.active then return end
  win.active, win.first = true, reaper.time_precise()
  reaper.defer(draw)
end

function win.close()
  win.was_down = false
  if win.open then gfx.quit() end
  win.open, win.active, win.dismissed, win.state = false, false, false, nil
end

return win
