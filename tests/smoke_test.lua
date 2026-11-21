-- Run: luajit tests/smoke_test.lua   (from the repo root; needs LuaJIT for setfenv + bit)
-- Two/three "clients" with a stubbed WoW API: death -> live sync -> removal -> login catch-up -> alert.
-- simulates a world-PvP death on client A and checks client B receives it.
local ROOT = arg[1] or "addon/GuildVendetta"
local FILES = { "Core.lua", "Capture.lua", "Sync.lua", "Alerts.lua", "UI.lua" }
local wire = {} -- addon messages "on the GUILD channel"
local now = 1000

local function mock()
  local m = {}
  return setmetatable(m, {
    __index = function(t, k) local f = mock(); rawset(t, k, f); return f end,
    __call = function() return mock() end,
  })
end

local function client(name)
  local frames, timers, printed = {}, {}, {}
  local env = setmetatable({}, { __index = _G })
  env._G = env
  env.print = function(s) printed[#printed + 1] = s end
  env.bit = require("bit")
  env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  env.tinsert = table.insert
  env.date = os.date
  env.time = function() return 1763700000 + now end
  env.GetServerTime = env.time
  env.GetTime = function() return now end
  env.COMBATLOG_OBJECT_REACTION_HOSTILE = 0x40
  env.COMBATLOG_OBJECT_TYPE_PLAYER = 0x400
  env.COMBATLOG_OBJECT_CONTROL_PLAYER = 0x100
  env.COMBATLOG_OBJECT_TYPE_PET = 0x1000
  env.COMBATLOG_OBJECT_TYPE_GUARDIAN = 0x2000
  env.RAID_CLASS_COLORS = { ROGUE = { colorStr = "fffff569" } }
  env.LOCALIZED_CLASS_NAMES_MALE = { ROGUE = "Rogue" }
  env.ChatTypeInfo = {}
  env.SOUNDKIT = {}
  env.StaticPopupDialogs = {}
  env.UISpecialFrames = {}
  env.SlashCmdList = {}
  env.Enum = { SendAddonMessageResult = { AddonMessageThrottle = 3, ChannelThrottle = 8 } }
  env.GetNormalizedRealmName = function() return "Mirage" end
  env.GetGuildInfo = function() return "Horde Hunters" end
  env.UnitName = function(u) if u == "player" then return name end end
  env.UnitGUID = function(u) if u == "player" then return "Player-1-" .. name end end
  env.UnitLevel = function() return 52 end
  env.UnitClass = function() return "Warrior", "WARRIOR" end
  env.IsInInstance = function() return false end
  env.GetRealZoneText = function() return "Stranglethorn Vale" end
  env.GetSubZoneText = function() return "Booty Bay" end
  env.GetPlayerInfoByGUID = function(g) return "Rogue", "ROGUE", "Undead", "Scourge", 2, nil, nil end
  env.Ambiguate = function(n) return (n:gsub("%-Mirage$", "")) end
  env.C_Map = { GetBestMapForUnit = function() return 1434 end,
    GetPlayerMapPosition = function() return { GetXY = function() return 0.271, 0.773 end } end }
  env.C_Timer = {
    After = function(_, fn) timers[#timers + 1] = fn end,
    NewTicker = function(_, fn) env.__tick = fn end,
  }
  env.C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(p, msg, ch) wire[#wire + 1] = { p, msg, ch, name .. "-Mirage" }; return 0 end,
  }
  env.CreateFrame = function(_, fname)
    local fr = mock()
    local ev = {}
    fr.RegisterEvent = function(_, e) ev[e] = true end
    fr.SetScript = function(_, s, fn) if s == "OnEvent" then fr.onEvent = fn end end
    fr.IsShown = function() return false end
    frames[#frames + 1] = { f = fr, ev = ev }
    if fname then env[fname] = fr end
    return fr
  end
  for _, k in ipairs({ "UIParent", "Minimap", "RaidWarningFrame", "GameTooltip", "Settings", "ScrollUtil",
    "MinimalSliderWithSteppersMixin", "ScrollBoxConstants", "CreateScrollBoxListLinearView",
    "CreateDataProvider", "PlaySound", "RaidNotice_AddMessage", "hooksecurefunc", "GameTooltip_Hide" }) do
    env[k] = mock()
  end
  env.Minimap.GetWidth = function() return 140 end
  local ns = {}
  for _, f in ipairs(FILES) do
    local chunk = assert(loadfile(ROOT .. "/" .. f))
    setfenv(chunk, env)
    chunk("GuildVendetta", ns)
  end
  local c = { ns = ns, env = env, printed = printed }
  function c.fire(e, ...)
    for _, fr in ipairs(frames) do
      if fr.ev[e] and fr.f.onEvent then fr.f.onEvent(fr.f, e, ...) end
    end
  end
  function c.runTimers()
    local t = timers; timers = {}
    for _, fn in ipairs(t) do fn() end
  end
  return c
end

local A, B = client("Thrall"), client("Jaina")
for _, c in ipairs({ A, B }) do
  c.fire("ADDON_LOADED", "GuildVendetta")
  c.fire("PLAYER_LOGIN")
  c.runTimers()
end
assert(A.ns.guildKey == "Horde Hunters-Mirage", tostring(A.ns.guildKey))

-- A takes damage from a hostile player, then dies
local cleu
A.env.CombatLogGetCurrentEventInfo = function() return unpack(cleu) end
cleu = { 0, "SPELL_DAMAGE", false, "Player-2-G", "Gankston", 0x40 + 0x400 + 0x100, 0, "Player-1-Thrall", "Thrall", 0x511 }
A.fire("COMBAT_LOG_EVENT_UNFILTERED")
cleu = { 0, "SWING_DAMAGE", false, "Player-2-S", "Stabbz-OtherRealm", 0x40 + 0x400 + 0x100, 0, "Player-1-Thrall", "Thrall", 0x511 }
now = now + 5
A.fire("COMBAT_LOG_EVENT_UNFILTERED")
A.fire("PLAYER_DEAD")
A.runTimers()
local n = 0
for id, e in pairs(A.ns.events) do n = n + 1; print("A event", id, #e.en, e.en[1].n, e.en[1].kb) end
assert(n == 1)
assert(#A.ns.view.rows == 2, #A.ns.view.rows)

-- deliver A's live broadcast to B
A.env.__tick()
assert(#wire >= 1, "nothing sent")
for _, m in ipairs(wire) do print("wire", m[1], m[3], m[2]) end
for _, m in ipairs(wire) do if m[4] ~= "Jaina-Mirage" then B.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end end
wire = {}
B.runTimers()
assert(#B.ns.view.rows == 2, "B did not get the kill")
print("B printed:", B.printed[#B.printed])

-- B removes Gankston; A gets it; Stabbz stays
B.ns.Remove("Gankston-Mirage")
B.env.__tick()
for _, m in ipairs(wire) do A.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
wire = {}
A.runTimers()
assert(#A.ns.view.rows == 1 and A.ns.view.rows[1].name == "Stabbz-OtherRealm", "removal not applied")

-- catch-up: a new client C logs in with an empty log and gets everything via H/E
local C = client("Rexxar")
C.fire("ADDON_LOADED", "GuildVendetta"); C.fire("PLAYER_LOGIN"); C.runTimers()
C.env.__tick() -- sends H
local function pump()
  for _ = 1, 50 do
    local msgs = wire; wire = {}
    for _, m in ipairs(msgs) do
      for _, c in ipairs({ A, B, C }) do
        if m[4] ~= c.ns.FullName(c.env.UnitName("player")) then c.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
      end
    end
    for _, c in ipairs({ A, B, C }) do c.runTimers(); c.env.__tick() end
    now = now + 0.5
  end
end
pump()
local cn = 0
for _ in pairs(C.ns.events) do cn = cn + 1 end
C.runTimers()
assert(cn == 2, "C has " .. cn .. " events")
assert(#C.ns.view.rows == 1)

-- alert on seeing a listed enemy via nameplate
A.env.UnitExists = function() return true end
A.env.UnitIsPlayer = function() return true end
A.env.UnitName = function(u) if u == "player" then return "Thrall" end return "Stabbz", "OtherRealm" end
A.env.UnitGUID = function() return "Player-2-S" end
A.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
print("A alert:", A.printed[#A.printed])
assert(A.printed[#A.printed]:find("VENDETTA"))
print("smoke: ok")
