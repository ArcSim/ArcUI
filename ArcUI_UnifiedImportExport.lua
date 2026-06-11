-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI_UnifiedImportExport.lua
-- Single import window. Paste any ArcUI export string — type is auto-detected.
-- Shows the correct import UI for each type (Bars, CDM, Master).
-- Fully backwards compatible with all existing export strings.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON_NAME, ns = ...
ns.UnifiedIE = ns.UnifiedIE or {}
local UIE = ns.UnifiedIE

local MSG_PREFIX = "|cff00ccffArcUI|r: "

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

local state = {
    importString  = "",
    detectedType  = nil,   -- "bars" | "cdm" | "master" | "cr"
    detectedData  = nil,
    importError   = nil,

    -- Bars-specific
    barsImportMode = "add",

    -- CDM-specific (what to import)
    cdmImportGroupLayouts   = true,
    cdmImportPositions      = true,
    cdmImportIconSettings   = true,
    cdmImportGlobalSettings = true,
    cdmImportFlattenGlobals = false,
    cdmImportGroupSettings  = true,
    cdmImportProfiles       = true,

    -- Cooldown Reminder-specific
    crImportMode     = "merge",  -- "merge" | "replace"
    crImportGlobals  = true,
    crImportPerSpell = true,

    -- Master-specific
    masterImportMode        = "merge",
    masterActiveOverrides   = {},  -- [specKey] = chosenProfileName
    masterSelectedProfiles  = {},  -- [specKey.."|"..profileName] = bool
}

-- Live args tables referenced by the AceConfig options group for Master.
-- ME.BuildImportSelectorArgs wipes+fills them when data is parsed.
local masterActiveSelectorArgs = {}
local masterProfileFilterArgs  = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- DETECTION
-- Tries each parser. Each checks its own prefix internally.
-- Old strings (no external tag) work as-is.
-- ═══════════════════════════════════════════════════════════════════════════

local function TryDetect(str)
    if not str or str == "" then return nil, nil, nil end

    -- Master (LibSerialize + ARCMASTER prefix)
    if ns.CDMMasterExport and ns.CDMMasterExport.ParseImportString then
        local data, err = ns.CDMMasterExport.ParseImportString(str)
        if data then return "master", data, nil end
    end

    -- CDM (loadstring-based + ARCCDM prefix)
    if ns.CDMImportExport and ns.CDMImportExport.ParseImportString then
        local data, err = ns.CDMImportExport.ParseImportString(str)
        if data then return "cdm", data, nil end
    end

    -- Bars (AceSerializer + ARCUI_BARS prefix)
    if ns.BarsImportExport and ns.BarsImportExport.ParseImportString then
        local data, err = ns.BarsImportExport.ParseImportString(str)
        if data then return "bars", data, nil end
    end

    -- Cooldown Reminder (AceSerializer + ARCUI_CR prefix)
    if ns.CRImportExport and ns.CRImportExport.ParseImportString then
        local data, err = ns.CRImportExport.ParseImportString(str)
        if data then return "cr", data, nil end
    end

    return nil, nil, "Could not detect import type — invalid or corrupted string"
end

local function OnStringParsed(t, d)
    state.detectedType = t
    state.detectedData = d

    -- Reset type-specific state
    state.barsImportMode = "add"
    state.masterImportMode = "merge"
    state.crImportMode = "merge"
    state.crImportGlobals = true
    state.crImportPerSpell = true
    wipe(state.masterActiveOverrides)

    if t == "master" and d and ns.CDMMasterExport and ns.CDMMasterExport.BuildImportSelectorArgs then
        -- Seed active overrides from the export's own activeProfile fields
        for specKey, specEntry in pairs(d.specs or {}) do
            state.masterActiveOverrides[specKey] = specEntry.activeProfile or nil
        end
        ns.CDMMasterExport.BuildImportSelectorArgs(
            d,
            state.masterActiveOverrides,
            state.masterSelectedProfiles,
            masterActiveSelectorArgs,
            masterProfileFilterArgs
        )
    else
        wipe(masterActiveSelectorArgs)
        wipe(masterProfileFilterArgs)
        wipe(state.masterSelectedProfiles)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PREVIEW TEXT
-- ═══════════════════════════════════════════════════════════════════════════

local TYPE_LABELS = {
    bars   = "|cffFFD100Bars Export|r",
    cdm    = "|cff00CCFFIcon Manager Export|r",
    master = "|cff00FF88Master Export|r",
    cr     = "|cffFF7777Cooldown Reminder Export|r",
}

local function BuildPreview(t, d)
    if not t or not d then return "" end
    local label = TYPE_LABELS[t] or t
    local lines = { "|cff00FF00Detected:|r " .. label .. "\n" }

    if t == "master" then
        if ns.CDMMasterExport and ns.CDMMasterExport.GenerateImportPreview then
            table.insert(lines, ns.CDMMasterExport.GenerateImportPreview(d))
        end

    elseif t == "cdm" then
        local stats = ns.CDMImportExport and ns.CDMImportExport.GetImportStats(d)
        if stats then
            -- Spec mismatch check
            local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
            if not currentSpec then
                local specIdx = GetSpecialization() or 1
                local _, _, classID = UnitClass("player")
                currentSpec = "class_" .. (classID or 0) .. "_spec_" .. specIdx
            end
            if d.sourceSpec and d.sourceSpec ~= currentSpec then
                local toDisplay = ns.CDMImportExport and ns.CDMImportExport.SpecKeyToDisplayName
                local sourceDisplay = toDisplay and toDisplay(d.sourceSpec) or d.sourceSpec
                local currentDisplay = toDisplay and toDisplay(currentSpec) or currentSpec
                return "|cffff4444Wrong Spec!|r\n\n" ..
                    "This export is for: |cffffd100" .. sourceDisplay .. "|r\n" ..
                    "You are playing:     |cffffd100" .. currentDisplay .. "|r\n\n" ..
                    "|cff888888Switch to the correct spec before importing.|r"
            end
            local timeStr = stats.timestamp and date("%Y-%m-%d %H:%M", stats.timestamp) or "Unknown"
            local lines = {
                "|cff00ff00Valid export detected!|r",
                "",
                "|cff888888From:|r " .. (stats.exportedBy or "?") .. " - " .. (stats.realm or "?"),
                "|cff888888Date:|r " .. timeStr,
                "|cff888888Version:|r " .. (d.version or "?"),
                "",
                "|cff00ccffContents:|r",
                "  Groups: |cffffffff" .. stats.groups .. "|r",
                "  Icon Positions: |cffffffff" .. stats.savedPositions .. "|r",
                "  Free Icons: |cffffffff" .. stats.freeIcons .. "|r",
                "  Layout Profiles: |cffffffff" .. stats.layoutProfiles .. "|r",
                "  Icon Settings: |cffffffff" .. stats.iconSettings .. "|r",
                "  Global Defaults: " .. (stats.hasGlobalAuraSettings and "|cff00ff00Aura|r " or "") .. (stats.hasGlobalCooldownSettings and "|cff00ff00Cooldown|r" or ""),
                "  Group Settings: " .. (stats.hasGroupSettings and "|cff00ff00Yes|r" or "|cff666666No|r"),
            }
            if (stats.arcAuras or 0) > 0 or (stats.arcAurasSpells or 0) > 0 then
                table.insert(lines, "")
                table.insert(lines, "|cff00ccffArc Auras:|r")
                if (stats.arcAuras or 0) > 0 then
                    table.insert(lines, "  Tracked Items: |cffffffff" .. stats.arcAuras .. "|r")
                end
                if (stats.arcAurasSpells or 0) > 0 then
                    table.insert(lines, "  Tracked Spells: |cffffffff" .. stats.arcAurasSpells .. "|r")
                end
            end
            table.insert(lines, "")
            if stats.hasCDMNativeLayout then
                local name = stats.cdmNativeLayoutName or "Unknown"
                table.insert(lines, "|cff00ccffCDM Layout:|r      |cff00ff00" .. name .. "|r")
            else
                table.insert(lines, "|cff00ccffCDM Layout:|r      |cff666666Not included|r")
            end
            return table.concat(lines, "\n")
        end

    elseif t == "bars" then
        local auraCount     = d.bars and #d.bars or 0
        local cooldownCount = d.cooldownBars and #d.cooldownBars or 0
        local resourceCount = d.resourceBars and #d.resourceBars or 0
        local timerCount    = d.timerBars and #d.timerBars or 0
        local total         = auraCount + cooldownCount + resourceCount + timerCount
        table.insert(lines, string.format(
            "|cff888888From:|r %s @ %s\n",
            d.exportedBy or "?", d.realm or "?"
        ))
        table.insert(lines, string.format(
            "%d bar(s) — |cffFFFF00%d aura|r  |cff00FFFF%d cooldown|r  |cff00FF88%d resource|r  |cffCC66FF%d timer|r",
            total, auraCount, cooldownCount, resourceCount, timerCount
        ))

    elseif t == "cr" then
        if ns.CRImportExport and ns.CRImportExport.GenerateImportPreview then
            table.insert(lines, ns.CRImportExport.GenerateImportPreview(d))
        end
    end

    return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMPORT DISPATCHER
-- ═══════════════════════════════════════════════════════════════════════════

local function DoImport()
    if not state.detectedType or not state.detectedData then
        print(MSG_PREFIX .. "|cffff0000No valid import data.|r")
        return
    end

    if state.detectedType == "master" then
        local success, result = ns.CDMMasterExport.Import(
            state.detectedData,
            state.masterImportMode,
            state.masterActiveOverrides,
            state.masterSelectedProfiles
        )
        if success then
            print(MSG_PREFIX .. "|cff00ff00" .. result .. "|r")
            StaticPopup_Show("ARCUI_MASTER_IMPORT_RELOAD")
        else
            print(MSG_PREFIX .. "|cffff0000Import failed:|r " .. (result or "Unknown"))
        end

    elseif state.detectedType == "cdm" then
        local success, result = ns.CDMImportExport.Import(state.importString, {
            importGroupLayouts   = state.cdmImportGroupLayouts,
            importPositions      = state.cdmImportPositions,
            importIconSettings   = state.cdmImportIconSettings,
            importGlobalSettings = state.cdmImportGlobalSettings,
            importFlattenGlobals = state.cdmImportFlattenGlobals,
            importGroupSettings  = state.cdmImportGroupSettings,
            importProfiles       = state.cdmImportProfiles,
        })
        if success then
            print(MSG_PREFIX .. "|cff00ff00CDM import successful!|r")
            StaticPopup_Show("ARCUI_RELOAD_AFTER_IMPORT")
        else
            print(MSG_PREFIX .. "|cffff0000Import failed:|r " .. (result or "Unknown"))
        end

    elseif state.detectedType == "bars" then
        local success, result = ns.BarsImportExport.ImportBars(state.detectedData, state.barsImportMode)
        if success then
            print(MSG_PREFIX .. "|cff00ff00" .. result .. "|r")
        else
            print(MSG_PREFIX .. "|cffff0000Import failed:|r " .. (result or "Unknown"))
        end

    elseif state.detectedType == "cr" then
        local success, result = ns.CRImportExport.Import(state.detectedData, {
            importMode      = state.crImportMode,
            importGlobals   = state.crImportGlobals,
            importPerSpell  = state.crImportPerSpell,
        })
        if success then
            print(MSG_PREFIX .. "|cff00ff00Cooldown Reminder import: " .. (result or "ok") .. "|r")
        else
            print(MSG_PREFIX .. "|cffff0000Import failed:|r " .. (result or "Unknown"))
        end
    end

    -- Clear after import
    state.importString = ""
    state.detectedType = nil
    state.detectedData = nil
    state.importError  = nil
    wipe(state.masterActiveOverrides)
    wipe(state.masterSelectedProfiles)
    wipe(masterActiveSelectorArgs)
    wipe(masterProfileFilterArgs)

    local ACR = LibStub("AceConfigRegistry-3.0", true)
    if ACR then ACR:NotifyChange("ArcUI") end
end

local function DoClear()
    state.importString = ""
    state.detectedType = nil
    state.detectedData = nil
    state.importError  = nil
    wipe(state.masterActiveOverrides)
    wipe(state.masterSelectedProfiles)
    wipe(masterActiveSelectorArgs)
    wipe(masterProfileFilterArgs)
    local ACR = LibStub("AceConfigRegistry-3.0", true)
    if ACR then ACR:NotifyChange("ArcUI") end
end

local function GetConfirmText()
    if state.detectedType == "cdm" then
        return "This will REPLACE your current Icon Manager settings.\n\nAre you sure?"
    elseif state.detectedType == "master" and state.masterImportMode == "replace" then
        return "Replace mode will WIPE existing profiles for matching specs.\n\nAre you sure?"
    elseif state.detectedType == "bars" and state.barsImportMode == "replace" then
        return "Replace mode will wipe ALL existing bars.\n\nAre you sure?"
    elseif state.detectedType == "cr" and state.crImportMode == "replace" then
        return "Replace mode will WIPE all current Cooldown Reminder spell/trigger configs.\n\nAre you sure?"
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS TABLE
-- ═══════════════════════════════════════════════════════════════════════════

function UIE.GetOptionsTable()
    return {
        type  = "group",
        name  = "Import",
        order = 1,
        args  = {

            -- ── Top description ──────────────────────────────────────────
            desc = {
                type     = "description",
                name     = "Paste any ArcUI export string — |cffFFD100Bars|r, |cff00CCFFIcon Manager|r, |cffFF7777Cooldown Reminder|r, or |cff00FF88Master Export|r. " ..
                           "The type is detected automatically. All existing export strings are supported.\n",
                order    = 1,
                fontSize = "medium",
            },

            -- ── Paste box ────────────────────────────────────────────────
            importString = {
                type      = "input",
                name      = "Paste Export String",
                order     = 2,
                multiline = 6,
                width     = "full",
                get = function() return state.importString end,
                set = function(_, val)
                    state.importString = val
                    if val and val ~= "" then
                        local t, d, err = TryDetect(val)
                        state.importError = err
                        if t and d then
                            OnStringParsed(t, d)
                        else
                            state.detectedType = nil
                            state.detectedData = nil
                        end
                    else
                        DoClear()
                    end
                end,
            },

            -- ── Detection status / preview ───────────────────────────────
            previewText = {
                type     = "description",
                name     = function()
                    if state.importError then
                        return "|cffff0000" .. state.importError .. "|r"
                    elseif state.detectedType and state.detectedData then
                        return BuildPreview(state.detectedType, state.detectedData)
                    else
                        return "|cff888888Paste a string above — type will be auto-detected.|r"
                    end
                end,
                order    = 3,
                fontSize = "medium",
            },

            -- ════════════════════════════════════════════════════════════
            -- BARS-SPECIFIC IMPORT UI
            -- ════════════════════════════════════════════════════════════
            barsOptionsHeader = {
                type   = "header",
                name   = "Bars Import Options",
                order  = 10,
                hidden = function() return state.detectedType ~= "bars" end,
            },
            barsImportMode = {
                type   = "select",
                name   = "Import Mode",
                order  = 11,
                width  = 1.2,
                hidden = function() return state.detectedType ~= "bars" end,
                values = {
                    add     = "Add to existing bars",
                    replace = "Replace all bars",
                },
                get = function() return state.barsImportMode end,
                set = function(_, val) state.barsImportMode = val end,
            },
            barsImportModeDesc = {
                type   = "description",
                name   = function()
                    if state.barsImportMode == "replace" then
                        return "|cffff6600WARNING: This will disable ALL existing bars!|r"
                    end
                    local emptyAura = 0
                    local db = ns.API and ns.API.GetDB and ns.API.GetDB()
                    if db and db.bars then
                        for i = 1, 500 do
                            local b = db.bars[i]
                            if not b or not b.tracking or not b.tracking.enabled then
                                emptyAura = emptyAura + 1
                            end
                        end
                    end
                    return string.format("|cff888888%d empty aura bar slots available.|r", emptyAura)
                end,
                order  = 12,
                hidden = function() return state.detectedType ~= "bars" end,
            },

            -- ════════════════════════════════════════════════════════════
            -- COOLDOWN REMINDER-SPECIFIC IMPORT UI
            -- ════════════════════════════════════════════════════════════
            crOptionsHeader = {
                type   = "header",
                name   = "Cooldown Reminder Import Options",
                order  = 16,
                hidden = function() return state.detectedType ~= "cr" end,
            },
            crImportMode = {
                type   = "select",
                name   = "Import Mode",
                order  = 17,
                width  = 1.2,
                hidden = function() return state.detectedType ~= "cr" end,
                values = {
                    merge   = "Merge (overwrite same spells, keep others)",
                    replace = "Replace all reminders",
                },
                get = function() return state.crImportMode end,
                set = function(_, val) state.crImportMode = val end,
            },
            crImportGlobals = {
                type   = "toggle",
                name   = "Import Global Settings",
                desc   = "Import the animation, queue/replace mode, position, audio, and other global settings.",
                order  = 18,
                width  = 1.2,
                hidden = function() return state.detectedType ~= "cr" end,
                get    = function() return state.crImportGlobals end,
                set    = function(_, v) state.crImportGlobals = v end,
            },
            crImportPerSpell = {
                type   = "toggle",
                name   = "Import Per-Spell Reminders",
                desc   = "Import the list of tracked spells/items, their per-spell trigger configs (animation, glow, priority, sound/TTS overrides), and per-spell delay/mute toggles.",
                order  = 19,
                width  = 1.2,
                hidden = function() return state.detectedType ~= "cr" end,
                get    = function() return state.crImportPerSpell end,
                set    = function(_, v) state.crImportPerSpell = v end,
            },
            crImportModeDesc = {
                type   = "description",
                name   = function()
                    if state.crImportMode == "replace" then
                        return "|cffff6600WARNING: This will WIPE all current Cooldown Reminder spell/trigger configs before importing.|r"
                    end
                    return "|cff888888Existing reminders not in the import will be kept. Same-spell entries get overwritten by the import.|r"
                end,
                order  = 19.5,
                hidden = function() return state.detectedType ~= "cr" end,
            },

            -- ════════════════════════════════════════════════════════════
            -- CDM-SPECIFIC IMPORT UI
            -- ════════════════════════════════════════════════════════════
            cdmOptionsHeader = {
                type   = "header",
                name   = "Icon Manager Import Options",
                order  = 20,
                hidden = function() return state.detectedType ~= "cdm" end,
            },
            cdmImportGroupLayouts = {
                type   = "toggle",
                name   = "Group Layouts",
                desc   = "Import group structure (positions, sizes, appearance)",
                order  = 21,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportGroupLayouts end,
                set    = function(_, v) state.cdmImportGroupLayouts = v end,
            },
            cdmImportPositions = {
                type   = "toggle",
                name   = "Icon Positions",
                desc   = "Import icon assignments to groups",
                order  = 22,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportPositions end,
                set    = function(_, v) state.cdmImportPositions = v end,
            },
            cdmImportIconSettings = {
                type   = "toggle",
                name   = "Icon Settings",
                desc   = "Import per-icon visual customizations",
                order  = 23,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportIconSettings end,
                set    = function(_, v) state.cdmImportIconSettings = v end,
            },
            cdmImportGlobalSettings = {
                type   = "toggle",
                name   = "Global Defaults",
                desc   = "Import global aura/cooldown default settings",
                order  = 24,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportGlobalSettings end,
                set    = function(_, v) state.cdmImportGlobalSettings = v end,
            },
            cdmImportFlattenGlobals = {
                type     = "toggle",
                name     = "Bake Globals into Icons",
                desc     = "Instead of overwriting your Global Defaults, merge the imported globals into each icon's per-icon settings. " ..
                           "The profile will look exactly as intended while your own Global Defaults stay untouched — " ..
                           "so your other profiles won't be affected.",
                order    = 24.5,
                width    = 1.4,
                hidden   = function() return state.detectedType ~= "cdm" end,
                disabled = function() return not state.cdmImportGlobalSettings end,
                get      = function() return state.cdmImportFlattenGlobals end,
                set      = function(_, v) state.cdmImportFlattenGlobals = v end,
            },
            cdmImportGroupSettings = {
                type   = "toggle",
                name   = "Group Settings",
                desc   = "Import spacing, scale, direction per viewer type",
                order  = 25,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportGroupSettings end,
                set    = function(_, v) state.cdmImportGroupSettings = v end,
            },
            cdmImportProfiles = {
                type   = "toggle",
                name   = "Layout Profiles",
                desc   = "Import layout profiles",
                order  = 26,
                width  = 0.7,
                hidden = function() return state.detectedType ~= "cdm" end,
                get    = function() return state.cdmImportProfiles end,
                set    = function(_, v) state.cdmImportProfiles = v end,
            },

            -- ════════════════════════════════════════════════════════════
            -- MASTER-SPECIFIC IMPORT UI
            -- ════════════════════════════════════════════════════════════
            masterOptionsHeader = {
                type   = "header",
                name   = "Master Import Options",
                order  = 30,
                hidden = function() return state.detectedType ~= "master" end,
            },
            masterImportMode = {
                type   = "select",
                name   = "Import Mode",
                order  = 31,
                width  = 1.2,
                hidden = function() return state.detectedType ~= "master" end,
                values = {
                    merge   = "Merge (add alongside existing)",
                    replace = "Replace (wipe matching specs first)",
                },
                get = function() return state.masterImportMode end,
                set = function(_, val) state.masterImportMode = val end,
            },
            masterImportModeDesc = {
                type   = "description",
                name   = function()
                    if state.masterImportMode == "merge" then
                        return "|cff888888Conflicting profile names are auto-renamed.|r"
                    else
                        return "|cffff6600WARNING: Existing profiles for matching specs will be wiped!|r"
                    end
                end,
                order  = 32,
                hidden = function() return state.detectedType ~= "master" end,
            },
            -- Per-spec active profile selectors (only appears when >1 profile per spec)
            masterActiveProfileHeader = {
                type   = "header",
                name   = "Active Profile Per Spec",
                order  = 33,
                hidden = function()
                    return state.detectedType ~= "master" or not next(masterActiveSelectorArgs)
                end,
            },
            masterActiveProfileDesc = {
                type     = "description",
                name     = "|cff888888Choose which profile becomes active for each spec after import.|r",
                order    = 34,
                fontSize = "medium",
                hidden   = function()
                    return state.detectedType ~= "master" or not next(masterActiveSelectorArgs)
                end,
            },
            masterActiveProfileSelectors = {
                type   = "group",
                name   = "",
                order  = 35,
                inline = true,
                hidden = function()
                    return state.detectedType ~= "master" or not next(masterActiveSelectorArgs)
                end,
                args   = masterActiveSelectorArgs,
            },
            -- Profile filter checkboxes
            masterProfileFilterHeader = {
                type     = "description",
                name     = "\n|cffffd700Choose which profiles to import:|r",
                order    = 36,
                fontSize = "medium",
                hidden   = function()
                    return state.detectedType ~= "master" or not next(masterProfileFilterArgs)
                end,
            },
            masterProfileFilter = {
                type   = "group",
                name   = "",
                order  = 37,
                inline = true,
                hidden = function()
                    return state.detectedType ~= "master" or not next(masterProfileFilterArgs)
                end,
                args   = masterProfileFilterArgs,
            },

            -- ════════════════════════════════════════════════════════════
            -- ACTION BUTTONS
            -- ════════════════════════════════════════════════════════════
            actionSpacer = {
                type   = "description",
                name   = "",
                order  = 90,
                hidden = function() return state.detectedType == nil end,
            },
            importBtn = {
                type     = "execute",
                name     = "Import",
                order    = 91,
                width    = 0.7,
                disabled = function() return state.detectedType == nil end,
                confirm  = GetConfirmText,
                func     = DoImport,
            },
            clearBtn = {
                type  = "execute",
                name  = "Clear",
                order = 92,
                width = 0.5,
                func  = DoClear,
            },
        },
    }
end

function ns.GetUnifiedImportExportOptionsTable()
    return UIE.GetOptionsTable()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHARACTER MIGRATION TAB
-- ═══════════════════════════════════════════════════════════════════════════

local MIG = {}

local function GetAllCharKeys()
    local keys = {}
    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if svChar then
        for k in pairs(svChar) do keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys
end

local function GetCurrentCharKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    if name and realm then return name .. " - " .. realm end
    return nil
end

-- Module-level so state survives AceConfig panel rebuilds
local migState = {
    fromKey  = nil,
    toName   = nil,
    toRealm  = nil,
}

function ns.GetMigrationOptionsTable()

    local NR = LibStub("AceConfigRegistry-3.0")

    local function BuildNewKey()
        local oldKey = migState.fromKey
        if not oldKey then return nil end
        local oldRealm = oldKey:match("%-+%s*(.+)$") or ""
        local realm = (migState.toRealm and migState.toRealm ~= "") and migState.toRealm or oldRealm
        local name  = migState.toName or ""
        if name == "" then return nil end
        return name .. (realm ~= "" and " - " .. realm or "")
    end

    local function DoMigrate()
        local oldKey = migState.fromKey
        local newKey = BuildNewKey()
        if not oldKey or not newKey then return end

        local svChar = ns.db and ns.db.sv and ns.db.sv.char
        if not svChar or not svChar[oldKey] then
            print("|cff00ccffArcUI Migration|r: Source character not found.")
            return
        end

        -- 1. Deep copy char data to new key, old key stays intact as a backup
        local function DeepCopy(orig)
            if type(orig) ~= "table" then return orig end
            local copy = {}
            for k, v in pairs(orig) do
                copy[DeepCopy(k)] = DeepCopy(v)
            end
            return copy
        end
        svChar[newKey] = DeepCopy(svChar[oldKey])

        -- Record old key as a backup so the UI can label it
        if not ns.db.global.migrationBackups then ns.db.global.migrationBackups = {} end
        ns.db.global.migrationBackups[oldKey] = true

        -- 2. Sweep global.sharedProfiles sourceChar references
        local gsp = ns.db.global and ns.db.global.sharedProfiles
        if gsp then
            for _, ref in pairs(gsp) do
                if ref.sourceChar == oldKey then ref.sourceChar = newKey end
            end
        end

        -- 3. Sweep global.defaultGroupTemplate sourceChar
        local tmpl = ns.db.global and ns.db.global.defaultGroupTemplate
        if tmpl and tmpl.sourceChar == oldKey then tmpl.sourceChar = newKey end

        -- 4. Sweep initializedCharacters across all AceDB profiles
        local profiles = ns.db.sv and ns.db.sv.profiles
        if profiles then
            for _, profData in pairs(profiles) do
                local ic = profData.cdmGroups and profData.cdmGroups.initializedCharacters
                if ic and ic[oldKey] then
                    ic[newKey] = ic[oldKey]
                    ic[oldKey] = nil
                end
            end
        end

        local oldName = oldKey:match("^(.-)%s*%-") or oldKey
        print("|cff00ccffArcUI Migration|r: '" .. oldKey .. "' → '" .. newKey .. "' complete. Old data kept as backup. Reload to apply.")
        migState.fromKey = nil
        migState.toName  = nil
        migState.toRealm = nil
        NR:NotifyChange("ArcUI")
    end

    local function GetCharValues()
        local vals = { [""] = "|cff666666Select character...|r" }
        local backups = ns.db.global and ns.db.global.migrationBackups or {}
        for _, k in ipairs(GetAllCharKeys()) do
            if backups[k] then
                vals[k] = k .. " |cff888888(Backup)|r"
            else
                vals[k] = k
            end
        end
        return vals
    end

    local function GetCharSorting()
        local order = { "" }
        for _, k in ipairs(GetAllCharKeys()) do order[#order + 1] = k end
        return order
    end

    local function CurrentCharFill()
        local cur = GetCurrentCharKey()
        if cur then
            migState.toName  = cur:match("^(.-)%s*%-") or cur
            migState.toRealm = cur:match("%-+%s*(.+)$") or ""
            NR:NotifyChange("ArcUI")
        end
    end

    local function GetNewKeyPreview()
        local newKey = BuildNewKey()
        if not newKey then return "" end
        return "|cff00ccffNew key: " .. newKey .. "|r"
    end

    -- A char entry left behind by "Delete Character" has cdmGroups/arcAuras nilled
    -- but the bare table still exists. Treat those as non-conflicting.
    local function HasMeaningfulData(entry)
        if type(entry) ~= "table" then return false end
        -- cdmGroups must have actual spec data, not just be an empty shell
        -- from a bad migration run
        local hasCDM = false
        if type(entry.cdmGroups) == "table" then
            if entry.cdmGroups.migratedFromProfile
            or (type(entry.cdmGroups.specData) == "table" and next(entry.cdmGroups.specData))
            or (type(entry.cdmGroups.layoutProfiles) == "table" and next(entry.cdmGroups.layoutProfiles)) then
                hasCDM = true
            end
        end
        local hasAuras = type(entry.arcAuras) == "table" and next(entry.arcAuras) ~= nil
        return hasCDM or hasAuras
    end

    local function IsReady()
        local oldKey = migState.fromKey
        local newKey = BuildNewKey()
        if not oldKey or not newKey then return false end
        if newKey == oldKey then return false end
        return true
    end

    local function TargetHasData()
        local newKey = BuildNewKey()
        if not newKey then return false end
        local svChar = ns.db and ns.db.sv and ns.db.sv.char
        return svChar and HasMeaningfulData(svChar[newKey])
    end

    return {
        type        = "group",
        name        = "Migration",
        childGroups = "tree",
        args = {
            header = {
                type     = "description",
                name     = "|cffd4af37Character Name / Realm Transfer|r",
                order    = 1,
                width    = "full",
                fontSize = "large",
            },
            desc = {
                type     = "description",
                name     = "If you renamed or realm-transferred a character, ArcUI lost track of its saved data because the internal key changed. This tool reassigns the key in-place — all settings, profiles, group layouts, bars, and Arc Auras move in one operation.\n\nA |cffff8800/reload|r is required after migrating.",
                order    = 2,
                width    = "full",
                fontSize = "medium",
            },
            spacer1 = { type = "description", name = " ", order = 2.5, width = "full" },

            -- STEP 1
            fromLabel = {
                type     = "description",
                name     = "|cffffd100Step 1|r  Select the old character",
                order    = 3,
                width    = "full",
                fontSize = "medium",
            },
            fromSelect = {
                type    = "select",
                name    = "Old Character",
                desc    = "Select the character whose data you want to reassign.",
                order   = 4,
                width   = 2.0,
                values  = GetCharValues,
                sorting = GetCharSorting,
                get     = function() return migState.fromKey or "" end,
                set     = function(_, val)
                    migState.fromKey = val ~= "" and val or nil
                    migState.toName  = nil
                    migState.toRealm = nil
                end,
            },
            spacer2 = { type = "description", name = " ", order = 4.5, width = "full" },

            -- STEP 2
            toLabel = {
                type     = "description",
                name     = "|cffffd100Step 2|r  Enter the new character name and realm",
                order    = 5,
                width    = "full",
                fontSize = "medium",
            },
            toDesc = {
                type     = "description",
                name     = "|cff888888Name change only: just update the name field, leave realm as-is.\nRealm transfer: update both name and realm fields.\nRealm names use their full in-game name, e.g. |r|cffccccccXal'atath's Endgame|r|cff888888 or |r|cffccccccArgent Dawn|r|cff888888 — exactly as shown in your character select screen.|r",
                order    = 5.1,
                width    = "full",
                fontSize = "small",
                hidden   = function() return not migState.fromKey or migState.fromKey == "" end,
            },
            toInput = {
                type  = "input",
                name  = "New Name",
                order = 6,
                width = 1.3,
                get   = function() return migState.toName or "" end,
                set   = function(_, val) migState.toName = val ~= "" and val or nil end,
            },
            toRealmInput = {
                type  = "input",
                name  = "Realm",
                desc  = "Leave blank to keep the existing realm. Change this for realm transfers.",
                order = 6.1,
                width = 1.5,
                get   = function()
                    if migState.toRealm then return migState.toRealm end
                    -- Pre-fill from old key
                    local oldKey = migState.fromKey
                    if oldKey then return oldKey:match("%-+%s*(.+)$") or "" end
                    return ""
                end,
                set   = function(_, val)
                    local oldKey = migState.fromKey
                    local oldRealm = oldKey and (oldKey:match("%-+%s*(.+)$") or "") or ""
                    -- Only store if it differs from original realm
                    migState.toRealm = (val ~= "" and val ~= oldRealm) and val or nil
                end,
                hidden = function() return not migState.fromKey or migState.fromKey == "" end,
            },
            useCurrentBtn = {
                type  = "execute",
                name  = "Use Current Character",
                desc  = "Fill in the name and realm of the character you are logged in as.",
                order = 6.2,
                width = 1.2,
                func  = CurrentCharFill,
            },
            previewNote = {
                type     = "description",
                name     = GetNewKeyPreview,
                order    = 6.6,
                width    = "full",
                fontSize = "small",
                hidden   = function() return not BuildNewKey() end,
            },
            conflictNote = {
                type     = "description",
                name     = "|cffff8800That key already has ArcUI data. Migrating will overwrite it. The source character's data will be kept as a backup.|r",
                order    = 6.7,
                width    = "full",
                fontSize = "small",
                hidden   = function() return not TargetHasData() end,
            },
            spacer3 = { type = "description", name = " ", order = 7, width = "full" },
            migrateBtn = {
                type     = "execute",
                name     = "Migrate Character",
                desc     = "Copy all ArcUI data from the old character to the new character key.",
                order    = 8,
                width    = 1.0,
                disabled = function() return not IsReady() end,
                confirm  = function()
                    local oldKey = migState.fromKey
                    local newKey = BuildNewKey()
                    if not oldKey or not newKey then return false end
                    if TargetHasData() then
                        return "'" .. newKey .. "' already has ArcUI data.\n\nThis will overwrite it with data from '" .. oldKey .. "'.\n\nThe old character data is kept as a backup.\n\nA /reload will be required after."
                    end
                    return "Copy all ArcUI data from '" .. oldKey .. "' to '" .. newKey .. "'?\n\nThe old character data is kept as a backup.\n\nA /reload will be required after."
                end,
                func = DoMigrate,
            },
        },
    }
end