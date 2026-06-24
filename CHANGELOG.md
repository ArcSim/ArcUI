## 3.7.5

### New Features

- **Aura Textures**: A new Buffs/Debuffs display type. Place any image on screen that turns on when a buff or debuff is active and off when it's gone. Pick from a built-in art gallery or your own file, drag and resize it in place, and optionally make it drain like a bar as the aura runs down, pulse, fade as it expires, or show a built-in countdown, with per-spec/talent and Hide When conditions.
- **Duration Text Threshold Colors**: Aura bars and Aura Textures can recolor their remaining-time countdown through seconds-based thresholds, so the number changes color as the aura nears expiry.
- **Stack Threshold Colors**: Color a tracked buff's stack number by how many stacks are up, with up to six adjustable count-and-color bands, working even in Mythic+ and instances.
- **Show Icon Toggle**: A new per-icon switch hides the icon art, swipe and flash while keeping just the stack and duration text, for clean text-only trackers.
- **Desaturate When Aura Inactive**: A new per-cooldown-icon option grays out the icon whenever its tracked buff drops, for an at-a-glance signal that the buff is down.
- **Kick Assist Smart Open**: An opt-in mode that, after a ready check, briefly watches party chat and only opens the marker picker if someone else calls out your marker, so you only re-pick when there's an actual clash.

### Improvements

- **Reorganized Options Menu**: Settings are regrouped for clarity, with a Buffs/Debuffs section gathering the aura Catalog, Textures and Appearance, and a dedicated Cooldowns section gathering Cooldown Bars, Custom Bars and Cooldown Reminder.
- **Bars Stay Out of the Way**: Cooldown, charge, resource, custom and timer bars are now click-through during normal play and only become draggable while the options panel is open, so they no longer intercept clicks in combat.
- **Bar Name Text Fine-Tuning**: Buff and debuff bars now expose X and Y offset on their name text, so you can nudge it after choosing a left, center or right position.
- **Cooldown Display Stability**: Further back-end hardening of the cooldown icon display to reduce the chance of it breaking partway through Mythic+ or other instanced content.
- **Kick Marker Stays on Your Focus**: Your interrupt marker is always placed on your focus and stays there, so re-pressing your kick key never moves it onto your current target.
- **Account-Wide Kick Assist Toggle**: Turning Kick Assist on or off now applies to all your characters, with your existing setting carried over automatically.
- **Clearer Marker Macro Wording**: Macro templates and the editor use a clearer marker placeholder and a renamed Add / Sync Marker Line button; older macros keep working.
- **Clearer Dynamic Cooldowns Help**: The Dynamic Cooldowns option now explains that an icon only collapses out of the row when its alpha is set to 0, and points you to the exact setting.

### Bug Fixes

- **Bar Text Alignment**: Left- and right-aligned bar name and duration text now pin their first character to the chosen edge instead of centering on it, so long names read correctly and no longer drift.
- **Resource Text Color in Instances**: Fixed resource bar value text that could break its threshold coloring inside dungeons, raids and PvP.
- **Self-Buff Icons Display Correctly**: Cooldown icons, custom labels and glows that track a personal self-buff (like Voidfall) now correctly recognize the buff as active instead of treating it as missing.
