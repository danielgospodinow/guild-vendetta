# Sync, by example

Every message below is **real output**: captured by running the addon's code as several simulated guildmates (the same harness as `tests/smoke_test.lua`). Nothing is hand-written except the commentary.

The cast: **Todor Zhivkoff**, **Jaina Proudmoore**, **Thrall Durotan** (guildies), later **Rexxar Misha** (new guildie). Enemies: **Yasashii Hinghtclaw** and **Muffe Kung**.

## Anatomy of a message

All sync traffic is hidden addon messages on the `GUILD` channel with the prefix `GVND`. Every message starts with a 5-character header:

```
E 02 1 1 K~1795289030~Todor Zhivkoff~...
│ │  │ │ └─ payload
│ │  │ └─── total parts (base36): 1
│ │  └───── this part (base36): 1
│ └──────── message id (base36), so parts of one message can be put back together
└────────── kind
```

| Kind | Name | Payload | When |
|---|---|---|---|
| `E` | event | one `KILL` / `REMOVE` / `VENDETTA`, fields split by `~` | live, and to fill gaps |
| `H` | digest | per day: `day:count:hash`, separated by `;` | at login / `/reload`, and in answer to a mismatched heartbeat |
| `I` | day id-set | `day:hash:` + 6-character fingerprints of that day's event ids | for a day two guildies disagree on |
| `B` | heartbeat | one hash of the whole digest | every 4–6 minutes per guildie |

`day` is days since 1970 (`20778` = 21 Nov 2026). Event ids are never sent. Each side derives them from the content, for example `K:Todor Zhivkoff:1795289030`.

## 1. Live: Todor dies to two enemies

```
Todor Zhivkoff    [event]  E0211K~1795289030~Todor Zhivkoff~32~PALADIN~Alterac Mountains~The Headland~1416~0.399~0.920~Yasashii Hinghtclaw,DRUID,NightElf,37,1,Player-6842-00C4852A^Muffe Kung,WARRIOR,Human,32,0,Player-6948-05F3FBB6
(guild chat)      [Vendetta] Todor Zhivkoff was killed by Yasashii Hinghtclaw, Muffe Kung in Alterac Mountains. Killer registered.
```

One message. Decoded:

| Field | Value |
|---|---|
| type | `K` (KILL) |
| time | `1795289030` (server time of death) |
| victim, level, class | Todor Zhivkoff, 32, PALADIN |
| zone, subzone, map, x, y | Alterac Mountains, The Headland, 1416, 39.9%, 92.0% |
| enemies (`^`-separated) | `name,class,race,level,killingBlow,characterId` |
| | Yasashii Hinghtclaw, DRUID, NightElf, 37, **1** (killing blow), Player-6842-00C4852A |
| | Muffe Kung, WARRIOR, Human, 32, 0, Player-6948-05F3FBB6 |

Jaina's and Thrall's addons append it to their logs. Everyone now holds **1 event**. The visible guild-chat line is a separate, ordinary chat message.

## 2. Live: Jaina takes Yasashii down

The game shows Jaina *"Yasashii Hinghtclaw dies, honorable kill…"*. Yasashii is on the list, so her addon records a vendetta:

```
Jaina Proudmoore  [event]  E0211V~1795289633~Player-6842-00C4852A~Yasashii Hinghtclaw~DRUID~Jaina Proudmoore~Alterac Mountains
(guild chat)      [Vendetta] Jaina Proudmoore took down Yasashii Hinghtclaw. Successful vendetta! (1-1)
```

`V` = VENDETTA: time, enemy's character ID, enemy name, class, **who gets credit**, zone. Yasashii's score is now `1-1`.

## 3. Live: Thrall removes Muffe Kung

```
Thrall Durotan    [event]  E0211R~1795289699~Player-6948-05F3FBB6~Thrall Durotan
```

`R` = REMOVE: "hide this enemy's kills up to `1795289699`", removed by Thrall. Muffe disappears from every online list. Everyone holds **3 events**.

## 4. Catch-up at login: Thrall was offline for one kill

While Thrall is offline, Todor dies again. Todor and Jaina get it live, so they hold **4 events** and Thrall still holds 3. Then Thrall logs in:

```mermaid
sequenceDiagram
    participant Th as Thrall (3 events)
    participant To as Todor (4)
    participant Ja as Jaina (4)
    Th->>To: H  "day 20778: 3 events, hash 2395705750"
    Th->>Ja: (same broadcast)
    Note over To,Ja: day 20778 differs (4 vs 3).<br/>Both would answer identically; Todor's random wait<br/>ends first, Jaina sees his answer and stays quiet.
    To->>Th: I  "day 20778: my 4 fingerprints"
    Note over Th: I'm missing lnjrx8.<br/>Answer with my own list so they can tell.
    Th->>To: I  "day 20778: my 3 fingerprints"
    To->>Th: E  the missing KILL
```

```
Thrall Durotan    [digest]      H031120778:3:2395705750
Todor Zhivkoff    [day id-set]  I041120778:1544699368:lnjrx8,1hj0ek,gi3g5b,lmywsf
Thrall Durotan    [day id-set]  I041120778:2395705750:1hj0ek,gi3g5b,lmywsf
Todor Zhivkoff    [event]       E0511K~1795293302~Todor Zhivkoff~32~PALADIN~Alterac Mountains~The Headland~1416~0.399~0.920~Yasashii Hinghtclaw,DRUID,NightElf,37,1,Player-6842-00C4852A
```

Step by step:

1. **`H…20778:3:2395705750`:** Thrall's digest: "on day 20778 I have 3 events, hash 2395705750".
2. **Todor and Jaina compare** with their own day 20778 (4 events, a different hash). The day differs, but the digest can't say *which* events, so one of them sends the day's fingerprints: `lnjrx8,1hj0ek,gi3g5b,lmywsf`.
3. **Thrall compares** those 4 fingerprints with his own 3. He is missing `lnjrx8`. He doesn't know which event that is, so he answers with his own list.
4. **Todor sees** that Thrall's list lacks `lnjrx8` (his newest KILL) and sends exactly that one event.

**Four messages, and each event is sent once.** Jaina stayed silent the whole time, because each answer she would have given had already appeared on the channel.

## 5. Heartbeat: everyone in sync

```
Jaina Proudmoore  [heartbeat]  B03111001900908
```

`1001900908` is a hash of Jaina's whole digest. Todor and Thrall compute the same number from their own logs, so nobody answers. This is what you'll see almost all the time: **one tiny message every 4–6 minutes per guildie.**

## 6. Heartbeat heals a lost live message

Jaina missed Thrall's removal (say she was on a loading screen when it went out). Nobody notices until the next heartbeat:

```
Todor Zhivkoff    [heartbeat]   B06111001900908
Jaina Proudmoore  [digest]      H041120778:3:3155731750
Todor Zhivkoff    [day id-set]  I071120778:1544699368:lnjrx8,1hj0ek,gi3g5b,lmywsf
Jaina Proudmoore  [day id-set]  I051120778:3155731750:lnjrx8,gi3g5b,lmywsf
Thrall Durotan    [event]       E0511R~1795289699~Player-6948-05F3FBB6~Thrall Durotan
```

1. Todor's heartbeat hash (`1001900908`) doesn't match Jaina's, so Jaina answers with her digest. Thrall's log matches Todor's, so he doesn't answer.
2. From there it's the same exchange as a login: the day 20778 id-sets show Jaina lacks `1hj0ek`, the REMOVE.
3. Thrall's random wait happened to end first, so he sends it. Todor sees it go by and skips his copy.

Without heartbeats, Jaina would stay out of date until her next login or `/reload`.

## 7. A brand-new guildie logs in

Rexxar just installed the addon and has an empty log. His digest is empty:

```
Rexxar Misha      [digest]  H0111
Todor Zhivkoff    [event]   E0811K~1795293302~Todor Zhivkoff~...      (newest first)
Todor Zhivkoff    [event]   E0911R~1795289699~Player-6948-05F3FBB6~Thrall Durotan
Todor Zhivkoff    [event]   E0a11V~1795289633~Player-6842-00C4852A~Yasashii Hinghtclaw~...
Todor Zhivkoff    [event]   E0b11K~1795289030~Todor Zhivkoff~...
```

When the other side has **no events at all** for a day, there's nothing to compare, so the events are sent straight away with no id-sets. Only Todor sends. Jaina and Thrall skip each event as they see Todor's copy go by. Rexxar now holds all **4 events**.

## 8. A message too big for one packet

WoW caps an addon message at 255 bytes, so a KILL with 12 attackers is split into 4 parts:

```
Jaina Proudmoore  [event]  E0614K~1795296968~Jaina Proudmoore~30~MAGE~Hillsbrad Foothills~Tarren Mill~1424~0.560~0.190~Raider1 Alliance,WARRIOR,Human,60,1,Player-6948-01000001^…^Raider3 Alliance,WARRIOR,Human,60,0,Player-6
Jaina Proudmoore  [event]  E06244948-01000003^Raider4 Alliance,…
Jaina Proudmoore  [event]  E0634er8 Alliance,…
Jaina Proudmoore  [event]  E0644ARRIOR,Human,60,0,Player-6948-01000012
```

Header `E 06 1 4`, `E 06 2 4`, `E 06 3 4`, `E 06 4 4`: message `06`, parts 1–4 of 4. Receivers put the parts back together by sender and message id, then decode the event. Parts that never complete are dropped after 60 seconds.

## Rules that keep it quiet

- **Identical logs give identical answers,** so every answer waits a random 1–5 s. It's skipped if the same answer (same digest, same day id-set, or the same event) appeared on the channel since the request came in.
- **Heartbeats aren't sent while there's still traffic to send,** so they don't pile onto an ongoing catch-up.
- **Known gap:** an event split into several parts takes about 1.6 s to fully arrive. If two guildies start sending the same one within that window, it gets sent twice. That's harmless (merging is by id) and rare.
