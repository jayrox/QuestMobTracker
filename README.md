# Quest Mob Tracker

A WoW Forever addon that tracks the quest you're working on: which mobs (or world objects) are tied to it, kills, drops, XP, gold and time.

## Install

Copy this folder to `World of Warcraft\_forever_\Interface\AddOns\QuestMobTracker\`, or create a junction so the game always loads the repo:

```powershell
New-Item -ItemType Junction -Path "C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\QuestMobTracker" -Target "C:\dev\QuestMobTracker"
```

Questie is optional. If installed, its database is used to list the mobs and objects for each quest.

## Commands

`/qmt show | hide | focus [quest] | scale <n> | alpha <n> | reset | history | debug | trace`

## Releasing

1. Bump `## Version:` in `QuestMobTracker_Forever.toc`.
2. Add an entry to `CHANGELOG.md`.
3. Commit, then `git tag vX.Y.Z`.
