-- One place that knows which OS we are on: "windows" | "macos" | "linux".
-- Inside REAPER we ask reaper.GetOS(); outside (tests) we infer it. `platform.set()` overrides it so the
-- per-OS script builders can be tested from any machine.
local platform = { _override = nil, _cached = nil }

function platform.os()
  if platform._override then return platform._override end
  if platform._cached then return platform._cached end
  local name
  local r = rawget(_G, "reaper")
  if r and r.GetOS then
    local o = r.GetOS():lower()
    if o:find("win") then name = "windows" elseif o:find("osx") or o:find("mac") then name = "macos" else name = "linux" end
  elseif package.config:sub(1, 1) == "\\" then
    name = "windows"
  else
    local p = io.popen("uname -s 2>/dev/null")
    local u = p and p:read("a") or ""
    if p then p:close() end
    name = u:find("Darwin") and "macos" or "linux"
  end
  platform._cached = name
  return name
end

function platform.set(name) platform._override = name end
function platform.is_windows() return platform.os() == "windows" end

-- Name of the REAPER process, for waiting until it has quit.
function platform.reaper_process()
  local o = platform.os()
  if o == "windows" then return "reaper.exe" elseif o == "macos" then return "REAPER" else return "reaper" end
end

-- Command that opens a URL in the default browser (used when SWS's CF_ShellExecute is unavailable).
function platform.open_command(url)
  local o = platform.os()
  if o == "windows" then return 'cmd.exe /c start "" "' .. url .. '"'
  elseif o == "macos" then return '/usr/bin/open "' .. url .. '"'
  else return 'xdg-open "' .. url .. '"' end
end

return platform
