# DPS Meter for Hailstone

A damage meter for the [Hailstone](https://github.com/projecthailstone) EverQuest client. It runs as a Lua script
with a small **DPS Meter** window that shows the damage per second of you and your group, and a details window with
every fight kept.

## The windows

**The meter** opens when the script starts. It shows:

- the group's damage per second in large type, with the fight's name, its length and the damage done;
- a graph of the last 40 seconds;
- a bar per player, coloured by class: their damage per second, damage and share. Your own bar is outlined.

- under the bars, the **platinum** you loot and the **AA** you gain **per hour**. Hover the strip for the totals
  and since when.

The window fits what it shows: it grows smoothly as players join the fight, up to the number of bars set in the
options (6 at first), and shrinks back when fewer took part, so it never has empty space at the bottom.

**Fight / Session** switches between the fight going on now (or the last one) and every fight kept, added up. A click
on a bar opens the details on that player. Drag the window by an empty spot; drag its bottom-right corner to scale it.

**The details** open from the meter's list button, or with `/dps details`. The fights are down the left, newest
first, with the **Session** at the top. For the fight you pick:

- **Totals:** damage, the group's damage per second, yours and your share, and the damage taken.
- **A graph of damage per second:** the group's as a filled area and the top five players as lines, as a 5-second
  average. Hover it to read any second. For the session it is a bar per fight; click a bar to open that fight.
- **For the session, platinum and AA:** platinum looted and sold, platinum per hour, AA gained and AA per hour. **Reset
  per hour** starts counting again from now.
- **Damage done:** each player's damage, share and rate. Hover a row for hits, misses, crits, the rate while hitting
  and the biggest hit. Click a row to see that player's abilities beside the table: melee by attack, spells, damage
  over time by spell, the damage shield, and their pet's part.
- **Damage taken:** who on your side took how much, and which mobs dealt it.
- **Mobs:** each mob's damage taken and dealt, and who slew it.

**End fight** ends the fight now. **Delete** forgets a fight you no longer want. The gear at the bottom left opens
the options.

## What counts

A fight starts with the first hit between your side and an NPC. Your side is you, your group and their pets, or
every player with **Everyone** in the options. The fight ends once nothing has hit for 6 seconds (you can change
this), or 2.5 seconds after a kill. A pet's damage counts for its owner unless you turn that off. Swarm pets count
too, since their names start with their owner's.

The damage is read from the combat lines in your chat, as most EverQuest parsers read the log:

- What your chat filters hide is not counted. To count other players' hits, keep "others' hits" shown.
- The hit display options must show full sentences, which is the default. The short and number-only modes leave out
  who hit.
- A pet's spells do not show their damage in chat, so only a pet's melee counts.
- The server sends damage over time and damage shield lines only to the caster. Another player's damage over time
  counts only when the server sends it to you as "has taken ... damage from <name> by <spell>".

## Platinum and AA per hour

These count from when the script starts (or `/dps reset`), over the whole time, in and out of fights. Each needs
a minute of time behind it before it shows a rate per hour; until then the meter shows what you have so far.

- **Platinum** is the coin you loot: the "You receive ... from the corpse." and "... as your split." lines. Coin
  from merchants, trades or the bank does not count.
- On a server with **NMSloot**, the coin it gets you for the items it sells counts too (the
  "[NMS] <item> sold for ..." lines). The meter's tooltip and the session's Platinum tile show loot and sales apart.
- **AA** is your AA experience: each point gained, plus the progress toward the next. Spending points does not
  lower it. Your AA experience slider decides how much of your experience goes there.

## Installing

1. On Hailstone's login screen, click **Add-ons**, paste `https://github.com/projecthailstone/hailstone-dpsmeter`,
   press Look, then Install. The card lists what it asks to do, and it gets no more than that. (To install by hand,
   copy the `dpsmeter` folder into the `scripts` folder of your Hailstone folder, so that you have
   `scripts/dpsmeter/init.lua`.)
2. In the game, type `/lua run dpsmeter`. To start it at every login, tick Autorun in the Lua Scripts window, or add
   it to `hailstone.ini`: `scripts.autoload = dpsmeter`.
3. Hide or show the meter with `/dps`, or from the EQ menu: **Plugins > DPS Meter**.

The windows are drawn for the Modern UI.

Settings and the fights are kept per server and character in `scripts/config/dpsmeter/`.

## Commands

| Command | |
|---|---|
| `/dps` | show or hide the meter |
| `/dps details` | show or hide the details |
| `/dps end` | end the fight going on now |
| `/dps clear` | forget every fight kept |
| `/dps rates` | platinum and AA so far, and per hour, in chat |
| `/dps reset` | count platinum and AA per hour from now |
| `/dps everyone`, `/dps group` | count every player, or only your group |

## For server owners

DPS Meter is an ordinary player script, so your `hailstone.cfg` decides whether it runs at all
(`[scripts] player = on` and the capabilities in `player_caps`). It needs `read`, `commands` (for its `/dps`
command), `events` and `ui`. It only reads: it never targets, casts, moves or speaks.

## Releasing

```sh
tools/release.sh 1.0.0             # runs the tests, packs and signs into release/v1.0.0/
tools/release.sh 1.0.0 --publish   # the same, then a GitHub release of this repository
```

The script's header lists what it needs: a client checkout with `hailstone_sign` built, and the add-on key. Keep
signing with the same key: a player's client pins the first key it sees and refuses an update signed with another.

## Licence

MIT (see `LICENSE`).

## Development

The line parser and the fight bookkeeping are tested with plain Lua 5.4:

```sh
lua5.4 tests/run.lua
```

`dpsmeter/init.lua`, which reads the game, and the window are not covered by these tests. Try them in the client.
