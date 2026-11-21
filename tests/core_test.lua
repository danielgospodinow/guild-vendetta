-- Run: luajit tests/core_test.lua   (from the repo root)
local ns = {}
assert(loadfile("addon/GuildVendetta/Core.lua"))("GuildVendetta", ns)

local function kill(vic, t, enemies)
  local e = { k = "K", t = t, vic = vic, vlvl = 50, vclass = "WARRIOR", zone = "Stranglethorn Vale",
    sub = "Booty Bay", map = 1434, x = 0.271, y = 0.773, en = enemies }
  e.id = ns.KillId(vic, t)
  return e
end
local function remove(enemy, t) return { k = "R", t = t, en = enemy, by = "Jaina-Mirage", id = ns.RemoveId(enemy, t) } end
local function add(log, e) log[e.id] = e end
local NOW = 1763701000

-- Encode/decode round trip
local k = kill("Thrall-Mirage", 1763700000, {
  { n = "Gankston-Mirage", c = "ROGUE", r = "Scourge", l = 60, kb = true },
  { n = "Stabbz-Mirage", c = "ROGUE", r = "Orc", l = -1, kb = false },
})
local d = ns.Decode(ns.Encode(k))
assert(d.id == k.id and d.vic == "Thrall-Mirage" and d.zone == "Stranglethorn Vale" and d.map == 1434)
assert(math.abs(d.x - 0.271) < 1e-6 and #d.en == 2 and d.en[1].kb and not d.en[2].kb and d.en[2].l == -1)
local r = ns.Decode(ns.Encode(remove("Gankston-Mirage", 1763700100)))
assert(r.k == "R" and r.en == "Gankston-Mirage" and r.id == "R:Gankston-Mirage:1763700100")
-- separators in strings are stripped, not injected
local evil = kill("Thrall-Mirage", 1763700000, { { n = "A~B^C,D", c = "ROGUE", r = "Orc", l = 1, kb = true } })
evil.zone = "Zone~with^seps,x"
local de = ns.Decode(ns.Encode(evil))
assert(de and de.en[1].n == "ABCD" and de.zone == "Zonewithsepsx")
-- malformed input rejected
for _, bad in ipairs({ "", "K~abc", "R~1763700000~~x", "K~1~a~1~b~c~d~1~0~0~n,c,r,1,1", "X~1763700000~a~b", 5 }) do
  assert(ns.Decode(bad) == nil, tostring(bad))
end

-- View: ranking, co-contributors survive removal, removed enemy returns on a new kill
local log = {}
add(log, k)
add(log, kill("Jaina-Mirage", 1763700050, { { n = "Gankston-Mirage", c = "ROGUE", r = "Scourge", l = 60, kb = true } }))
add(log, kill("Rexxar-Mirage", 1763700060, { { n = "Healbot-Mirage", c = "PRIEST", r = "Tauren", l = -1, kb = true } }))
local v = ns.BuildView(log, NOW)
assert(v.rows[1].name == "Gankston-Mirage" and v.rows[1].count == 2 and v.rows[1].rank == 1)
assert(v.rows[2].name == "Healbot-Mirage") -- 1 kill, more recent than Stabbz
assert(v.rows[3].name == "Stabbz-Mirage" and v.rows[3].level == -1)
assert(v.rows[1].kills[1].vic == "Jaina-Mirage") -- newest kill first

add(log, remove("Gankston-Mirage", 1763700100))
v = ns.BuildView(log, NOW)
assert(not v.byKey["Gankston-Mirage"] and v.byKey["Stabbz-Mirage"].count == 1)

add(log, kill("Thrall-Mirage", 1763700200, { { n = "Gankston-Mirage", c = "ROGUE", r = "Scourge", l = 60, kb = true } }))
v = ns.BuildView(log, NOW)
assert(v.byKey["Gankston-Mirage"].count == 1) -- back, only with the post-removal kill

-- GUID is the identity when known: same GUID under two spellings is one enemy, removal by GUID
local g1 = kill("Jaina-Mirage", 1763700300, { { n = "Todor", g = "Player-6842-AAA", c = "PALADIN", r = "Scourge", l = 32, kb = true } })
local g2 = kill("Rexxar-Mirage", 1763700400, { { n = "Todor-Zhivkoff", g = "Player-6842-AAA", c = "PALADIN", r = "Scourge", l = -1, kb = true } })
assert(ns.Decode(ns.Encode(g1)).en[1].g == "Player-6842-AAA")
add(log, g1); add(log, g2)
v = ns.BuildView(log, NOW)
assert(v.byKey["Player-6842-AAA"].count == 2 and v.byKey["Player-6842-AAA"].level == 32)
add(log, remove("Player-6842-AAA", 1763700500))
assert(not ns.BuildView(log, NOW).byKey["Player-6842-AAA"])
log[g1.id], log[g2.id], log[ns.RemoveId("Player-6842-AAA", 1763700500)] = nil, nil, nil

-- Vendettas: encode/decode, malformed rejected
local function vend(enemy, name, by, t) return { k = "V", t = t, en = enemy, n = name, c = "ROGUE", by = by, zone = "Arathi Highlands", id = ns.VendettaId(enemy, by, t) } end
local dv = ns.Decode(ns.Encode(vend("Player-2-G", "Gankston Doe", "Jaina Proudmoore", 1763700600)))
assert(dv.k == "V" and dv.en == "Player-2-G" and dv.n == "Gankston Doe" and dv.by == "Jaina Proudmoore" and dv.zone == "Arathi Highlands")
assert(dv.id == "V:Player-2-G:Jaina Proudmoore:1763700600")
assert(ns.Decode("V~1763700600~~x~ROGUE~y~z") == nil and ns.Decode("V~1763700600~a~b~c~~z") == nil)

-- Score: theirs = kills; ours = vendetta kills, credits within 60s are one kill; victims are distinct
do
  local L = {}
  local G = { n = "Gankston Doe", g = "Player-2-G", c = "ROGUE", r = "Scourge", l = 60, kb = true }
  add(L, kill("Todor Zhivkoff", 1763700000, { G }))
  add(L, kill("Jaina Proudmoore", 1763700100, { G }))
  add(L, kill("Todor Zhivkoff", 1763700200, { G }))
  add(L, vend("Player-2-G", "Gankston Doe", "Thrall Durotan", 1763700300))
  add(L, vend("Player-2-G", "Gankston Doe", "Jaina Proudmoore", 1763700330)) -- same kill, second guildie
  local r = ns.BuildView(L, NOW).byKey["Player-2-G"]
  assert(r.count == 3 and r.ours == 1, r.count .. "-" .. r.ours)
  assert(#r.vendettas[1].by == 2 and r.vendettas[1].by[1] == "Thrall Durotan")
  assert(#r.victims == 2 and r.victims[1].vic == "Todor Zhivkoff" and r.lastVictim.t == 1763700200)
  add(L, vend("Player-2-G", "Gankston Doe", "Thrall Durotan", 1763700500)) -- a second kill
  local v2 = ns.BuildView(L, NOW)
  assert(v2.byKey["Player-2-G"].ours == 2)
  -- revengers: every credit counts, ranked by count
  assert(v2.revengers[1].name == "Thrall Durotan" and v2.revengers[1].count == 2 and v2.revengers[2].count == 1)
  assert(v2.revengers[1].lastEnemy == "Gankston Doe")
  -- REMOVE: score starts over, revengers keep their credits; a new kill brings the enemy back at 1-0
  add(L, remove("Player-2-G", 1763700600))
  add(L, kill("Rexxar Misha", 1763700700, { G }))
  local v3 = ns.BuildView(L, NOW)
  assert(v3.byKey["Player-2-G"].count == 1 and v3.byKey["Player-2-G"].ours == 0)
  assert(v3.revengers[1].count == 2)
  -- Expiry: kills older than 14 days drop off; vendettas never expire
  local later = 1763700700 + ns.EXPIRY + 1
  assert(#ns.BuildView(L, later).rows == 0 and ns.BuildView(L, later).revengers[1].count == 2)
  assert(ns.Expired({ k = "K", t = 1 }, later) and ns.Expired({ k = "R", t = 1 }, later))
  assert(not ns.Expired({ k = "V", t = 1 }, later) and not ns.Expired({ k = "K", t = later - 10 }, later))
end

-- Digests: identical logs match; a missing event is detected in both directions
local a, b = {}, {}
for id, e in pairs(log) do a[id] = e; b[id] = e end
local send, more = ns.DiffDigest(ns.Buckets(a), ns.DecodeDigest(ns.EncodeDigest(ns.Buckets(b))))
assert(#send == 0 and not more)
b[k.id] = nil
send, more = ns.DiffDigest(ns.Buckets(a), ns.DecodeDigest(ns.EncodeDigest(ns.Buckets(b))))
assert(#send == 1 and send[1] == math.floor(k.t / 86400) and more)
send, more = ns.DiffDigest(ns.Buckets(b), ns.DecodeDigest(ns.EncodeDigest(ns.Buckets(a))))
assert(#send == 1 and more)

-- Two-part names (WoW: Forever): every API shape normalizes to "First Second"
assert(ns.Name("Todor", "Zhivkoff") == "Todor Zhivkoff")
assert(ns.Name("Todor-Zhivkoff") == "Todor Zhivkoff")
assert(ns.Name("Todor Zhivkoff", "Zhivkoff") == "Todor Zhivkoff")
assert(ns.Name("Todor", "") == "Todor" and ns.Name(nil) == nil)

print("core_test: ok")
