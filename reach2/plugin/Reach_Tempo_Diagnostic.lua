-- Reach: Tempo diagnostic (read-only; changes nothing).
-- Select a few items (ideally on tracks with different timebases), run this, change the tempo, run it again,
-- and paste both console outputs. It shows how this REAPER stores and retimes items when the tempo changes.
local function p(s) reaper.ShowConsoleMsg(s .. "\n") end

p("==== Reach tempo diagnostic  " .. os.date("%Y-%m-%d %H:%M:%S") .. "  REAPER " .. reaper.GetAppVersion())

local bpm, bpi = reaper.GetProjectTimeSignature2(0)
p(("Project tempo: %.3f BPM, %d beats per measure"):format(bpm, bpi))
local n = reaper.CountTempoTimeSigMarkers(0)
p("Tempo/time-signature markers: " .. n)
for i = 0, n - 1 do
  local _, t, measure, beat, mbpm, num, den, linear = reaper.GetTempoTimeSigMarker(0, i)
  p(("  #%d at %.4fs (measure %d, beat %.3f): %.3f BPM, %d/%d%s"):format(i, t, measure, beat, mbpm, num, den,
    linear and ", linear ramp" or ""))
end

-- Project-level timebase settings, read from the saved project file (save first for current values).
local _, path = reaper.EnumProjects(-1, "")
if path and path ~= "" then
  local f = io.open(path, "r")
  if f then
    local text = f:read("a")
    f:close()
    for _, key in ipairs({ "TIMELOCKMODE", "TEMPOENVLOCKMODE", "TEMPO" }) do
      local line = text:match("\n%s*(" .. key .. " [^\n]*)")
      p("Project file: " .. (line or (key .. " (not found)")))
    end
  end
else
  p("Project not saved yet: save it to see the project timebase settings.")
end

local modes = { [-1] = "project default", [0] = "time", [1] = "beats (pos, len, rate)", [2] = "beats (pos only)" }
local count = reaper.CountSelectedMediaItems(0)
p("Selected items: " .. count .. (count == 0 and "  (select some items and run again)" or ""))
for i = 0, count - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local track = reaper.GetMediaItem_Track(item)
  local _, tname = reaper.GetTrackName(track)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local mode = math.floor(reaper.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE"))
  local take = reaper.GetActiveTake(item)
  local rate = take and reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 0
  local qn0, qn1 = reaper.TimeMap2_timeToQN(0, pos), reaper.TimeMap2_timeToQN(0, pos + len)
  local _, tchunk = reaper.GetTrackStateChunk(track, "", false)
  local track_beat = tchunk:match("\n%s*BEAT ([^\n]*)") or "?"
  p(("-- item %d on \"%s\": %.4fs + %.4fs, rate %.4f | QN %.4f -> %.4f | item timebase %s | track BEAT %s"):format(
    i + 1, tname, pos, len, rate, qn0, qn1, modes[mode] or tostring(mode), track_beat))
  local _, ichunk = reaper.GetItemStateChunk(item, "", false)
  for line in ichunk:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    for _, key in ipairs({ "POSITION", "SNAPOFFS", "LENGTH", "BEAT", "PLAYRATE", "SOFFS" }) do
      if trimmed:sub(1, #key + 1) == key .. " " then p("     " .. trimmed) end
    end
  end
end
p("==== end")
