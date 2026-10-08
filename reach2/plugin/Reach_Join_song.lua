-- Reach: Join_song (REAPER action script)
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""):gsub("\\", "/")
package.path = dir .. "?.lua;" .. package.path
for k in pairs(package.loaded) do if k:match("^reach%.") then package.loaded[k] = nil end end
require("reach.actions").join(dir)
