-- Guild sync over hidden GUILD addon messages.
--   E <event>       one KILL/REMOVE/VENDETTA: sent live, and during reconciliation
--   H <digest>      "my log, per day: count + hash" — sent at login, and in answer to a heartbeat
--   I <day id-set>  "the event fingerprints I hold for this day" — sent for days that differ
--   B <hash>        heartbeat every ~5 min: one hash of the whole digest
--
-- Reconciliation (login, or a heartbeat whose hash doesn't match ours):
--   H  -> peers compare per day: days only the peer has -> peer sends those events (E)
--                                 days only H's sender has -> peer sends an empty id-set (I)
--                                 days both have, differing -> peer sends its id-set (I)
--   I  -> receiver sends the events the I's sender lacks (E), and if the I lists events the
--         receiver lacks, answers with its own id-set (I) so the other side sends them.
-- Guildies with identical logs give identical answers, so each answer waits a random 1-5 s and is
-- skipped if an identical one (or the same event) appeared on the channel meanwhile.
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
  -- ponytail: digest capped to the newest days that fit 35 chunks (~400 days of activity)
  local s = ns.EncodeDigest(ns.Buckets(ns.events))
  return #s > 35 * CHUNK and s:sub(-35 * CHUNK):gsub("^[^;]*;", "") or s
end

local function root() return tostring(ns.Hash(digest())) end

-- Queue an answer unless an identical one was seen on the channel since `asked`.
local function answer(kind, key, text, asked)
  if (seen[key] or 0) >= asked then return end
  seen[key] = GetTime()
  queue[#queue + 1] = { kind = kind, text = text }
end

local function offerIdSet(d, asked)
  local text = ns.EncodeIdSet(d, ns.events)
  answer("I", "I" .. text:match("^%d+:%d+"), text, asked)
end

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

-- Random delay before answering, so guildies with identical logs see each other's answers and stay quiet.
local function later(fn) C_Timer.After(1 + math.random() * 4, fn) end

local function handle(kind, text, sender)
  local asked = GetTime()
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
    later(function() answer("H", "H" .. mine, digest(), asked) end)
  elseif kind == "H" then
    seen["H" .. tostring(ns.Hash(text))] = asked
    local mineOnly, theirsOnly, differ = ns.DiffDigest(ns.Buckets(ns.events), ns.DecodeDigest(text))
    later(function()
      local list = {}
      for _, d in ipairs(mineOnly) do
        for _, e in ipairs(ns.DayEvents(ns.events, d)) do list[#list + 1] = e end
      end
      sendEvents(list, asked)
      for _, d in ipairs(differ) do offerIdSet(d, asked) end
      for _, d in ipairs(theirsOnly) do offerIdSet(d, asked) end -- empty set: "send me all of it"
    end)
  elseif kind == "I" then
    local d, h, theirs = ns.DecodeIdSet(text)
    if not d then return end
    seen["I" .. d .. ":" .. h] = asked
    local missing, have, iLack = {}, {}, false
    for _, e in ipairs(ns.DayEvents(ns.events, d)) do
      local short = ns.ShortId(e.id)
      have[short] = true
      if not theirs[short] then missing[#missing + 1] = e end
    end
    for short in pairs(theirs) do
      if not have[short] then iLack = true end
    end
    later(function()
      sendEvents(missing, asked)
      if iLack then offerIdSet(d, asked) end
    end)
  end
end

local function onMessage(prefix, msg, channel, sender)
  if prefix ~= PREFIX or channel ~= "GUILD" or ns.Name(sender) == me or not ns.guildKey or #msg < 5 then return end
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
  C_Timer.After(8, ns.RequestSync)
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
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.NewTicker(TICK, tick)
  else
    onMessage(...)
  end
end)
