# Guild Vendetta — Design

Date: 2026-11-21 · Status: approved

> **Update 2026-11-21 (probe round 1, live client 1.60.1):** the combat log is **blocked** for addons on Forever. `CombatLogGetCurrentEventInfo` doesn't exist, and registering `COMBAT_LOG_EVENT_UNFILTERED` triggers "blocked from an action only available to the Blizzard UI". Changes:
> - **Kill capture** reads `C_DeathRecap` on `PLAYER_DEAD` instead of a 60-second combat-log buffer. Contributors are limited to the enemy players in the recap.
> - **Proximity** uses nameplates, target and mouseover only.
> - **Enemies are keyed by GUID.** Names have two parts on Forever and the realm comes back empty, so the name is only a fallback key.
> - **Pet kills** can't be credited to the owner.

> **Update 2026-11-21 (#12):** added a `VENDETTA` event type (one credit per guildie who helped kill a listed enemy, detected from the honorable-kill message with a targeting fallback) and a score per enemy: their kills vs. our vendetta kills, where credits within 60 s are one kill. Both halves of the score start over on REMOVE. Other changes:
> - **Revengers leaderboard:** counts every credit, all-time.
> - **Announcements:** deaths and vendettas are posted in visible guild chat (toggleable).
> - **Expiry:** kills and removals expire after 14 days; vendettas never do.

> **Update 2026-11-21 (sync v2):** catch-up now goes digest → per-day id-sets (6-character fingerprints) → only the missing events. The old reply digest (`h`) is gone. A heartbeat every 4–6 minutes broadcasts one hash of the whole log; a mismatch triggers the same reconciliation. Worked examples with real messages are in [docs/sync-examples.md](../../sync-examples.md).

> **Update 2026-11-22 (sync v3):** login and `/reload` send a heartbeat instead of a digest, so a reload with nothing new costs one message. Digests group events into units: each of the last 15 days, plus 30-day blocks for older events (only vendettas live that long), which keeps them about two messages long. All id-sets of one answer travel in one `I` message (`unit:hash:ids|unit:hash:ids`).

## Intent

A World of Warcraft: Forever addon that keeps a **guild-shared vendetta list**: every enemy player who killed you or a guildmate in world PvP. When someone on the list shows up near you, the addon alerts you (screen flash + raid-warning message + sound), so the guild can avoid them, hunt them, or warn each other.

## Goals

- Record world-PvP deaths of guild members automatically, the moment they happen.
- Share the list across the guild live, with no server to run.
- Alert when a listed enemy is near.
- Let any guild member remove an entry (X button); removal applies guild-wide.
- Look and feel like Blizzard's own UI.

## Non-goals (v1)

- A backend server, database, web view, or companion desktop app (see "Later: option B").
- Tracking deaths in battlegrounds, arenas, or duels.
- Tracking deaths to NPCs.
- Cross-guild sharing.
- Entry expiry / cleanup.

## Anti-goals

- **Noise.** If the list fills with BG deaths or the alert fires every few seconds on the same enemy, the addon has failed even if it technically works.
- **Leaking data outside the guild.** Nothing is ever sent outside the GUILD addon channel.
- **External dependencies.** Plain Lua, no Ace3/LibStub libraries.

## Constraints

- **Addons have no network access.** In-game Lua cannot make HTTP requests, so a server can't participate in live features.
- **WoW: Forever runs on the modern client with Midnight-era addon restrictions** (per pre-launch third-party reports; not confirmed by Blizzard). Player names / combat-log fields may be "secret" (unreadable to addons) in combat, possibly including world PvP. Addon messages are blocked in some instanced content. **Task 1 of the plan is a probe addon that verifies this in the live client** before anything else is built; if **any** needed data is unreadable (attacker names, levels, nameplates, guild addon messages in the open world), stop and revisit the design with the user.
- The interface (TOC) number and TOC suffix for Forever must be read from the live client (`/dump (select(4, GetBuildInfo()))`).
- Addon messages: ≤255 bytes each, throttled by the client.
- "Nearby" is limited to what the client sees: nameplates, target, mouseover, and combat-log events in range. There is no area-scan API.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | In-game only: SavedVariables on each PC + live sync over hidden GUILD addon messages | Zero infra, live, every guild self-hosts automatically. Members offline when a kill happens catch up only from guildies who are online when they log in. |
| B (later) | A + a Go companion desktop app that syncs SavedVariables with a Go service (Render + Neon) | Central history, web view, catch-up with nobody online. Every member installs an extra app; server data arrives only after `/reload`; infra to run. |
| C (rejected) | Server only | The addon can't reach a server, so live alerts are impossible. |

The user chose A; B becomes a GitHub issue. The Go backend arrives only with B.

## Design

### Repo layout

```
addon/GuildVendetta/       # the addon; copied/symlinked into Interface/AddOns
  GuildVendetta.toc
  *.lua, *.xml
docs/                      # design docs
README.md
```

`server/` (Go) is added only when option B is built.

### Kill capture

- The addon keeps a rolling buffer of **hostile player** damage events against the local player from the combat log, covering the **last 60 seconds**.
- On `PLAYER_DEAD` (the client's death event), if the player is in the open world (not a battleground, arena, or duel), it builds an entry from the buffer:
  - all distinct enemy players who damaged you in the last 60 s are **contributors**;
  - the source of the last damage event is marked **killing blow**;
  - pet/guardian damage is attributed to its owner when the client reveals the owner; otherwise the pet is skipped. *(builder may decide the exact owner-resolution method)*
- No hostile player in the buffer (NPC death, fall damage, etc.) → no entry.
- Duel exclusion: ignore damage from your current duel opponent and deaths while a duel is active (`DUEL_REQUESTED`/`DUEL_FINISHED` tracking or equivalent).
- Battleground/arena exclusion: `IsInInstance()` returns `pvp` or `arena` → skip. Any other instanced content → skip as well (world PvP only).

### Entry data

One entry = one death of a guildmate.

| Field | Notes |
|---|---|
| `id` | `victimGUID .. ":" .. deathServerTime` — deduplicates the same kill arriving from several peers |
| `victim` | name, class, level |
| `enemies[]` | per contributor: name, realm, class, race, level (or `??` if hidden, recorded as -1), `killingBlow` bool |
| `zone`, `subzone`, `mapID`, `x`, `y` | where it happened |
| `time` | server time of death |

Enemy level comes from the best source the client has seen for that GUID in the session (target, mouseover, nameplate). Class/race come from `GetPlayerInfoByGUID`. Unknown level shows as `??`.

The UI groups entries by enemy and shows a **kill count** per enemy: the number of active (non-removed) KILL events they contributed to. The list is **sorted by kill count, highest first** (the enemy who has killed the most guildies ranks #1); ties break by most recent kill.

### Data model: a replicated event log

The list is an append-only log of two event types, like a Kafka topic whose replicas live in every guildie's SavedVariables instead of on a broker:

- **KILL** `{id, victim, enemies[], zone…, time}` — one per guildmate death.
- **REMOVE** `{enemyName-Realm, removedBy, removedAt}` — "hide this enemy's kills up to `removedAt`".

The view is derived: an enemy is listed if they appear in at least one KILL whose `time` is later than the latest REMOVE for that enemy. Consequences:

- Removing an enemy never touches co-contributors on the same kill.
- A removed enemy **comes back** if they kill a guildie again after the removal (user decision).
- Events are immutable and merging is a set union by event id (KILL: `id`; REMOVE: `enemy:removedAt`), so replaying or receiving duplicates is harmless.

Note: hidden addon messages are **not** persisted by the game. They are delivered only to clients online at that moment, so each client must keep its own copy of the log and sync missing events with peers.

### Sync protocol (hidden guild messages)

All traffic uses `C_ChatInfo.SendAddonMessage(PREFIX, payload, "GUILD")` with a registered prefix (e.g. `GVND`). These messages are delivered to every online guild member's client but are **never shown in chat**; only addons listening on the same prefix receive them (`CHAT_MSG_ADDON`). This is the same mechanism DBM, RCLootCouncil, etc. use.

Messages:

- **KILL** — sent immediately from the victim's own client on death. Online guildies append it and it is live in their list within ~1 s.
- **REMOVE** — sent when someone clicks X. Online guildies append it and the enemy disappears from their list immediately. REMOVE events are kept and synced forever so a stale copy can't resurrect old kills.
- **Login catch-up (anti-entropy)** — on login / `/reload`, the client and the online guildies exchange summaries of which events they hold and **each side sends the other whatever it is missing**, so the result is the union of everything held by everyone online. A time watermark alone is *not* sufficient (it skips older events held by a peer who comes online later). Suggested shape: summaries bucketed by day (count + hash per bucket), drill into differing buckets, then send missing events. Exact format is the builder's call.
- Catch-up sends **newest events first** and trickles the rest in the background at the client's throttle rate (≈1,000 events in ~15 min). It shares the addon-message budget with other addons, so it must be paced.

Rules:

- Only messages whose sender is in your guild (channel = GUILD) are accepted.
- Catch-up comes **only from guildies online at the time**. If nobody holding an event is online, you get it the next time you and someone who has it are online together.
- Avoid every online guildie re-sending the same events (builder's call, e.g. random reply delay; stand down for events already seen on the channel).
- Payloads must fit 255 bytes; an entry with many contributors spans multiple messages. Serialization format is the builder's call.

### Proximity alerts

Triggered when a GUID/name on the active (non-removed) list is seen via:

- `NAME_PLATE_UNIT_ADDED`
- target change / mouseover
- a combat-log event with that player as source or destination

Alert (each part toggleable in settings):

- red screen-edge flash (full-screen texture pulse),
- raid-warning style message, e.g. `VENDETTA: Gankston (Rogue, 60) — killed Thrall ×3`,
- warning sound.

Cooldown: the same enemy alerts at most once per **5 minutes** (configurable).

### UI

Blizzard-native templates (portrait frame, title bar, inset, scroll list, red close button), class-colored names.

```
┌[☠]─ Guild Vendetta ───────────────────────────[x]┐
│ Search: [__________]   Show: [All ▾]   42 enemies │
├───────────────────────────────────────────────────┤
│ #  Enemy      Kills Lvl  Last victim  Where      When │
│ 1  Gankston R  3    60   Thrall   Stranglethorn 2h [X]│
│ 2  Healbot  P  1    ??   Jaina    Tarren Mill   1d [X]│
├───────────────────────────────────────────────────┤
│ Last sync: 1 min ago from Thrall        [Settings] │
└───────────────────────────────────────────────────┘
```

- Opened with `/gv` or a minimap button (no LibDBIcon).
- Rows group by enemy, sorted by kill count (desc), ties by most recent kill; clicking a row expands all their kills, contributors (killing blow marked), and coordinates.
- `[X]` removes the enemy guild-wide (one REMOVE event). Co-contributors stay listed; the enemy returns if they kill again.
- Settings live in the standard Options → AddOns panel: flash / message / sound toggles, alert cooldown.

## Decided by the user

- Option A (in-game only); B later as an issue.
- World PvP only — battlegrounds, arenas, duels excluded (must be stated in the README).
- Contributor window: 60 s.
- X removes guild-wide; a removed enemy comes back if they kill a guildie again.
- Event-log model (KILL / REMOVE events, Kafka-style), replicated across guildies' saved files.
- Blizzard-like UI; monorepo; GitHub Issues for tracking.
- README must explain: the hidden guild messages, the death hook, how removal works, that updates are live, that sync only comes from online players.

## Claude's calls (correctable)

- Killing blow marked; pet kills credited to owner when resolvable.
- Kill count per enemy.
- List sorted by kill count, highest first (user decision); ties by most recent kill (Claude's call).
- 5-minute per-enemy alert cooldown; alert parts toggleable.
- Row expand for details; settings in the Blizzard AddOns panel.
- Removed-by note kept on REMOVE events.
- Login catch-up is a two-way exchange of missing events (not a time watermark), newest first, paced.
- If the probe (task 1) shows partial restrictions, stop and decide with the user; no pre-planned fallbacks.
- No entry expiry in v1.
- Plain Lua, no libraries; `addon/GuildVendetta/` layout.

## Left to the builder

- Serialization format and multi-message chunking.
- Catch-up summary format, reply de-duplication, and pacing.
- Exact pet-owner resolution.
- Sound choice and flash texture.

## Later: option B

A Go companion app reads/writes the addon's SavedVariables file and syncs with a Go HTTP service backed by Postgres (Render + Neon, or self-hosted on a Mac mini via cloudflared). Each guild can run its own instance. Tracked as a GitHub issue.
