# guild-vendetta

A **World of Warcraft: Forever** addon that keeps a guild-shared **vendetta list**: every enemy player who has killed you or one of your guildmates in world PvP. When someone on the list comes near you, the addon flashes your screen red, shows a raid-warning style message, and plays a warning sound.

> **Status: v0.1, untested in-game.** The first build is in, but it has not run in the live client yet. Work is tracked in [GitHub Issues](https://github.com/danielgospodinow/guild-vendetta/issues). The full design is in [docs/superpowers/specs/2026-11-21-guild-vendetta-design.md](docs/superpowers/specs/2026-11-21-guild-vendetta-design.md).

## Features

- **Automatic kill tracking.** When a guildmate dies to enemy players, the kill is recorded the moment it happens.
- **Every contributor counts.** Everyone who damaged the victim in the **last 60 seconds** before death is listed, and the killing blow is marked. Pet kills are credited to the pet's owner when the game reveals who that is.
- **Kill rank.** Each enemy shows how many guildmates they have killed, and the list is sorted by that count, so the worst offender is #1.
- **Proximity alerts.** You get a red screen flash, a raid-warning message and a sound when a listed enemy is seen nearby. Each part can be turned off. The same enemy alerts at most once every 5 minutes by default.
- **Shared across the guild, live.** Every guildmate running the addon sees the same list, and updates arrive within about a second.
- **Removal with the X button.** Any guild member can remove an enemy, and the removal applies to the whole guild.
- **Blizzard-native look.** The addon uses Blizzard's own frame templates and class-colored names, and its settings live in the standard *Options → AddOns* panel.
- **No server, no setup.** Every guild automatically has its own private list.

### World PvP only

The addon **only tracks world PvP**. Deaths in **battlegrounds, arenas, and duels are ignored**, as are deaths inside any other instance. Tracking those would bury the real grudges in noise.

### What each entry holds

| Field | Example |
|---|---|
| Enemy name, realm, class, race | Gankston-Mirage, Rogue, Undead |
| Enemy level at the time of the kill | `60`, or `??` when the game hides it (enemy far above your level) |
| Killing blow / contributor | ★ Gankston, Stabbz, Mageboi |
| Guildmate killed, and their level | Thrall (52) |
| Where | Stranglethorn Vale, Booty Bay outskirts (x, y) |
| When | server time of death |

## The UI

```
┌[☠]─ Guild Vendetta ──────────────────────────────────[x]┐
│      [🔍 Search      ]                       42 enemies │
├──────────────────────────────────────────────────────────┤
│  #  Enemy        Kills  Lvl  Last victim  Where     When  │
│  1  + Gankston     3    60   Thrall       Stranglethorn 2h [x]│
│        killed Thrall (52) in Stranglethorn Vale, Booty Bay │
│        (27.1, 77.3), 2h ago, by *Gankston, Stabbz          │
│  2  + Healbot      1    ??   Jaina        Tarren Mill  1d [x]│
├──────────────────────────────────────────────────────────┤
│ Last sync: 1m ago from Thrall                 [Settings] │
└──────────────────────────────────────────────────────────┘
```

- Open it with `/gv` or the minimap button. Escape closes it.
- Click a row to expand every kill by that enemy, with contributors, the killing blow (`*`) and map coordinates.
- `[x]` removes that enemy for the whole guild, after a confirmation.

### Commands

| Command | What it does |
|---|---|
| `/gv` or `/vendetta` | Open or close the window |
| `/gv test` | Preview the alert (flash, message, sound) |
| `/gv sync` | Ask online guildmates for anything you're missing |
| `/gv status` | Show the guild, entry counts, and whether the game lets the addon read the combat log |

## Install

The addon targets the WoW: Forever client (interface `16001`).

1. Clone this repo.
2. Link the addon into your Forever AddOns folder (macOS paths shown):
   ```bash
   ln -s "$PWD/addon/GuildVendetta" "/Applications/World of Warcraft/_forever_/Interface/AddOns/GuildVendetta"
   ```
   On Windows, copy `addon/GuildVendetta` into `World of Warcraft\_forever_\Interface\AddOns\` instead.
3. Restart the game, or run `/reload` if it is already running.

### Probe addon (diagnostics)

`probe/GuildVendettaProbe` is a throwaway diagnostic addon ([#1](https://github.com/danielgospodinow/guild-vendetta/issues/1)). It logs what the game lets addons read: combat log, death info, enemy names and levels, and guild messages. Link it the same way, play a bit of world PvP, then `/reload`. Its log is saved to `WTF/Account/<account>/SavedVariables/GuildVendettaProbe.lua`. `/gvp ping` tests guild messages; guildmates running the probe answer with a pong.

## How it works

### No server: the guild is the database

WoW addons **cannot access the internet**, because in-game Lua has no HTTP. So the list lives **inside the game, on every guildmate's PC**:

- Each player's copy is saved in the addon's *SavedVariables* file. WoW writes it on logout and `/reload`.
- The copies are kept in sync with **hidden guild addon messages**.

```mermaid
flowchart LR
    subgraph A["Thrall's PC"]
        A1[GuildVendetta addon] --- A2[(SavedVariables)]
    end
    subgraph B["Jaina's PC"]
        B1[GuildVendetta addon] --- B2[(SavedVariables)]
    end
    subgraph C["Rexxar's PC"]
        C1[GuildVendetta addon] --- C2[(SavedVariables)]
    end
    A1 <-- "hidden GUILD addon messages" --> B1
    B1 <-- "hidden GUILD addon messages" --> C1
    A1 <-- "hidden GUILD addon messages" --> C1
```

### Hidden guild messages

WoW gives addons their own message channel, `C_ChatInfo.SendAddonMessage(prefix, text, "GUILD")`. These messages:

- are delivered to **every guildmate who is online** at that moment,
- are **never shown in chat**, and only addons listening on the same prefix (`GVND`) receive them,
- are **not stored by the game**. Anyone offline simply doesn't get them, so each addon keeps its own copy of the list.

Deadly Boss Mods, RCLootCouncil and other big addons sync data the same way.

Messages are limited to 255 bytes and are throttled by the client, so large transfers are split and paced.

### The list is an event log

Like a Kafka topic, the list is an append-only log of events. The difference is that the log is copied onto every guildmate's PC instead of living on a central broker. There are two event types:

| Event | Meaning |
|---|---|
| `KILL` | One guildmate death: victim, all enemy contributors (killing blow marked), levels, zone, coordinates, time |
| `REMOVE` | "Hide this enemy's kills up to time T", with who removed them |

The list you see is **computed** from the log. An enemy shows up if they have at least one `KILL` newer than their latest `REMOVE`. Events never change once written, and merging two copies is just a union, so receiving the same event twice is harmless.

### Live updates: the death hook

The game fires an event the instant you die (`PLAYER_DEAD`). The addon builds the `KILL` event from the last 60 seconds of combat log and **broadcasts it immediately**, so online guildmates have it within about a second.

```mermaid
sequenceDiagram
    participant G as Gankston (enemy)
    participant T as Thrall's addon
    participant O as Online guildmates' addons
    G->>T: damage, damage, killing blow
    Note over T: PLAYER_DEAD fires<br/>world PvP? not a duel/BG/arena?
    T->>T: build KILL from last 60s of hits<br/>append to own log
    T-->>O: hidden GUILD message: KILL
    O->>O: append to log, refresh list
    Note over O: Gankston now on everyone's list
```

### Removal (the X button)

Clicking `[X]` appends a `REMOVE` event and broadcasts it, the same way as a kill:

- The enemy disappears from **every online guildmate's list immediately**. Offline guildmates pick it up at their next sync.
- Anyone who killed **alongside** the removed enemy keeps their kills on the list.
- If the removed enemy **kills a guildmate again**, they come back. A removal only clears kills up to the moment of removal.
- `REMOVE` events are kept forever, so an old copy of the list can't bring a removed enemy back.

### Catching up at login: sync only from online players

On login or `/reload`, your addon and the guildmates **who are online right now** compare which events each side has, and **each sends the other whatever it is missing**. Newest events go first, and the rest trickle in in the background at the game's message rate, about 1,000 events in roughly 15 minutes.

```mermaid
sequenceDiagram
    participant Y as You (just logged in)
    participant P as Online guildmates
    Y-->>P: "here's a summary of what I have"
    P-->>Y: summaries of what they have
    P-->>Y: events you're missing (newest first, paced)
    Y-->>P: events they're missing
    Note over Y,P: everyone online ends up with the union
```

The catch: **a sync can only come from guildmates who are online.** If a kill happened while you were offline and everyone who has it is offline too, you get it the next time you're online together with any one of them. The more of the guild runs the addon, the faster everything spreads.

### Proximity alerts

The game has no "scan the area" feature, so "nearby" means the enemy has been **seen by your client** in one of these ways:

- their nameplate appears,
- you target or mouse over them,
- they show up in a combat-log event near you.

That's roughly nameplate range.

```mermaid
flowchart LR
    S["Nameplate / target / mouseover / combat log"] --> M{On the list?<br/>not removed}
    M -- no --> X[ignore]
    M -- yes --> C{Alerted in the<br/>last 5 min?}
    C -- yes --> X
    C -- no --> F["Red screen flash + raid-warning message + sound"]
```

## Known limitations

- **WoW: Forever addon restrictions.** Forever reportedly uses Midnight-era rules that hide some combat data (player names, combat-log details) from addons. This is unconfirmed by Blizzard. The first task is a [probe (#1)](https://github.com/danielgospodinow/guild-vendetta/issues/1) that checks in the live client what the addon can actually read. The design may change based on the result.
- **Only the victim's client can record the kill**, because only it sees the full combat log of the death. Guildmates without the addon won't contribute kills.
- **Level may be `??`** when the game hides the enemy's level.
- **Offline catch-up needs a guildmate online** who has the missing data (see above).

## Self-hosting

There is nothing to host. Each guild's list lives in its members' game clients and is shared only over that guild's channel. Nothing is ever sent outside the guild.

## Roadmap: optional server (option B)

A later, optional add-on to the above, tracked in [#9](https://github.com/danielgospodinow/guild-vendetta/issues/9):

```mermaid
flowchart LR
    W[WoW client + addon] <--> SV[(SavedVariables file)]
    SV <--> CA["Companion app (Go)<br/>on each member's PC"]
    CA <-- HTTPS --> API["Go service<br/>(Render, or a Mac mini via cloudflared)"]
    API <--> DB[(Postgres on Neon)]
```

This would add one central history, catch-up even when nobody is online, and a possible web view of the list. The cost is that every member installs a companion app, and server data reaches the game only on `/reload` or login. Each guild could run its own instance.

## Repo layout

```
addon/GuildVendetta/       # the WoW addon (plain Lua, no libraries)
  Core.lua                 #   event log, ranked view, wire encoding, sync digests
  Capture.lua              #   60s hit buffer + death hook -> KILL
  Sync.lua                 #   hidden guild messages: live events + login catch-up
  Alerts.lua               #   nameplate/target/mouseover/combat-log detection, flash/message/sound
  UI.lua                   #   window, minimap button, settings panel, /gv
probe/GuildVendettaProbe/  # diagnostic addon for the live client (#1)
tests/                     # plain-Lua tests, no WoW needed
docs/                      # design docs
server/                    # (future) Go companion app + service, option B
```

## Development

The tests run outside the game with [LuaJIT](https://luajit.org/) (`brew install luajit`):

```bash
luajit tests/core_test.lua
```

```bash
luajit tests/smoke_test.lua
```

`core_test` covers encoding, the ranked view, removal rules and sync digests. `smoke_test` loads the whole addon as three simulated guildmates with a stubbed WoW API and runs a death, live sync, a removal, login catch-up and an alert.

## Contributing

Features and bugs are tracked in [GitHub Issues](https://github.com/danielgospodinow/guild-vendetta/issues).

## License

See [LICENSE](LICENSE).
