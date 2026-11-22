-- Run: luajit tests/smoke_test.lua   (from the repo root; needs LuaJIT for setfenv + bit)
-- Two/three "clients" with a stubbed WoW API: death -> live sync -> removal -> login catch-up -> alert.
-- simulates a world-PvP death on client A and checks client B receives it.
local ROOT = arg[1] or "addon/GuildVendetta"
local FILES = { "Core.lua", "Capture.lua", "Sync.lua", "Alerts.lua", "UI.lua" }
local wire = {} -- addon messages "on the GUILD channel"
local chat = {} -- visible guild chat lines
local now = 1000

local function mock()
  local m = {}
  return setmetatable(m, {
    __index = function(t, k) local f = mock(); rawset(t, k, f); return f end,
    __call = function() return mock() end,
  })
end

local function client(first, second)
  local name = first
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
  env.UnitName = function(u) if u == "player" then return first, second end end -- Forever: two names
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
  env.__timers = function(d, fn) timers[#timers + 1] = { due = now + d, fn = fn } end
  env.C_Timer = {
    After = function(d, fn) timers[#timers + 1] = { due = now + d, fn = fn } end,
    NewTicker = function(_, fn) env.__tick = fn end,
  }
  env.C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(p, msg, ch) wire[#wire + 1] = { p, msg, ch, first .. "-" .. second }; return 0 end,
    SendChatMessage = function(msg, ch) chat[#chat + 1] = ch .. ": " .. msg end,
  }
  env.COMBATLOG_HONORGAIN = "%s dies, honorable kill Rank: %s (Estimated Honor Points: %d)"
  env.UnitIsDead = function() return false end
  env.UnitAffectingCombat = function() return false end
  env.UnitExists = function() return false end
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
    "CreateDataProvider", "PlaySound", "RaidNotice_AddMessage", "hooksecurefunc", "GameTooltip_Hide",
    "PanelTemplates_SetTab", "PanelTemplates_SetNumTabs", "PanelTemplates_TabResize" }) do
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
  -- runTimers() fires every pending timer; runTimers(true) only those due by the test clock
  function c.clearTimers() timers = {} end
  function c.runTimers(dueOnly)
    local t = timers; timers = {}
    for _, x in ipairs(t) do
      if dueOnly and x.due > now then timers[#timers + 1] = x else x.fn() end
    end
  end
  return c
end

local A, B = client("Thrall", "Durotan"), client("Jaina", "Proudmoore")
for _, c in ipairs({ A, B }) do
  c.fire("ADDON_LOADED", "GuildVendetta")
  c.fire("PLAYER_LOGIN")
  c.runTimers()
end
assert(A.ns.guildKey == "Horde Hunters-Mirage", tostring(A.ns.guildKey))

-- A dies; the death recap lists two hostile players, a mob, and A itself (fall damage)
local HOSTILE_PLAYER = 0x40 + 0x400 + 0x100
A.env.C_DeathRecap = {
  GetRecapEvents = function() return {
    { timestamp = 1763700990, sourceGUID = "Player-2-G", sourceName = "Gankston Doe", sourceFlags = HOSTILE_PLAYER },
    { timestamp = 1763700995, sourceGUID = "Player-2-S", sourceName = "Stabbz Roe", sourceFlags = HOSTILE_PLAYER },
    { timestamp = 1763700992, sourceGUID = "Creature-0-1", sourceName = "Raptor", sourceFlags = 0xa48 },
    { timestamp = 1763700993, sourceGUID = "Player-1-Thrall", sourceName = "Thrall Durotan", sourceFlags = 0x511 },
    { timestamp = 1763700991, sourceGUID = "Player-2-G", sourceName = "Gankston Doe", sourceFlags = HOSTILE_PLAYER },
  } end,
  HasRecapEvents = function() return false end,
}
A.fire("PLAYER_DEAD")
A.runTimers() -- recap is read 1s after death
A.runTimers() -- view rebuild
local n = 0
for id, e in pairs(A.ns.events) do n = n + 1; print("A event", id, #e.en, e.en[1].n, e.en[1].kb) end
assert(n == 1)
assert(#A.ns.view.rows == 2, #A.ns.view.rows)

-- deliver A's live broadcast to B
A.env.__tick()
assert(#wire >= 1, "nothing sent")
for _, m in ipairs(wire) do print("wire", m[1], m[3], m[2]) end
for _, m in ipairs(wire) do if m[4] ~= "Jaina-Proudmoore" then B.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end end
wire = {}
B.runTimers()
assert(#B.ns.view.rows == 2, "B did not get the kill")
assert(B.ns.view.byKey["Player-2-S"].name == "Stabbz Roe", "two-part names not kept")

-- B removes Gankston; A gets it; Stabbz stays
B.ns.Remove("Player-2-G")
B.env.__tick()
for _, m in ipairs(wire) do A.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
wire = {}
A.runTimers()
assert(#A.ns.view.rows == 1 and A.ns.view.rows[1].name == "Stabbz Roe", "removal not applied")

-- a second death that reuses the same (stale) recap is not recorded twice
A.fire("PLAYER_DEAD"); A.runTimers(); A.runTimers()
local an = 0
for _ in pairs(A.ns.events) do an = an + 1 end
assert(an == 2, "stale recap recorded again: " .. an)

-- a big kill (many attackers) spans several chunks and is reassembled
local big = { k = "K", t = 1763701100, vic = "Jaina-Mirage", vlvl = 40, vclass = "MAGE", zone = "Ashenvale", sub = "",
  en = {} }
for i = 1, 20 do big.en[i] = { n = "Raider" .. i .. "-Mirage", g = "Player-9-" .. i, c = "WARRIOR", r = "Human", l = 60, kb = i == 1 } end
big.id = B.ns.KillId(big.vic, big.t)
B.ns.AddEvent(big); B.ns.Broadcast(big)
for _ = 1, 10 do B.env.__tick() end
assert(#wire > 1, "expected multiple chunks, got " .. #wire)
for _, m in ipairs(wire) do A.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
wire = {}
A.runTimers()
assert(A.ns.events[big.id] and #A.ns.events[big.id].en == 20, "chunked kill not reassembled")

-- the victim announced the death in visible guild chat
assert(chat[1] == "GUILD: [Vendetta] Thrall Durotan was killed by Stabbz Roe, Gankston Doe in Stranglethorn Vale. Killer registered.", chat[1])

-- vendetta via honorable-kill message (first name only) on B; A learns of it and the score becomes 1-1
B.fire("CHAT_MSG_COMBAT_HONOR_GAIN", "Stabbz dies, honorable kill Rank: Private (Estimated Honor Points: 12)")
B.runTimers(); B.env.__tick()
for _, m in ipairs(wire) do A.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
wire = {}
A.runTimers(); B.runTimers(); B.runTimers()
local st = A.ns.view.byKey["Player-2-S"]
assert(st.count == 1 and st.ours == 1, "score " .. st.count .. "-" .. st.ours)
assert(chat[#chat] == "GUILD: [Vendetta] Jaina Proudmoore took down Stabbz Roe. Successful vendetta! (1-1)", chat[#chat])

-- fallback on A: Stabbz targeted in combat, then seen dead -> A is credited for the same kill (still 1-1)
A.env.UnitExists = function() return true end
A.env.UnitGUID = function(u) if u == "player" then return "Player-1-Thrall" end return "Player-2-S" end
A.env.UnitAffectingCombat = function() return true end
A.env.UnitIsPlayer = function() return true end
A.env.UnitName = function(u) if u == "player" then return "Thrall", "Durotan" end return "Stabbz", "Roe" end
A.fire("PLAYER_TARGET_CHANGED")
A.env.UnitIsDead = function() return true end
A.fire("UNIT_HEALTH", "target")
A.runTimers(); A.runTimers()
st = A.ns.view.byKey["Player-2-S"]
assert(st.ours == 1 and #st.vendettas[1].by == 2, "fallback credit: ours=" .. st.ours)
assert(A.ns.view.revengers[1] and #A.ns.view.revengers == 2)
A.env.UnitIsDead = function() return false end
A.env.UnitExists = function() return false end
A.env.__tick()

-- catch-up: a new client C logs in with an empty log; its login heartbeat starts the exchange (B/H/I/E)
local C = client("Rexxar", "Misha")
C.fire("ADDON_LOADED", "GuildVendetta"); C.fire("PLAYER_LOGIN"); C.runTimers()
C.env.__tick() -- sends its login heartbeat
local function pump()
  for _ = 1, 50 do
    local msgs = wire; wire = {}
    for _, m in ipairs(msgs) do
      for _, c in ipairs({ A, B, C }) do
        if c.ns.Name(m[4]) ~= c.ns.Name(c.env.UnitName("player")) then c.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
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
assert(cn == 5, "C has " .. cn .. " events")
assert(#C.ns.view.rows == 21)

-- heartbeat: B silently lost an event (e.g. a live message missed during a loading screen).
-- Heartbeats no longer match B's; the digest / id-set exchange heals B.
-- A and C hold identical logs, so between them they send at most one answer of each kind.
local lostId = big.id
B.ns.events[lostId] = nil
B.runTimers()
wire = {}
A.ns.Heartbeat()
local sent = {}
local tapped = pump
pump = function()
  for _ = 1, 50 do
    local msgs = wire; wire = {}
    for _, m in ipairs(msgs) do
      sent[#sent + 1] = m[4] .. ":" .. m[2]:sub(1, 1)
      for _, c in ipairs({ A, B, C }) do
        if c.ns.Name(m[4]) ~= c.ns.Name(c.env.UnitName("player")) then c.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
      end
    end
    for _, c in ipairs({ A, B, C }) do c.runTimers(true); c.env.__tick() end
    now = now + 0.5
  end
end
A.env.__tick()
pump()
pump = tapped
assert(B.ns.events[lostId], "heartbeat did not heal B")
local digests = 0
for _, k in ipairs(sent) do
  if k == "Thrall-Durotan:H" or k == "Rexxar-Misha:H" then digests = digests + 1 end
end
assert(digests <= 1, "identical logs answered twice: " .. table.concat(sent, " "))

-- alert on seeing a listed enemy via nameplate (after the 5 min cooldown from the targeting above)
now = now + 301
A.env.UnitExists = function() return true end
A.env.UnitIsPlayer = function() return true end
A.env.UnitName = function(u) if u == "player" then return "Thrall", "Durotan" end return "Stabbz", "Roe" end
A.env.UnitGUID = function() return "Player-2-S" end
A.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
print("A alert:", A.printed[#A.printed])
assert(A.printed[#A.printed]:find("VENDETTA"))
-- Scale: a newcomer catching up on 20 events gets each event once, however many in-sync guildies
-- are online, and still gets everything when the first guildies in the answer order are AFK.
local function newcomer(peers, seed, afk)
  math.randomseed(seed)
  wire, now = {}, 5000
  local all = {}
  for i = 1, peers do all[i] = client("Peer" .. i, "Guild") end
  for _, c in ipairs(all) do c.fire("ADDON_LOADED", "GuildVendetta"); c.fire("PLAYER_LOGIN"); c.clearTimers() end
  for i = 1, 20 do
    local e = { k = "K", t = 1763700000 + now - i * 12000, vic = "Victim" .. i .. " Guild", vlvl = 30, vclass = "MAGE",
      zone = "Ashenvale", sub = "", en = { { n = "Ganker Bad", g = "Player-1-G", c = "ROGUE", r = "Orc", l = 40, kb = true } } }
    e.id = all[1].ns.KillId(e.vic, e.t)
    for _, c in ipairs(all) do c.ns.events[e.id] = e end
  end
  local function run(steps, muted, count)
    for _ = 1, steps do
      local msgs = wire; wire = {}
      for _, m in ipairs(msgs) do
        if not muted[m[4]] then
          if count and m[2]:sub(1, 1) == "E" then count.E = count.E + 1 end
          for _, c in ipairs(all) do
            if c.ns.Name(m[4]) ~= c.ns.Name(c.env.UnitName("player")) then c.fire("CHAT_MSG_ADDON", m[1], m[2], m[3], m[4]) end
          end
        end
      end
      for _, c in ipairs(all) do c.runTimers(true); c.env.__tick() end
      now = now + 0.5
    end
  end
  for _, c in ipairs(all) do -- one heartbeat round so everyone knows who's online, as in-game
    c.env.C_Timer.After = function(d, fn) if d < 200 then c.env.__timers(d, fn) end end
    c.ns.Heartbeat(); c.env.__tick()
  end
  run(20, {})
  now = now + 400
  local new = client("Newbie", "Guild")
  new.fire("ADDON_LOADED", "GuildVendetta"); new.fire("PLAYER_LOGIN"); new.clearTimers()
  new.env.C_Timer.After = function(d, fn) if d < 200 then new.env.__timers(d, fn) end end
  table.insert(all, new)
  local muted, count = {}, { E = 0 }
  for i = 1, afk do muted["Peer" .. i .. "-Guild"] = true end
  new.ns.Heartbeat(); new.env.__tick() -- the login heartbeat
  run(120, muted, count)
  local got = 0
  for _ in pairs(new.ns.events) do got = got + 1 end
  return count.E, got
end
for _, case in ipairs({ { 5, 0 }, { 15, 0 }, { 10, 5 } }) do
  for seed = 1, 3 do
    local sent, got = newcomer(case[1], seed, case[2])
    assert(got == 20 and sent == 20, string.format("%d peers (%d afk): %d sent, %d received", case[1], case[2], sent, got))
  end
end

print("smoke: ok")
