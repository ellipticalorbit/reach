-- Typed wrapper over the Reach server's REST API. All methods must run inside an async task.
local http = require("reach.http")
local json = require("reach.json")

local function esc(guid) return (guid:gsub("[{}]", { ["{"] = "%7B", ["}"] = "%7D" })) end

local Api = {}
Api.__index = Api

local api = {}

function api.new(opts) -- opts: base_url, token (string or function returning one)
  return setmetatable({ base_url = opts.base_url, token = opts.token }, Api)
end

-- base_url may be a string or a function (so settings changes apply immediately)
-- "quake.example.com" -> "https://quake.example.com" (http for localhost / plain IPs); strips trailing slashes.
function api.normalise_url(u)
  u = (u or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
  if u ~= "" and not u:match("^%a[%w+.-]*://") then
    local host = u:match("^[^/:]+")
    local local_host = host == "localhost" or host:match("^127%.") or host:match("^%d+%.%d+%.%d+%.%d+$")
    u = (local_host and "http://" or "https://") .. u
  end
  return u
end

function Api:base()
  local u = type(self.base_url) == "function" and self.base_url() or self.base_url or ""
  return api.normalise_url(u)
end

local function err_message(status, data, raw)
  local d = data and data.detail
  if type(d) == "table" then d = d.error or json.encode(d) end
  return d and tostring(d) or (raw ~= "" and raw or ("HTTP " .. status))
end

local function check(res, ok_statuses)
  local data = http.decode(res)
  if res.status == 0 then
    error({ msg = "Cannot reach the Reach server: " .. tostring(res.err), code = 0, network = true }, 0)
  end
  if res.status >= 200 and res.status < 300 then return data, res.status end
  if ok_statuses and ok_statuses[res.status] then return data, res.status end
  error({ msg = err_message(res.status, data, res.body), code = res.status, data = data,
          unauthorized = res.status == 401 }, 0)
end

function Api:_headers()
  local t = self.token
  if type(t) == "function" then t = t() end
  return t and { Authorization = "Bearer " .. t } or {}
end

function Api:call(method, path, body, opts)
  opts = opts or {}
  local res = http.request({ url = self:base() .. path, method = method, json = body, json_text = opts.json_text,
                             headers = self:_headers(), timeout = opts.timeout })
  return check(res, opts.ok)
end

function Api:device_start(label) return self:call("POST", "/auth/device", { label = label or "" }) end

-- Returns token, or nil + reason ("authorization_pending" etc.)
function Api:device_poll(device_code)
  local data, status = self:call("POST", "/auth/device/token", { device_code = device_code }, { ok = { [400] = true } })
  if status == 200 then return data.access_token end
  local e = data and data.detail and data.detail.error
  return nil, e or "error"
end

function Api:me() return self:call("GET", "/me") end
function Api:create_project(name) return self:call("POST", "/projects", { name = name }) end
function Api:join(code) return self:call("POST", "/join", { code = code }) end
function Api:projects() return self:call("GET", "/projects") end
function Api:project(id) return self:call("GET", "/projects/" .. id) end
function Api:changes(id, since) return self:call("GET", "/projects/" .. id .. "/changes?since=" .. (since or 0)) end
function Api:tracks(id, state) return self:call("GET", "/projects/" .. id .. "/tracks?state=" .. (state or "live")) end
function Api:revisions(id, guid) return self:call("GET", "/projects/" .. id .. "/tracks/" .. esc(guid) .. "/revisions") end
function Api:restore(id, guid, rev)
  -- an empty Lua table would encode as [] rather than {}
  return self:call("POST", "/projects/" .. id .. "/tracks/" .. esc(guid) .. "/restore", nil,
    { json_text = rev and ('{"rev":' .. math.floor(rev) .. '}') or "{}" })
end

-- { [sha] = bytes } for blobs the project has (to size download progress).
function Api:blob_sizes(id, hashes)
  if #hashes == 0 then return {} end
  return self:call("POST", "/projects/" .. id .. "/blobs/info", { hashes = hashes }).sizes
end

function Api:blobs_missing(id, hashes)
  if #hashes == 0 then return {} end
  return self:call("POST", "/projects/" .. id .. "/blobs/missing", { hashes = hashes }).missing
end

-- Returns data or, for a 422 missing_blobs reply, nil + list of missing hashes.
function Api:push(id, tracks)
  local data, status = self:call("POST", "/projects/" .. id .. "/push", { tracks = tracks }, { ok = { [422] = true } })
  if status == 422 then
    local d = data and data.detail
    if type(d) == "table" and d.error == "missing_blobs" then return nil, d.missing end
    error({ msg = err_message(status, data, ""), code = status, data = data }, 0)
  end
  return data
end

-- {ogg sha, ...} -> { [ogg sha] = wav sha } for those that have a high-quality WAV companion.
function Api:hq_lookup(id, hashes)
  if #hashes == 0 then return {} end
  return self:call("POST", "/projects/" .. id .. "/hq/lookup", { hashes = hashes }).variants
end

-- links: { { ogg = sha, wav = sha }, ... }
function Api:hq_link(id, links)
  if #links == 0 then return {} end
  return self:call("POST", "/projects/" .. id .. "/hq", { links = links }).results
end

function Api:put_blob(id, sha, path, on_progress)
  local res = http.request({ url = self:base() .. "/projects/" .. id .. "/blobs/" .. sha, method = "PUT",
                             upload_file = path, headers = self:_headers(), on_progress = on_progress })
  return check(res)
end

function Api:get_blob(id, sha, dest, on_progress)
  local res = http.request({ url = self:base() .. "/projects/" .. id .. "/blobs/" .. sha, method = "GET",
                             output_file = dest, headers = self:_headers(), on_progress = on_progress })
  if res.status ~= 200 then
    require("reach.fs").remove(dest)
    error({ msg = "download failed (HTTP " .. res.status .. ")" .. (res.err and (": " .. res.err) or ""),
            code = res.status }, 0)
  end
end

return api
