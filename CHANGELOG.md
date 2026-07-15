## 3.7.8

### New Features

- **Focus Castbar: Hide Non-Important Casts** — Show the focus castbar only for casts Blizzard marks as important (the dangerous ones), so it stays out of the way during trash. Off by default.
- **Global Font & Texture** — Set your font and bar texture once and apply them everywhere at once (all bars, both castbars, and cooldown text) instead of changing each one by hand.

### Improvements

- **Match Icon Edges now works on aura bars** — Lines your aura bars up neatly with your icon group, the same way it already does for the other bar types. If you already had it on, the bar will snap into place.

### Bug Fixes

- **Stacks and timers show again** — Fixed aura stack numbers and duration timers that had stopped showing for some players.
- **Midnight (12.1) fixes** — On the upcoming Midnight patch, duration bars and aura textures now keep working properly in combat.

## 3.7.7

### New Features

- **Patch 12.1 (Midnight) Support**: ArcUI now runs on the 12.1 Midnight PTR. The new patch changes how buffs and debuffs can be read, which used to break large parts of the addon. ArcUI now detects the new restrictions and adapts, so your bars, cooldown icons, and aura tracking keep working. The few options the new rules make impossible are disabled on 12.1 and clearly marked in the panel (they still work normally on live). This is a work in progress and may have rough edges, but the addon is now usable on 12.1 instead of breaking.
- **Focus Castbar**: A castbar showing what your focus target is casting, with spell name, timer, and icon. Color it differently for spells you can't interrupt or hide those entirely, show a marker the moment your interrupt comes off cooldown, keep the bar on screen briefly after a cast (colored for success, fail, or interrupt), and add a glow for important casts. Off by default, under Castbar > Focus Castbar. Contributed by Seraidi.
- **Dim or Hide a Cooldown Icon While Its Aura Is Active**: A per-icon option to fade or fully hide a cooldown icon while the buff it tracks is up, so an icon that is already in use gets out of the way. Off by default.

### Improvements

- **Collapsible Option Sections**: The Cooldown Reminder appearance and audio panel and the Custom Auras and Cooldowns lists now use collapsible headers so long panels are easier to scan.

### Bug Fixes

- **Cooldown Reminder: No False Alert on Windup Items**: Items with a short effect window before their real cooldown (like the Algari Puzzle Box) no longer announce "ready" the instant the effect ends.
- **Cooldown Reminder: Reminders Work Immediately When Set Mid-Cooldown**: A reminder created or edited while the spell or item is already on cooldown now starts tracking right away.
- **Instance and Mythic+ Stability**: Totem cooldown bars and secondary-resource bars (such as Soul Fragments and Maelstrom Weapon) no longer risk errors inside dungeons and raids.

## 3.7.6

### New Features

- **Kick Assist Interrupt Alert**: Get a sound or spoken (text-to-speech) alert the moment your focus starts casting and your interrupt is off cooldown, so you know to look and kick. Pick from built-in alert sounds or any shared-media sound, choose the channel, set your own spoken word, and preview it. Off by default.

### Bug Fixes

- **Single-Charge Spells as Cooldown Bars**: Spells with a single charge, like Evoker's Fire Breath, now show up in the cooldown bar picker and track as a normal cooldown, instead of being mistaken for a charge spell and showing a 0/1 count.
- **Aura Threshold Glows on Self-Buffs**: Fixed threshold glows on tracked buff and debuff icons that could fail to fire for personal buffs, so they now light up reliably as the aura nears your set threshold.
