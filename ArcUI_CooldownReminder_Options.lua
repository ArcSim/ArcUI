-- ===================================================================
-- ArcUI_CooldownReminder_Options.lua
-- Options panel for Cooldown Reminder.
-- Mirrors CooldownBarOptions: icon-grid catalog → select → create,
-- active reminders listed below as collapsible entries.
-- ===================================================================

local ADDON, ns = ...
ns.CooldownReminder = ns.CooldownReminder or {}
local CR = ns.CooldownReminder
local AceConfigRegistry = LibStub("AceConfigRegistry-3.0")
local AceConfigDialog   = LibStub("AceConfigDialog-3.0")

local function GetDB()     return CR.GetDB and CR.GetDB() end
local function GetEngine() return CR.Engine end
local function NotifyChange() AceConfigRegistry:NotifyChange("ArcUI") end

-- ===================================================================
-- SPELL CATALOG  — delegates directly to ns.CooldownBars.spellCatalog
-- Uses the same scan, same exclusion list, same sort as Cooldown Bars.
-- ===================================================================
local selectedSpellID = nil
local searchText      = ""
local expandedKeys    = {}   -- ["s_197214"] = true  (expanded in active list)

local function ScanPlayerSpells()
    -- Reuse CooldownBars scanner exactly — same sources, same filters, same sort
    if ns.CooldownBars and ns.CooldownBars.ScanPlayerSpells then
        return ns.CooldownBars.ScanPlayerSpells()
    end
    return 0
end

local function GetSpellCatalog()
    -- Always read from CooldownBars live catalog
    if ns.CooldownBars and ns.CooldownBars.spellCatalog then
        return ns.CooldownBars.spellCatalog
    end
    return {}
end

local function EnsureCatalog()
    local cat = GetSpellCatalog()
    if #cat == 0 and not InCombatLockdown() then
        ScanPlayerSpells()
    end
end

local function GetCatalogEntries()
    EnsureCatalog()
    local catalog = GetSpellCatalog()
    if searchText == "" then return catalog end
    local low = searchText:lower()
    local out = {}
    for _, d in ipairs(catalog) do
        if d.name:lower():find(low, 1, true) then out[#out+1] = d end
    end
    return out
end

-- ===================================================================
-- ACTIVE REMINDERS HELPERS
-- ===================================================================
local function IsTracked(spellID)
    local db = GetDB(); if not db then return false end
    return db.whitelist and (db.whitelist[tostring(spellID)] or db.whitelist[spellID]) and true or false
end

local function IsItemTracked(itemID)
    local db = GetDB(); if not db then return false end
    return db.whitelist and db.whitelist["i:"..tostring(itemID)] and true or false
end

local function GetSoundList()
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local sounds = { "Default", "None" }
    local seen = { Default=true, None=true }
    if lsm then
        for _, s in ipairs(lsm:List("sound") or {}) do
            if not seen[s] then sounds[#sounds+1] = s; seen[s] = true end
        end
    end
    return sounds
end

local function PlaySoundFor(dbKey)
    local db = GetDB(); if not db then return end
    local snd = (db.spellSounds and db.spellSounds[dbKey]) or db.soundName or "Default"
    if snd == "None" then return end
    if snd == "Default" then PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master"); return end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local path = lsm and lsm:Fetch("sound", snd, true)
    if path then PlaySoundFile(path, db.soundChannel or "Master")
    else PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master") end
end

-- ===================================================================
-- ACTIVE REMINDER ENTRY  (collapsible, like CreateActiveBarEntry)
-- ===================================================================
local function CreateActiveReminderEntry(spellID, isItem, orderBase)
    local optKey = isItem and ("i_"..spellID) or ("s_"..spellID)
    local dbKey  = isItem and ("i:"..tostring(spellID)) or tostring(spellID)

    local function GetIcon()
        if isItem then
            if C_Item and C_Item.GetItemIconByID then
                local icon = C_Item.GetItemIconByID(spellID)
                if icon then return icon end
            end
            return 134400
        end
        return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)) or 134400
    end

    local function GetName()
        if isItem then
            return CR.GetItemNameCached and CR.GetItemNameCached(spellID) or ("Item:"..spellID)
        end
        return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or tostring(spellID)
    end

    local entry = {
        type   = "group",
        name   = "",
        inline = true,
        order  = orderBase,
        args   = {
            -- Collapsible header with icon + name (same pattern as CooldownBarOptions)
            header = {
                type   = "toggle",
                name   = function()
                    local name = GetName()
                    local icon = GetIcon()
                    return string.format("|T%d:16:16:0:0|t |cff00ccff%s|r |cff888888(ID: %d)|r",
                        icon, name, spellID)
                end,
                desc             = "Click to expand/collapse",
                dialogControl    = "CollapsibleHeader",
                get              = function() return expandedKeys[optKey] end,
                set              = function(_, v) expandedKeys[optKey] = v end,
                order            = 0,
                width            = "full",
            },
            -- Preview (full pulse: icon + sound)
            preview = {
                type  = "execute",
                name  = "Preview Alert",
                desc  = "Fire Trigger #1 (or the legacy pulse if no triggers exist) to preview what this reminder will look and sound like.",
                order = 1,
                width = 0.8,
                hidden = function() return not expandedKeys[optKey] end,
                func  = function()
                    local db = GetDB()
                    -- Prefer the multi-trigger pipeline: preview the FIRST
                    -- trigger so the user hears exactly what will fire.
                    if db and db.spellTriggers and db.spellTriggers[dbKey]
                       and #db.spellTriggers[dbKey] > 0
                       and CR.DoPulseFromTrigger then
                        local t = db.spellTriggers[dbKey][1]
                        local kind = isItem and "PREVIEW" or "PREVIEW"
                        CR.DoPulseFromTrigger(spellID, kind, isItem, t)
                        return
                    end
                    -- Legacy fallback for spells with no trigger array.
                    if CR.DoPulseNow then CR.DoPulseNow(spellID, "PREVIEW", isItem) end
                end,
            },
            -- Per-spell icon toggle
            -- Per-spell controls — HIDDEN. The new multi-trigger system makes
            -- these redundant: every trigger has its own Show icon / Play sound
            -- / Sound / TTS controls. Kept in the table (not deleted) so existing
            -- saved data round-trips cleanly, but never displayed.
            iconEnabled = {
                type    = "toggle",
                name    = "Show icon (legacy)",
                order   = 1.5,
                width   = 0.8,
                hidden  = function() return true end,
                get     = function()
                    local db = GetDB(); if not db then return true end
                    if not db.spellIconDisabled then return true end
                    return not db.spellIconDisabled[dbKey]
                end,
                set     = function(_, v)
                    local db = GetDB(); if not db then return end
                    if not db.spellIconDisabled then db.spellIconDisabled = {} end
                    if v then
                        db.spellIconDisabled[dbKey] = nil
                    else
                        db.spellIconDisabled[dbKey] = true
                    end
                end,
            },
            soundEnabled = {
                type    = "toggle",
                name    = "Play sound (legacy)",
                order   = 1.6,
                width   = 0.8,
                hidden  = function() return true end,
                get     = function()
                    local db = GetDB(); if not db then return true end
                    if not db.spellSoundDisabled then return true end
                    return not db.spellSoundDisabled[dbKey]
                end,
                set     = function(_, v)
                    local db = GetDB(); if not db then return end
                    if not db.spellSoundDisabled then db.spellSoundDisabled = {} end
                    if v then
                        db.spellSoundDisabled[dbKey] = nil
                    else
                        db.spellSoundDisabled[dbKey] = true
                    end
                end,
            },
            sound = {
                type    = "select",
                name    = "Sound (legacy)",
                order   = 2,
                width   = 1.4,
                hidden  = function() return true end,
                values  = function()
                    local t = {}; for _, s in ipairs(GetSoundList()) do t[s] = s end; return t
                end,
                sorting = GetSoundList,
                get = function()
                    local db = GetDB(); if not db then return "Default" end
                    return (db.spellSounds and db.spellSounds[dbKey]) or db.soundName or "Default"
                end,
                set = function(_, val)
                    local db = GetDB(); if not db then return end
                    if not db.spellSounds then db.spellSounds = {} end
                    db.spellSounds[dbKey] = val
                end,
            },
            previewSound = {
                type   = "execute",
                name   = "Play (legacy)",
                order  = 3,
                width  = 0.4,
                hidden = function() return true end,
                func   = function() PlaySoundFor(dbKey) end,
            },
            ttsText = {
                type    = "input",
                name    = "TTS Text (legacy)",
                order   = 3.5,
                width   = 1.6,
                hidden  = function() return true end,
                get     = function()
                    local db = GetDB(); if not db then return "" end
                    return (db.spellTTS and db.spellTTS[dbKey]) or ""
                end,
                set     = function(_, val)
                    local db = GetDB(); if not db then return end
                    if not db.spellTTS then db.spellTTS = {} end
                    if val == "" then
                        db.spellTTS[dbKey] = nil
                    else
                        db.spellTTS[dbKey] = val
                    end
                end,
            },
            ttsPreview = {
                type   = "execute",
                name   = "Speak (legacy)",
                order  = 3.6,
                width  = 0.4,
                hidden = function() return true end,
                func   = function() end,
            },
            -- Delayed reminder: mode select
            -- HIDDEN — superseded entirely by the Triggers list below. Kept
            -- in the table (not deleted) so existing saved data round-trips
            -- cleanly, but no longer exposed in the UI.
            delayMode = {
                type   = "select",
                name   = "Reminder mode (legacy)",
                order  = 3.7,
                width  = 1.2,
                hidden = function() return true end,
                values = {
                    off        = "Off (ready only)",
                    afterCast  = "After cast only",
                    afterReady = "After ready only",
                    both       = "Both (ready + after cast)",
                },
                sorting = { "off", "afterCast", "afterReady", "both" },
                get = function()
                    local db = GetDB(); if not db then return "off" end
                    return (db.spellDelayMode and db.spellDelayMode[dbKey]) or "off"
                end,
                set = function(_, val)
                    local db = GetDB(); if not db then return end
                    if not db.spellDelayMode then db.spellDelayMode = {} end
                    if val == "off" then
                        db.spellDelayMode[dbKey] = nil
                    else
                        db.spellDelayMode[dbKey] = val
                    end
                end,
            },
            -- Delayed reminder: seconds
            -- HIDDEN — superseded by the per-trigger seconds slider in the
            -- Triggers list. Kept in the table for saved-data round-trip.
            delaySeconds = {
                type   = "range",
                name   = "Delay (sec, legacy)",
                order  = 3.8,
                width  = 0.8,
                min    = 0.5,
                max    = 60,
                step   = 0.5,
                hidden = function() return true end,
                get = function()
                    local db = GetDB(); if not db then return 3 end
                    return tonumber(db.spellDelaySeconds and db.spellDelaySeconds[dbKey]) or 3
                end,
                set = function(_, val)
                    local db = GetDB(); if not db then return end
                    if not db.spellDelaySeconds then db.spellDelaySeconds = {} end
                    db.spellDelaySeconds[dbKey] = tonumber(val) or 3
                end,
            },
            -- ─────────────────────────────────────────────────────────────
            -- MULTI-TRIGGER LIST
            --
            -- When ANY entries are added here, this list TAKES OVER from
            -- the legacy single-trigger system above. The Reminder Mode /
            -- Delay fields gray out and the engine fires per-trigger
            -- pulses with each trigger's own sound/TTS settings.
            --
            -- All triggers share an array at db.spellTriggers[dbKey].
            -- Each entry: { type, seconds, sound, tts, showIcon, soundDisabled }
            -- Up to 5 triggers per spell.
            -- ─────────────────────────────────────────────────────────────
            triggersHeader = {
                type   = "description",
                name   = "\n|cffffd700Triggers|r  |cff666666(when this spell fires its reminder. Each trigger has its own sound/TTS.)|r",
                order  = 3.9,
                width  = "full",
                fontSize = "medium",
                hidden = function() return not expandedKeys[optKey] end,
            }
            ,
            -- Trigger rows are inserted by the loop below (3.91..3.95).

            -- Add Trigger button — appended at order 4.5, past the 5 rows
            -- which occupy 3.95..4.20 (5 * 0.05 slice each).
            addTrigger = {
                type   = "execute",
                name   = "+ Add Trigger",
                desc   = "Append a new trigger to the list. Up to 5 per spell.",
                order  = 4.5,
                width  = "full",
                hidden = function() return not expandedKeys[optKey] end,
                disabled = function()
                    local db = GetDB(); if not db then return true end
                    local list = db.spellTriggers and db.spellTriggers[dbKey] or {}
                    return #list >= 5
                end,
                func = function()
                    local db = GetDB(); if not db then return end
                    if not db.spellTriggers then db.spellTriggers = {} end
                    if not db.spellTriggers[dbKey] then db.spellTriggers[dbKey] = {} end
                    table.insert(db.spellTriggers[dbKey], {
                        type    = "when_ready",
                        seconds = 3,
                        sound   = nil,
                        tts     = nil,
                        showIcon = nil,
                        soundDisabled = false,
                    })
                    NotifyChange()
                end,
            },
            -- Delayed reminder: seconds
            -- (rest of args follow below — original remove/spacer)
            -- Remove
            remove = {
                type    = "execute",
                name    = "|cffff4444Remove this spell|r",
                order   = 5,
                width   = 0.8,
                hidden  = function() return not expandedKeys[optKey] end,
                confirm = true,
                confirmText = "Remove this cooldown reminder?",
                func = function()
                    local db = GetDB(); if not db then return end
                    if isItem then
                        db.whitelist["i:"..tostring(spellID)] = nil
                        if db.spellSounds then db.spellSounds["i:"..tostring(spellID)] = nil end
                        if db.spellTTS then db.spellTTS["i:"..tostring(spellID)] = nil end
                        if db.spellIconDisabled then db.spellIconDisabled["i:"..tostring(spellID)] = nil end
                        if db.spellSoundDisabled then db.spellSoundDisabled["i:"..tostring(spellID)] = nil end
                        if db.spellDelayMode then db.spellDelayMode["i:"..tostring(spellID)] = nil end
                        if db.spellDelaySeconds then db.spellDelaySeconds["i:"..tostring(spellID)] = nil end
                        if db.spellTriggers then db.spellTriggers["i:"..tostring(spellID)] = nil end
                    else
                        db.whitelist[tostring(spellID)] = nil
                        db.whitelist[spellID] = nil
                        if db.spellSounds then
                            db.spellSounds[tostring(spellID)] = nil
                            db.spellSounds[spellID] = nil
                        end
                        if db.spellTTS then
                            db.spellTTS[tostring(spellID)] = nil
                            db.spellTTS[spellID] = nil
                        end
                        if db.spellIconDisabled then
                            db.spellIconDisabled[tostring(spellID)] = nil
                            db.spellIconDisabled[spellID] = nil
                        end
                        if db.spellSoundDisabled then
                            db.spellSoundDisabled[tostring(spellID)] = nil
                            db.spellSoundDisabled[spellID] = nil
                        end
                        if db.spellDelayMode then
                            db.spellDelayMode[tostring(spellID)] = nil
                            db.spellDelayMode[spellID] = nil
                        end
                        if db.spellDelaySeconds then
                            db.spellDelaySeconds[tostring(spellID)] = nil
                            db.spellDelaySeconds[spellID] = nil
                        end
                        if db.spellTriggers then
                            db.spellTriggers[tostring(spellID)] = nil
                            db.spellTriggers[spellID] = nil
                        end
                    end
                    GetEngine():RebuildTrackedSpells("remove")
                    expandedKeys[optKey] = nil
                    NotifyChange()
                end,
            },
            -- Spacer
            spacer = { type = "description", name = "", order = 10, width = "full",
                       hidden = function() return not expandedKeys[optKey] end },
        },
    }

    -- ────────────────────────────────────────────────────────────────────
    -- TRIGGER ROW INJECTION
    --
    -- Each row gets six widgets (type select, seconds, sound, TTS,
    -- showIcon toggle, remove). All keyed off entry.args so they live
    -- inside the same collapsible block. Orders 3.91..3.95 reserve space
    -- between the triggersHeader (3.9) and the addTrigger button (3.99).
    -- Each row's widgets cluster within (3.9 + i*0.01) .. (3.9 + i*0.01 + 0.005).
    -- ────────────────────────────────────────────────────────────────────
    local MAX_TRIGGERS = 5
    local TYPE_VALUES = {
        on_use         = "On use (when cast)",
        when_ready     = "When ready (cooldown done)",
        on_proc        = "On proc (proc glow turns on)",
        after_ready    = "N seconds after ready",
        into_cooldown  = "N seconds after cast",
    }
    local TYPE_SORTING = { "on_use", "when_ready", "on_proc", "after_ready", "into_cooldown" }

    local function getTrigger(idx)
        local db = GetDB(); if not db then return nil end
        local list = db.spellTriggers and db.spellTriggers[dbKey]
        if not list or idx > #list then return nil end
        return list[idx]
    end

    local function rowHidden(idx)
        return function()
            if not expandedKeys[optKey] then return true end
            return getTrigger(idx) == nil
        end
    end

    for idx = 1, MAX_TRIGGERS do
        -- Each row claims a 0.05 slice of order space.
        local rowOrder = 3.9 + (idx * 0.05)
        local hideRow  = rowHidden(idx)

        -- Per-trigger expansion key — independent of the parent spell's
        -- collapsed/expanded state. Trigger #1 defaults to expanded, the
        -- rest default to collapsed so the user sees a clean stack of
        -- "Trigger #2 — When ready", "Trigger #3 — ...", click to expand.
        local trigExpandKey = string.format("%s_trig_%d", optKey, idx)
        if expandedKeys[trigExpandKey] == nil and idx == 1 then
            expandedKeys[trigExpandKey] = true
        end
        local function trigCollapsed()
            return not expandedKeys[trigExpandKey]
        end
        local function hideContent()
            -- Hide the content widgets when EITHER the parent spell is
            -- collapsed, OR the trigger row doesn't exist yet, OR this
            -- trigger is collapsed.
            return hideRow() or trigCollapsed()
        end

        -- Collapsible header with the trigger summary as its label.
        -- Replaces the old separator + label combo. Click to expand/collapse.
        entry.args[string.format("trigger_%d_header", idx)] = {
            type   = "toggle",
            name   = function()
                local t = getTrigger(idx)
                if not t then return "" end
                local typeLabel = TYPE_VALUES[t.type or "on_use"] or t.type or "?"
                if (t.type == "after_ready" or t.type == "into_cooldown")
                   and tonumber(t.seconds) then
                    typeLabel = string.format("%s (%ds)", typeLabel, tonumber(t.seconds))
                end
                return string.format("|cffffd700Trigger #%d|r  |cffaaaaaa—|r  |cff88ccff%s|r",
                    idx, typeLabel)
            end,
            desc          = "Click to expand/collapse this trigger's settings.",
            dialogControl = "CollapsibleHeader",
            get           = function() return expandedKeys[trigExpandKey] end,
            set           = function(_, v) expandedKeys[trigExpandKey] = v end,
            order         = rowOrder + 0.001,
            width         = "full",
            hidden        = hideRow,
        }

        -- Type selector — full width on its own line so the label is unambiguous.
        entry.args[string.format("trigger_%d_type", idx)] = {
            type   = "select",
            name   = "When does this trigger fire?",
            order  = rowOrder + 0.002,
            width  = "full",
            hidden = hideContent,
            values = TYPE_VALUES,
            sorting = TYPE_SORTING,
            get = function()
                local t = getTrigger(idx); return t and t.type or "on_use"
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                if not TYPE_VALUES[val] then return end
                t.type = val
                NotifyChange()
            end,
        }

        -- Seconds slider — only shown for after_ready / into_cooldown.
        entry.args[string.format("trigger_%d_seconds", idx)] = {
            type    = "range",
            name    = function()
                local t = getTrigger(idx)
                if not t then return "Seconds" end
                if t.type == "after_ready" then return "Seconds after ready" end
                if t.type == "into_cooldown" then return "Seconds after cast" end
                return "Seconds"
            end,
            desc    = "How many seconds the trigger waits before firing.",
            order   = rowOrder + 0.003,
            width   = "full",
            min     = 0.5,
            max     = 60,
            step    = 0.5,
            hidden  = function()
                if hideContent() then return true end
                local t = getTrigger(idx); if not t then return true end
                return t.type ~= "after_ready" and t.type ~= "into_cooldown"
            end,
            get = function()
                local t = getTrigger(idx); return t and tonumber(t.seconds) or 3
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                t.seconds = tonumber(val) or 3
                NotifyChange()
            end,
        }

        entry.args[string.format("trigger_%d_sound_enabled", idx)] = {
            type    = "toggle",
            name    = "Play sound",
            desc    = "If off, this trigger fires silently (icon only).",
            order   = rowOrder + 0.004,
            width   = 0.7,
            hidden  = hideContent,
            get = function()
                local t = getTrigger(idx)
                return t and not t.soundDisabled or false
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.soundDisabled = (not v) and true or nil
                NotifyChange()
            end,
        }
        entry.args[string.format("trigger_%d_show_icon", idx)] = {
            type    = "toggle",
            name    = "Show icon",
            desc    = "If off, this trigger fires sound/TTS only with no on-screen icon.",
            order   = rowOrder + 0.005,
            width   = 0.7,
            hidden  = hideContent,
            get = function()
                local t = getTrigger(idx)
                if not t then return true end
                return t.showIcon ~= false
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.showIcon = (not v) and false or nil
                NotifyChange()
            end,
        }

        -- Per-trigger proc gate: when on, this trigger fires only if the
        -- spell currently has a Spell Activation Overlay (proc glow) active
        -- at the moment the trigger would otherwise fire. Default off
        -- (opt-in). For items, the use-spell's proc state is checked.
        -- Hidden for "on_proc" triggers — the proc is necessarily active
        -- when those fire, so the gate is redundant.
        entry.args[string.format("trigger_%d_require_proc", idx)] = {
            type    = "toggle",
            name    = "Only fire when proc is active",
            desc    = "When enabled, this trigger ONLY fires if the spell currently has a proc glow / Spell Activation Overlay active at the moment the trigger would fire. Layered on top of the trigger's normal timing — e.g. 'When ready' + this option = fire only when the cooldown comes up AND the proc is currently active. For items, checks the item's use-spell.",
            order   = rowOrder + 0.0055,
            width   = "full",
            hidden  = function()
                if hideContent() then return true end
                local t = getTrigger(idx)
                return t and t.type == "on_proc" or false
            end,
            get = function()
                local t = getTrigger(idx)
                return t and t.requireProc == true or false
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.requireProc = v and true or nil
                NotifyChange()
            end,
        }

        entry.args[string.format("trigger_%d_sound", idx)] = {
            type    = "select",
            name    = "Sound",
            desc    = "Sound for this trigger. 'Default' uses the global sound.",
            order   = rowOrder + 0.006,
            width   = 1.4,
            hidden  = hideContent,
            disabled = function()
                local t = getTrigger(idx)
                return t and t.soundDisabled or false
            end,
            values  = function()
                local t = {}
                for _, s in ipairs(GetSoundList()) do t[s] = s end
                return t
            end,
            sorting = GetSoundList,
            get = function()
                local t = getTrigger(idx)
                return (t and t.sound) or "Default"
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                if val == "Default" then t.sound = nil else t.sound = val end
                -- Keep the legacy db.spellSounds map in sync. If this is
                -- Trigger #1, mirror its sound there so legacy code paths
                -- (Preview Alert old path, any other readers) stay consistent
                -- and the next migration won't try to re-fold an old value
                -- back into the trigger.
                if idx == 1 then
                    local db = GetDB()
                    if db then
                        db.spellSounds = db.spellSounds or {}
                        if val == "Default" or not val or val == "" then
                            db.spellSounds[dbKey] = nil
                        else
                            db.spellSounds[dbKey] = val
                        end
                    end
                end
                NotifyChange()
            end,
        }
        entry.args[string.format("trigger_%d_sound_preview", idx)] = {
            type   = "execute",
            name   = "Play",
            desc   = "Preview this trigger's sound.",
            order  = rowOrder + 0.007,
            width  = 0.4,
            hidden = hideContent,
            disabled = function()
                local t = getTrigger(idx)
                return t and t.soundDisabled or false
            end,
            func   = function()
                local t = getTrigger(idx); if not t then return end
                local db = GetDB(); if not db then return end
                local snd = t.sound or db.soundName or "Default"
                if snd == "None" then return end
                if snd == "Default" then
                    PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master"); return
                end
                local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
                local path = lsm and lsm:Fetch("sound", snd, true)
                if path then PlaySoundFile(path, db.soundChannel or "Master")
                else PlaySound(db.fallbackSoundKitID or 12867, db.soundChannel or "Master") end
            end,
        }

        entry.args[string.format("trigger_%d_tts", idx)] = {
            type    = "input",
            name    = "TTS text (optional, overrides sound)",
            desc    = "Text-to-speech for this trigger. When set, overrides the sound.",
            order   = rowOrder + 0.008,
            width   = 1.4,
            hidden  = hideContent,
            get = function()
                local t = getTrigger(idx); return (t and t.tts) or ""
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                if val == "" then t.tts = nil else t.tts = val end
                -- Keep legacy db.spellTTS in sync for Trigger #1, same
                -- reasoning as the sound setter above.
                if idx == 1 then
                    local db = GetDB()
                    if db then
                        db.spellTTS = db.spellTTS or {}
                        if val == "" then
                            db.spellTTS[dbKey] = nil
                        else
                            db.spellTTS[dbKey] = val
                        end
                    end
                end
                NotifyChange()
            end,
        }
        entry.args[string.format("trigger_%d_tts_speak", idx)] = {
            type   = "execute",
            name   = "Speak",
            desc   = "Preview this trigger's TTS text.",
            order  = rowOrder + 0.009,
            width  = 0.4,
            hidden = hideContent,
            disabled = function()
                local t = getTrigger(idx)
                return not (t and t.tts and t.tts ~= "")
            end,
            func   = function()
                local t = getTrigger(idx); if not t or not t.tts or t.tts == "" then return end
                local db = GetDB(); if not db then return end
                local voiceID = (CR.ResolveTTSVoiceID and CR.ResolveTTSVoiceID(db.ttsVoiceOverride)) or 0
                local rate
                if db.ttsRateOverride ~= nil then
                    rate = tonumber(db.ttsRateOverride) or 0
                elseif C_TTSSettings and C_TTSSettings.GetSpeechRate then
                    rate = C_TTSSettings.GetSpeechRate()
                end
                if CR.SpeakTTS then CR.SpeakTTS(t.tts, voiceID, rate) end
            end,
        }

        -- Animation style — drop-down. "Default" means use global db.animStyle.
        local ANIM_LABELS = {
            ["default"] = "Default (use global)",
            ["fade"]    = "Fade",
            ["no_fade"] = "No Fade (snap off)",
            ["flash"]   = "Flash (urgent)",
            ["zoom"]    = "Zoom (pop in + fade)",
        }
        local ANIM_SORT = {
            "default", "fade", "no_fade", "flash", "zoom",
        }
        entry.args[string.format("trigger_%d_anim_style", idx)] = {
            type    = "select",
            name    = "Animation",
            desc    = "How the icon animates when this trigger fires.",
            order   = rowOrder + 0.0091,
            width   = 1.4,
            hidden  = hideContent,
            values  = ANIM_LABELS,
            sorting = ANIM_SORT,
            get = function()
                local t = getTrigger(idx)
                return (t and t.animStyle) or "default"
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                if val == "default" then t.animStyle = nil else t.animStyle = val end
                NotifyChange()
            end,
        }

        -- Priority — controls how this trigger's pulse interacts with
        -- others when the icon is already busy.
        --
        -- 0 (default) = no special treatment; standard mode rules apply
        --               (replace/queue/stack as configured globally).
        -- 1+        = "elevated" — interrupts any lower-priority pulse
        --               currently on screen, plays for the FULL pulse
        --               duration without being replaced or interrupted
        --               by lower-priority alerts. In stack mode, used
        --               as eviction order when the stack is full.
        --               In queue mode, lower-priority entries are
        --               dropped from a full queue first.
        --
        -- Higher numbers strictly beat lower numbers; equal priorities
        -- fall through to the user's chosen mode behavior. Useful for
        -- ensuring critical procs (e.g. defensive cooldowns ready, key
        -- raid mechanics) aren't drowned out by routine reminders.
        entry.args[string.format("trigger_%d_priority", idx)] = {
            type   = "range",
            name   = "Priority",
            desc   = "0 = normal. Higher values interrupt and resist replacement by lower-priority pulses.\n\n"
                  .. "|cffffd200P0|r — default; standard mode rules apply.\n"
                  .. "|cffffd200P1-2|r — elevated; interrupts P0 alerts.\n"
                  .. "|cffffd200P3-5|r — critical; reserve for must-not-miss alerts.\n\n"
                  .. "Same-priority pulses still respect replace/queue/stack mode normally.",
            order  = rowOrder + 0.00905,
            width  = 1.4,
            min    = 0, max = 5, step = 1,
            hidden = hideContent,
            get    = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.priority)) or 0
            end,
            set    = function(_, v)
                local t = getTrigger(idx); if not t then return end
                v = math.floor((tonumber(v) or 0) + 0.5)
                if v <= 0 then t.priority = nil else t.priority = v end
                NotifyChange()
            end,
        }

        -- Glow type — drop-down. "none" means no glow.
        local GLOW_LABELS = {
            ["none"]     = "None",
            ["pixel"]    = "Pixel (marching dots)",
            ["autocast"] = "Autocast (sparkles)",
            ["button"]   = "Button (action-bar)",
            ["proc"]     = "Proc (Blizzard)",
            ["ants"]     = "Ants (border crawl)",
            ["ach_proc"] = "Achievement proc",
        }
        local GLOW_SORT = {
            "none", "pixel", "autocast", "button", "proc", "ants", "ach_proc",
        }
        entry.args[string.format("trigger_%d_glow_type", idx)] = {
            type    = "select",
            name    = "Glow",
            desc    = "Optional glow effect drawn around the icon while the pulse is on screen. Stops automatically when the icon fades.",
            order   = rowOrder + 0.0092,
            width   = 1.4,
            hidden  = hideContent,
            values  = GLOW_LABELS,
            sorting = GLOW_SORT,
            get = function()
                local t = getTrigger(idx)
                return (t and t.glowType) or "none"
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                if val == "none" then t.glowType = nil else t.glowType = val end
                NotifyChange()
            end,
        }

        -- Glow color — RGBA color picker. Only relevant when glow is on.
        entry.args[string.format("trigger_%d_glow_color", idx)] = {
            type    = "color",
            name    = "Glow color",
            desc    = "Color tint for the glow. Defaults to ArcUI cyan.",
            order   = rowOrder + 0.0093,
            width   = 0.8,
            hasAlpha = true,
            hidden  = function()
                if hideContent() then return true end
                local t = getTrigger(idx)
                return not (t and t.glowType and t.glowType ~= "none")
            end,
            get = function()
                local t = getTrigger(idx)
                local c = t and t.glowColor or { 0.0, 0.8, 1.0, 1.0 }
                return c[1], c[2], c[3], c[4] or 1
            end,
            set = function(_, r, g, b, a)
                local t = getTrigger(idx); if not t then return end
                t.glowColor = { r, g, b, a or 1 }
                NotifyChange()
            end,
        }

        -- ── PER-TRIGGER PULSE DURATION + ANIMATION TUNING ───────────
        -- Each setting is OPTIONAL — nil means "inherit from the global
        -- Animation Tuning section". The toggle below lets the user
        -- enable per-trigger overrides; when off, the override values
        -- are still saved on the trigger but the engine ignores them.
        --
        -- Helper: figure out which animation style is effective for this
        -- trigger so we know which tuning rows to show. Trigger override
        -- wins over global default.
        local function effectiveAnim(t)
            return (t and t.animStyle) or (GetDB() and GetDB().animStyle) or "fade"
        end

        entry.args[string.format("trigger_%d_override_anim", idx)] = {
            type   = "toggle",
            name   = "Override timing/tuning",
            desc   = "When ON, this trigger uses its own Pulse Duration and animation tuning values instead of the global ones. When OFF, the override values below are ignored (and global settings apply) — but they're remembered so toggling back on restores them.",
            order  = rowOrder + 0.0094,
            width  = "full",
            hidden = hideContent,
            get    = function()
                local t = getTrigger(idx)
                return t and t._overrideAnim == true
            end,
            set    = function(_, val)
                local t = getTrigger(idx); if not t then return end
                t._overrideAnim = val and true or nil
                if not val then
                    -- Strip anim override fields so engine ignores them
                    -- regardless of remembered values. (Toggling back on
                    -- restores defaults; users re-enter custom values
                    -- intentionally.)
                    t.pulseDuration      = nil
                    t.animFadeSmoothing  = nil
                    t.animFlashSpeed     = nil
                    t.animZoomStart      = nil
                    t.animZoomPeak       = nil
                    t.animZoomPopTime    = nil
                    t.animZoomSettleTime = nil
                end
                NotifyChange()
            end,
        }

        local function overrideOff()
            if hideContent() then return true end
            local t = getTrigger(idx)
            return not (t and t._overrideAnim)
        end

        entry.args[string.format("trigger_%d_pulse_duration", idx)] = {
            type   = "range",
            name   = "Pulse Duration (override)",
            desc   = "Total seconds this trigger's pulse stays on screen. Animations are scaled to fit.",
            order  = rowOrder + 0.0095,
            width  = 1.5,
            min    = 0.1, max = 5.0, step = 0.05,
            hidden = overrideOff,
            get    = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.pulseDuration))
                    or (GetDB() and tonumber(GetDB().pulseDuration))
                    or 1.0
            end,
            set    = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.pulseDuration = math.floor(v * 100 + 0.5) / 100
            end,
        }

        -- Fade smoothing override (only when effective style is "fade")
        entry.args[string.format("trigger_%d_fade_smoothing", idx)] = {
            type   = "select",
            name   = "Fade Curve (override)",
            desc   = "Shape of the fade-out for this trigger.",
            order  = rowOrder + 0.0096,
            width  = 1.5,
            values = {
                ["NONE"]   = "Linear",
                ["OUT"]    = "Ease Out",
                ["IN"]     = "Ease In",
                ["IN_OUT"] = "Ease In/Out",
            },
            sorting = { "NONE", "OUT", "IN", "IN_OUT" },
            hidden = function()
                if overrideOff() then return true end
                return effectiveAnim(getTrigger(idx)) ~= "fade"
            end,
            get = function()
                local t = getTrigger(idx)
                return (t and t.animFadeSmoothing)
                    or (GetDB() and GetDB().animFadeSmoothing)
                    or "OUT"
            end,
            set = function(_, val)
                local t = getTrigger(idx); if not t then return end
                t.animFadeSmoothing = val
            end,
        }

        -- Flash override (only when effective style is "flash")
        entry.args[string.format("trigger_%d_flash_speed", idx)] = {
            type   = "range",
            name   = "Flash Step Speed (override)",
            desc   = "Per-step flash speed for this trigger.",
            order  = rowOrder + 0.0097,
            width  = 1.5,
            min    = 0.03, max = 0.30, step = 0.01,
            hidden = function()
                if overrideOff() then return true end
                return effectiveAnim(getTrigger(idx)) ~= "flash"
            end,
            get = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.animFlashSpeed))
                    or (GetDB() and tonumber(GetDB().animFlashSpeed))
                    or 0.10
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.animFlashSpeed = math.floor(v * 100 + 0.5) / 100
            end,
        }

        -- Zoom overrides (only when effective style is "zoom")
        local function zoomOff()
            if overrideOff() then return true end
            return effectiveAnim(getTrigger(idx)) ~= "zoom"
        end
        entry.args[string.format("trigger_%d_zoom_start", idx)] = {
            type = "range", name = "Zoom Start Scale (override)",
            desc = "Starting scale for this trigger's zoom.",
            order = rowOrder + 0.00981, width = 1.5,
            min = 0.30, max = 1.00, step = 0.05,
            hidden = zoomOff,
            get = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.animZoomStart))
                    or (GetDB() and tonumber(GetDB().animZoomStart))
                    or 0.70
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.animZoomStart = math.floor(v * 100 + 0.5) / 100
            end,
        }
        entry.args[string.format("trigger_%d_zoom_peak", idx)] = {
            type = "range", name = "Zoom Peak Scale (override)",
            desc = "Overshoot peak for this trigger's zoom.",
            order = rowOrder + 0.00982, width = 1.5,
            min = 1.00, max = 1.50, step = 0.05,
            hidden = zoomOff,
            get = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.animZoomPeak))
                    or (GetDB() and tonumber(GetDB().animZoomPeak))
                    or 1.15
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.animZoomPeak = math.floor(v * 100 + 0.5) / 100
            end,
        }
        entry.args[string.format("trigger_%d_zoom_pop", idx)] = {
            type = "range", name = "Zoom Pop Speed (override)",
            desc = "Pop-in time for this trigger's zoom.",
            order = rowOrder + 0.00983, width = 1.5,
            min = 0.04, max = 0.40, step = 0.01,
            hidden = zoomOff,
            get = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.animZoomPopTime))
                    or (GetDB() and tonumber(GetDB().animZoomPopTime))
                    or 0.12
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.animZoomPopTime = math.floor(v * 100 + 0.5) / 100
            end,
        }
        entry.args[string.format("trigger_%d_zoom_settle", idx)] = {
            type = "range", name = "Zoom Settle Speed (override)",
            desc = "Settle time for this trigger's zoom.",
            order = rowOrder + 0.00984, width = 1.5,
            min = 0.02, max = 0.30, step = 0.01,
            hidden = zoomOff,
            get = function()
                local t = getTrigger(idx)
                return (t and tonumber(t.animZoomSettleTime))
                    or (GetDB() and tonumber(GetDB().animZoomSettleTime))
                    or 0.08
            end,
            set = function(_, v)
                local t = getTrigger(idx); if not t then return end
                t.animZoomSettleTime = math.floor(v * 100 + 0.5) / 100
            end,
        }

        entry.args[string.format("trigger_%d_remove", idx)] = {
            type   = "execute",
            name   = "|cffff4444Remove this trigger|r",
            order  = rowOrder + 0.010,
            width  = "full",
            hidden = hideContent,
            func = function()
                local db = GetDB(); if not db then return end
                local list = db.spellTriggers and db.spellTriggers[dbKey]
                if not list or idx > #list then return end
                table.remove(list, idx)
                if #list == 0 then db.spellTriggers[dbKey] = nil end
                -- Also clear this trigger's expansion state so it doesn't
                -- linger when a new trigger gets added at the same idx.
                expandedKeys[trigExpandKey] = nil
                NotifyChange()
            end,
        }
    end

    return entry
end

-- ===================================================================
-- MAIN OPTIONS TABLE
-- ===================================================================
function ns.GetCooldownReminderOptionsTable()
    local db = GetDB()
    EnsureCatalog()

    local args = {}

    -- ── TOP: Enable + master controls ──────────────────────────────
    args.enabledToggle = {
        type = "toggle", name = "Enable Cooldown Reminder",
        desc = "Master on/off for all cooldown reminder alerts",
        order = 1, width = "full",
        get = function() local d = GetDB(); return d and d.enabled or false end,
        set = function(_, v)
            local d = GetDB(); if not d then return end
            d.enabled = v
            if CR.ApplySettings then CR.ApplySettings() end
        end,
    }
    args.testAlert = {
        type = "execute", name = "Test Alert",
        desc = "Fire a full test pulse (icon + sound) using the first tracked reminder",
        order = 2, width = 0.7,
        func = function()
            if CR.TestPulse and not CR.TestPulse() then
                print("|cff00ccffArcUI|r CR: Add a spell first to test an alert.")
            end
        end,
    }

    -- ── SPELL CATALOG ──────────────────────────────────────────────
    args.catalogHeader = { type = "header", name = "Spell Catalog", order = 10 }
    args.searchBox = {
        type = "input", name = "Search",
        desc = "Search spells by name",
        order = 11, width = 0.9,
        get = function() return searchText end,
        set = function(_, v)
            searchText = v; selectedSpellID = nil; NotifyChange()
        end,
    }
    args.rescanBtn = {
        type = "execute", name = "Rescan",
        desc = "Rescan spellbook for available abilities",
        order = 12, width = 0.5,
        disabled = function() return InCombatLockdown() end,
        func = function()
            catalogBuilt = false
            local count = ScanPlayerSpells()
            print(string.format("|cff00ccffArcUI|r CR: Found %d spells", count))
            NotifyChange()
        end,
    }
    args.addSpellID = {
        type = "input", name = "Add Spell ID",
        desc = "Manually enter a spell ID, or shift-click a spell link, to track it. Useful for spells not shown in the catalog (cross-class, profession, racials, etc.)",
        order = 12.5, width = 0.8,
        get = function() return "" end,
        set = function(_, val)
            val = (val or ""):match("^%s*(.-)%s*$"); if val == "" then return end
            local spellID = CR.ParseSpellID and CR.ParseSpellID(val)
            if not spellID then print("|cff00ccffArcUI|r CR: Invalid spell"); return end
            local ok, err = GetEngine():AddSpell(spellID)
            if not ok then print("|cff00ccffArcUI|r CR: "..tostring(err)) end
            NotifyChange()
        end,
    }
    args.addItemID = {
        type = "input", name = "Add Item ID",
        desc = "Enter an item ID or shift-click an item link to track it",
        order = 13, width = 0.8,
        get = function() return "" end,
        set = function(_, val)
            val = (val or ""):match("^%s*(.-)%s*$"); if val == "" then return end
            local itemID = CR.ParseItemID and CR.ParseItemID(val)
            if not itemID then print("|cff00ccffArcUI|r CR: Invalid item"); return end
            local ok, err = GetEngine():AddItem(itemID)
            if not ok then print("|cff00ccffArcUI|r CR: "..tostring(err)) end
            NotifyChange()
        end,
    }
    args.catalogCount = {
        type = "description", order = 14,
        name = function()
            local entries = GetCatalogEntries()
            local total = #GetSpellCatalog()
            if #entries < total then
                return string.format("|cff888888Showing %d of %d spells|r", #entries, total)
            end
            return string.format("|cff888888%d spells|r", total)
        end,
        fontSize = "medium",
    }
    args.catalogSpacer = { type = "description", name = " ", order = 15 }

    -- ── SELECTED SPELL INFO + CREATE BUTTON ────────────────────────
    args.selectedHeader = {
        type = "header", order = 200,
        name = function()
            if not selectedSpellID then return "" end
            local tex  = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(selectedSpellID)) or 134400
            local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(selectedSpellID)) or "Unknown"
            return string.format("|T%d:20:20:0:0|t %s", tex, name)
        end,
        hidden = function() return not selectedSpellID end,
    }
    args.selectedInfo = {
        type = "description", order = 201, fontSize = "medium",
        hidden = function() return not selectedSpellID end,
        name = function()
            if not selectedSpellID then return "" end
            local data
            for _, d in ipairs(GetSpellCatalog()) do
                if d.spellID == selectedSpellID then data = d; break end
            end
            if not data then return string.format("Spell ID: %d", selectedSpellID) end
            local lines = { string.format("|cffffd700Spell ID:|r %d", data.spellID) }
            if data.hasCharges then
                lines[#lines+1] = string.format("|cffffd700Charges:|r %d max", data.maxCharges)
            elseif data.hasCooldown then
                lines[#lines+1] = "|cffffd700Type:|r Cooldown"
            end
            return table.concat(lines, "\n")
        end,
    }
    args.btnCreate = {
        type = "execute", order = 210, width = 0.9,
        name = function()
            if not selectedSpellID then return "Create Reminder" end
            if IsTracked(selectedSpellID) then
                return "|cff00ff00[Active]|r"
            end
            return "Create Reminder"
        end,
        desc = "Add this spell to the Cooldown Reminder tracked list",
        hidden = function() return not selectedSpellID end,
        func = function()
            if not selectedSpellID then return end
            if IsTracked(selectedSpellID) then return end
            local ok, err = GetEngine():AddSpell(selectedSpellID)
            if not ok then print("|cff00ccffArcUI|r CR: "..tostring(err)) end
            NotifyChange()
        end,
    }
    args.clearBtn = {
        type = "execute", name = "Clear Selection",
        order = 211, width = 0.8,
        hidden = function() return not selectedSpellID end,
        func = function() selectedSpellID = nil; NotifyChange() end,
    }
    args.btnSpacer = { type = "description", name = "", order = 220,
                       hidden = function() return not selectedSpellID end }

    -- ── CATALOG ICON GRID (order 100–199) ──────────────────────────
    local entries = GetCatalogEntries()
    for i, data in ipairs(entries) do
        if i <= 80 then
            local sid       = data.spellID
            local tracked   = IsTracked(sid)
            local isSelected = (selectedSpellID == sid)
            -- Render icon inline in name (avoids AceConfig image-stretching)
            args["spell_"..sid] = {
                type        = "execute",
                name        = tracked and "|cff00ff00*|r" or " ",
                image       = function() return data.texture or C_Spell.GetSpellTexture(sid) or 134400 end,
                imageWidth  = 28,
                imageHeight = 28,
                order       = 100 + i,
                width       = 0.22,
                desc = function()
                    local tip = string.format("|cffffd100%s|r\nID: %d", data.name, sid)
                    if data.hasCharges then
                        tip = tip .. string.format("\n|cff00ccffCharges: %d|r", data.maxCharges)
                    end
                    if tracked then tip = tip .. "\n\n|cff00ff00[Reminder Active]|r" end
                    tip = tip .. "\n\n|cff888888Click to select|r"
                    return tip
                end,
                func = function()
                    if selectedSpellID == sid then selectedSpellID = nil
                    else selectedSpellID = sid end
                    NotifyChange()
                end,
            }
        end
    end

    -- ── ACTIVE REMINDERS (order 500+) ──────────────────────────────
    args.activeHeader = { type = "header", name = "Active Reminders", order = 500 }
    args.activeDesc = {
        type = "description", order = 501, fontSize = "medium",
        name = function()
            local db = GetDB(); if not db then return "" end
            local count = 0
            for _, v in pairs(db.whitelist or {}) do if v then count = count + 1 end end
            if count == 0 then
                return "|cff888888No reminders yet. Select a spell above and click Create Reminder.|r"
            end
            return string.format("|cff888888%d active reminder(s). Click to expand settings.|r", count)
        end,
    }

    -- Active spell reminders
    if db then
        local activeOrder = 510
        -- Spells
        for k, enabled in pairs(db.whitelist or {}) do
            if enabled then
                local isItem = type(k) == "string" and k:match("^i:(%d+)") ~= nil
                local id
                if isItem then id = tonumber(k:match("^i:(%d+)"))
                else id = tonumber(k) end
                if id then
                    local entryKey = isItem and ("active_i_"..id) or ("active_s_"..id)
                    args[entryKey] = CreateActiveReminderEntry(id, isItem, activeOrder)
                    activeOrder = activeOrder + 1
                end
            end
        end
    end

    -- ── APPEARANCE & AUDIO TAB (nested under tracked group) ---------
    -- Returned as sibling tab via childGroups="tab" on parent

    return {
        type        = "group",
        name        = "Cooldown Reminder",
        childGroups = "tab",
        args = {
            tracked = {
                type  = "group",
                name  = "Tracked Spells & Items",
                order = 1,
                args  = args,
            },
            appearance = {
                type  = "group",
                name  = "Appearance & Audio",
                order = 2,
                args  = {
                    zoneHeader = { type="header", name="Enabled In", order=1 },
                    enabledInWorld = {
                        type="toggle", name="World", order=2,
                        get=function() local d=GetDB(); return d and d.enabledInWorld~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.enabledInWorld=v; GetEngine():_EvaluateZoneEnabled() end end,
                    },
                    enabledInDungeons = {
                        type="toggle", name="Dungeons", order=3,
                        get=function() local d=GetDB(); return d and d.enabledInDungeons~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.enabledInDungeons=v; GetEngine():_EvaluateZoneEnabled() end end,
                    },
                    enabledInRaids = {
                        type="toggle", name="Raids", order=4,
                        get=function() local d=GetDB(); return d and d.enabledInRaids~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.enabledInRaids=v; GetEngine():_EvaluateZoneEnabled() end end,
                    },
                    enabledInArena = {
                        type="toggle", name="Arena", order=5,
                        get=function() local d=GetDB(); return d and d.enabledInArena~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.enabledInArena=v; GetEngine():_EvaluateZoneEnabled() end end,
                    },
                    appearHeader = { type="header", name="Appearance", order=10 },
                    iconEnabled = {
                        type="toggle", name="Show pulse icon",
                        desc="Master switch for the pulse icon. When off, no spell shows an icon (sound/TTS only). When on, each spell's own Show Icon toggle controls whether the icon shows for that specific reminder.",
                        order=10.5, width="full",
                        get=function() local d=GetDB(); return d and d.iconEnabled~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.iconEnabled=v end end,
                    },
                    cancelOnCast = {
                        type="toggle", name="Cancel pulse on cast",
                        desc="When the user casts a spell, immediately kill any visible or queued pulse for that same spell. The reminder's job is done once the spell is actually cast.",
                        order=10.6, width="full",
                        get=function() local d=GetDB(); return d and d.cancelOnCast~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.cancelOnCast=v end end,
                    },
                    queueMode = {
                        type="select", name="Overlap Behavior",
                        desc="How to handle a new alert when the pulse icon is already animating.\n\n"
                           .. "|cffffd200Replace|r — new alert immediately replaces the current icon (classic pop-up behavior).\n\n"
                           .. "|cffffd200Queue|r — new alerts wait their turn; each shows at center after the previous finishes fading.\n\n"
                           .. "|cffffd200Stack|r — icons display side-by-side like a dynamic group. Newest appears next to the existing one and they share the display; each fades out on its own timer.\n\n"
                           .. "Sounds/TTS always play immediately regardless of this setting.",
                        order=11, width=1.6,
                        values={ replace="Replace", queue="Queue", stack="Stack (side-by-side)" },
                        sorting={"replace","queue","stack"},
                        get=function() local d=GetDB(); return (d and d.queueMode) or "queue" end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            local oldMode = d.queueMode
                            d.queueMode = v
                            -- Keep legacy field in sync for backwards safety
                            d.noOverlapAlerts = (v == "queue")
                            -- Mode change requires a clean slate — without this,
                            -- leftover stack extras / queued pulses from the
                            -- previous mode confuse the new mode's routing
                            -- and effectively force a /reload to recover.
                            if oldMode ~= v and CR.FlushPulseState then
                                CR.FlushPulseState()
                            end
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    stackDirection = {
                        type="select", name="Stack Direction",
                        desc="Which side new icons appear on (Stack mode only)",
                        order=11.1, width=0.8,
                        values={ left="Left", right="Right" },
                        sorting={"right","left"},
                        disabled=function() local d=GetDB(); return (d and d.queueMode) ~= "stack" end,
                        get=function() local d=GetDB(); return (d and d.stackDirection) or "right" end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.stackDirection = v
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    stackSpacing = {
                        type="range", name="Stack Spacing",
                        desc="Pixel gap between stacked icons (Stack mode only). Negative values overlap icons.",
                        order=11.2, width=1.2, min=-32, max=96, step=1,
                        disabled=function() local d=GetDB(); return (d and d.queueMode) ~= "stack" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.stackSpacing)) or 4 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.stackSpacing = math.floor(v + 0.5)
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    replaceGuard = {
                        type="range", name="Replace Guard",
                        desc="Seconds a Replace-mode pulse is protected from being replaced by a newer alert. "
                           .. "0 = replace instantly. Higher values ensure brief pulses don't get cut off before the user can see them. (Replace mode only)",
                        order=11.3, width=1.5, min=0, max=2.0, step=0.05,
                        disabled=function() local d=GetDB(); return (d and d.queueMode) ~= "replace" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.replaceGuard)) or 0.4 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.replaceGuard = math.floor(v * 100 + 0.5) / 100
                        end,
                    },
                    queueMaxLen = {
                        type="range", name="Queue Max Length",
                        desc="Maximum number of alerts that can stack up in the queue. When full, the oldest queued alert is dropped. (Queue mode only)",
                        order=11.4, width=1.2, min=1, max=10, step=1,
                        disabled=function() local d=GetDB(); return (d and d.queueMode) ~= "queue" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.queueMaxLen)) or 3 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.queueMaxLen = math.floor(v + 0.5)
                        end,
                    },
                    queueInterDelay = {
                        type="range", name="Queue Gap",
                        desc="Seconds of pause between the fade-out of one queued pulse and the appearance of the next. "
                           .. "0 = back-to-back (the next pulse starts the instant the previous finishes fading). (Queue mode only)",
                        order=11.5, width=1.5, min=0, max=2.0, step=0.05,
                        disabled=function() local d=GetDB(); return (d and d.queueMode) ~= "queue" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.queueInterDelay)) or 0 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.queueInterDelay = math.floor(v * 100 + 0.5) / 100
                        end,
                    },
                    lockPosition = {
                        type="toggle", name="Lock position",
                        desc="Lock the pulse icon position",
                        order=12,
                        get=function() local d=GetDB(); return d and d.locked~=false end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.locked=v
                            if CR.ApplySettings then CR.ApplySettings() end
                            if v then CR.HideAnchor() else CR.ShowAnchor() end
                        end,
                    },
                    showAnchor = {
                        type="execute", name="Show Anchor",
                        desc="Unlock and show the draggable anchor to reposition the pulse icon",
                        order=13,
                        func=function()
                            local d=GetDB(); if not d then return end
                            d.locked=false
                            if CR.ApplySettings then CR.ApplySettings() end
                            if CR.ShowAnchor then CR.ShowAnchor() end
                            NotifyChange()
                        end,
                    },
                    posHeader = { type="header", name="Position", order=14 },
                    posX = {
                        type="input", name="X", order=15, width=0.5,
                        get=function() local d=GetDB(); return d and tostring(d.x or 0) or "0" end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            local n=tonumber(v); if n then d.x=math.floor(n+0.5) end
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    posY = {
                        type="input", name="Y", order=16, width=0.5,
                        get=function() local d=GetDB(); return d and tostring(d.y or 120) or "120" end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            local n=tonumber(v); if n then d.y=math.floor(n+0.5) end
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    posPreview = {
                        type="execute", name="Preview Alert", order=16.5, width=1.0,
                        desc="Fire a single test pulse at the current position/size",
                        func=function()
                            if CR.TestPulse then CR.TestPulse() end
                        end,
                    },
                    posPreviewMulti = {
                        type="execute", name="Preview Multiple", order=16.6, width=1.2,
                        desc="Fire 3 staggered test pulses so you can see Queue / Stack behavior in action",
                        func=function()
                            if CR.TestPulseMultiple then CR.TestPulseMultiple(3, 0.25) end
                        end,
                    },
                    pulseDuration = {
                        type="range", name="Pulse Duration",
                        desc="How long the pulse stays on screen (seconds). For animated styles, the entire animation sequence is scaled to this duration.",
                        order=17, width=1.5, min=0.1, max=5.0, step=0.05,
                        get=function() local d=GetDB(); return d and d.pulseDuration or 1.0 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.pulseDuration=math.floor(v*100+0.5)/100
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    iconSize = {
                        type="range", name="Icon Size",
                        order=18, width=1.5, min=32, max=256, step=1,
                        get=function() local d=GetDB(); return d and d.size or 64 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.size=math.floor(v+0.5)
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    iconOpacity = {
                        type="range", name="Icon Opacity",
                        order=19, width=1.5, min=0.1, max=1.0, step=0.05, isPercent=true,
                        get=function() local d=GetDB(); return d and d.iconOpacity or 1.0 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.iconOpacity=math.floor(v*100+0.5)/100
                            if CR.ApplySettings then CR.ApplySettings() end
                        end,
                    },
                    resetAppearance = {
                        type="execute", name="Reset to Defaults", order=20,
                        func=function()
                            local d=GetDB(); if not d then return end
                            d.size=64; d.iconOpacity=1; d.point="CENTER"; d.relPoint="CENTER"
                            d.x=0; d.y=120; d.pulseDuration=1.00; d.locked=true
                            d.queueMode="queue"; d.noOverlapAlerts=true
                            d.stackDirection="right"; d.stackSpacing=4
                            d.replaceGuard=0.4; d.queueMaxLen=3; d.queueInterDelay=0
                            d.animStyle="fade"
                            d.animFadeSmoothing="OUT"
                            d.animFlashSpeed=0.10
                            d.animZoomStart=0.70
                            d.animZoomPeak=1.15
                            d.animZoomPopTime=0.12
                            d.animZoomSettleTime=0.08
                            if CR.FlushPulseState then CR.FlushPulseState() end
                            if CR.ApplySettings then CR.ApplySettings() end
                            if CR.HideAnchor then CR.HideAnchor() end
                            NotifyChange()
                        end,
                    },

                    -- ─── ANIMATION TUNING ─────────────────────────────
                    -- Per-style speed / shape parameters. Each control is
                    -- only visible when the matching style is the active
                    -- default.
                    animationHeader = {
                        type="header", name="Animation Tuning", order=25,
                    },
                    animationDesc = {
                        type="description", order=25.04, fontSize="small",
                        name="Pick the animation style and fine-tune its entrance phase. Pulse Duration above sets the total on-screen time; the entrance is subtracted from it and the remainder is the trailing fade.",
                    },
                    animStyle = {
                        type="select", name="Default Animation",
                        desc="Animation style used when a trigger doesn't override it. Per-trigger settings (in each spell's Triggers list) take priority.",
                        order=25.05, width=1.5,
                        values={
                            ["fade"]    = "Fade",
                            ["no_fade"] = "No Fade (snap off)",
                            ["flash"]   = "Flash (urgent)",
                            ["zoom"]    = "Zoom (pop in + fade)",
                        },
                        sorting={"fade","no_fade","flash","zoom"},
                        get=function() local d=GetDB(); return (d and d.animStyle) or "fade" end,
                        set=function(_,v) local d=GetDB(); if d then d.animStyle=v end end,
                    },

                    -- Fade params
                    animFadeHeader = {
                        type="description", order=25.10, fontSize="medium",
                        name="|cffffd200Fade|r",
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "fade" end,
                    },
                    animFadeSmoothing = {
                        type="select", name="Fade Curve",
                        desc=
                            "Shape of the fade-out over time.\n\n"
                            .. "|cffffd200Linear|r — constant rate (steady fade).\n\n"
                            .. "|cffffd200Ease Out|r (default) — fades fast at first, slow at the end (lingers).\n\n"
                            .. "|cffffd200Ease In|r — fades slow at first, then snaps off at the end.\n\n"
                            .. "|cffffd200Ease In/Out|r — slow at both ends, fast in the middle.",
                        order=25.11, width=1.5,
                        values={
                            ["NONE"]   = "Linear",
                            ["OUT"]    = "Ease Out (default)",
                            ["IN"]     = "Ease In",
                            ["IN_OUT"] = "Ease In/Out",
                        },
                        sorting={"NONE","OUT","IN","IN_OUT"},
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "fade" end,
                        get=function() local d=GetDB(); return (d and d.animFadeSmoothing) or "OUT" end,
                        set=function(_,v) local d=GetDB(); if d then d.animFadeSmoothing=v end end,
                    },

                    -- Flash params
                    animFlashHeader = {
                        type="description", order=25.20, fontSize="medium",
                        name="|cffffd200Flash|r",
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "flash" end,
                    },
                    animFlashSpeed = {
                        type="range", name="Flash Step Speed",
                        desc="How fast each individual flash bounce plays (seconds per step). 4 steps total. Lower = more rapid blinking.",
                        order=25.21, width=1.5, min=0.03, max=0.30, step=0.01,
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "flash" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.animFlashSpeed)) or 0.10 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.animFlashSpeed = math.floor(v * 100 + 0.5) / 100
                        end,
                    },

                    -- Zoom params
                    animZoomHeader = {
                        type="description", order=25.30, fontSize="medium",
                        name="|cffffd200Zoom|r",
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "zoom" end,
                    },
                    animZoomStart = {
                        type="range", name="Zoom Start Scale",
                        desc="Size the icon starts at, relative to its final size. Smaller values = bigger pop-in effect. 1.0 = no pop-in.",
                        order=25.31, width=1.5, min=0.30, max=1.00, step=0.05,
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "zoom" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.animZoomStart)) or 0.70 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.animZoomStart = math.floor(v * 100 + 0.5) / 100
                        end,
                    },
                    animZoomPeak = {
                        type="range", name="Zoom Peak Scale",
                        desc="Size of the overshoot at the top of the pop-in (the icon briefly grows past its final size before settling). 1.0 = no overshoot.",
                        order=25.32, width=1.5, min=1.00, max=1.50, step=0.05,
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "zoom" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.animZoomPeak)) or 1.15 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.animZoomPeak = math.floor(v * 100 + 0.5) / 100
                        end,
                    },
                    animZoomPopTime = {
                        type="range", name="Zoom Pop Speed",
                        desc="Seconds for the pop-in (start scale → peak scale). Lower = snappier entrance.",
                        order=25.33, width=1.5, min=0.04, max=0.40, step=0.01,
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "zoom" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.animZoomPopTime)) or 0.12 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.animZoomPopTime = math.floor(v * 100 + 0.5) / 100
                        end,
                    },
                    animZoomSettleTime = {
                        type="range", name="Zoom Settle Speed",
                        desc="Seconds for the settle (peak scale → final size). Higher = softer landing.",
                        order=25.34, width=1.5, min=0.02, max=0.30, step=0.01,
                        hidden=function() local d=GetDB(); return (d and d.animStyle) ~= "zoom" end,
                        get=function() local d=GetDB(); return (d and tonumber(d.animZoomSettleTime)) or 0.08 end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            d.animZoomSettleTime = math.floor(v * 100 + 0.5) / 100
                        end,
                    },

                    animResetTuning = {
                        type="execute", name="Reset Animation Tuning", order=25.90,
                        hidden=function()
                            local d=GetDB()
                            local s = d and d.animStyle
                            return s == "no_fade"
                        end,
                        func=function()
                            local d=GetDB(); if not d then return end
                            d.animFadeSmoothing="OUT"
                            d.animFlashSpeed=0.10
                            d.animZoomStart=0.70
                            d.animZoomPeak=1.15
                            d.animZoomPopTime=0.12
                            d.animZoomSettleTime=0.08
                            NotifyChange()
                        end,
                    },
                    audioHeader = { type="header", name="Audio", order=30 },
                    soundEnabled = {
                        type="toggle", name="Enable sound", order=31,
                        desc="Master switch for sound/TTS. When off, no spell plays audio. When on, each spell's own Play Sound toggle controls whether that specific reminder plays audio.",
                        get=function() local d=GetDB(); return d and d.soundEnabled~=false end,
                        set=function(_,v) local d=GetDB(); if d then d.soundEnabled=v end end,
                    },
                    soundChannel = {
                        type="select", name="Sound Channel", order=32,
                        values={Master="Master",SFX="SFX",Music="Music",Ambience="Ambience",Dialog="Dialog"},
                        sorting={"Master","SFX","Music","Ambience","Dialog"},
                        get=function() local d=GetDB(); return d and d.soundChannel or "Master" end,
                        set=function(_,v) local d=GetDB(); if d then d.soundChannel=v end end,
                    },
                    defaultSound = {
                        type="select", name="Default Alert Sound",
                        desc="Sound when no per-spell override is set",
                        order=33, width=1.5,
                        values=function() local t={}; for _,s in ipairs(GetSoundList()) do t[s]=s end; return t end,
                        sorting=GetSoundList,
                        get=function() local d=GetDB(); return d and d.soundName or "Default" end,
                        set=function(_,v) local d=GetDB(); if d then d.soundName=v end end,
                    },
                    previewSound = {
                        type="execute", name="Preview", order=34, width=0.4,
                        func=function()
                            local d=GetDB(); if not d then return end
                            local snd=d.soundName or "Default"
                            if snd=="None" then return end
                            if snd=="Default" then PlaySound(d.fallbackSoundKitID or 12867, d.soundChannel or "Master"); return end
                            local lsm=LibStub and LibStub("LibSharedMedia-3.0",true)
                            local path=lsm and lsm:Fetch("sound",snd,true)
                            if path then PlaySoundFile(path, d.soundChannel or "Master")
                            else PlaySound(d.fallbackSoundKitID or 12867, d.soundChannel or "Master") end
                        end,
                    },
                    cutoffPreviousSound = {
                        type   = "toggle",
                        name   = "Cut off previous sound",
                        desc   = "When ON, a new alert sound stops the previous one. Useful for short cooldowns where back-to-back triggers cause overlapping/delayed audio. Also applies to TTS.",
                        order  = 35,
                        width  = 1.5,
                        get    = function() local d=GetDB(); return d and d.cutoffPreviousSound or false end,
                        set    = function(_, v) local d=GetDB(); if d then d.cutoffPreviousSound=v end end,
                    },
                    cutoffFadeTime = {
                        type   = "range",
                        name   = "Cutoff fade-out (seconds)",
                        desc   = "How long the previous sound fades out when cut off. 0 = hard cut (clicky). 0.1-0.2 = smooth blend. Higher values let more of the old sound bleed into the new one.",
                        order  = 36,
                        width  = 1.5,
                        min    = 0,
                        max    = 0.5,
                        step   = 0.05,
                        bigStep = 0.05,
                        disabled = function() local d=GetDB(); return not (d and d.cutoffPreviousSound) end,
                        get    = function() local d=GetDB(); return d and d.cutoffFadeTime or 0.1 end,
                        set    = function(_, v) local d=GetDB(); if d then d.cutoffFadeTime=tonumber(v) or 0.1 end end,
                    },
                    ttsHeader = { type="header", name="Text-to-Speech", order=40 },
                    ttsInfo = {
                        type="description",
                        name="|cff00ccffSet TTS text in the spell's row above. When set, TTS takes priority over the sound for that spell.|r",
                        order=41, width="full", fontSize="medium",
                    },
                    ttsVoiceOverride = {
                        type="select", name="Voice",
                        desc="Default uses your WoW TTS voice (Esc > Options > Accessibility > Text to Speech). "
                           .. "Male/Female overrides it by picking a matching voice from the system list.",
                        order=42, width=1.4,
                        values={
                            ["default"] = "Default (WoW setting)",
                            ["male"]    = "Male",
                            ["female"]  = "Female",
                        },
                        sorting={"default","male","female"},
                        get=function() local d=GetDB(); return (d and d.ttsVoiceOverride) or "default" end,
                        set=function(_,v) local d=GetDB(); if d then d.ttsVoiceOverride=v end end,
                    },
                    ttsRateUseCustom = {
                        type="toggle", name="Override speech rate",
                        desc="Use a custom speech rate for ArcUI TTS instead of the WoW default.",
                        order=43, width=1.0,
                        get=function() local d=GetDB(); return d and d.ttsRateOverride ~= nil end,
                        set=function(_,v)
                            local d=GetDB(); if not d then return end
                            if v then
                                -- Seed from current WoW rate so the slider starts in a sensible spot
                                if C_TTSSettings and C_TTSSettings.GetSpeechRate then
                                    d.ttsRateOverride = C_TTSSettings.GetSpeechRate() or 0
                                else
                                    d.ttsRateOverride = 0
                                end
                            else
                                d.ttsRateOverride = nil
                            end
                        end,
                    },
                    ttsRate = {
                        type="range", name="Speech Rate",
                        desc="-10 = slowest, 0 = normal, 10 = fastest",
                        order=44, width=1.6, min=-10, max=10, step=1,
                        disabled=function() local d=GetDB(); return not (d and d.ttsRateOverride ~= nil) end,
                        get=function() local d=GetDB(); return (d and tonumber(d.ttsRateOverride)) or 0 end,
                        set=function(_,v) local d=GetDB(); if d and d.ttsRateOverride ~= nil then d.ttsRateOverride=math.floor(v+0.5) end end,
                    },
                    ttsPreview = {
                        type="execute", name="Preview Voice", order=46, width=1.0,
                        func=function()
                            local d = GetDB(); if not d then return end
                            local voiceID = (CR.ResolveTTSVoiceID and CR.ResolveTTSVoiceID(d.ttsVoiceOverride)) or 0
                            local rate
                            if d.ttsRateOverride ~= nil then
                                rate = tonumber(d.ttsRateOverride) or 0
                            elseif C_TTSSettings and C_TTSSettings.GetSpeechRate then
                                rate = C_TTSSettings.GetSpeechRate()
                            end
                            if CR.SpeakTTS then
                                if not CR.SpeakTTS("Cooldown Reminder test", voiceID, rate) then
                                    print("|cff00ccffArcUI CR|r: TTS API not available")
                                end
                            end
                        end,
                    },
                },
            },
        },
    }
end