-- Event log (KILL / REMOVE / VENDETTA), derived views, wire encoding, sync digests.
-- The pure functions here run outside WoW too (see tests/core_test.lua).
local _, ns = ...

ns.DEFAULTS = { flash = true, message = true, sound = true, announce = true, cooldown = 5, minimap = true, minimapAngle = 200 }
ns.EXPIRY = 14 * 86400   -- kills (and removals) older than this drop off the list
ns.CLUSTER = 60          -- vendetta credits for one enemy within this many seconds are one kill
ns.events = {}      -- current guild's log: id -> event
ns.view = { rows = {}, byKey = {}, byName = {}, revengers = {} }
ns.listeners = {}   -- called after the view is rebuilt
ns.onLoaded = {}    -- called once settings are loaded
ns.onGuild = {}     -- called when the guild log is ready (login or guild change)

-- Encoding -----------------------------------------------------------------
-- KILL:   K~t~victim~vlvl~vclass~zone~sub~map~x~y~enemy^enemy...   enemy = name,class,race,level,kb,guid
-- REMOVE: R~t~enemyKey~by
-- VENDETTA: V~t~enemyKey~enemyName~enemyClass~by~zone   (a guildie helped kill a listed enemy)
-- Enemies are identified by GUID (names are ambiguous on Forever); name is the fallback key.
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
function ns.EnemyKey(x) return (x.g and x.g ~= "") and x.g or x.n end
function ns.RemoveId(enemy, t) return "R:" .. enemy .. ":" .. t end
function ns.VendettaId(enemy, by, t) return "V:" .. enemy .. ":" .. by .. ":" .. t end

-- Vendettas are kept forever (they feed the revengers leaderboard).
function ns.Expired(e, now) return e.k ~= "V" and e.t < now - ns.EXPIRY end

function ns.Encode(e)
  if e.k == "R" then
    return table.concat({ "R", e.t, clean(e.en, 80), clean(e.by) }, "~")
  elseif e.k == "V" then
    return table.concat({ "V", e.t, clean(e.en, 80), clean(e.n), clean(e.c, 16), clean(e.by), clean(e.zone) }, "~")
  end
  local en = {}
  for i, x in ipairs(e.en) do
    en[i] = table.concat({ clean(x.n), clean(x.c, 16), clean(x.r, 24), x.l or -1, x.kb and 1 or 0, clean(x.g, 40) }, ",")
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
  if f[1] == "V" and #f == 7 and f[3] ~= "" and f[6] ~= "" then
    return { k = "V", t = t, en = f[3], n = f[4], c = f[5], by = f[6], zone = f[7], id = ns.VendettaId(f[3], f[6], t) }
  end
  if f[1] ~= "K" or #f ~= 11 or f[3] == "" then return end
  local e = {
    k = "K", t = t, vic = f[3], vlvl = num(f[4], -1, 200) or -1, vclass = f[5], zone = f[6], sub = f[7],
    map = num(f[8], 0, 1e7), x = num(f[9], 0, 1), y = num(f[10], 0, 1), en = {},
  }
  for _, part in ipairs(split(f[11], "^")) do
    local p = split(part, ",")
    if (#p ~= 5 and #p ~= 6) or p[1] == "" then return end
    e.en[#e.en + 1] = { n = p[1], c = p[2], r = p[3], l = num(p[4], -1, 200) or -1, kb = p[5] == "1", g = p[6] or "" }
  end
  if #e.en == 0 or #e.en > 40 then return end
  e.id = ns.KillId(e.vic, t)
  return e
end

-- View -----------------------------------------------------------------------
-- An enemy is listed if they have a KILL in the last 14 days that is newer than their latest REMOVE.
-- Score: theirs = those kills; ours = vendetta kills on them since the latest REMOVE, where credits
-- from several guildies within CLUSTER seconds count as one kill. Rows are ranked by theirs.
-- Revengers: every vendetta credit ever, per guildie (not reset by removals or expiry).

local function newest(a, b) return a.t > b.t end

function ns.BuildView(events, now)
  local cutoff = now - ns.EXPIRY
  local removed, strikes, revByName, revengers = {}, {}, {}, {}
  for _, e in pairs(events) do
    if e.k == "R" and e.t > (removed[e.en] or 0) then removed[e.en] = e.t end
  end
  local byKey, byName, rows = {}, {}, {}
  for _, e in pairs(events) do
    if e.k == "K" and e.t > cutoff then
      for _, x in ipairs(e.en) do
        local key = ns.EnemyKey(x)
        if e.t > (removed[key] or 0) then
          local row = byKey[key]
          if not row then
            row = { key = key, name = x.n, kills = {}, vendettas = {}, last = 0, level = -1, levelT = 0, ours = 0 }
            byKey[key], byName[x.n] = row, row
            rows[#rows + 1] = row
          end
          row.kills[#row.kills + 1] = e
          row.class, row.race = row.class or x.c, row.race or x.r
          if e.t > row.last then row.last = e.t end
          if x.l ~= -1 and e.t >= row.levelT then row.level, row.levelT = x.l, e.t end
        end
      end
    elseif e.k == "V" then
      strikes[e.en] = strikes[e.en] or {}
      table.insert(strikes[e.en], e)
      local r = revByName[e.by]
      if not r then
        r = { name = e.by, count = 0, last = 0 }
        revByName[e.by] = r
        revengers[#revengers + 1] = r
      end
      r.count = r.count + 1
      if e.t > r.last then r.last, r.lastEnemy, r.lastClass = e.t, e.n, e.c end
    end
  end
  for key, list in pairs(strikes) do
    local row = byKey[key]
    if row then
      table.sort(list, function(a, b) return a.t < b.t end)
      local cluster
      for _, v in ipairs(list) do
        if v.t > (removed[key] or 0) then
          if cluster and v.t - cluster.t <= ns.CLUSTER then
            if not cluster.seen[v.by] then
              cluster.seen[v.by] = true
              table.insert(cluster.by, v.by)
            end
          else
            cluster = { t = v.t, zone = v.zone, by = { v.by }, seen = { [v.by] = true } }
            table.insert(row.vendettas, cluster)
          end
        end
      end
      row.ours = #row.vendettas
      table.sort(row.vendettas, newest)
    end
  end
  for _, row in ipairs(rows) do
    row.count = #row.kills -- theirs
    table.sort(row.kills, newest)
    row.victims, row.lastVictim = {}, row.kills[1]
    local seen = {}
    for _, k in ipairs(row.kills) do
      if not seen[k.vic] then
        seen[k.vic] = true
        table.insert(row.victims, k)
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.last ~= b.last then return a.last > b.last end
    return a.name < b.name
  end)
  for i, row in ipairs(rows) do row.rank = i end
  table.sort(revengers, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    if a.last ~= b.last then return a.last > b.last end
    return a.name < b.name
  end)
  for i, r in ipairs(revengers) do r.rank = i end
  return { rows = rows, byKey = byKey, byName = byName, revengers = revengers }
end

-- Sync digests ------------------------------------------------------------------
-- Events are grouped into units: one per day for the last RECENT_DAYS days, and one per 30-day
-- block before that (old days only hold vendettas, which never expire, so the digest stays small
-- however old the guild is). A unit is a string: "20778" (a day) or "m692" (a 30-day block).
-- A unit's summary is count + hash of its sorted event ids.

ns.RECENT_DAYS = 15

function ns.Hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return h
end
local hash = ns.Hash

function ns.UnitOf(t, now)
  local d = math.floor(t / 86400)
  if d >= math.floor(now / 86400) - ns.RECENT_DAYS then return tostring(d) end
  return "m" .. math.floor(d / 30)
end

-- First day a unit covers; orders units by age.
function ns.UnitStart(u)
  local m = u:match("^m(%d+)$")
  return m and tonumber(m) * 30 or tonumber(u)
end
local function newestFirst(a, b) return ns.UnitStart(a) > ns.UnitStart(b) end

function ns.Buckets(events, now)
  local ids = {}
  for id, e in pairs(events) do
    local u = ns.UnitOf(e.t, now)
    ids[u] = ids[u] or {}
    table.insert(ids[u], id)
  end
  local out = {}
  for u, list in pairs(ids) do
    table.sort(list)
    out[u] = { count = #list, hash = hash(table.concat(list, ";")) }
  end
  return out
end

-- Oldest unit first, so a digest cut to fit keeps its newest end.
function ns.EncodeDigest(buckets)
  local units = {}
  for u in pairs(buckets) do units[#units + 1] = u end
  table.sort(units, function(a, b) return newestFirst(b, a) end)
  local parts = {}
  for i, u in ipairs(units) do parts[i] = u .. ":" .. buckets[u].count .. ":" .. buckets[u].hash end
  return table.concat(parts, ";")
end

function ns.DecodeDigest(s)
  local out = {}
  for u, c, h in s:gmatch("(m?%d+):(%d+):(%d+)") do out[u] = { count = tonumber(c), hash = tonumber(h) } end
  return out
end

-- Compares unit summaries: units only we have, units only they have, units both have but differ.
-- Each list is newest first.
function ns.DiffDigest(mine, theirs)
  local mineOnly, theirsOnly, differ = {}, {}, {}
  for u, b in pairs(mine) do
    local o = theirs[u]
    if not o then mineOnly[#mineOnly + 1] = u elseif o.hash ~= b.hash then differ[#differ + 1] = u end
  end
  for u in pairs(theirs) do
    if not mine[u] then theirsOnly[#theirsOnly + 1] = u end
  end
  table.sort(mineOnly, newestFirst); table.sort(theirsOnly, newestFirst); table.sort(differ, newestFirst)
  return mineOnly, theirsOnly, differ
end

-- Id-sets: for units both sides have but disagree on, each side lists a short fingerprint of every
-- event id in the unit, so the other side sends only what's missing. One message carries the
-- id-sets of all such units: "20778:1544699368:lnjrx8,1hj0ek|m692:0:" (an empty set means
-- "send me everything in this unit").
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
function ns.ShortId(id)
  local n, out = hash(id) % 2176782336, "" -- 36^6
  for _ = 1, 6 do
    local r = n % 36
    out = B36:sub(r + 1, r + 1) .. out
    n = math.floor(n / 36)
  end
  return out
end

function ns.UnitEvents(events, u, now)
  local list = {}
  for _, e in pairs(events) do
    if ns.UnitOf(e.t, now) == u then list[#list + 1] = e end
  end
  table.sort(list, function(a, b) return a.t > b.t end)
  return list
end

function ns.EncodeIdSets(units, events, now)
  local buckets, out = ns.Buckets(events, now), {}
  for i, u in ipairs(units) do
    local ids = {}
    for j, e in ipairs(ns.UnitEvents(events, u, now)) do ids[j] = ns.ShortId(e.id) end
    out[i] = u .. ":" .. (buckets[u] and buckets[u].hash or 0) .. ":" .. table.concat(ids, ",")
  end
  return table.concat(out, "|")
end

-- Returns a list of { unit, hash, set }, or nil if any part is malformed.
function ns.DecodeIdSets(s)
  local out = {}
  for part in (s .. "|"):gmatch("([^|]*)|") do
    local u, h, rest = part:match("^(m?%d+):(%d+):([%w,]*)$")
    if not u then return end
    local set = {}
    for id in rest:gmatch("%w+") do set[id] = true end
    out[#out + 1] = { unit = u, hash = tonumber(h), set = set }
  end
  if #out > 0 then return out end
end

-- Runtime (WoW only) -----------------------------------------------------------

local pending
function ns.Changed()
  if pending then return end
  pending = true
  C_Timer.After(0.3, function()
    pending = false
    ns.view = ns.BuildView(ns.events, GetServerTime())
    for _, fn in ipairs(ns.listeners) do fn() end
  end)
end

-- Stores an event; returns true if it was new.
function ns.AddEvent(e)
  if not e or not e.id or ns.events[e.id] or ns.Expired(e, GetServerTime()) then return false end
  ns.events[e.id] = e
  ns.Changed()
  return true
end

-- WoW: Forever characters have two names (e.g. "Todor Zhivkoff"); APIs return them as
-- (first, second) or as "First-Second". Everything the addon stores and shows uses "First Second".
function ns.Name(first, second)
  if type(first) ~= "string" or first == "" then return end
  first = first:gsub("%-", " ")
  if type(second) == "string" and second ~= "" and not first:find(" ", 1, true) then
    return first .. " " .. second
  end
  return first
end

function ns.Print(fmt, ...)
  print("|cffff4040Guild Vendetta:|r " .. string.format(fmt, ...))
end

-- Each guild gets its own log, so alts in other guilds don't mix lists.
function ns.LoadGuild()
  local guild = GetGuildInfo("player")
  if not guild then return false end
  local key = guild .. "-" .. (GetNormalizedRealmName() or "")
  if ns.guildKey == key then return true end
  ns.guildKey = key
  GuildVendettaDB.guilds[key] = GuildVendettaDB.guilds[key] or { events = {} }
  ns.guildDB = GuildVendettaDB.guilds[key]
  ns.events = ns.guildDB.events
  local now = GetServerTime()
  for id, e in pairs(ns.events) do
    if ns.Expired(e, now) then ns.events[id] = nil end
  end
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
