## 3.7.12

### New Features

- **New Icon Routing** — Choose where newly added Cooldown Manager icons go, per category: send new Essential, Utility, or Buff icons to a specific group, to a free position, or leave the default. Set it account-wide with per-character and per-spec overrides in the Groups panel, and CDM export/import strings can now carry your routing (new "New Icons" checkboxes with a preview of where each category goes).
- **Show IDs on Hover** — New global toggle that adds an ArcUI ID readout to tooltips: cooldown ID, spell ID, override and linked spells, equip slot, item category, and the icon texture ID the Custom Icon box accepts. Works on CDM icons, Arc icons, action bars, buffs, bags and more.
- **Out of Stock look for potions and healthstones** — Cooldown Manager potion and healthstone icons get their own Out of Stock section: choose desaturation, opacity, and an optional tint for when your bags run dry, and the icon recovers the moment you restock. Dim When Out of Stock is now available on these icons too.
- **Pingable toggle (Arc Pings)** — Every icon and group gets a Pingable toggle: turn it off and pings pass straight through that icon to the world instead of announcing the hovered spell. Works on Arc icons and Blizzard's own CDM icons.
- **New sound: Kaching** — An "ArcUI: Kaching" sound is now available in every ArcUI sound dropdown.

### Improvements

- **Aura icon glows completed** — The Aura Active glow on aura icons now supports Scale, X/Y Offset, Glow Strata, and Glow Frame Level; the style dropdown shows the style actually applied; and the Preview toggle now works on aura icons, showing the glow without the buff up so you can tune it.
- **Totem, pet, and ground bars** — These bars now honor a custom Max Duration and the bar-color and countdown-text threshold coloring options.
- **Ping Keys with action bar addons** — Ping Keys now work with Bartender4, ElvUI, and mixed bar setups, and follow rebinds and profile switches without re-adding.
- **Max Duration honesty on 12.1** — For regular aura bars the Max Duration option is now locked to Auto with an on-panel explanation (12.1 removed the API for a custom maximum); totem-type bars keep their working custom max.

### Bug Fixes

- **Giant or wrong-sized CDM icons** — Fixed the intermittent bug where icons could suddenly render huge or take another icon's size, most often when opening the options panel, plus new safety guards so a bad size can never be stamped again.
- **Group renames** — Renaming a group (including Essential/Utility/Buffs) no longer brings back an empty default group every login, and no longer leaves ghost drag overlays or floating slot-number badges behind.
- **Aura icon states** — Active Alpha now actually dims the icon and swipe, Preserve Duration Text keeps the texts at full strength, and Show Icon off hides the artwork while keeping duration and stack text visible — with the icon still shown for editing while the options panel is open.
- **Pulse glow was invisible** — The Pulse glow styles on aura icons rendered nothing in real play (they only showed in the preview); they now use the Cooldown Manager's own alert flash art.
- **Potion and healthstone icons** — Fixed the errors these icons could throw from usability tint, glows, and tooltip hover; potions now stay colored while their buff is running instead of greying out immediately; and Glow When Aura Active now works on item icons.
- **Cooldown bars across specs** — Bars set to show on multiple specs no longer read "Tracking Failed" outside the spec they were created in.
- **Pet and totem bar countdowns** — Duration text on pet, totem, and ground-effect bars (e.g. Call Dreadstalkers) shows again on 12.1, and aura bars with a manual max no longer sit stuck at full.
- **Stack bars over 20 stacks** — Ticks, borders, and the At Max color no longer vanish on bars with more than 20 stacks.
- **Post-dungeon error** — Fixed an "EnableMouse on bad self" error that could appear after dungeons on icons carrying the new stack-count displays.
- **CN client crash shield** — Worked around a Chinese-client bug that could crash the game when aura countdown text refreshes; decimal countdowns on aura icons show whole seconds on the CN client until Blizzard fixes it.
- **Custom Icons form error** — Adding a Custom Icon timer by spell ID no longer errors on submit.

## 3.7.11

### New Features

- **Use Texture Colors** — A new toggle on aura, stack, duration, cooldown, charge, and resource bars plus both castbars: show your fill texture's own colors (gradients, rainbows, artwork) instead of tinting it with the bar color. Color controls that no longer apply gray out and say why.
- **One voice for the whole addon** — Everything that speaks (Cooldown Reminder, CDM aura alerts, Arc icon alerts) now shares one Voice and Speech Rate setting and respects your Text-to-Speech volume. New speech controls include a Test Voice button, the "sound between messages" tick toggle, and a shortcut to WoW's own speech options.
- **Ignore Spell Overrides for Arc spell icons** — A new per-icon toggle that keeps an Arc spell icon on its base spell's cooldown, artwork, and glows even while the spell is temporarily overridden.

### Improvements

- **Auto-Track Trinket Slots got their own section** — The trinket auto-track controls moved out of the filter dropdown into a collapsible section right under Global Options, and an auto-tracked icon's Enabled toggle now drives the slot setting itself, so turning one off finally sticks across reloads.
- **Proper alert sound pickers** — CDM aura alert dropdowns now show sound names with a preview button instead of raw file paths, and sound and speech can be set independently for every alert.
- **Icons stay honest through spec changes** — An icon could keep an "aura active" look or a stuck ready glow after changing specs; ArcUI now re-checks every icon once the Cooldown Manager finishes shuffling and clears anything stale automatically.

### Bug Fixes

- **CDM aura alerts fire again** — The alert feature was silently broken, and it now also covers icons the Cooldown Manager creates mid-session in dungeons.
- **Potions and healthstones get cooldown visuals** — Bag-item icons in the Cooldown Manager never dimmed or dropped their ready glow. Item icons' ready glow also no longer stays on through the whole cooldown, and Ignore Aura Override now works on them.
- **Custom Icon field works again** — Entering a spell, item, or icon ID in the Custom Icon box threw an error on every keystroke.
- **Custom icons stop flickering in combat** — A custom icon could snap back to the original artwork and flip between the two mid-fight, especially in dungeons.
- **Stack bars show their countdown in combat** — A stack bar's duration text went blank the moment combat started.
- **Settings apply without a reload** — Changing countdown color thresholds, visiting the options panel, or flipping a bar between Stacks and Duration mode could silently kill a bar or texture countdown until a reload, especially after a fight.
- **Textures added by spell ID count down** — Their duration text and drain never attached at all.
- **Hiding an icon keeps its texts** — With Show Icon off, the stack count and countdown vanished along with the icon art instead of floating on their own.

## 3.7.10.d

### Improvements

- **Hide When Inactive in the Catalog** — The Hide When Inactive toggle is now available directly on each bar's row in the Aura Catalog next to Hide CDM Icon/Bar, so you no longer need to dig into the Appearance tab for it.

### Bug Fixes

- **Stack text settings now survive reloads** — Show at 1 Stack and stack color bands on aura icons and CDM icons no longer silently stop working after a reload or login.
- **Double stack numbers in dungeons** — Fixed CDM icons sometimes showing two overlapping stack counts inside dungeons.
- **Stuck stack count on target swap** — Fixed CDM icons sometimes keeping the previous target's stack count after switching targets.
- **Stack display vanishing mid-dungeon** — Fixed the CDM icon stack display disappearing for the rest of a dungeon after the Cooldown Manager rebuilt its icons; it now follows the icon through rebuilds, even in combat.
- **Buff on Pet bar empty after reload** — Fixed Buff on Pet bars (e.g. Dark Transformation) showing an empty fill after a reload.
- **Tooltip errors on scenario widgets** — Fixed errors when hovering scenario/affix spell displays with Spell IDs in Tooltips enabled.

## 3.7.10.c

### New Features

- **Track buffs on your pet** — A new "Buff on Pet" type for duration bars and a "Buff (pet)" mode for aura icons, for buffs your pet carries (like Dark Transformation) that normal tracking can't see.
- **Stack colors and Show at 1 Stack are back on 12.1** — Color the stack number by stack count and show it even at a single stack, on both aura icons and Cooldown Manager buff icons — working everywhere including raids and Mythic+. Changes apply instantly, and the color band controls got a cleaner layout.

### Bug Fixes

- **Icons stay colored while their buff is active** — A cooldown icon could stay grayed out through the whole buff after the last update.
- **No more duplicate icons after importing a profile** — Importing could leave an unclickable copy of an icon in your row, and sometimes an empty floating square.
- **Aura glow timing options tell the truth on 12.1** — The % and seconds glow thresholds cannot work on 12.1 (an aura's remaining time is protected), so those modes are removed there and saved thresholds behave as Always. CDM Pandemic Timing still works exactly.
- **CDM Timer Mirror options say what applies** — Fill mode, smoothing and conditional color cannot affect mirrored bars; they are now disabled with an explanation instead of silently doing nothing.
- **Panels look right alongside other addons** — With many addons installed, another addon's copy of a shared library could flatten ArcUI's side-by-side option layouts.

## 3.7.10.b

### Bug Fixes

- **Aura icon countdown colors work again** — The countdown text on tracked buff and debuff icons changes color at your thresholds again, everywhere including raids and Mythic+.
- **No more floating empty border after a combat reload** — A square border with nothing inside could appear at the Cooldown Manager's default position after reloading mid-fight. Icon borders now only draw around icons that actually have art.

## 3.7.10.a

### Improvements

- **Loads on 12.0.x again** — For players whose game client has not updated to Midnight 12.1 yet, ArcUI no longer shows as incompatible. The new 12.1 features stay dormant until your client is on 12.1, and the What's New window waits for it too.

## 3.7.10

### New Features

- **Aura Icons — track any buff or debuff by spell ID** — Give it a spell ID and you get an icon for that aura, whether or not the Cooldown Manager knows about it. They keep working in raids and Mythic+, where addons are no longer allowed to read your auras: a dimmed ghost while the aura is missing, the real icon while it is on you.
- **Spell-ID Aura Groups** — Aura icons get their own group type that flows and compacts like any other Arc group, with its own border, title, drag mode, visibility conditions and per-spec profiles.
- **Aura alert sounds** — Play a sound the moment an aura lands, refreshes or drops. The game plays these itself, so they still fire in content where aura tracking is hidden from addons.
- **Cooldown Manager aura alerts** — Sounds and spoken callouts for buffs and debuffs tracked by the Cooldown Manager, with separate triggers for gaining it, losing it, and stacks going up.
- **Refresh-window glows** — Aura icons can glow during the pandemic window, so you know exactly when reapplying is worth it.
- **Aura bars and textures by spell ID** — The Aura Catalog has a new green Add tile: enter a spell ID and it joins the catalog, so the same buttons build a duration bar, a stack bar or a texture for auras the Cooldown Manager never sees.
- **Ping Keys and the Ping Feed** — Call your cooldowns out to your group with one key and no macros, and read everyone's pings in a window you can lay out yourself.
- **New Add window for Arc icons** — One place to add items, trinkets, spell cooldowns, aura icons and custom timers, with a drag-and-drop zone.
- **One Icon Catalog** — The Arc Icons and Custom Icons tabs are gone: every icon, its settings, load conditions, the timer editor, auto-tracking and bulk management now live together in the Icon Catalog.
- **Guided tours** — The What's New window can now walk you to exactly where the new features live.
- **Stack Priority for free icons** — Free-positioned icons get a Stack Strata and Stack Level control in Icon Positioning, so you decide exactly which icon draws on top when icons overlap. The whole icon moves together — glows, text and keybinds follow.

### Improvements

- **Aura Textures work again on 12.1** — Progress and Drain textures are driven by the game engine now, so the art still drains during combat and inside instances.
- **Bulk management for Arc icons** — Clear all spells, all aura icons or everything at once, and force a refresh of Arc frames.
- **Layout safety warning** — Loading a profile while layouts are linked can overwrite the shared layout on every character. The first time you do something risky, ArcUI explains it once.
- **Smoother resource bars** — Energy and other fast-regenerating bars moved in visible chunks out of combat. They now update ten times a second while regenerating, and still cost nothing at rest.
- **One line at login** — ArcUI now prints a single load message instead of a stream of module chatter.
- **Fewer cooldown updates per keypress** — Icons only react to cooldown events that actually concern them, cutting the work done on every cast of any ability.

### Bug Fixes

- **Replacement spells show their real cooldown** — Spells that get swapped out by a talent or a proc (Stormstrike becoming Windstrike under Ascendance, Flame Shock becoming Voltaic Blaze) were read from the original spell, so those icons looked like they were never on cooldown. They now follow whichever form is live, and the icon art follows it too.
- **High-haste cooldown flicker fixed** — Cooldown icons no longer blink ready for a split second mid-cooldown when you press other abilities, which got worse the more haste and cooldown reduction you had. Any cooldown read taken while a global cooldown is running now re-checks itself the moment that global ends, on both Arc icons and Cooldown Manager icons.
- **Cooldown Manager icons gray out on cooldown again** — Managed icons could stay full-color while on cooldown even though Arc icons of the same spell grayed out correctly. ArcUI now drives the gray-out itself instead of relying on the game's, which silently stops working on styled icons.
- **Totem icons no longer stick as active** — A totem icon could keep showing as active after the totem was gone, most visibly on Earthbind.
- **Charge numbers no longer vanish on faded groups** — A group at partial opacity hid its charge text completely until you opened the CD Manager panel.
- **On-use trinkets no longer go missing at login** — A trinket whose data had not loaded yet was treated as passive and hidden by the On-Use filter until you toggled auto-track off and on.
- **Layouts no longer look like they reset on every relog** — A phantom spec entry created early at login made ArcUI read and write the wrong spec's layout depending on timing.
- **Cooldown Reminder fires for buff-consumption cooldowns** — Spells whose cooldown only starts when the buff is spent never armed their ready reminder.
- **Bars and textures survive a combat reload** — Reloading mid-fight or inside a dungeon could leave a duration bar's fill frozen and an aura texture's art static for the rest of the session, because they only set themselves up if the aura happened to be active at the right moment. They now set up as soon as they know which aura they track.
- **Aura texture art shows its real colour** — Progress and Drain art could come up with the dimmed "missing" colour baked in instead of the active one.
- **Duration text settings apply on 12.1 bars** — Decimals, abbreviation and colour-by-time were being ignored on engine-driven bars.
- **Bar fill no longer bleeds over the border**, and tick marks come back on bars that hide when inactive.
- **Unit frames stay put** — Addons anchored to Arc icon groups no longer drift when the group is rebuilt.
- **Charge bars hide for spells your build doesn't know** — A charge bar for an untalented spell (like Healing Stream Totem on Elemental) stayed on screen as an empty black frame instead of hiding.
- **The Utility group keeps its column count** — Column settings could creep back to their default after a reload or relog.
- **Trinkets keep their slot** — A trinket icon could get bumped out of its saved position by another icon claiming the same cell during login or a spec change.
- **Cooldown Reminder panel grays out while the module is off** — so it is clear those settings will not do anything until you enable it.

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
