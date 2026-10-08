-- HTTP via curl (ships with macOS and Windows 10+). Requests run as background processes so REAPER
-- stays responsive; request options go through a curl config file so secrets never hit a command line.
local fs = require("reach.fs")
local platform = require("reach.platform")
local proc = require("reach.proc")
local async = require("reach.async")
local json = require("reach.json")

local http = { curl = nil }

local function cfg_quote(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

local function curl_path()
  if http.curl then return http.curl end
  return platform.is_windows() and "curl.exe" or "curl"
end

local counter = 0

-- opts: url, method, headers{}, json (table) or json_text (string), body (string), upload_file, output_file, timeout (sec)
-- Returns {status=, body=, json=(lazy via http.decode), err=}. Must run inside a task.
function http.request(opts)
  counter = counter + 1
  fs.mkdir(proc.tmp)
  local base = string.format("%s/h%d_%d_%d", proc.tmp, os.time(), math.random(1000000), counter)
  local cfg, bodyf, outf = base .. ".cfg", base .. ".body", opts.output_file or (base .. ".resp")

  local c = { "silent", "show-error", "globoff", "user-agent = " .. cfg_quote("ReachReaper/0.1"),
              "connect-timeout = 15", "max-time = " .. (opts.timeout or 60),
              "url = " .. cfg_quote(opts.url), "output = " .. cfg_quote(outf),
              "write-out = " .. cfg_quote("%{http_code}") }
  local headers = {}
  for k, v in pairs(opts.headers or {}) do headers[#headers + 1] = k .. ": " .. v end
  if opts.json ~= nil or opts.json_text ~= nil then
    assert(fs.write(bodyf, opts.json_text or json.encode(opts.json)))
    headers[#headers + 1] = "Content-Type: application/json"
    c[#c + 1] = "request = " .. cfg_quote(opts.method or "POST")
    c[#c + 1] = "data-binary = " .. cfg_quote("@" .. bodyf)
  elseif opts.upload_file then
    c[#c + 1] = "upload-file = " .. cfg_quote(opts.upload_file)
    headers[#headers + 1] = "Content-Type: application/octet-stream"
  elseif opts.method and opts.method ~= "GET" then
    c[#c + 1] = "request = " .. cfg_quote(opts.method)
  end
  for _, h in ipairs(headers) do c[#c + 1] = "header = " .. cfg_quote(h) end
  assert(fs.write(cfg, table.concat(c, "\n") .. "\n"))

  local res, why = proc.run({ curl_path(), "-K", fs.native(cfg) }, (opts.timeout or 60) + 30)
  fs.remove(cfg)
  fs.remove(bodyf)
  if not res then fs.remove(outf) return { status = 0, err = why or "failed to run curl" } end
  local status = tonumber(res.stdout:match("%d+$") or "") or 0
  local body
  if opts.output_file then
    body = nil
  else
    body = fs.read(outf)
    fs.remove(outf)
  end
  local err
  if res.code ~= 0 then
    err = (res.stderr ~= "" and res.stderr or ("curl exited with code " .. tostring(res.code))):gsub("%s+$", "")
  end
  return { status = status, body = body or "", err = err }
end

function http.decode(res)
  if res.body and res.body ~= "" then
    local ok, v = pcall(json.decode, res.body)
    if ok then return v end
  end
  return nil
end

return http
