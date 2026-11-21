-- Kill capture: on death, read the death recap (WoW: Forever blocks the combat log for addons)
-- and record a KILL with every enemy player in it.
-- Vendetta capture: when a listed enemy we fought dies, record a VENDETTA credit for us.
-- Both are announced in guild chat.
local _, ns = ...

ns.levels = {} -- guid -> last seen level (filled by Alerts from target/mouseover/nameplates)
ns.health = { recap = "no death yet", secret = 0 }

-- WoW: Forever can mark data as "secret"; secret values can't be compared or stored.
function ns.Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE or 0x40
local duelEnd         -- { epoch, session }: recap hits from before a duel ended must not count
local lastRecapStamp  -- newest timestamp of the recap we already used, to skip stale recaps

-- Recap timestamps may be epoch or session seconds; compare against the matching clock.
local function afterDuel(ts)
  if not duelEnd or type(ts) ~= "number" then return true end
  return ts > (ts > 1e9 and duelEnd.epoch or duelEnd.session)
end

local function newest(evs)
  local t = 0
  for _, ev in ipairs(evs) do
    if type(ev.timestamp) == "number" and not ns.Secret(ev.timestamp) and ev.timestamp > t then t = ev.timestamp end
  end
  return t
end

local function where()
  local map = C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  return map, x, y
end

-- Most recent recap: the no-argument call, else the highest id that has events.
local function recapEvents()
  local ok, evs = pcall(C_DeathRecap.GetRecapEvents)
  if not (ok and type(evs) == "table" and #evs > 0) then
    evs = nil
    for id = 100, 1, -1 do
      if C_DeathRecap.HasRecapEvents(id) then
        evs = C_DeathRecap.GetRecapEvents(id)
        break
      end
    end
  end
  if type(evs) ~= "table" or #evs == 0 then return end
  local n = newest(evs)
  if n ~= 0 and n == lastRecapStamp then return end
  return evs
end

local function attackers(evs)
  -- newest first, so list[1] dealt the last blow (secret timestamps keep recap order)
  local sorted = {}
  for i, ev in ipairs(evs) do sorted[i] = ev end
  local function stamp(ev) return (type(ev.timestamp) == "number" and not ns.Secret(ev.timestamp)) and ev.timestamp or 0 end
  table.sort(sorted, function(a, b) return stamp(a) > stamp(b) end)
  evs = sorted
  local list, seen = {}, {}
  for _, ev in ipairs(evs) do
    local guid, name, flags, ts = ev.sourceGUID, ev.sourceName, ev.sourceFlags, ev.timestamp
    if ns.Secret(guid) or ns.Secret(name) or ns.Secret(flags) or ns.Secret(ts) then
      ns.health.secret = ns.health.secret + 1
    elseif type(guid) == "string" and guid:find("^Player%-") and guid ~= ns.playerGUID and not seen[guid]
        and (type(flags) ~= "number" or bit.band(flags, HOSTILE) > 0)
        and afterDuel(ts) then
      seen[guid] = true
      list[#list + 1] = { guid = guid, name = name }
    end
  end
  return list
end

-- Prefer whichever source carries both names.
local function fullName(recapName, name, second)
  local a, b = ns.Name(name, second), ns.Name(recapName)
  if a and a:find(" ", 1, true) then return a end
  return b or a or "Unknown"
end

local function onDeath()
  -- World PvP only: battlegrounds, arenas and every other instance are ignored.
  if IsInInstance() or not ns.guildKey then return end
  local evs = recapEvents()
  if not evs then
    ns.health.recap = "no recap events"
    return
  end
  lastRecapStamp = newest(evs)
  local list = attackers(evs)
  ns.health.recap = ns.health.secret > 0 and "secret values" or "ok"
  if #list == 0 then return end -- not a PvP death

  local enemies, names = {}, {}
  for i, b in ipairs(list) do
    local _, class, _, race, _, name, second = GetPlayerInfoByGUID(b.guid)
    enemies[i] = {
      g = b.guid, n = fullName(b.name, name, second), c = class or "", r = race or "",
      l = ns.levels[b.guid] or -1, kb = i == 1,
    }
    names[i] = enemies[i].n
  end
  local map, x, y = where()
  local e = {
    k = "K", t = GetServerTime(), vic = ns.Name(UnitName("player")), vlvl = UnitLevel("player"),
    vclass = select(2, UnitClass("player")), zone = GetRealZoneText() or "", sub = GetSubZoneText() or "",
    map = map, x = x, y = y, en = enemies,
  }
  e.id = ns.KillId(e.vic, e.t)
  if ns.AddEvent(e) then
    ns.Broadcast(e)
    ns.Print("your death to %s was added to the vendetta list.", table.concat(names, ", "))
    ns.Announce("%s was killed by %s in %s. Killer registered.", e.vic, table.concat(names, ", "), e.zone)
  end
end

-- Vendettas ---------------------------------------------------------------------
-- Without the combat log, "a guildie helped kill a listed enemy" is detected two ways:
--   1. the honorable-kill message, which the game sends to everyone who contributed to the kill;
--   2. fallback: we had the enemy targeted while in combat in the last 60s, then saw them dead.
-- ponytail: two signals until the live client shows which one Forever supports; drop the other then

local engaged = {}  -- enemy guid -> GetTime() we last had them targeted in combat
local credited = {} -- enemy key -> GetTime() of our last credit, so one kill credits once

function ns.Announce(fmt, ...)
  if not ns.settings.announce then return end
  pcall(C_ChatInfo.SendChatMessage or SendChatMessage, "[Vendetta] " .. string.format(fmt, ...), "GUILD")
end

function ns.Score(row) return row.count .. "-" .. row.ours end

local function credit(row)
  if IsInInstance() or not ns.guildKey then return end
  local now = GetTime()
  if credited[row.key] and now - credited[row.key] < ns.CLUSTER then return end
  credited[row.key] = now
  local me = ns.Name(UnitName("player"))
  local e = { k = "V", t = GetServerTime(), en = row.key, n = row.name, c = row.class or "", by = me,
    zone = GetRealZoneText() or "" }
  e.id = ns.VendettaId(e.en, me, e.t)
  if not ns.AddEvent(e) then return end
  ns.Broadcast(e)
  ns.Print("vendetta! you helped take down %s.", row.name)
  -- One announcement per kill: the guildie whose credit came first speaks, the rest stay quiet.
  C_Timer.After(1 + math.random() * 2, function()
    local r = ns.view.byKey[row.key]
    local kill = r and r.vendettas[1]
    if kill and kill.by[1] == me then
      ns.Announce("%s took down %s. Successful vendetta! (%s)", table.concat(kill.by, ", "), r.name, ns.Score(r))
    end
  end)
end

-- "%s dies, honorable kill Rank: %s (...)" -> Lua pattern capturing the first %s
local function toPattern(fmt)
  if type(fmt) ~= "string" then return end
  local p = fmt:gsub("[%%%(%)%.%+%-%*%?%[%]%^%$]", "%%%0"):gsub("%%%%s", "(.-)", 1):gsub("%%%%s", ".-"):gsub("%%%%d", "%%d+")
  return "^" .. p
end
local honorPatterns = {}
for _, g in ipairs({ "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK" }) do
  honorPatterns[#honorPatterns + 1] = toPattern(_G[g])
end
honorPatterns[#honorPatterns + 1] = "^(.-) dies, honorable kill"

-- The message may carry only the first name; accept it when it matches exactly one listed enemy.
local function findRow(name)
  name = ns.Name(name)
  if not name then return end
  if ns.view.byName[name] then return ns.view.byName[name] end
  local match, prefix = nil, "^" .. name:gsub("%p", "%%%0") .. " "
  for _, r in ipairs(ns.view.rows) do
    if r.name:find(prefix) then
      if match then return end
      match = r
    end
  end
  return match
end

local function onHonor(msg)
  if ns.Secret(msg) or type(msg) ~= "string" then return end
  for _, p in ipairs(honorPatterns) do
    local name = msg:match(p)
    if name then
      local row = findRow(name)
      if row then credit(row) end
      return
    end
  end
end

local function watch(unit)
  if not UnitExists(unit) then return end
  local guid, dead = UnitGUID(unit), UnitIsDead(unit)
  if ns.Secret(guid) or ns.Secret(dead) then return end
  local row = ns.view.byKey[guid]
  if not row then return end
  if dead then
    if engaged[guid] and GetTime() - engaged[guid] <= 60 then credit(row) end
  elseif unit == "target" and UnitAffectingCombat("player") then
    engaged[guid] = GetTime()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("DUEL_FINISHED")
f:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("UNIT_HEALTH")
f:SetScript("OnEvent", function(_, ev, arg)
  if ev == "CHAT_MSG_COMBAT_HONOR_GAIN" then
    onHonor(arg)
  elseif ev == "PLAYER_TARGET_CHANGED" or ev == "PLAYER_REGEN_DISABLED" then
    watch("target")
  elseif ev == "UNIT_HEALTH" then
    if arg == "target" or (type(arg) == "string" and arg:find("^nameplate")) then watch(arg) end
  elseif ev == "PLAYER_DEAD" then
    C_Timer.After(1, onDeath) -- give the client a moment to build the recap
  elseif ev == "PLAYER_LOGIN" then
    ns.playerGUID = UnitGUID("player")
  else
    duelEnd = { epoch = time(), session = GetTime() }
  end
end)
