# Sync, by example

Every message below is **real output**: captured by running the addon's code as several simulated guildmates (the same harness as `tests/smoke_test.lua`). Nothing is hand-written except the commentary.

The cast: **Todor Zhivkoff**, **Jaina Proudmoore**, **Thrall Durotan**, **Sylvanas Windrunner** (guildies), plus **Rexxar Misha** and **Garrosh Hellscream** logging in. Enemies: **Yasashii Hinghtclaw**, **Muffe Kung** and **Gankston Doe**.

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
| `B` | heartbeat | one hash of the whole digest | 8 s after login or `/reload`, then every 4–6 minutes |
| `H` | digest | per unit: `unit:count:hash`, separated by `;` | in answer to a heartbeat whose hash differs |
| `I` | id-sets | per unit: `unit:hash:` + 6-character fingerprints of its events, units separated by `|` | for the units two guildies disagree on, all in one message |

**Units.** The digest groups events into units. Each of the last 15 days is its own unit, written as days since 1970 (`20778` = 21 Nov 2026). Anything older is grouped into 30-day blocks, written `m` + block number (`m690` = 4 Sep to 3 Oct 2026). Kills and removals expire after 14 days, so old blocks only hold vendettas, which are kept forever for the leaderboard. A year-old guild's digest is about 28 units, two message parts.

Event ids are never sent. Each side derives them from the content, for example `K:Todor Zhivkoff:1795289030`.

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

## 4. Logging in: four guildies in sync, one player arrives

Login and `/reload` use the same check as the periodic heartbeat: 8 seconds after logging in, the addon broadcasts one hash of its log. The four guildies online (Todor, Jaina, Thrall, Sylvanas) hold the same 5 events:

| Event | Unit | Fingerprint |
|---|---|---|
| KILL of Todor (today) | `20778` | `lmywsf` |
| VENDETTA by Jaina on Yasashii (today) | `20778` | `gi3g5b` |
| REMOVE of Muffe by Thrall (today) | `20778` | `1hj0ek` |
| KILL of Sylvanas (yesterday) | `20777` | `3tzzlw` |
| VENDETTA by Thrall on Gankston (60 days ago) | `m690` | `9opjcv` |

Their digest is `m690:1:585697855;20777:1:2408568836;20778:3:2395705750`, which hashes to `2163612622`. Times below are seconds after the newcomer's heartbeat.

### 4a. A brand-new player (empty log)

```
t=0.0  Rexxar Misha         B 5381
t=0.8  Sylvanas Windrunner  H m690:1:585697855;20777:1:2408568836;20778:3:2395705750
t=5.7  Rexxar Misha         I 20778:0:|20777:0:|m690:0:
t=6.4  Jaina Proudmoore     E R~1795289699~Player-6948-05F3FBB6~Thrall Durotan
t=6.5  Jaina Proudmoore     E V~1795289633~Player-6842-00C4852A~Yasashii Hinghtclaw~...
t=6.6  Jaina Proudmoore     E K~1795289030~Todor Zhivkoff~...
t=6.7  Jaina Proudmoore     E K~1795202630~Sylvanas Windrunner~...
t=6.8  Jaina Proudmoore     E V~1790105030~Player-6948-0ABCDEF1~Gankston Doe~...
```

1. **Heartbeat.** Rexxar's log is empty, so his hash is `5381`, the hash of an empty digest.
2. **Digest.** All four guildies see that `5381` isn't their `2163612622`, and all four would answer with the same digest. They take turns, and for this request Sylvanas is first, so she sends it. The other three see her digest go by and stay quiet.
3. **Id-sets.** Rexxar compares the digest with his own (empty) one. He has nothing in any of the three units, so he sends one message with an empty id-set for each: "send me all of these". He just logged in, so he waits 4 s longer than usual before sending (see "Who answers").
4. **Events.** The four guildies all see what Rexxar lacks. This time Jaina is first in line, so she sends the five events. The others watch them go by and skip their copies.

**8 messages, and each event crosses the channel once.**

### 4b. A returning player (missing 2 events)

Garrosh was offline yesterday and part of today. He holds 3 of the 5 events.

```
t=0.0  Garrosh Hellscream   B 28244048
t=0.7  Jaina Proudmoore     H m690:1:585697855;20777:1:2408568836;20778:3:2395705750
t=5.5  Garrosh Hellscream   I 20778:1900282881:1hj0ek,lmywsf|20777:0:
t=6.2  Todor Zhivkoff       E V~1795289633~Player-6842-00C4852A~Yasashii Hinghtclaw~...
t=6.3  Todor Zhivkoff       E K~1795202630~Sylvanas Windrunner~...
```

1. Garrosh's hash differs from theirs, so one guildie (Jaina) answers with the digest.
2. Garrosh compares unit by unit. Unit `m690` matches, so he skips it. For `20778` both sides have events but the hashes differ, so he lists his fingerprints. He has nothing for `20777`, so he sends an empty id-set for it. Both go in one message.
3. The guildies compare. In `20778` Garrosh lacks `gi3g5b` (Jaina's vendetta), and `20777` is empty, so he lacks `3tzzlw` too. The first in line (Todor) sends exactly those two events.

**5 messages, and only the 2 missing events are sent.**

### 4c. `/reload` while up to date

```
t=0.0  Todor Zhivkoff       B 2163612622
```

Everyone computes the same hash, so nobody answers. **One message.** This is what almost every login, reload and periodic heartbeat looks like.

## 5. Heartbeat: everyone in sync

```
Jaina Proudmoore  [heartbeat]  B06111001900908
```

`1001900908` is a hash of Jaina's whole digest. Todor and Thrall compute the same number from their own logs, so nobody answers. This is what you'll see almost all the time: **one tiny message every 4–6 minutes per guildie.**

## 6. Heartbeat heals a lost live message

Jaina missed Thrall's removal (say she was on a loading screen when it went out). Nobody notices until the next heartbeat:

```
Todor Zhivkoff    [heartbeat]   B05111001900908
Jaina Proudmoore  [digest]      H071120778:3:3155731750
Thrall Durotan    [id-sets]     I051120778:1544699368:lnjrx8,1hj0ek,gi3g5b,lmywsf
Jaina Proudmoore  [id-sets]     I081120778:3155731750:lnjrx8,gi3g5b,lmywsf
Thrall Durotan    [event]       E0611R~1795289699~Player-6948-05F3FBB6~Thrall Durotan
```

1. Todor's heartbeat hash (`1001900908`) doesn't match Jaina's, so Jaina answers with her digest. Thrall's log matches Todor's, so he doesn't answer.
2. From there it's the same exchange as a login: the id-sets for unit 20778 show Jaina lacks `1hj0ek`, the REMOVE.
3. For this request, the turn order puts Thrall before Todor, so Thrall sends the id-set and then the REMOVE. Todor stays quiet.

Without heartbeats, Jaina would stay out of date until her next login or `/reload`.

## 7. A message too big for one packet

WoW caps an addon message at 255 bytes, so a KILL with 12 attackers is split into 4 parts:

```
Jaina Proudmoore  [event]  E0914K~1795296978~Jaina Proudmoore~30~MAGE~Hillsbrad Foothills~Tarren Mill~1424~0.560~0.190~Raider1 Alliance,WARRIOR,Human,60,1,Player-6948-01000001^…^Raider3 Alliance,WARRIOR,Human,60,0,Player-6
Jaina Proudmoore  [event]  E09244948-01000003^Raider4 Alliance,…
Jaina Proudmoore  [event]  E0934er8 Alliance,…
Jaina Proudmoore  [event]  E0944ARRIOR,Human,60,0,Player-6948-01000012
```

Header `E 09 1 4`, `E 09 2 4`, `E 09 3 4`, `E 09 4 4`: message `09`, parts 1–4 of 4. Receivers put the parts back together by sender and message id, then decode the event. Parts that never complete are dropped after 60 seconds.

## Who answers: taking turns

Everyone with the same log would give the same answer, so for each request the guildies **take turns**:

- Every addon keeps a list of guildies it has heard from in the last 10 minutes. Heartbeats every 4–6 minutes keep it fresh.
- For each request, every addon sorts that list by a hash of *name + requester + request*. They all get the same order, and the order changes from request to request, so the work spreads around the guild.
- Place 0 answers after 0.5 s, place 1 after 2.5 s, place 2 after 4.5 s, and so on.
- When a guildie's turn comes, it skips anything that already appeared on the channel since the request arrived. Normally that's everything, so only place 0 sends.
- If place 0 is AFK or lagging, place 1 covers it 2 s later.
- A guildie who logged in less than 6 minutes ago may not have heard everyone's heartbeat yet, so it waits an extra 4 s to avoid taking someone else's turn.

Measured in the simulator, with a newcomer catching up on 20 events (20 runs per size):

| Online guildies | Random waits (old) | Turn order |
|---|---|---|
| 5 | avg 27, worst 60 | **20** every time |
| 10 | avg 33, worst 60 | **20** every time |
| 20 | avg 63, worst 140 | **20** every time |
| 40 | — | **20** every time |
| 20, with half AFK | — | **20**, and the newcomer got all 20 every time |

## Other rules

- **Heartbeats aren't sent while there's still traffic to send,** so they don't pile onto an ongoing catch-up.
- **Known gap:** an event split into several parts takes about 1.6 s to fully arrive. If a guildie's turn comes during that window, it may send the same event again. That's harmless (merging is by id) and rare.
