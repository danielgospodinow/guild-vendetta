-- Guild sync over hidden GUILD addon messages.
--   E <event>     one KILL/REMOVE/VENDETTA: sent live, and during reconciliation
--   B <hash>      heartbeat: one hash of our whole digest. Sent 8 s after login or /reload, then
--                 every 4-6 min. Guildies with the same hash stay silent.
--   H <digest>    "my log, per unit: count + hash" (a unit is a recent day or an older 30-day
--                 block). Sent in answer to a heartbeat whose hash differs from ours.
--   I <id-sets>   "the event fingerprints I hold for these units", for units that differ.
--
-- Reconciliation, after a heartbeat mismatch:
--   B  -> anyone whose hash differs answers with H.
--   H  -> receiver compares unit by unit: units only it has -> sends those events (E);
--         units the H's sender has that it lacks or disagrees on -> sends its id-sets (I),
--         all in one message (empty set = "send me all of it").
--   I  -> receiver sends the events the I's sender lacks (E), and if the I lists events the
--         receiver lacks, answers with its own id-sets for those units (I).
-- Guildies with identical logs would give identical answers, so they take turns: for each request,
-- every addon sorts the guildies it has heard from (heartbeats keep this list fresh) by a hash of
-- name + request, and answers after 0.5 s + 2 s per place in that order. The first answers; the rest
-- see its answer (or the same events) arrive during their wait and stay quiet. If the first is AFK,
-- the second's turn comes 2 s later.
-- Framing: kind(1) msgid(2) seq(1) total(1) chunk(<=245), base36 counters.
local _, ns = ...

local PREFIX = "GVND"
local CHUNK = 245
local TICK = 0.4      -- seconds between sends; the client throttles bursts anyway
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local queue = {}      -- pending messages: { kind, text } or { event, since }
local chunks = {}     -- chunks of the message being sent
local partial = {}    -- sender..msgid -> { at, total, parts }
local recent = {}     -- event id -> time seen on the channel
local seen = {}       -- "H"/"I" answer key -> time an identical answer was seen on the channel
local peers = {}      -- guildie name -> time we last heard from their addon
local loginAt = 0
local msgid = 0
local me

local function b36(n) return B36:sub(n + 1, n + 1) end
local function unb36(c) return (B36:find(c, 1, true) or 0) - 1 end

local function split(kind, text)
  local total = math.max(1, math.ceil(#text / CHUNK))
  if total > 35 then return end
  msgid = (msgid + 1) % (36 * 36)
  local id = b36(math.floor(msgid / 36)) .. b36(msgid % 36)
  for i = 1, total do
    chunks[#chunks + 1] = kind .. id .. b36(i) .. b36(total) .. text:sub((i - 1) * CHUNK + 1, i * CHUNK)
  end
end

local function tick()
  if #chunks == 0 then
    local item = table.remove(queue, 1)
    if not item then return end
    if item.event then
      -- someone else sent it since the request came in, so every online peer already has it
      if item.since and (recent[item.event.id] or 0) >= item.since then return end
      recent[item.event.id] = GetTime()
      split("E", ns.Encode(item.event))
    else
      split(item.kind, item.text)
    end
    if #chunks == 0 then return end
  end
  if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
  local r = C_ChatInfo.SendAddonMessage(PREFIX, chunks[1], "GUILD")
  local throttled = Enum.SendAddonMessageResult
    and (r == Enum.SendAddonMessageResult.AddonMessageThrottle or r == Enum.SendAddonMessageResult.ChannelThrottle)
  if not throttled then table.remove(chunks, 1) end
end

-- Live event: goes ahead of any reconciliation traffic.
function ns.Broadcast(e)
  table.insert(queue, 1, { event = e })
end

-- `since`: when the request arrived; any copy seen on the channel after that makes ours redundant.
local function sendEvents(list, since)
  table.sort(list, function(a, b) return a.t > b.t end) -- newest first
  for _, e in ipairs(list) do queue[#queue + 1] = { event = e, since = since } end
end

local function digest()
  -- ponytail: capped to the newest units that fit 35 chunks; with 30-day blocks that's decades
  local s = ns.EncodeDigest(ns.Buckets(ns.events, GetServerTime()))
  return #s > 35 * CHUNK and s:sub(-35 * CHUNK):gsub("^[^;]*;", "") or s
end

local function root() return tostring(ns.Hash(digest())) end

-- Queue an answer unless an identical one was seen on the channel since `asked`.
local function answer(kind, key, text, asked)
  if (seen[key] or 0) >= asked then return end
  seen[key] = GetTime()
  queue[#queue + 1] = { kind = kind, text = text }
end

local function offerIdSets(units, asked)
  if #units == 0 then return end
  local text = ns.EncodeIdSets(units, ns.events, GetServerTime())
  answer("I", "I" .. ns.Hash(text), text, asked)
end

local function unitEvents(u) return ns.UnitEvents(ns.events, u, GetServerTime()) end

function ns.RequestSync()
  if ns.guildKey then queue[#queue + 1] = { kind = "H", text = digest() } end
end

-- Skipped while we're still sending, so a busy reconciliation isn't interrupted by its own heartbeat.
function ns.Heartbeat()
  if ns.guildKey and #queue == 0 and #chunks == 0 then queue[#queue + 1] = { kind = "B", text = root() } end
end

local function scheduleHeartbeat()
  C_Timer.After(240 + math.random() * 120, function() -- jittered so guildies don't beat in lockstep
    ns.Heartbeat()
    scheduleHeartbeat()
  end)
end

-- Our turn to answer `request` from `requester`, as a delay. Everyone computes the same order.
local function turn(requester, request)
  local now, list = GetTime(), { me }
  for name, at in pairs(peers) do
    if now - at < 600 and name ~= requester then list[#list + 1] = name end
  end
  local h = {}
  for _, name in ipairs(list) do h[name] = ns.Hash(name .. "|" .. requester .. "|" .. request) end
  table.sort(list, function(a, b)
    if h[a] ~= h[b] then return h[a] < h[b] end
    return a < b
  end)
  local place = 0
  for i, name in ipairs(list) do
    if name == me then place = i - 1 end
  end
  -- just logged in: we may not have heard every guildie's heartbeat yet, so let the others go first
  local fresh = now - loginAt < 360 and 4 or 0
  return 0.5 + place * 2 + fresh + math.random() * 0.3
end

local function later(requester, request, fn) C_Timer.After(turn(requester, request), fn) end

local function handle(kind, text, sender)
  local asked, requester, request = GetTime(), ns.Name(sender), kind .. ns.Hash(text)
  if kind == "E" then
    local e = ns.Decode(text)
    if not e then return end
    recent[e.id] = asked
    if ns.AddEvent(e) then
      ns.guildDB.lastSync = { t = time(), from = ns.Name(sender) } -- live news is announced in guild chat
    end
  elseif kind == "B" then
    local mine = root()
    if text == mine then return end -- same log, nothing to do
    later(requester, request, function() answer("H", "H" .. mine, digest(), asked) end)
  elseif kind == "H" then
    seen["H" .. tostring(ns.Hash(text))] = asked
    local mineOnly, theirsOnly, differ = ns.DiffDigest(ns.Buckets(ns.events, GetServerTime()), ns.DecodeDigest(text))
    later(requester, request, function()
      local list = {}
      for _, u in ipairs(mineOnly) do
        for _, e in ipairs(unitEvents(u)) do list[#list + 1] = e end
      end
      sendEvents(list, asked)
      for _, u in ipairs(theirsOnly) do differ[#differ + 1] = u end -- we list nothing: "send me all of it"
      offerIdSets(differ, asked)
    end)
  elseif kind == "I" then
    local sets = ns.DecodeIdSets(text)
    if not sets then return end
    seen["I" .. ns.Hash(text)] = asked
    local missing, lacking = {}, {}
    for _, s in ipairs(sets) do
      local have, iLack = {}, false
      for _, e in ipairs(unitEvents(s.unit)) do
        local short = ns.ShortId(e.id)
        have[short] = true
        if not s.set[short] then missing[#missing + 1] = e end
      end
      for short in pairs(s.set) do
        if not have[short] then iLack = true end
      end
      if iLack then lacking[#lacking + 1] = s.unit end
    end
    later(requester, request, function()
      sendEvents(missing, asked)
      offerIdSets(lacking, asked)
    end)
  end
end

local function onMessage(prefix, msg, channel, sender)
  if prefix ~= PREFIX or channel ~= "GUILD" or ns.Name(sender) == me or not ns.guildKey or #msg < 5 then return end
  peers[ns.Name(sender)] = GetTime()
  local kind, id, seq, total = msg:sub(1, 1), msg:sub(2, 3), unb36(msg:sub(4, 4)), unb36(msg:sub(5, 5))
  if seq < 1 or total < seq then return end
  if total == 1 then return handle(kind, msg:sub(6), sender) end
  local now, key = GetTime(), sender .. id
  for k, p in pairs(partial) do
    if now - p.at > 60 then partial[k] = nil end
  end
  local p = partial[key] or { at = now, total = total, parts = {}, n = 0 }
  partial[key] = p
  if not p.parts[seq] then p.parts[seq], p.n = msg:sub(6), p.n + 1 end
  if p.n == p.total then
    partial[key] = nil
    handle(kind, table.concat(p.parts), sender)
  end
end

local beating
table.insert(ns.onGuild, function()
  C_Timer.After(8, ns.Heartbeat) -- login and /reload: same check as every heartbeat
  if not beating then
    beating = true
    scheduleHeartbeat()
  end
end)

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, ev, ...)
  if ev == "PLAYER_LOGIN" then
    me = ns.Name(UnitName("player"))
    loginAt = GetTime()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.NewTicker(TICK, tick)
  else
    onMessage(...)
  end
end)
