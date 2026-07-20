## 3.7.9

### New Features

- **Apply Look — copy a bar's style onto other bars** — Style one bar, then apply its look to all bars of that type, all bars of every type, or a hand-picked list. The Include toggles choose what gets copied, and Text is now split into Stack, Duration, Name and Ready text so you can copy exactly the part you want.
- **Skins panel cleanup + Castbar skin picker** — The Load Skin dropdown now lives inside the Skins section for every bar type, and the Castbar finally has its own, so loading a saved skin is where you'd expect it.
- **Castbar skins remember position** — Per-spec castbar skins now restore where the bar sits on screen, so switching specs puts each castbar back in its own spot. Re-save each skin once to pick this up.
- **Ignore Hard ICD for charge spells** — New per-icon option for charge spells that lock briefly after each use (like Monk's Zenith): the icon no longer looks fully spent while you still hold a charge, and the swipe shows the real recharge instead of the lockout.
- **Gained-on-cooldown spells just work** — Arc icons for spells you only have while a cooldown is active (Void Volley, Zenith Stomp) now appear when you gain them and disappear after, instead of being marked "not part of this spec" and needing Show Always.
- **Per-side Fill Inset for aura bars** — Independent Left/Right/Top/Bottom insets so custom bar textures with built-in borders sit perfectly inside the background. Contributed by Linawow.
- **Addon integration API** — Other addons can now anchor their frames to ArcUI's icon groups reliably (fixes unit frames shifting on druid form changes with MSUF, and opens the door for more integrations).

### Improvements

- **Hide stacks at zero on Arc icons** — The "Hide at 0" option now works on Arc cooldown icon stack text, everywhere including dungeons.

### Bug Fixes

- **Castbar no longer disappears mid-cast** — Casting an instant spell (like Shimmer) or pressing your next cast early no longer hides the bar or flashes a false "Cancelled", and reloading mid-cast brings the bar right back.
- **Castbar Match Size sticks after reload** — Castbars matched to a group's size no longer come back wrong after a reload.
- **Timer text no longer flickers on dimmed icons** — Cooldown text kept visible with Preserve Duration Text no longer flickers or vanishes while Ignore Aura Override is on (was worst on Fire and Storm Elemental).
- **Custom timer icons no longer blink** — Timer icons watching a spell no longer randomly flip between their Active and Not Active looks.
- **Thin borders sit flush** — 1px icon borders no longer drift a pixel off the icon at some UI scales.

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
