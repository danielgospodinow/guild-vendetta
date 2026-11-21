-- Guild sync over hidden GUILD addon messages.
--   E <event>   one KILL/REMOVE, sent live and during catch-up
--   H <digest>  "here's what I hold" (sent at login); receivers send what we lack and reply with h
--   h <digest>  reply digest; receivers only send what the replier lacks (no further replies)
-- Framing: kind(1) msgid(2) seq(1) total(1) chunk(<=245), base36 counters.
local _, ns = ...

local PREFIX = "GVND"
local CHUNK = 245
local TICK = 0.4      -- seconds between sends; the client throttles bursts anyway
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local queue = {}      -- pending messages: { kind, text } or { event, queued }
local chunks = {}     -- chunks of the message being sent
local partial = {}    -- sender..msgid -> { at, total, parts }
local recent = {}     -- event id -> time seen on the channel (dedupe catch-up)
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
      -- someone else sent it after we queued it, so every online peer already has it
      if item.queued and (recent[item.event.id] or 0) > item.queued then return end
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

-- Live event: goes ahead of any catch-up traffic.
function ns.Broadcast(e)
  table.insert(queue, 1, { event = e })
end

local function digest()
  -- ponytail: digest capped to the newest days that fit 35 chunks (~400 days of activity)
  local s = ns.EncodeDigest(ns.Buckets(ns.events))
  return #s > 35 * CHUNK and s:sub(-35 * CHUNK):gsub("^[^;]*;", "") or s
end

function ns.RequestSync()
  if ns.guildKey then queue[#queue + 1] = { kind = "H", text = digest() } end
end

local function sendDays(days)
  local want, list = {}, {}
  for _, d in ipairs(days) do want[d] = true end
  for _, e in pairs(ns.events) do
    if want[math.floor(e.t / 86400)] then list[#list + 1] = e end
  end
  table.sort(list, function(a, b) return a.t > b.t end) -- newest first
  for _, e in ipairs(list) do queue[#queue + 1] = { event = e, queued = GetTime() } end
end

local function handle(kind, text, sender)
  if kind == "E" then
    local e = ns.Decode(text)
    if not e then return end
    recent[e.id] = GetTime()
    if ns.AddEvent(e) then
      ns.guildDB.lastSync = { t = time(), from = ns.Name(sender) } -- live news is announced in guild chat
    end
  elseif kind == "H" or kind == "h" then
    local send, theyHaveMore = ns.DiffDigest(ns.Buckets(ns.events), ns.DecodeDigest(text))
    -- random delay spreads replies so guildmates can see each other's sends and skip duplicates
    C_Timer.After(1 + math.random() * 4, function()
      sendDays(send)
      if kind == "H" and theyHaveMore then queue[#queue + 1] = { kind = "h", text = digest() } end
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

table.insert(ns.onGuild, function()
  C_Timer.After(8, ns.RequestSync)
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
