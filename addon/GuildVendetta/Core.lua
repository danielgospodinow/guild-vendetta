-- Event log (KILL / REMOVE), derived vendetta view, wire encoding, sync digests.
-- The pure functions here run outside WoW too (see tests/core_test.lua).
local _, ns = ...

ns.DEFAULTS = { flash = true, message = true, sound = true, cooldown = 5, minimap = true, minimapAngle = 200 }
ns.events = {}      -- current guild's log: id -> event
ns.view = { rows = {}, byName = {} }
ns.listeners = {}   -- called after the view is rebuilt
ns.onLoaded = {}    -- called once settings are loaded
ns.onGuild = {}     -- called when the guild log is ready (login or guild change)

-- Encoding -----------------------------------------------------------------
-- KILL:   K~t~victim~vlvl~vclass~zone~sub~map~x~y~enemy^enemy...   enemy = name,class,race,level,kb
-- REMOVE: R~t~enemy~by
-- Ids are derived from content, never sent, so a peer can't forge a mismatching id.

local function clean(s, max)
  s = tostring(s or ""):gsub("[~^,|\n]", "")
  return s:sub(1, max or 64)
end

local function num(s, lo, hi)
  local n = tonumber(s)
  if n and n >= lo and n <= hi then return n end
end

function ns.KillId(victim, t) return "K:" .. victim .. ":" .. t end
function ns.RemoveId(enemy, t) return "R:" .. enemy .. ":" .. t end

function ns.Encode(e)
  if e.k == "R" then
    return table.concat({ "R", e.t, clean(e.en), clean(e.by) }, "~")
  end
  local en = {}
  for i, x in ipairs(e.en) do
    en[i] = table.concat({ clean(x.n), clean(x.c, 16), clean(x.r, 24), x.l or -1, x.kb and 1 or 0 }, ",")
  end
  return table.concat({ "K", e.t, clean(e.vic), e.vlvl or -1, clean(e.vclass, 16), clean(e.zone),
    clean(e.sub), e.map or "", e.x and string.format("%.3f", e.x) or "",
    e.y and string.format("%.3f", e.y) or "", table.concat(en, "^") }, "~")
end

local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
  return out
end

-- Returns an event table or nil for anything malformed (input comes from other players).
function ns.Decode(s)
  if type(s) ~= "string" or #s > 4000 then return end
  local f = split(s, "~")
  local t = num(f[2], 1e9, 1e11)
  if not t then return end
  if f[1] == "R" and #f == 4 and f[3] ~= "" then
    return { k = "R", t = t, en = f[3], by = f[4], id = ns.RemoveId(f[3], t) }
  end
  if f[1] ~= "K" or #f ~= 11 or f[3] == "" then return end
  local e = {
    k = "K", t = t, vic = f[3], vlvl = num(f[4], -1, 200) or -1, vclass = f[5], zone = f[6], sub = f[7],
    map = num(f[8], 0, 1e7), x = num(f[9], 0, 1), y = num(f[10], 0, 1), en = {},
  }
  for _, part in ipairs(split(f[11], "^")) do
    local p = split(part, ",")
    if #p ~= 5 or p[1] == "" then return end
    e.en[#e.en + 1] = { n = p[1], c = p[2], r = p[3], l = num(p[4], -1, 200) or -1, kb = p[5] == "1" }
  end
  if #e.en == 0 or #e.en > 40 then return end
  e.id = ns.KillId(e.vic, t)
  return e
end

-- View -----------------------------------------------------------------------
-- An enemy is listed if they have a KILL newer than their latest REMOVE.
-- Rows are ranked by kill count, ties by most recent kill.

function ns.BuildView(events)
  local removed = {}
  for _, e in pairs(events) do
    if e.k == "R" and e.t > (removed[e.en] or 0) then removed[e.en] = e.t end
  end
  local byName, rows = {}, {}
  for _, e in pairs(events) do
    if e.k == "K" then
      for _, x in ipairs(e.en) do
        if e.t > (removed[x.n] or 0) then
          local row = byName[x.n]
          if not row then
            row = { name = x.n, kills = {}, last = 0, level = -1, levelT = 0 }
            byName[x.n] = row
            rows[#rows + 1] = row
          end
          row.kills[#row.kills + 1] = e
          row.class, row.race = row.class or x.c, row.race or x.r
          if e.t > row.last then row.last = e.t end
          if x.l ~= -1 and e.t >= row.levelT then row.level, row.levelT = x.l, e.t end
        end
      end
    end
  end
  for _, row in ipairs(rows) do
    row.count = #row.kills
    table.sort(row.kills, function(a, b) return a.t > b.t end)
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.last ~= b.last then return a.last > b.last end
    return a.name < b.name
  end)
  for i, row in ipairs(rows) do row.rank = i end
  return { rows = rows, byName = byName }
end

-- Sync digests ------------------------------------------------------------------
-- Events are bucketed by day; a bucket's summary is count + hash of its sorted ids.

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end

function ns.Buckets(events)
  local ids = {}
  for id, e in pairs(events) do
    local d = math.floor(e.t / 86400)
    ids[d] = ids[d] or {}
    table.insert(ids[d], id)
  end
  local out = {}
  for d, list in pairs(ids) do
    table.sort(list)
    out[d] = { count = #list, hash = hash(table.concat(list, ";")) }
  end
  return out
end

function ns.EncodeDigest(buckets)
  local parts = {}
  for d, b in pairs(buckets) do parts[#parts + 1] = d .. ":" .. b.count .. ":" .. b.hash end
  table.sort(parts)
  return table.concat(parts, ";")
end

function ns.DecodeDigest(s)
  local out = {}
  for d, c, h in s:gmatch("(%d+):(%d+):(%d+)") do out[tonumber(d)] = { count = tonumber(c), hash = tonumber(h) } end
  return out
end

-- Days where we hold events the peer may lack, and whether the peer holds days we may lack.
function ns.DiffDigest(mine, theirs)
  local send, theyHaveMore = {}, false
  for d, b in pairs(mine) do
    local o = theirs[d]
    if not o or o.hash ~= b.hash then send[#send + 1] = d end
  end
  for d, o in pairs(theirs) do
    local b = mine[d]
    if not b or b.hash ~= o.hash then theyHaveMore = true end
  end
  table.sort(send, function(a, b) return a > b end) -- newest days first
  return send, theyHaveMore
end

-- Runtime (WoW only) -----------------------------------------------------------

local pending
function ns.Changed()
  if pending then return end
  pending = true
  C_Timer.After(0.3, function()
    pending = false
    ns.view = ns.BuildView(ns.events)
    for _, fn in ipairs(ns.listeners) do fn() end
  end)
end

-- Stores an event; returns true if it was new.
function ns.AddEvent(e)
  if not e or not e.id or ns.events[e.id] then return false end
  ns.events[e.id] = e
  ns.Changed()
  return true
end

function ns.FullName(name, realm)
  if not name then return end
  if realm and realm ~= "" then return name .. "-" .. realm:gsub("%s", "") end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. GetNormalizedRealmName()
end

function ns.Print(fmt, ...)
  print("|cffff4040Guild Vendetta:|r " .. string.format(fmt, ...))
end

-- Each guild gets its own log, so alts in other guilds don't mix lists.
function ns.LoadGuild()
  local guild = GetGuildInfo("player")
  if not guild then return false end
  local key = guild .. "-" .. GetNormalizedRealmName()
  if ns.guildKey == key then return true end
  ns.guildKey = key
  GuildVendettaDB.guilds[key] = GuildVendettaDB.guilds[key] or { events = {} }
  ns.guildDB = GuildVendettaDB.guilds[key]
  ns.events = ns.guildDB.events
  ns.Changed()
  for _, fn in ipairs(ns.onGuild) do fn() end
  return true
end

local f = CreateFrame and CreateFrame("Frame")
if f then
  f:RegisterEvent("ADDON_LOADED")
  f:RegisterEvent("PLAYER_LOGIN")
  f:RegisterEvent("PLAYER_GUILD_UPDATE")
  f:RegisterEvent("GUILD_ROSTER_UPDATE")
  f:SetScript("OnEvent", function(_, ev, arg)
    if ev == "ADDON_LOADED" and arg == "GuildVendetta" then
      GuildVendettaDB = GuildVendettaDB or {}
      GuildVendettaDB.guilds = GuildVendettaDB.guilds or {}
      GuildVendettaDB.settings = GuildVendettaDB.settings or {}
      for k, v in pairs(ns.DEFAULTS) do
        if GuildVendettaDB.settings[k] == nil then GuildVendettaDB.settings[k] = v end
      end
      ns.settings = GuildVendettaDB.settings
      for _, fn in ipairs(ns.onLoaded) do fn() end
    elseif ev ~= "ADDON_LOADED" and ns.settings then
      ns.LoadGuild()
    end
  end)
end
