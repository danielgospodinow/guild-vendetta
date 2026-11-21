-- Throwaway probe for issue #1. Logs what the client exposes to addons:
-- combat log, death, death recap, hostile unit info, guild addon messages.
-- Every value is passed through S() so "secret" values are reported, not used.

local PREFIX = "GVNDPROBE"
local MAX_LOG = 1500
local f = CreateFrame("Frame")
local db
local buffer = {} -- recent CLEU events involving the player, for death analysis
local seen = {}   -- rate limit for unit logging
local cleuLogged = 0

local function secret(v) return issecretvalue and issecretvalue(v) or false end
local function S(v)
  if secret(v) then return "<SECRET>" end
  local ok, s = pcall(tostring, v)
  return ok and s or "<ERR>"
end
local function try(fn, ...)
  if type(fn) ~= "function" then return "<MISSING>" end
  local r = { pcall(fn, ...) }
  if not r[1] then return "<ERROR: " .. S(r[2]) .. ">" end
  local out = {}
  for i = 2, #r do out[#out + 1] = S(r[i]) end
  return table.concat(out, ", ")
end

local function log(fmt, ...)
  local line = date("%H:%M:%S ") .. string.format(fmt, ...)
  print("|cffff4040GVP|r " .. line)
  if db then
    table.insert(db.log, line)
    if #db.log > MAX_LOG then table.remove(db.log, 1) end
  end
end

local function has(path)
  local v = _G
  for k in path:gmatch("[^.]+") do
    if type(v) ~= "table" then return "no" end
    v = v[k]
  end
  return v ~= nil and type(v) or "no"
end

local function apiReport()
  log("== build: %s | project %s", try(GetBuildInfo), S(WOW_PROJECT_ID))
  for _, p in ipairs({
    "issecretvalue", "canaccessvalue", "CombatLogGetCurrentEventInfo", "C_CombatLog",
    "C_DeathRecap", "GetDeathRecapLink", "DeathRecap_HasEvents", "C_ChatInfo.SendAddonMessage",
    "C_ChatInfo.InChatMessagingLockdown", "GetPlayerInfoByGUID", "C_Map.GetBestMapForUnit",
    "C_Map.GetPlayerMapPosition", "C_NamePlate.GetNamePlateForUnit", "IsInInstance",
  }) do
    log("api %s = %s", p, has(p))
  end
  for _, ns in ipairs({ "C_CombatLog", "C_DeathRecap" }) do
    if type(_G[ns]) == "table" then
      local keys = {}
      for k in pairs(_G[ns]) do keys[#keys + 1] = k end
      table.sort(keys)
      log("%s: %s", ns, table.concat(keys, " "))
    end
  end
end

local function where()
  local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
  local x, y = pos and pos:GetXY()
  return string.format("zone=%s sub=%s map=%s xy=%s,%s instance=%s",
    S(GetRealZoneText()), S(GetSubZoneText()), S(map), S(x), S(y), try(IsInInstance))
end

-- Combat log -----------------------------------------------------------------

local function onCLEU()
  local ok, ts, sub, _, sGUID, sName, sFlags, _, dGUID, dName, dFlags = pcall(CombatLogGetCurrentEventInfo)
  if not ok then
    if cleuLogged < 5 then cleuLogged = cleuLogged + 1; log("CLEU info error: %s", S(ts)) end
    return
  end
  local me = UnitGUID("player")
  local touchesMe = secret(dGUID) or secret(sGUID) or dGUID == me or sGUID == me
  if not touchesMe then return end
  if cleuLogged < 80 then
    cleuLogged = cleuLogged + 1
    log("CLEU %s src=%s/%s flags=%s -> dst=%s/%s combat=%s",
      S(sub), S(sName), S(sGUID), S(sFlags), S(dName), S(dGUID), S(InCombatLockdown()))
  end
  if secret(dGUID) or dGUID == me then
    table.insert(buffer, { t = GetTime(), sub = sub, guid = sGUID, name = sName, flags = sFlags })
  end
  local now = GetTime()
  while buffer[1] and now - buffer[1].t > 60 do table.remove(buffer, 1) end
end

local function deathReport()
  log("== PLAYER_DEAD | %s | dueling? see DUEL events above", where())
  log("buffer: %d events in last 60s", #buffer)
  local done = {}
  for i = #buffer, 1, -1 do
    local e = buffer[i]
    local key = secret(e.guid) and ("secret" .. i) or S(e.guid)
    if not done[key] then
      done[key] = true
      log("  attacker %s guid=%s flags=%s last=%s %.1fs before death | info=%s",
        S(e.name), S(e.guid), S(e.flags), S(e.sub), GetTime() - e.t,
        secret(e.guid) and "n/a" or try(GetPlayerInfoByGUID, e.guid))
    end
  end
  C_Timer.After(2, function()
    if C_DeathRecap then
      for id = 1, 10 do
        local hasEv = try(C_DeathRecap.HasRecapEvents, id)
        if hasEv:find("true") then
          local evs = select(2, pcall(C_DeathRecap.GetRecapEvents, id))
          log("deathrecap id=%d has events: %s", id, S(type(evs) == "table" and #evs))
          if type(evs) == "table" then
            for j, ev in ipairs(evs) do
              if j > 8 then break end
              local parts = {}
              for k, v in pairs(ev) do parts[#parts + 1] = k .. "=" .. S(v) end
              log("  recap[%d] %s", j, table.concat(parts, " "))
            end
          end
        end
      end
    end
    log("== end death report")
  end)
end

-- Units ------------------------------------------------------------------------

local function unitReport(unit, why)
  if not UnitExists(unit) then return end
  local isPlayer = UnitIsPlayer(unit)
  if not secret(isPlayer) and not isPlayer then return end
  local guid = UnitGUID(unit)
  local key = secret(guid) and unit or guid
  if seen[key] and GetTime() - seen[key] < 30 then return end
  seen[key] = GetTime()
  log("%s %s: name=%s guid=%s lvl=%s class=%s race=%s faction=%s enemy=%s canAttack=%s combat=%s",
    why, unit, try(UnitName, unit), S(guid), try(UnitLevel, unit), try(UnitClass, unit),
    try(UnitRace, unit), try(UnitFactionGroup, unit), try(UnitIsEnemy, "player", unit),
    try(UnitCanAttack, "player", unit), S(InCombatLockdown()))
end

-- Addon comms ------------------------------------------------------------------

local lastPing = 0
local function ping(why)
  if GetTime() - lastPing < 20 then return end
  lastPing = GetTime()
  local msg = "ping " .. why .. " from " .. UnitName("player") .. " t=" .. time()
  log("send GUILD %q -> %s (combat=%s)", msg,
    try(C_ChatInfo.SendAddonMessage, PREFIX, msg, "GUILD"), S(InCombatLockdown()))
end

-- Events -----------------------------------------------------------------------

local handlers = {
  ADDON_LOADED = function(name)
    if name ~= "GuildVendettaProbe" then return end
    GuildVendettaProbeDB = GuildVendettaProbeDB or { log = {} }
    db = GuildVendettaProbeDB
    log("prefix registered: %s", try(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX))
    local ok, err = pcall(f.RegisterEvent, f, "COMBAT_LOG_EVENT_UNFILTERED")
    log("RegisterEvent(CLEU) ok=%s err=%s", S(ok), S(err))
  end,
  PLAYER_LOGIN = function() apiReport(); log("login | %s | guild=%s", where(), try(GetGuildInfo, "player")) end,
  COMBAT_LOG_EVENT_UNFILTERED = onCLEU,
  PLAYER_DEAD = deathReport,
  PLAYER_TARGET_CHANGED = function() unitReport("target", "target") end,
  UPDATE_MOUSEOVER_UNIT = function() unitReport("mouseover", "mouseover") end,
  NAME_PLATE_UNIT_ADDED = function(unit) unitReport(unit, "nameplate") end,
  PLAYER_REGEN_DISABLED = function() log("entered combat"); ping("in-combat") end,
  PLAYER_REGEN_ENABLED = function() log("left combat") end,
  DUEL_REQUESTED = function(who) log("DUEL_REQUESTED by %s", S(who)) end,
  DUEL_FINISHED = function() log("DUEL_FINISHED") end,
  CHAT_MSG_ADDON = function(prefix, text, channel, sender)
    if prefix ~= PREFIX then return end
    log("recv %s from %s: %q", S(channel), S(sender), S(text))
    if not secret(text) and text:find("^ping") and sender ~= UnitName("player") .. "-" .. GetNormalizedRealmName() then
      C_ChatInfo.SendAddonMessage(PREFIX, "pong to " .. S(sender), "GUILD")
    end
  end,
}
for ev in pairs(handlers) do
  if ev ~= "COMBAT_LOG_EVENT_UNFILTERED" then pcall(f.RegisterEvent, f, ev) end
end
f:SetScript("OnEvent", function(_, ev, ...)
  local ok, err = pcall(handlers[ev], ...)
  if not ok then log("handler %s error: %s", ev, S(err)) end
end)

SLASH_GVPROBE1 = "/gvp"
SlashCmdList.GVPROBE = function(arg)
  if arg == "ping" then lastPing = 0; ping("manual")
  elseif arg == "reset" then wipe(db.log); cleuLogged = 0; wipe(seen); log("log reset")
  elseif arg == "api" then apiReport()
  else log("status: %d log lines, %d buffered | %s | cmds: ping, api, reset", #db.log, #buffer, where())
  end
end
