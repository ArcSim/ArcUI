-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_CustomIcons_Presets.lua
--
-- A library of ready-made custom timer configs the user can one-click add
-- from the Custom Icons tab. Each entry is pure data — no behavior, just a
-- config table that gets handed to ArcAurasTimer.AddTimer when the user
-- clicks "Add" on the preset.
--
-- A preset is:
--   {
--     id          = "shaman_natures_guardian",  -- stable key (for de-dupe)
--     name        = "Nature's Guardian",        -- display name
--     classToken  = "SHAMAN",                    -- nil = universal, else UnitClass() token
--     category    = "Defensives",                -- free-form group label
--     description = "Health threshold proc ...", -- shown in tooltip
--     spellID     = 31616,                       -- effect ID (may differ from talent ID)
--     duration    = 45,
--     opts        = { startTrigger = {...}, endTrigger = {...} },
--   }
--
-- Adding a new preset is just appending a table to the list below. No code
-- changes required. Keep presets minimal and well-tested before shipping.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

-- Public registry. Options UI iterates this list to render the picker.
ns.CustomIconsPresets = ns.CustomIconsPresets or {}

-- ─────────────────────────────────────────────────────────────────────────
-- SHAMAN
-- ─────────────────────────────────────────────────────────────────────────
table.insert(ns.CustomIconsPresets, {
    id         = "shaman_natures_guardian",
    name       = "Nature's Guardian",
    classToken = "SHAMAN",
    category   = "Defensives",
    description = "Passive health-threshold self-heal proc. The talent ID (30884) "
        .. "doesn't expose a cooldown to addons, so this preset watches the EFFECT "
        .. "spell ID (31616) that fires when the proc triggers. 45-second internal "
        .. "cooldown — the timer matches that window.",
    spellID    = 31616,
    duration   = 45,
    opts = {
        startTrigger = {
            events          = { cooldown = true },
            restartOnRefire = false,
        },
        endTrigger = {
            events = { death = true },
        },
    },
})

-- ─────────────────────────────────────────────────────────────────────────
-- UNIVERSAL (all classes & specs)
-- ─────────────────────────────────────────────────────────────────────────

-- Alnscorned Essence (TWW season trinket). The on-equip / proc effect
-- spell ID is 1266687, with a 12-second buff window per stack. Stacks
-- overlap — each application has its own independent expiry — which is
-- why the preset uses Independent stack mode. Cooldown event start with
-- restartOnRefire so each new proc both extends the swipe and pushes a
-- fresh per-stack expiry into the list.
table.insert(ns.CustomIconsPresets, {
    id         = "trinket_alnscorned_essence",
    name       = "Alnscorned Essence",
    classToken = nil,           -- universal trinket
    category   = "Trinkets",
    description = "Tracks the Alnscorned Essence trinket buff (12s per stack, "
        .. "overlap-style). Uses Independent stack mode so each application "
        .. "falls off on its own timer. Ideal for visualizing how many "
        .. "stacks are about to drop and when.",
    spellID    = 1266687,
    duration   = 12,
    opts = {
        startTrigger = {
            events          = { cooldown = true },
            restartOnRefire = true,
            trackStacks     = true,
            stackMode       = "independent",
        },
        endTrigger = {},
    },
})

-- Algeth'ar Puzzle Box (Vault of the Incarnates trinket — still BiS-tier
-- in many builds for the on-use haste). Active spellID is 383781, 20s
-- duration on use. Cast-success start (you're the one pressing the
-- button), death end so the icon clears on a wipe.
table.insert(ns.CustomIconsPresets, {
    id         = "trinket_algethar_puzzle_box",
    name       = "Algeth'ar Puzzle Box",
    classToken = nil,           -- universal trinket
    category   = "Trinkets",
    description = "Tracks the Algeth'ar Puzzle Box on-use haste buff (20s). "
        .. "Starts on cast success, stops on player death so the icon "
        .. "doesn't keep ticking through a wipe.",
    spellID    = 383781,
    duration   = 20,
    opts = {
        startTrigger = {
            events          = { cast = true },
            restartOnRefire = false,
        },
        endTrigger = {
            events = { death = true },
        },
    },
})

-- Light's Potential. War Within combat potion buff, 30-second duration,
-- spellID 1236616. Starts on cast-success when the player drinks the
-- potion, stops on death so the icon clears through a wipe.
table.insert(ns.CustomIconsPresets, {
    id         = "universal_lights_potential",
    name       = "Light's Potential",
    classToken = nil,           -- universal
    category   = "Consumables",
    description = "Tracks the Light's Potential combat potion buff (30s). "
        .. "Starts on cast success, stops on player death.",
    spellID    = 1236616,
    duration   = 30,
    opts = {
        startTrigger = {
            events          = { cast = true },
            restartOnRefire = true,
        },
        endTrigger = {
            events = { death = true },
        },
    },
})

-- More presets can be added below as they're tested and confirmed working.
-- Each entry follows the same shape. Examples to add later:
--   - Priest  Fade
--   - DK     Rune Tap (if cooldown event fires)
--   - Paladin Ardent Defender
--   - Warrior Shield Block  (if cooldown event fires)
--   - Monk   Dampen Harm (ICD tracking)
-- Always verify the effect vs talent ID with /spellwatch discover before shipping.

-- ─────────────────────────────────────────────────────────────────────────
-- Public API
-- ─────────────────────────────────────────────────────────────────────────

-- Return presets filtered to the player's current class. Nil classToken
-- entries ("universal") are always included. Matches on the non-localized
-- UnitClass() token so it works on any game client language.
function ns.GetCustomIconPresetsForPlayer()
    local _, playerClass = UnitClass("player")
    local out = {}
    for _, p in ipairs(ns.CustomIconsPresets) do
        if not p.classToken or p.classToken == playerClass then
            out[#out + 1] = p
        end
    end
    return out
end

-- Check whether a preset is already in the user's timer DB. Used by the
-- picker UI to gray out Add buttons that would duplicate an existing timer.
-- We match on arcID because preset.id is designed to be used as the arcID
-- stem when the preset is applied — see AddTimerFromPreset below.
function ns.IsPresetInstalled(preset)
    if not preset or not preset.id then return false end
    local db = ns.db and ns.db.char and ns.db.char.arcAuras
    if not db or not db.customTimers then return false end
    -- AddTimer appends "_N" if the base ID collides, so any timer whose
    -- arcID is the preset.id or starts with "presetid_" counts as installed.
    if db.customTimers[preset.id] then return true end
    for arcID in pairs(db.customTimers) do
        if arcID:sub(1, #preset.id + 1) == preset.id .. "_" then
            return true
        end
    end
    return false
end

-- One-shot install: hands the preset config to ArcAurasTimer.AddTimer.
-- Returns (success, arcID_or_error_message).
function ns.AddTimerFromPreset(preset)
    if not preset or type(preset) ~= "table" then
        return false, "Invalid preset"
    end
    if not preset.spellID or not preset.duration then
        return false, "Preset missing spellID or duration"
    end
    if not ns.ArcAurasTimer or not ns.ArcAurasTimer.AddTimer then
        return false, "Timer engine not loaded"
    end
    return ns.ArcAurasTimer.AddTimer(preset.spellID, preset.duration, preset.opts or {})
end