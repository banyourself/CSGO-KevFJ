# KevFJ

Funjump mode for CS:GO hide and seek servers. It is a practice mode: nobody can damage anyone,
knives do nothing, fast knife is on, and the round is held open for up to an hour so people
can just mess around with movement.

Forked from **amuFJ** by hiiamu (amuDev) and rewritten fairly heavily. Upstream is 459 lines,
this is 870, with roughly 750 lines added and 340 removed.

## Install

Drop the `addons` folder into your `csgo` folder:

```
addons/sourcemod/plugins/KevFJ.smx        the compiled plugin
addons/sourcemod/scripting/KevFJ.sp       source
```

No config files needed. Convars get written to `cfg/sourcemod/KevFJ.cfg` on first run.

## How it works

Players vote it on with `!fj`, or an admin forces it. While it is running:

* nobody takes damage, in either direction, and knives deal nothing
* everyone passes through everyone else, so you cannot body block
* the round clock is held open, up to an hour
* godmode, noclip, spectate and teleport are available as toggles

The vote always proposes the opposite of whatever is currently running, so the same command
turns it on and off depending on when you type it. It needs a strict majority of everyone in
the game, not just of the people who bothered to answer, so ignoring the menu counts as a no.

## What I changed from amuFJ

**It became a full gamemode instead of a timed round.** FJ has no end of its own any more, it
runs until it is voted or forced off. That meant taking ownership of the round clock, which is
most of the added code.

**Round clock handling.** `mp_roundtime` only applies from the *next* round, so the current
round gets pinned on the game rules entity as well, because the HUD clock reads
`m_fRoundStartTime + m_iRoundTime - now`. It is re-applied every round on purpose, since
hnsmix re-asserts its own round time and hnsova pins ten minutes for OVA, so FJ has to claim
the clock back each time rather than setting it once.

The `round_start` hook is deliberately **Post**, not Pre, because hidenseek hooks it as Pre and
therefore always runs first. Writing from Post means FJ writes last and its round length is the
one that survives.

**It coexists with the other gamemodes.** A mix owns the round flow, and FJ holds the clock
open for an hour at a time, so the two cannot share a server. FJ checks for an active mix on a
timer rather than only on round boundaries, because a mix can start at any moment.

**Mid-round joiners get respawned.** An FJ round can run an hour and CS:GO only spawns a
joiner at the next round start, so anyone connecting or leaving spectate used to sit dead until
the round turned over. Now they come straight into play.

**A proper admin menu** with target pickers for every action, plus a vote menu for players. Both
land on exactly 7 items, which is the most a menu page holds before Exit gets pushed to a second
page.

**A Discord hook.** It tells hnsmix's live status embed to redraw the moment FJ toggles, so the
sidebar color is correct immediately rather than waiting on the 90 second safety net.

**A native**, `KevFJ_isFJActive`, so hnsova and hnsmix can ask whether FJ owns the round.

## Commands

```
!fj              vote it on or off
!fjmenu          admin menu, or the vote for regular players
!cancelfj        cancel a running vote
```

Convars cover godmode, noclip, nocollide, spectate, teleport and the round length.

## Credits

Original **amuFJ** by **hiiamu / amuDev**:
[github.com/amuDev/amuFJ](https://github.com/amuDev/amuFJ) and on AlliedModders.

`myinfo` credits **zwolof** ([github.com/zwolof](https://github.com/zwolof)) alongside me,
carried over from the version this grew out of.

## License

GPL-3.0, see `LICENSE`.
