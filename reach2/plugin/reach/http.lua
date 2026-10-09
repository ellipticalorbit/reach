-- HTTP via curl (ships with macOS and Windows 10+). Requests run as background processes so REAPER
-- stays responsive; request options go through a curl config file so secrets never hit a command line.
local fs = require("reach.fs")
local platform = require("reach.platform")
local proc = require("reach.proc")
local async = require("reach.async")
local cancel = require("reach.cancel")
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

-- Last "NN.N%" in curl's --progress-bar output, as a fraction 0..1 (nil if none yet).
function http.parse_progress(text)
  local last
  for pct in (text or ""):gmatch("(%d+%.?%d*)%%") do last = pct end
  return last and math.min(1, tonumber(last) / 100) or nil
end

-- Keep only curl's own error lines (progress-bar noise removed).
local function clean_error(stderr)
  local lines = {}
  for line in (stderr:gsub("\r", "\n") .. "\n"):gmatch("(.-)\n") do
    if line:match("^curl") then lines[#lines + 1] = line end
  end
  local text = #lines > 0 and table.concat(lines, "\n") or stderr:gsub("[#%s]*%d*%.?%d*%%", ""):gsub("%s+$", "")
  return text
end

-- opts: url, method, headers{}, json (table) or json_text (string), upload_file, output_file,
--       timeout (seconds, total; omit for transfers), on_progress(fraction), limit_rate
-- File transfers (upload_file / output_file) have no total time limit, because a multi-GB WAV legitimately takes
-- long. They are aborted only if they stall (under 1 KB/s for 2 minutes), and retried on transient failures.
-- Returns {status=, body=, err=}. Must run inside a task.
function http.request(opts)
  counter = counter + 1
  fs.mkdir(proc.tmp)
  local base = string.format("%s/h%d_%d_%d", proc.tmp, os.time(), math.random(1000000), counter)
  local cfg, bodyf, outf = base .. ".cfg", base .. ".body", opts.output_file or (base .. ".resp")
  local transfer = opts.upload_file ~= nil or opts.output_file ~= nil

  local c = { "show-error", "globoff", "user-agent = " .. cfg_quote("ReachReaper/0.1"),
              "connect-timeout = 30", "retry = 3", "retry-delay = 2", "retry-connrefused",
              "url = " .. cfg_quote(opts.url), "output = " .. cfg_quote(outf),
              "write-out = " .. cfg_quote("%{http_code}") }
  if transfer then
    c[#c + 1] = "progress-bar"        -- percentages on stderr, polled below
    c[#c + 1] = "speed-limit = 1024"  -- abort only if slower than 1 KB/s ...
    c[#c + 1] = "speed-time = 120"    -- ... for 2 minutes
  else
    c[#c + 1] = "silent"
    c[#c + 1] = "max-time = " .. (opts.timeout or 120)
  end
  if opts.limit_rate then c[#c + 1] = "limit-rate = " .. opts.limit_rate end -- e.g. "8M"; used by tests
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

  local job = proc.start({ curl_path(), "-K", fs.native(cfg) }, { match = fs.native(cfg) })
  local timeout = (not transfer) and ((opts.timeout or 120) + 30) or nil
  local last_poll, last_frac = 0, nil
  proc.wait(job, { timeout = timeout, cancellable = transfer, on_tick = function()
    if opts.on_progress then
      local now = async.clock()
      if now - last_poll >= 0.25 then
        last_poll = now
        local f = http.parse_progress(job:stderr_tail(512))
        if f and f ~= last_frac then last_frac = f opts.on_progress(f) end
      end
    end
  end })
  fs.remove(cfg)
  fs.remove(bodyf)
  if transfer and cancel.requested then       -- stopped by the user: leave nothing half-written behind
    job:abandon()
    if opts.output_file then fs.remove(outf) end
    error(cancel.error(), 0)
  end
  if not job:finished() then job:abandon() fs.remove(outf) return { status = 0, err = "timeout" } end
  local res = job:result()
  if opts.on_progress and res.code == 0 then opts.on_progress(1) end
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
    err = clean_error(res.stderr)
    if err == "" then err = "curl exited with code " .. tostring(res.code) end
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
