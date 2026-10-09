-- A single "the user pressed Cancel" flag. The progress window sets it; long waits (transfers, ffmpeg, hashing)
-- watch it and stop the running process, then raise cancel.error(). It is reset at the start of every sync.
local cancel = { requested = false }

function cancel.request() cancel.requested = true end
function cancel.reset() cancel.requested = false end
function cancel.error() return { cancelled = true, user = true, msg = "Cancelled." } end
function cancel.check() if cancel.requested then error(cancel.error(), 0) end end

return cancel
