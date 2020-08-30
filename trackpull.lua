kb = reaper.GetResourcePath()
if os ~= "Win32" and os ~= "Win64" then
    s = "/"
  else
    s = "\\"
  end
val = dofile(kb..s.."Scripts"..s.."gitinit.lua");
trackpull();
