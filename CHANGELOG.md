# Changelog

Versions follow [Semantic Versioning](https://semver.org): MAJOR.MINOR.PATCH.

## 0.4.19

- The hand-in location (NPC, continent, zone, coordinates) sits in its own small grey block with a gap below the quest's objective text, and the objective text starts at the top of its card instead of hanging out of the bottom.
- README: install, what it shows and a description of each command.

## 0.4.18

- Quests whose objectives are object interactions (`0/1 Bloodsail Trunk examined`, "used", "activated") are now tracked too. Before, such a quest was ignored, so focusing it in the game's tracker left the window on the previous quest. Quests that are ready to turn in are tracked too, even when no countable objective is left (for example "Return to X"), so they can be focused and show their reward on the XP bar.
- When a quest has nothing to count, the card shows the quest's own objective text (for example "Speak with Witch Doctor Uzer'i...") instead of "No kills yet" / "No drops yet". With Questie installed, a second line gives the hand-in NPC or object, continent, zone and coordinates.

## 0.4.17

- Fixed `attempted to index a table that cannot be indexed with secret keys` (repeating once a second): this client can return "secret" GUIDs and names, which can't be used as table keys. Unit GUID/name lookups now skip secret values, and so does the loot-source GUID.

## 0.4.16

- Quests completed (session tooltip) now counts only definite turn-ins, so abandoned quests are not counted: the game's `<quest> completed.` message, the `QUEST_TURNED_IN` event, a quest leaving the log within 3s of a quest reward line (`Experience gained` / `Received <money>`), or Questie's `RegisterForQuestUpdates` API (backup, if Questie is installed).
- Session quest XP and gold come from the game's reward lines (`Experience gained: N.`, `Received <money>.`) instead of lookups; the reward money line is no longer credited to a looted mob.
- An XP-message kill only leaves its loot-claim marker when it counted the kill, and the marker is released when the corpse is identified, so it can't swallow a later loot-only kill.
- `/qmt kills` detail line adds turn-in and quest XP counters; `/qmt trace` prints turn-in lines.

## 0.4.15

- Nameplate kill detection: every visible creature nameplate is watched (`NAME_PLATE_UNIT_ADDED/REMOVED`, `UNIT_HEALTH` on the plate, plus the 1s check). A dead, not tap-denied creature counts as a kill even when it was never targeted.
- XP-message kills only leave a loot-claim marker when they are the ones that counted the kill, so a kill already counted from its nameplate can't swallow a later loot kill.
- Removed the `UnitHealth` read from the target-death check (hidden value on this client family; `UnitIsDead` is enough).

## 0.4.14

- Kill detection: this client delivers no combat log events (registering `COMBAT_LOG_EVENT_UNFILTERED` raised ADDON_ACTION_FORBIDDEN), so it is no longer registered.
- Looting a creature corpse that nothing else counted now counts a kill (also catches grey mobs); `LOOT_READY` is handled so auto-loot works. An XP-message kill claims its corpse's loot so it isn't counted twice.
- The target is also checked for death once a second, since `UNIT_HEALTH` is sparse here.
- Turn-ins are detected when a completed quest leaves the log (no `QUEST_TURNED_IN` event).
- `/qmt kills` shows which paths counted kills plus detail counters; `/qmt trace` prints each kill and the path that counted it; `/qmt debug` and `/qmt kills` show the addon version.
- Events are registered one per line, with a check that names any event the client blocks.

## 0.4.13

- XP bar: light purple segment after the green one showing where the bar would reach if the shown quest were completed; follows the focus, with a tooltip line.
- "Left your log" message reports total time in log, with active time in brackets.
- No longer registers COMBAT_LOG_EVENT_UNFILTERED (protected in this client; it raised ADDON_ACTION_FORBIDDEN).

## 0.4.12

- XP bar: thin dark dividers between each completed quest's share of the green section.
- XP bar tooltip: session block with quests completed, quest-related XP earned and gold earned (since login; turn-in rewards via `QUEST_TURNED_IN`).
- Objective lines are colored by progress, red through orange and yellow to green when complete.

## 0.4.11

- Gold: money looted a second or more after the loot window closed is now credited to the last corpse opened (10s window); `/qmt trace` also prints money lines.
- Drops tile uses the quest log's item count when it is higher than what was seen dropping, with a tooltip explaining the difference.

## 0.4.10

- Fixed 0.4.9: kills and XP stopped counting for mobs that Questie doesn't list for a quest (the handler errored). Unmatched mobs are held in memory again and claimed when they drop the quest item.

## 0.4.9

- Only mobs related to a quest are counted for it: kill objectives, Questie's mob/object list, or (without Questie) a mob that drops the quest item. Unmatched mobs are held in memory only and claimed when they drop the item.
- Every quest in the log tracks its own mobs and items regardless of which quest is shown.
- Fixed: a saved "Next quest" peek could become a permanent lock.
- Quest reward lookups are cached; per-mob lookup tables are pruned.
- Removed unused code (button helper, soft-focus logic), merged duplicate kill counting.

## 0.4.8

- Item values from Auctionator (optional dependency) and the game's vendor price in the source tooltips and the Gold tile tooltip.
- Source tooltips laid out like Auctionator's own: item link, then Vendor / Auction lines with coin icons, plus totals.

## 0.4.7

- Level progress bar along the bottom: current XP (blue), reward XP of completed quests (green), remaining (blank), with a tooltip.
- Removed the Auto / Next quest / Reset quest buttons; use `/qmt focus` and `/qmt reset`.
- Source row tooltips list every item each source has dropped, not just quest items.

## 0.4.6

- Source list shows 5 rows and scrolls with the mouse wheel.
- Sources are sorted by items dropped, then drops, then kills.

## 0.4.5

- Objective list moved inside the latest-drop card.
- Dropped the "just now" age from the latest drop/kill line.
- XP and Gold tiles have a tooltip with mob earnings, quest reward and total (reward read from the game API or Questie when available).

## 0.4.4

- Objective list (up to 5 kill/item objectives, green when complete) under the latest card.

## 0.4.3

- Follows the quest focused in the game's tracker; stays on it until another quest sees a kill or loot.
- "Next quest" is now a 20-second peek instead of a lock. Only `/qmt focus` locks.
- Shorter pre-kill timer label: `in log 3:55:22`.

## 0.4.2

- Redrew the icon's "!" to match the in-game quest marker (gold, tapered, dark outline).

## 0.4.1

- Added an addon-list icon (`icon.tga`, generated by `tools/make_icon.py`) and `## IconTexture` in the `.toc`.

## 0.4.0 - initial repository import

- Reads the quest log and tracks quests with kill or item objectives.
- Matches mobs to quests: kill objectives directly, item objectives by learning drops, plus the optional Questie database (mobs and world objects).
- Auto-focuses the quest for the mob you target or kill; `/qmt focus` to lock one.
- Counts kills from target death and the XP message, since this client sends no combat log events.
- Credits loot to the last mob killed or looted, or to a world object read from the tooltip.
- Active timer (first kill onwards, pauses after 60s idle) and idle timer; both freeze when the objectives are complete.
- Stat tiles, latest drop/kill card, per-source table, `/qmt scale` and `/qmt alpha`.

### Known issues

- Sessions that predate the active/idle timers carry their old running time as active time.
- Loot can be credited to the wrong mob if looted more than 90 seconds after the kill or out of order.
