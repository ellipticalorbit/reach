-- Small filesystem helpers. Paths use "/" internally (REAPER and Windows both accept it).
local fs = {}

local function R() return rawget(_G, "reaper") end

function fs.norm(path) return (path:gsub("\\", "/")) end

function fs.native(path)
  if package.config:sub(1, 1) == "\\" then return (path:gsub("/", "\\")) end
  return path
end

function fs.join(a, b)
  if a:sub(-1) == "/" then return a .. b end
  return a .. "/" .. b
end

function fs.basename(path) return (path:match("([^/\\]+)$")) or path end
function fs.dirname(path) return (path:match("^(.*)[/\\][^/\\]*$")) or "." end
function fs.ext(path) return ((path:match("%.([^./\\]+)$")) or ""):lower() end

function fs.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local d = f:read("a")
  f:close()
  return d
end

function fs.write(path, data)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

function fs.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function fs.size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:seek("end")
  f:close()
  return s
end

function fs.mkdir(path)
  local r = R()
  if r and r.RecursiveCreateDirectory then
    r.RecursiveCreateDirectory(path, 0)
  elseif package.config:sub(1, 1) == "\\" then
    os.execute('mkdir "' .. fs.native(path) .. '" >NUL 2>&1')
  else
    os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
  end
end

function fs.remove(path) os.remove(path) end

-- Rename, replacing the destination (Windows os.rename refuses to).
function fs.rename(from, to)
  os.remove(to)
  return os.rename(from, to)
end

return fs
