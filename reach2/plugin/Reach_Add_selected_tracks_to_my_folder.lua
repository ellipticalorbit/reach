-- Reach: Add_selected_tracks_to_my_folder (REAPER action script)
local dir = (debug.getinfo(1, "S").source:match("^@(.*[/\\])") or ""):gsub("\\", "/")
package.path = dir .. "?.lua;" .. package.path
for k in pairs(package.loaded) do if k:match("^reach%.") then package.loaded[k] = nil end end
require("reach.actions").add_selected(dir)
