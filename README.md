# ArcUI

A World of Warcraft addon for WoW 12.0 (Midnight) that adds tracking bars, custom icon groups, and cooldown tooling built on top of Blizzard's native CooldownViewer (CDM).

**Current version:** 3.6.8  
 
**Related addon:** ArcUI_ProcTracker

---

## What it does

### Tracking Bars
Horizontal bars that track buff/debuff durations, stack counts, resource levels, cooldowns, charges, and custom timers — anchored to CDM group containers or positioned freely. Bars update event-driven (no polling).

- **Aura bars** — buff/debuff duration and stack tracking with threshold highlights and tick marks
- **Resource bars** — primary and secondary power with smoothing, segmented/fragmented display modes, spell-cost forecasting, and per-spec auto power profiles
- **Cooldown & charge bars** — per-spell cooldown progress with charge tracking
- **Timer bars** — custom timers with configurable triggers (cast events, cooldown events, procs)
- **Appearance presets** — save and apply skins across bar types; library stored globally

### CDM Integration
ArcUI attaches to Blizzard's CooldownViewer to extend every icon it manages.

- **Icon groups** — drag-reorganize CDM icons into custom groups with grid/flex layouts, per-spec profiles, and visibility conditions (combat, mounted, group size, etc.)
- **Icon styling** — custom glow types (pixel, autocast, proc, Blizzard ants), alpha/desaturation for inactive states, cooldown text color curves, custom labels (up to 3 overlays per icon), keybind text
- **GCD filter** — strips the GCD swipe from cooldown icons so it doesn't obscure real cooldowns
- **Spell usability tinting** — vertex color tinting when a spell can't be cast, with optional glow
- **Arc Auras** — custom item, trinket, or spell icons that live in CDM groups but track whatever you want, including custom timers with stack modes
- **Assisted Combat Highlight** — mirrors Blizzard's "next cast" highlight on CDM and Arc Aura frames
- **Button Press Highlight** — flash or hold overlay on button press via action/cast hooks
- **Masque support** — optional skin registration for CDM and Arc Aura frames

### Cooldown Reminder
Watches for spell and item cooldown-ready transitions and fires queued pulse animations, sounds, TTS, and per-trigger glows. Configurable per spell with priority ordering.

### Custom Tracking
Deterministic aura/cooldown engine driven by `UNIT_SPELLCAST_SUCCEEDED`. Supports stacks, decay timers, modifier conditions, and talent/spec gating — for cases where UNIT_AURA isn't reliable enough.

### Import / Export
Single import window that auto-detects string type (bars, CDM layout, master export, or Cooldown Reminder) and routes to the right importer. Master export covers all characters and specs in one string. Shared profiles let same-class alts sync their CDM layout by reference.

---

## Slash commands

| Command | What it does |
|---|---|
| `/arcui` or `/ab` | Open options |
| `/arc` | Arc Auras manager |
| `/arcuicr` | Cooldown Reminder options |
| `/arcrepair` | SavedVariables cleanup (ghost bars, corruption) |
| `/cdbar` | Cooldown bar debug/management |
| `/arcmasque` | Masque group registration |

---

## Requirements

- Blizzard CooldownViewer must be **enabled** in the Edit Mode layout you're using
---

## Notes

- All features default to **off** — nothing changes until you enable it
- Settings are per-character, per-spec, with optional global defaults
- SavedVariables: `ArcUIDB`
