-- Throwaway probe for issue #1. Logs what the client exposes to addons:
-- death recap, hostile unit info, name APIs, guild addon messages.
-- Round 1 showed the combat log is blocked for addons on Forever, so it's no longer touched.
-- Every value is passed through S() so "secret" values are reported, not used.

local PREFIX = "GVNDPROBE"
local MAX_LOG = 1500
local f = CreateFrame("Frame")
local db
local seen = {} -- rate limit for unit logging

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

local function where()
  local map = C_Map.GetBestMapForUnit("player")
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  return string.format("zone=%s sub=%s map=%s xy=%s,%s instance=%s",
    S(GetRealZoneText()), S(GetSubZoneText()), S(map), S(x), S(y), try(IsInInstance))
end

-- Death recap -------------------------------------------------------------------

local function dumpRecap(label, evs)
  log("deathrecap %s: %s events", label, S(type(evs) == "table" and #evs or evs))
  if type(evs) ~= "table" then return end
  for j, ev in ipairs(evs) do
    if j > 10 then break end
    local parts = {}
    for k, v in pairs(ev) do parts[#parts + 1] = k .. "=" .. S(v) end
    table.sort(parts)
    log("  recap[%d] %s", j, table.concat(parts, " "))
  end
end

local function deathReport()
  log("== PLAYER_DEAD | %s | time=%s GetTime=%s", where(), S(time()), S(GetTime()))
  C_Timer.After(1, function()
    local ok, evs = pcall(C_DeathRecap.GetRecapEvents)
    dumpRecap("GetRecapEvents()", ok and evs or ("<ERROR " .. S(evs) .. ">"))
    for id = 1, 100 do
      local okh, has = pcall(C_DeathRecap.HasRecapEvents, id)
      if okh and has == true then
        log("deathrecap id=%d link=%s", id, try(C_DeathRecap.GetRecapLink, id))
        dumpRecap("id " .. id, select(2, pcall(C_DeathRecap.GetRecapEvents, id)))
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
  end,
  PLAYER_LOGIN = function()
    log("== build: %s | project %s", try(GetBuildInfo), S(WOW_PROJECT_ID))
    log("login | %s | guild=%s", where(), try(GetGuildInfo, "player"))
    log("names: UnitName=%s | UnitFullName=%s | GetUnitName=%s | realm=%s | normRealm=%s | guid=%s",
      try(UnitName, "player"), try(UnitFullName, "player"), try(GetUnitName, "player", true),
      try(GetRealmName), try(GetNormalizedRealmName), S(UnitGUID("player")))
  end,
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
    if not secret(text) and text:find("^ping") and not text:find("from " .. UnitName("player") .. " ", 1, true) then
      C_ChatInfo.SendAddonMessage(PREFIX, "pong to " .. S(sender), "GUILD")
    end
  end,
}
for ev in pairs(handlers) do pcall(f.RegisterEvent, f, ev) end
f:SetScript("OnEvent", function(_, ev, ...)
  local ok, err = pcall(handlers[ev], ...)
  if not ok then log("handler %s error: %s", ev, S(err)) end
end)

SLASH_GVPROBE1 = "/gvp"
SlashCmdList.GVPROBE = function(arg)
  if arg == "ping" then lastPing = 0; ping("manual")
  elseif arg == "reset" then wipe(db.log); wipe(seen); log("log reset")
  else log("status: %d log lines | %s | cmds: ping, reset", #db.log, where())
  end
end
