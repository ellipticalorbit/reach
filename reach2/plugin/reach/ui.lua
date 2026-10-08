-- User interaction. `ui.reaper()` uses REAPER dialogs and the console; `ui.headless()` is scriptable for tests.
local ui = {}

function ui.reaper()
  local R = reaper
  local u = {}
  function u:log(msg) R.ShowConsoleMsg("[Reach] " .. msg .. "\n") end
  function u:info(title, msg) R.MB(msg, title, 0) end
  function u:confirm(title, msg) return R.MB(msg, title, 4) == 6 end

  -- Returns "mine" | "theirs" | "both"
  function u:resolve_conflict(c)
    local who = c.author or c.owner or "someone"
    if c.kind == "both_edited" then
      local r = R.MB("Track \"" .. c.name .. "\" was changed here and also by " .. who .. ".\n\n" ..
        "YES  = keep MY version\nNO   = use THEIR version\nCANCEL = keep BOTH (their version, plus a copy of mine)",
        "Reach: conflict", 3)
      if r == 6 then return "mine" elseif r == 7 then return "theirs" else return "both" end
    elseif c.kind == "remote_deleted" then
      local r = R.MB("Track \"" .. c.name .. "\" was deleted by " .. who .. " but you changed it.\n\n" ..
        "YES = keep my version (restore it for everyone)\nNO = delete it here too", "Reach: conflict", 4)
      return r == 6 and "mine" or "theirs"
    else
      local r = R.MB("You deleted track \"" .. c.name .. "\" but " .. who .. " changed it.\n\n" ..
        "YES = delete it for everyone\nNO = bring their version back", "Reach: conflict", 4)
      return r == 6 and "mine" or "theirs"
    end
  end

  function u:confirm_deletes(names)
    local list = table.concat(names, "\n  ", 1, math.min(#names, 15)) .. (#names > 15 and "\n  ..." or "")
    return R.MB(#names .. " synced track(s) are no longer in your Reach folder:\n\n  " .. list ..
      "\n\nDelete them for everyone? (Deleted tracks can be restored with 'Reach: Restore deleted tracks'.)",
      "Reach: deleted tracks", 4) == 6
  end

  function u:prompt(title, caption, default)
    local ok, v = R.GetUserInputs(title, 1, caption .. ",extrawidth=250", default or "")
    if ok then return v end
    return nil
  end

  function u:open_url(url)
    if R.CF_ShellExecute then R.CF_ShellExecute(url) return end
    local win = package.config:sub(1, 1) == "\\"
    if win then R.ExecProcess('cmd.exe /c start "" "' .. url .. '"', -1)
    else R.ExecProcess('/usr/bin/open "' .. url .. '"', -1) end
  end

  function u:clipboard(text) if R.CF_SetClipboard then R.CF_SetClipboard(text) end end
  return u
end

-- opts: conflict (string or function(c)), confirm_deletes (bool or function), open_url (function)
function ui.headless(opts)
  opts = opts or {}
  local u = { logs = {}, conflicts_seen = {} }
  function u:log(msg) self.logs[#self.logs + 1] = msg if opts.verbose then print("[ui] " .. msg) end end
  function u:info() end
  function u:confirm() return true end
  function u:resolve_conflict(c)
    self.conflicts_seen[#self.conflicts_seen + 1] = c
    local v = opts.conflict or "theirs"
    if type(v) == "function" then return v(c) end
    return v
  end
  function u:confirm_deletes(names)
    local v = opts.confirm_deletes
    if v == nil then return true end
    if type(v) == "function" then return v(names) end
    return v
  end
  function u:open_url(url) if opts.open_url then opts.open_url(url) end end
  function u:clipboard() end
  return u
end

return ui
