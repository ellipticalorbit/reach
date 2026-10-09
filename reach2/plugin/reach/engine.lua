-- The sync engine. Knows nothing about REAPER itself: it talks to a `tracks` adapter (the project), a
-- `media` helper, an `api` client, a `store` and a `ui`, so it can be tested outside REAPER.
--
-- Model: every track inside a "Reach folder" (a top-level folder track carrying a reach_owner mark) is
-- synced. For each track we remember what the server had when we last synced (base: rev, fingerprint,
-- parent, ordering key). A track is "locally changed" if its fingerprint/parent/key differ from base and
-- "remotely changed" if the server's rev is newer. Both -> conflict, which the user resolves.
local canon = require("reach.canon")
local keys = require("reach.keys")
local sha256 = require("reach.sha256")
local async = require("reach.async")
local fs = require("reach.fs")
local progress = require("reach.progress")
local cancel = require("reach.cancel")

local Engine = {}
Engine.__index = Engine

local engine = {}

local DEFAULT_SERVER = "http://localhost:8000"
local NOTES_PREFIX = "Reach join code: "

-- env: api, store, tracks, media, ui, new_guid (function)
function engine.new(env)
  return setmetatable({ api = env.api, store = env.store, tracks = env.tracks, media = env.media, ui = env.ui,
                        new_guid = env.new_guid, device_label = env.device_label or "REAPER" }, Engine)
end

local function fail(msg) error({ msg = msg, user = true }, 0) end
engine.fail = fail

---------------------------------------------------------------------------------------------------
-- Login / link
---------------------------------------------------------------------------------------------------

function Engine:server_url()
  local st = self.store.project_load()
  return (st and st.server) or self.store.cfg_get("server_url") or DEFAULT_SERVER
end

-- Device-style login: opens the browser for Google sign-in, then waits for approval.
function Engine:login()
  local d = self.api:device_start(self.device_label)
  -- Build the URL from the server we are actually talking to; don't trust the host the server reports
  -- (a misconfigured server would send us to localhost).
  local base = self.api:base()
  self.ui:log("Opening browser to sign in. If it doesn't open, go to " .. base .. "/device and enter code " ..
              d.user_code)
  self.ui:open_url(base .. "/device?user_code=" .. d.user_code)
  local deadline = async.clock() + d.expires_in
  while async.clock() < deadline do
    async.sleep(d.interval or 3)
    local token, why = self.api:device_poll(d.device_code)
    if token then
      self.store.cfg_set("token@" .. self.api:base(), token)
      local me = self.api:me()
      self.ui:log("Signed in as " .. me.display_name .. " (" .. me.email .. ")")
      return me
    elseif why ~= "authorization_pending" then
      fail(why == "access_denied" and "Sign-in was denied." or ("Sign-in failed: " .. tostring(why)))
    end
  end
  fail("Sign-in timed out.")
end

function Engine:has_token() return self.store.cfg_get("token@" .. self.api:base()) ~= nil end

function Engine:ensure_login()
  if not self:has_token() then self:login() end
end

local function new_state(server, project)
  return { server = server, project_id = project.id, name = project.name, join_code = project.join_code,
           seq = 0, base = {} }
end

-- Create the song on the server and link this project to it. Returns the join code.
function Engine:share(name)
  local existing = self.store.project_load()
  if existing and existing.project_id then fail("This project is already linked to a Reach song.") end
  local p = self.api:create_project(name)
  self.store.project_save(new_state(self:server_url(), p))
  self.store.update_notes(NOTES_PREFIX, p.join_code)
  return p.join_code
end

-- Link this (typically new, empty) project to someone else's song using its join code.
function Engine:join(code)
  local existing = self.store.project_load()
  if existing and existing.project_id then fail("This project is already linked to a Reach song.") end
  local p = self.api:join(code)
  self.store.project_save(new_state(self:server_url(), p))
  return p
end

-- Owner only: fetch the join code from the server, remember it, and write it into the project notes.
function Engine:show_join_code()
  local st = self.store.project_load()
  if not st or not st.project_id then fail("This project isn't linked to a Reach song.") end
  self:ensure_login()
  local p = self.api:project(st.project_id)
  if not p.join_code then fail("Only the song's owner can see the join code. Ask them for it.") end
  st.join_code = p.join_code
  self.store.project_save(st)
  self.store.update_notes(NOTES_PREFIX, p.join_code)
  return p.join_code
end

-- Share the song and immediately sync (which offers to move existing tracks into the new folder).
-- Returns join code, sync summary.
function Engine:share_and_sync(name)
  local code = self:share(name)
  self.ui:log("Song shared. Join code: " .. code)
  return code, self:sync()
end

-- Join a song in a brand-new project: validates the code first (so a typo doesn't create an empty
-- project), lets the UI create + save the new project, links it, and syncs. Returns song, sync summary.
function Engine:join_new(code)
  self:ensure_login()
  local p = self.api:join(code)
  if not self.ui:new_project(p.name) then
    fail("Join cancelled: the new project was not saved.")
  end
  self.store.project_save(new_state(self:server_url(), p))
  self.ui:log("Joined \"" .. p.name .. "\"")
  return p, self:sync()
end

-- All songs on the server that I belong to: { id, name, role, join_code (owners only), storage_bytes }.
-- Flags the one this project is linked to.
function Engine:list_songs()
  self:ensure_login()
  local songs = self.api:projects()
  local st = self.store.project_load()
  for _, song in ipairs(songs) do song.linked = st ~= nil and st.project_id == song.id end
  return songs
end

function Engine:deleted_tracks()
  local st = self.store.project_load()
  return self.api:tracks(st.project_id, "deleted")
end

function Engine:restore(guid, rev)
  local st = self.store.project_load()
  return self.api:restore(st.project_id, guid, rev)
end

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

-- Fingerprint form: cached media (Ogg or its WAV companion) collapses to the one canonical Ogg reference, and
-- the source type is normalised, so a track looks identical whether it points at the Ogg or at the WAV.
function Engine:canonical(chunk)
  local mapped = canon.map_files(chunk, function(path)
    local ref = self.media:ref_for_local(path)
    if ref then return ref, "VORBIS" end
  end)
  return canon.strip_volatile(mapped)
end

-- Server chunk -> chunk with local media paths. Uses the high-quality WAV where we have it, else the Ogg.
function Engine:localize(chunk)
  return canon.map_files(chunk, function(path)
    local sha = path:match("^reach%-media://(%x+)%.ogg$")
    if not sha then return nil end
    local hq = self.media:hq_path(sha)
    if fs.exists(hq) then return hq, "WAVE" end
    return self.media:path_for(sha), "VORBIS"
  end)
end

-- Run `fn(item, on_progress)` for each item (3 at a time) as one byte-measured phase. items: { size = bytes, ... }
function Engine:run_transfers(label, items, fn)
  local total = 0
  for _, it in ipairs(items) do total = total + (it.size or 0) end
  local tracker = self._tracker
  tracker:phase(label, { total_bytes = total > 0 and total or nil, items = #items })
  local jobs = {}
  for i, it in ipairs(items) do
    jobs[i] = function()
      local j = tracker:job(it.size)
      fn(it, j.update)
      j.finish()
    end
  end
  async.parallel(jobs, 3)
end

-- Download audio for these Ogg shas: the WAV companion where `variants` has one, else the Ogg itself.
-- Files we already have are skipped. Counts WAV downloads in summary.hq_downloaded.
function Engine:download_audio(pid, shas, variants, summary)
  local todo, blobs = {}, {}
  for _, sha in ipairs(shas) do
    local wav = variants[sha]
    local have = fs.exists(wav and self.media:hq_path(sha) or self.media:path_for(sha))
    if not have then
      todo[#todo + 1] = { sha = sha, wav = wav, blob = wav or sha }
      blobs[#blobs + 1] = wav or sha
    end
  end
  if #todo == 0 then return end
  -- Sizes only make the progress bar accurate; an older server without the endpoint must not break the sync.
  local ok, sizes = pcall(function() return self.api:blob_sizes(pid, blobs) end)
  if not ok then sizes = {} end
  for _, it in ipairs(todo) do it.size = sizes[it.blob] or 0 end
  local label = "Downloading audio"
  for _, it in ipairs(todo) do if it.wav then label = "Downloading audio (high quality where available)" break end end
  self:run_transfers(label, todo, function(it, on_progress)
    if it.wav then
      self.media:ensure_hq(it.sha, it.wav, on_progress)
      summary.hq_downloaded = summary.hq_downloaded + 1
    else
      self.media:ensure_local(it.sha, on_progress)
    end
  end)
end

-- HQ sync, local side: audio we already have as an Ogg may have a WAV companion on the server now. Fetch those
-- and point the tracks at them (fingerprints are unaffected, see canonical()).
function Engine:upgrade_local_media(pid, summary)
  local snap = self.tracks:snapshot()
  local order, seen = {}, {}
  for _, t in ipairs(snap) do
    for _, p in ipairs(canon.file_refs(t.chunk)) do
      local sha = fs.basename(fs.norm(p)):match("^(%x+)%.ogg$")
      if sha and #sha == 64 and not seen[sha] then seen[sha] = true order[#order + 1] = sha end
    end
  end
  if #order == 0 then return end
  local variants = self.api:hq_lookup(pid, order)
  local with_wav = {}
  for _, sha in ipairs(order) do if variants[sha] then with_wav[#with_wav + 1] = sha end end
  self:download_audio(pid, with_wav, variants, summary)
  local items = {}
  for _, t in ipairs(snap) do
    local touched = false
    local new = canon.map_files(t.chunk, function(path)
      local sha = fs.basename(fs.norm(path)):match("^(%x+)%.ogg$")
      if sha and #sha == 64 and fs.exists(self.media:hq_path(sha)) then
        touched = true
        return self.media:hq_path(sha), "WAVE"
      end
    end)
    if touched then items[#items + 1] = { guid = t.guid, chunk = new } end
  end
  if #items > 0 then
    self.tracks:begin_batch()
    local ok, err = pcall(function() self.tracks:apply(items) end)
    self.tracks:end_batch()
    if not ok then error(err, 0) end
  end
end

-- HQ sync, upload side: attach the lossless original (or a lossless WAV conversion) to the Oggs the server
-- already has for my tracks. Only uses Oggs we cached when the track was pushed; re-encoding would produce a
-- different Ogg that no track references.
function Engine:upload_hq_companions(pid, summary)
  local ui, api = self.ui, self.api
  local source_of, order = {}, {}
  for _, t in ipairs(self.tracks:snapshot()) do
    for _, p in ipairs(canon.file_refs(t.chunk)) do
      if not self.media:ref_for_local(p) and self.media.is_lossless(p) then
        local ogg = self.media:cached_ogg(p)
        if ogg and not source_of[ogg] then source_of[ogg] = p order[#order + 1] = ogg end
      end
    end
  end
  if #order == 0 then return end
  local absent = {}
  for _, h in ipairs(api:blobs_missing(pid, order)) do absent[h] = true end
  local have = api:hq_lookup(pid, order)
  local todo = {}
  for _, ogg in ipairs(order) do
    if not absent[ogg] and not have[ogg] then todo[#todo + 1] = ogg end
  end
  if #todo == 0 then return end

  ui:log("Preparing " .. #todo .. " high-quality file(s)...")
  self._tracker:phase("Preparing high-quality audio", { items = #todo })
  local jobs = {}
  for i, ogg in ipairs(todo) do
    jobs[i] = function()
      local wav, why = self.media:prepare_wav(source_of[ogg])
      self._tracker:item_done()
      return { ogg = ogg, wav = wav, why = why, path = source_of[ogg] }
    end
  end
  local links, wav_shas = {}, {}
  for _, res in ipairs(async.parallel(jobs, 2)) do
    if res.wav then
      links[#links + 1] = { ogg = res.ogg, wav = res.wav }
      wav_shas[#wav_shas + 1] = res.wav
    else
      summary.hq_failed[#summary.hq_failed + 1] = { name = fs.basename(res.path), reason = res.why }
    end
  end
  local missing = api:blobs_missing(pid, wav_shas)
  if #missing > 0 then
    ui:log("Uploading " .. #missing .. " high-quality file(s)...")
    local items = {}
    for i, h in ipairs(missing) do
      items[i] = { key = h, size = fs.size(self.media:upload_path(h, "wav")) or 0 }
    end
    self:run_transfers("Uploading high-quality audio", items, function(it, on_progress)
      api:put_blob(pid, it.key, self.media:upload_path(it.key, "wav"), on_progress)
    end)
  end
  for _, r in ipairs(api:hq_link(pid, links)) do
    if r.status == "linked" then summary.hq_uploaded = summary.hq_uploaded + 1 end
  end
end

local function pk(parent) return parent or "" end

-- Snapshot of synced tracks, with fingerprints and (re)assigned ordering keys.
-- `remote` (optional): feed tracks not yet applied; new local tracks are keyed after any remote siblings.
function Engine:scan(st, remote)
  local snap = self.tracks:snapshot()
  local map, order, groups = {}, {}, {}
  for _, t in ipairs(snap) do
    local cc = self:canonical(t.chunk)
    local l = { guid = t.guid, chunk = t.chunk, parent = t.parent, fp = sha256.hex(cc),
                name = canon.get_name(t.chunk) }
    map[t.guid] = l
    order[#order + 1] = l
    local k = pk(t.parent)
    groups[k] = groups[k] or {}
    table.insert(groups[k], t.guid)
  end
  for k, list in pairs(groups) do
    local known = {}
    for _, g in ipairs(list) do
      local b = st.base[g]
      if b and b.key and pk(b.parent) == k then known[g] = b.key end
    end
    local assigned = keys.assign(list, known)
    -- Brand-new tracks at the tail go after any sibling we know of (including unpulled remote ones).
    local floor = nil
    for _, r in ipairs(remote or {}) do
      if pk(r.parent_guid) == k and not map[r.guid] and r.position and (not floor or r.position > floor) then
        floor = r.position
      end
    end
    if floor then
      local last_known
      for i, g in ipairs(list) do if known[g] then last_known = i end end
      local n = 0
      for i = (last_known or 0) + 1, #list do
        n = n + 1
        assigned[list[i]] = math.max(assigned[list[i]], floor + n)
      end
    end
    for _, g in ipairs(list) do map[g].key = assigned[g] end
  end
  return map, order
end

local function locally_changed(l, b)
  return b == nil or l.fp ~= b.fp or pk(l.parent) ~= pk(b.parent) or l.key ~= b.key
end

-- Full desired order (DFS by parent, then key) as {guid=, parent=} entries.
local function build_order(nodes)
  local children, roots = {}, {}
  for g, n in pairs(nodes) do
    if n.parent and nodes[n.parent] then
      children[n.parent] = children[n.parent] or {}
      table.insert(children[n.parent], g)
    else
      roots[#roots + 1] = g
    end
  end
  local function sort(list)
    table.sort(list, function(a, b)
      if nodes[a].key ~= nodes[b].key then return nodes[a].key < nodes[b].key end
      return a < b
    end)
  end
  sort(roots)
  local out = {}
  local function visit(g, parent)
    out[#out + 1] = { guid = g, parent = parent }
    local ch = children[g]
    if ch then
      sort(ch)
      for _, c in ipairs(ch) do visit(c, g) end
    end
  end
  for _, g in ipairs(roots) do visit(g, nil) end
  return out
end

---------------------------------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------------------------------

-- opts.hq: also upload the lossless originals, and prefer them when downloading.
-- Shows a progress window (via the UI) for the duration.
function Engine:sync(opts)
  cancel.reset()
  self._tracker = progress.new(self.ui)
  local ok, result = pcall(self._sync, self, opts)
  self._tracker:finish()
  if not ok then error(result, 0) end
  return result
end

function Engine:_sync(opts)
  local hq = opts and opts.hq or false
  local st = self.store.project_load()
  if not st or not st.project_id then
    fail("This project isn't linked to a Reach song. Use 'Reach: Share song' or 'Reach: Join song' first.")
  end
  st.base, st.seq = st.base or {}, st.seq or 0
  local ui, api, tracks = self.ui, self.api, self.tracks
  local pid = st.project_id
  local summary = { pulled = 0, pushed = 0, removed_here = 0, deleted_remote = 0, conflicts = 0,
                    skipped = {}, conflicted = {}, hq_uploaded = 0, hq_downloaded = 0, hq_failed = {} }

  self:ensure_login()
  ui:log("Syncing with the server...")
  self._tracker:phase("Contacting the server")
  local me = api:me()
  local feed = api:changes(pid, st.seq)
  local locals = self:scan(st, feed.tracks)

  -- 1. Classify remote changes against local state ----------------------------------------------
  local apply, conflicts = {}, {}
  for _, r in ipairs(feed.tracks) do
    local b, l = st.base[r.guid], locals[r.guid]
    if b and r.rev <= b.rev then goto continue end -- already have it (e.g. our own push)
    do
      local lc = l and locally_changed(l, b)
      if r.deleted then
        if not l then
          st.base[r.guid] = nil
        elseif not lc then
          apply[#apply + 1] = { guid = r.guid, deleted = true }
          st.base[r.guid] = nil
          summary.deleted_remote = summary.deleted_remote + 1
        else
          conflicts[#conflicts + 1] = { kind = "remote_deleted", r = r, l = l }
        end
      elseif not l then
        if b then
          conflicts[#conflicts + 1] = { kind = "local_deleted", r = r }
        else
          apply[#apply + 1] = { guid = r.guid, r = r }
        end
      elseif not lc then
        apply[#apply + 1] = { guid = r.guid, r = r }
      else
        conflicts[#conflicts + 1] = { kind = "both_edited", r = r, l = l }
      end
    end
    ::continue::
  end

  -- 2. Resolve conflicts ------------------------------------------------------------------------
  local extra = {} -- local duplicates created by "keep both"
  for _, c in ipairs(conflicts) do
    local r, l = c.r, c.l
    local name = canon.get_name(r.chunk or "") ~= "" and canon.get_name(r.chunk) or (l and l.name) or r.guid
    local choice = ui:resolve_conflict({ kind = c.kind, name = name, owner = r.owner, author = r.author,
                                         guid = r.guid })
    if c.kind == "both_edited" then
      if choice == "mine" then
        st.base[r.guid] = { rev = r.rev, fp = "", parent = r.parent_guid, key = r.position }
      elseif choice == "both" then
        local newg = self.new_guid()
        local chunk = canon.clone_chunk(l.chunk, r.guid, newg, self.new_guid)
        chunk = canon.set_name(chunk, l.name .. " (conflict - " .. me.display_name .. ")")
        extra[#extra + 1] = { guid = newg, chunk = chunk, parent = l.parent, key = l.key + 0.0001 }
        apply[#apply + 1] = { guid = r.guid, r = r }
      else
        apply[#apply + 1] = { guid = r.guid, r = r }
      end
    elseif c.kind == "remote_deleted" then
      if choice == "theirs" then
        apply[#apply + 1] = { guid = r.guid, deleted = true }
        st.base[r.guid] = nil
        summary.deleted_remote = summary.deleted_remote + 1
      else -- keep my edited version; it will be pushed on top of the delete (an undelete)
        st.base[r.guid] = { rev = r.rev, fp = "", parent = r.parent_guid, key = r.position }
      end
    else -- local_deleted: I removed it, someone else changed it
      if choice == "theirs" then
        apply[#apply + 1] = { guid = r.guid, r = r }
      else
        st.base[r.guid].rev = r.rev -- my delete will be pushed on top of their edit
      end
    end
  end

  -- 3. Fetch media and apply remote changes ------------------------------------------------------
  local need, seen = {}, {}
  for _, a in ipairs(apply) do
    if a.r then
      for _, ref in ipairs(canon.file_refs(a.r.chunk)) do
        local sha = ref:match("^reach%-media://(%x+)%.ogg$")
        if sha and not seen[sha] then seen[sha] = true need[#need + 1] = sha end
      end
    end
  end
  if #need > 0 then
    -- HQ: take the WAV companion where there is one, the Ogg where there isn't. LQ: always the Ogg.
    local variants = hq and api:hq_lookup(pid, need) or {}
    self:download_audio(pid, need, variants, summary)
  end

  local items = {}
  for _, a in ipairs(apply) do
    if a.deleted then items[#items + 1] = { guid = a.guid, deleted = true }
    else items[#items + 1] = { guid = a.guid, chunk = self:localize(a.r.chunk) } end
    if a.r then summary.pulled = summary.pulled + 1 end
  end
  for _, e in ipairs(extra) do items[#items + 1] = { guid = e.guid, chunk = e.chunk } end

  if #items > 0 then
    local nodes = {}
    for g, l in pairs(locals) do nodes[g] = { parent = l.parent, key = l.key } end
    for _, a in ipairs(apply) do
      if a.deleted then nodes[a.guid] = nil
      else nodes[a.guid] = { parent = a.r.parent_guid, key = a.r.position } end
    end
    for _, e in ipairs(extra) do nodes[e.guid] = { parent = e.parent, key = e.key } end

    tracks:begin_batch()
    local ok, err = pcall(function()
      tracks:apply(items)
      tracks:arrange(build_order(nodes))
    end)
    tracks:end_batch()
    if not ok then error(err, 0) end

    for _, a in ipairs(apply) do
      if a.r then
        local now_chunk = tracks:chunk(a.guid)
        st.base[a.guid] = { rev = a.r.rev, fp = sha256.hex(self:canonical(now_chunk)),
                            parent = a.r.parent_guid, key = a.r.position, name = canon.get_name(now_chunk) }
      end
    end
    self.store.project_save(st) -- remember what we applied even if the push below fails
  end

  -- Make sure I have a Reach folder. Done *after* pulling: if the server already has one of mine (e.g. I
  -- synced from another project), it has just been applied and we must not create a second.
  local my_folder = tracks:ensure_folder(me)

  -- Tracks outside every Reach folder are not synced: tell the user (once per track unless they say "later").
  summary.adopted = 0
  if tracks.orphans then
    st.ignored = st.ignored or {}
    local fresh, names = {}, {}
    for _, o in ipairs(tracks:orphans()) do
      if not st.ignored[o.guid] then fresh[#fresh + 1] = o names[#names + 1] = o.name end
    end
    if #fresh > 0 then
      local choice = ui:confirm_orphans(names)
      if choice == "adopt" then
        local wanted = {}
        for _, o in ipairs(fresh) do wanted[o.guid] = true end
        summary.adopted = tracks:adopt(my_folder, wanted) or 0
      elseif choice == "ignore" then
        for _, o in ipairs(fresh) do st.ignored[o.guid] = true end
      end
    end
  end

  if hq then self:upgrade_local_media(pid, summary) end

  -- 4. Work out what to push ---------------------------------------------------------------------
  local ordered
  locals, ordered = self:scan(st)
  local changed, deletes = {}, {}
  for _, l in ipairs(ordered) do
    if locally_changed(l, st.base[l.guid]) then changed[#changed + 1] = l end
  end
  for g, b in pairs(st.base) do
    if not locals[g] then deletes[#deletes + 1] = { guid = g, rev = b.rev, name = b.name or g } end
  end
  table.sort(deletes, function(a, b) return a.guid < b.guid end)
  if #deletes > 0 then
    local names = {}
    for _, d in ipairs(deletes) do names[#names + 1] = d.name end
    if not ui:confirm_deletes(names) then deletes = {} end
  end

  -- 5. Prepare media for changed tracks ------------------------------------------------------------
  local paths, path_list = {}, {}
  for _, l in ipairs(changed) do
    for _, p in ipairs(canon.file_refs(l.chunk)) do
      if not self.media:ref_for_local(p) and not paths[p] then paths[p] = true path_list[#path_list + 1] = p end
    end
  end
  local sha_of, bad = {}, {}
  if #path_list > 0 then
    ui:log("Preparing " .. #path_list .. " audio file(s) (transcoding to Ogg)...")
    self._tracker:phase("Preparing audio (encoding to Ogg)", { items = #path_list })
    local jobs = {}
    for i, p in ipairs(path_list) do
      jobs[i] = function()
        local sha, why = self.media:prepare_upload(p)
        self._tracker:item_done()
        return { path = p, sha = sha, why = why }
      end
    end
    for _, res in ipairs(async.parallel(jobs, 2)) do
      if res.sha then sha_of[res.path] = res.sha else bad[res.path] = res.why end
    end
  end

  local push_items, push_by_guid, wanted = {}, {}, {}
  for _, l in ipairs(changed) do
    local problem
    for _, p in ipairs(canon.file_refs(l.chunk)) do
      if not self.media:ref_for_local(p) and bad[p] then problem = bad[p] break end
    end
    if problem then
      summary.skipped[#summary.skipped + 1] = { name = l.name, reason = problem }
    else
      local upload = canon.map_files(l.chunk, function(path)
        -- The server only ever sees the canonical Ogg reference (a pulled WAV companion maps back to its Ogg).
        local ref = self.media:ref_for_local(path)
        if ref then return ref, "VORBIS" end
        return "reach-media://" .. sha_of[path] .. ".ogg", "VORBIS"
      end)
      upload = canon.strip_volatile(upload)
      local bad_chunk = canon.problem(upload, l.guid)
      if bad_chunk then
        ui:log("Skipping \"" .. l.name .. "\": " .. bad_chunk)
        summary.skipped[#summary.skipped + 1] = { name = l.name, reason = bad_chunk }
        goto next_track
      end
      for _, ref in ipairs(canon.file_refs(upload)) do wanted[ref:match("^reach%-media://(%x+)%.ogg$")] = true end
      local b = st.base[l.guid]
      local it = { guid = l.guid, base_rev = b and b.rev or 0, op = "upsert", chunk = upload,
                   parent_guid = l.parent, position = l.key }
      push_items[#push_items + 1] = it
      push_by_guid[l.guid] = l
    end
    ::next_track::
  end
  for _, d in ipairs(deletes) do
    push_items[#push_items + 1] = { guid = d.guid, base_rev = d.rev, op = "delete" }
  end

  -- 6. Upload audio, then push ---------------------------------------------------------------------
  local function upload_blobs(hashes)
    local missing = api:blobs_missing(pid, hashes)
    if #missing == 0 then return end
    ui:log("Uploading " .. #missing .. " audio file(s)...")
    local items = {}
    for i, h in ipairs(missing) do items[i] = { key = h, size = fs.size(self.media:upload_path(h, "ogg")) or 0 } end
    self:run_transfers("Uploading audio", items, function(it, on_progress)
      api:put_blob(pid, it.key, self.media:upload_path(it.key, "ogg"), on_progress)
    end)
  end

  if #push_items > 0 then
    local hashes = {}
    for h in pairs(wanted) do hashes[#hashes + 1] = h end
    table.sort(hashes)
    upload_blobs(hashes)
    self._tracker:phase("Saving tracks to the server")
    local result, missing = api:push(pid, push_items)
    if not result then -- server lost track of a blob (e.g. purged): re-upload and retry once
      upload_blobs(missing)
      result, missing = api:push(pid, push_items)
      if not result then fail("The server is missing audio files that could not be uploaded.") end
    end
    for _, res in ipairs(result.results) do
      local l = push_by_guid[res.guid]
      if res.status == "conflict" then
        summary.conflicts = summary.conflicts + 1
        summary.conflicted[#summary.conflicted + 1] = (l and l.name) or res.guid
      elseif l then
        st.base[res.guid] = { rev = res.rev, fp = l.fp, parent = l.parent, key = l.key, name = l.name }
        if res.status == "accepted" then summary.pushed = summary.pushed + 1 end
      else -- a delete
        st.base[res.guid] = nil
        if res.status == "accepted" then summary.removed_here = summary.removed_here + 1 end
      end
    end
  end

  st.seq = feed.seq
  self.store.project_save(st)

  -- HQ: lossless companions go up after the tracks are safely pushed, so a failure here can't lose a push.
  if hq then
    local ok, err = pcall(function() self:upload_hq_companions(pid, summary) end)
    if not ok then
      if type(err) == "table" and err.cancelled then error(err, 0) end   -- a cancel is not a "problem"
      summary.hq_error = type(err) == "table" and (err.msg or "unknown error") or tostring(err)
      ui:log("High-quality upload problem: " .. summary.hq_error)
    end
  end
  self.store.save_project()
  return summary
end

-- Move the currently selected (unsynced) tracks into the user's own Reach folder.
function Engine:adopt_selected()
  local me = self.api:me()
  local folder = self.tracks:ensure_folder(me)
  return self.tracks:adopt_selected(folder)
end

return engine
