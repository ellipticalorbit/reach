-- Fractional ordering keys for siblings. Moving or inserting one track only changes that track's key,
-- so reordering doesn't make every sibling look "modified" (and conflict with collaborators).
local keys = {}

-- order: guids in their local order. known: guid -> existing key (or nil).
-- Returns guid -> key, keeping the largest set of existing keys that are already in order.
function keys.assign(order, known)
  local n = #order
  -- longest strictly-increasing subsequence over items that have a key
  local best_len, prev = {}, {}
  local top, top_len = nil, 0
  for i = 1, n do
    local ki = known[order[i]]
    if ki then
      best_len[i], prev[i] = 1, nil
      for j = 1, i - 1 do
        local kj = known[order[j]]
        if kj and kj < ki and best_len[j] + 1 > best_len[i] then
          best_len[i], prev[i] = best_len[j] + 1, j
        end
      end
      if best_len[i] > top_len then top, top_len = i, best_len[i] end
    end
  end
  local keep = {}
  local i = top
  while i do keep[i] = true i = prev[i] end

  local result = {}
  for idx = 1, n do if keep[idx] then result[order[idx]] = known[order[idx]] end end

  local idx = 1
  while idx <= n do
    if keep[idx] then
      idx = idx + 1
    else
      local first = idx
      while idx <= n and not keep[idx] do idx = idx + 1 end
      local count = idx - first
      local lo = first > 1 and result[order[first - 1]] or nil
      local hi = idx <= n and result[order[idx]] or nil
      for m = 1, count do
        local k
        if lo and hi then k = lo + (hi - lo) * m / (count + 1)
        elseif lo then k = lo + m
        elseif hi then k = hi - (count - m + 1)
        else k = m end
        result[order[first + m - 1]] = k
      end
    end
  end
  -- Precision exhausted after many insertions between the same neighbours: renumber.
  for m = 2, n do
    if not (result[order[m]] > result[order[m - 1]] + 1e-9) then
      for r = 1, n do result[order[r]] = r end
      break
    end
  end
  for g, v in pairs(result) do result[g] = tonumber(string.format("%.12g", v)) end
  return result
end

return keys
