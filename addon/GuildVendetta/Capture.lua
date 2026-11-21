-- Kill capture: keep the last 60s of hostile-player damage against us; on death, record a KILL.
-- Also feeds hostile players seen in the combat log to the proximity alerts.
local _, ns = ...

local WINDOW = 60
ns.levels = {} -- guid -> last seen level (filled by Alerts from target/mouseover/nameplates)
ns.health = { combatLog = "not registered", secret = 0 }

-- WoW: Forever can mark combat data as "secret"; secret values can't be compared or stored.
function ns.Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

local DAMAGE = {
  SWING_DAMAGE = true, RANGE_DAMAGE = true, SPELL_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true,
  DAMAGE_SHIELD = true, DAMAGE_SPLIT = true, SPELL_INSTAKILL = true,
}
local HOSTILE, PLAYER = COMBATLOG_OBJECT_REACTION_HOSTILE, COMBATLOG_OBJECT_TYPE_PLAYER
local CONTROL = COMBATLOG_OBJECT_CONTROL_PLAYER
local PETLIKE = bit.bor(COMBATLOG_OBJECT_TYPE_PET, COMBATLOG_OBJECT_TYPE_GUARDIAN)

local buffer = {} -- { t, guid, name }, oldest first
local owners = {} -- pet/guardian guid -> { guid, name } from SPELL_SUMMON
local dueling = false

local function hostilePlayer(flags)
  return bit.band(flags, HOSTILE) > 0 and bit.band(flags, PLAYER) > 0
end

local function onCombatLog()
  local _, sub, _, sGUID, sName, sFlags, _, dGUID, dName, dFlags = CombatLogGetCurrentEventInfo()
  if ns.Secret(sub) or ns.Secret(sGUID) or ns.Secret(sName) or ns.Secret(sFlags)
      or ns.Secret(dGUID) or ns.Secret(dName) or ns.Secret(dFlags) then
    ns.health.secret = ns.health.secret + 1
    return
  end
  if sName and hostilePlayer(sFlags) then ns.Seen(sName, sGUID) end
  if dName and hostilePlayer(dFlags) then ns.Seen(dName, dGUID) end

  if sub == "SPELL_SUMMON" and bit.band(sFlags, PLAYER) > 0 then
    owners[dGUID] = { guid = sGUID, name = sName }
    return
  end
  if not DAMAGE[sub] or dGUID ~= ns.playerGUID or dueling then return end
  if bit.band(sFlags, HOSTILE) == 0 or bit.band(sFlags, CONTROL) == 0 then return end
  if bit.band(sFlags, PLAYER) == 0 then
    -- ponytail: owners only known from summons we saw; unresolved pets are skipped
    local owner = bit.band(sFlags, PETLIKE) > 0 and owners[sGUID]
    if not owner then return end
    sGUID, sName = owner.guid, owner.name
  end
  buffer[#buffer + 1] = { t = GetTime(), guid = sGUID, name = sName }
  if #buffer > 500 then table.remove(buffer, 1) end
end

local function where()
  local map = C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  return map, x, y
end

local function onDeath()
  local now, list, seen = GetTime(), {}, {}
  for i = #buffer, 1, -1 do -- newest first, so list[1] dealt the last blow
    local b = buffer[i]
    if now - b.t > WINDOW then break end
    if not seen[b.guid] then
      seen[b.guid] = true
      list[#list + 1] = b
    end
  end
  wipe(buffer)
  -- World PvP only: battlegrounds, arenas and every other instance are ignored.
  if IsInInstance() or #list == 0 or not ns.guildKey then return end

  local enemies, names = {}, {}
  for i, b in ipairs(list) do
    local _, class, _, race, _, name, realm = GetPlayerInfoByGUID(b.guid)
    enemies[i] = {
      n = ns.FullName(name or b.name, realm), c = class or "", r = race or "",
      l = ns.levels[b.guid] or -1, kb = i == 1,
    }
    names[i] = enemies[i].n
  end
  local map, x, y = where()
  local e = {
    k = "K", t = GetServerTime(), vic = ns.FullName(UnitName("player")), vlvl = UnitLevel("player"),
    vclass = select(2, UnitClass("player")), zone = GetRealZoneText() or "", sub = GetSubZoneText() or "",
    map = map, x = x, y = y, en = enemies,
  }
  e.id = ns.KillId(e.vic, e.t)
  if ns.AddEvent(e) then
    ns.Broadcast(e)
    ns.Print("your death to %s was added to the vendetta list.", table.concat(names, ", "))
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_DEAD")
for _, ev in ipairs({ "DUEL_REQUESTED", "DUEL_INBOUNDS", "DUEL_OUTOFBOUNDS", "DUEL_FINISHED" }) do
  f:RegisterEvent(ev)
end
f:SetScript("OnEvent", function(_, ev)
  if ev == "COMBAT_LOG_EVENT_UNFILTERED" then
    onCombatLog()
  elseif ev == "PLAYER_DEAD" then
    onDeath()
  elseif ev == "PLAYER_LOGIN" then
    ns.playerGUID = UnitGUID("player")
    local ok, err = pcall(f.RegisterEvent, f, "COMBAT_LOG_EVENT_UNFILTERED")
    ns.health.combatLog = ok and "ok" or ("unavailable: " .. tostring(err))
    if type(StartDuel) == "function" then
      hooksecurefunc("StartDuel", function() dueling = true end)
    end
  elseif ev == "DUEL_FINISHED" then
    dueling = false
    wipe(buffer) -- duel damage must never count toward a later world-PvP death
  else
    dueling = true
  end
end)
