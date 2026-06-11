-- ===================================================================
-- ArcUI_CR_ImportExport.lua
-- Import/Export functionality for ArcUI Cooldown Reminder configurations.
--
-- Exposes ns.CRImportExport with the public surface area that
-- ArcUI_UnifiedImportExport.lua expects:
--   ParseImportString(str)       -> data, err   (validates ARCUI_CR prefix)
--   ExportSelected(opts)         -> string, err
--   Import(data, opts)           -> success, msg
--   GenerateImportPreview(data)  -> preview string
--
-- Also exposes ns.CRImportExport.GetExportPayloadForMaster() so the
-- Master Export module can bundle Cooldown Reminder settings into its
-- own ARCMASTER string. The Master importer can then route the payload
-- back through CRImportExport.Import for application.
--
-- Pattern intentionally mirrors ArcUI_Bars_ImportExport.lua:
--   AceSerializer:Serialize → LibDeflate:CompressDeflate → EncodeForPrint
-- ===================================================================

local ADDON, ns = ...
ns.CRImportExport = ns.CRImportExport or {}
local IE = ns.CRImportExport

local LibDeflate    = LibStub("LibDeflate")
local AceSerializer = LibStub("AceSerializer-3.0")

-- Constants
local EXPORT_VERSION = 1
local EXPORT_PREFIX  = "ARCUI_CR"
local MSG_PREFIX     = "|cff00ccffArcUI|r: "

-- ===================================================================
-- DB ACCESS — Cooldown Reminder lives at ns.API.GetDB().cooldownReminder
-- Mirrors how the engine itself locates its DB scope so we always read
-- the same data the engine does.
-- ===================================================================

local function GetCRDB()
    local CR = ns.CooldownReminder
    if CR and CR.GetDB then return CR.GetDB() end
    -- Fallback: direct lookup if engine isn't loaded yet
    local rootDB = ns.API and ns.API.GetDB and ns.API.GetDB()
    return rootDB and rootDB.cooldownReminder
end

-- ===================================================================
-- DEEP COPY — same shape as Bars module's DeepCopy
-- ===================================================================

local function DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[DeepCopy(k)] = DeepCopy(v)
    end
    return copy
end

-- ===================================================================
-- WHAT GETS EXPORTED
--
-- Two top-level slices:
--   1. globals      — visual / behavioral settings the user has tuned
--                     globally (animation, queue mode, position, etc.)
--   2. perSpell     — { whitelist, spellTriggers, spellSounds, spellTTS,
--                       spellIconDisabled, spellSoundDisabled,
--                       spellDelayMode, spellDelaySeconds }
--                     keyed by spellID-string or "i:<itemID>" the same way
--                     the engine stores them.
--
-- We DO NOT export character-specific things like position drift from
-- mid-game drag (they ARE included on purpose if the user wants their
-- whole layout) and we DO NOT export anything that isn't in DB_DEFAULTS
-- (no transient state).
-- ===================================================================

-- Globals to include. Listed explicitly so we don't accidentally ship
-- runtime junk that may have been stuffed onto the AceDB table by some
-- other code path.
local EXPORTED_GLOBAL_KEYS = {
    -- Visibility / position / size
    "size", "iconOpacity",
    "point", "relPoint", "x", "y",
    "iconEnabled", "locked",
    -- Pulse + animation tuning (all DB defaults)
    "pulseDuration",
    "animStyle",
    "animFadeSmoothing",
    "animFlashSpeed",
    "animZoomStart", "animZoomPeak",
    "animZoomPopTime", "animZoomSettleTime",
    -- Queue / replace / stack
    "queueMode", "stackDirection", "stackSpacing",
    "replaceGuard", "queueMaxLen", "queueInterDelay",
    "noOverlapAlerts",  -- legacy mirror; kept for migration safety
    "cancelOnCast",
    -- Audio defaults
    "soundEnabled", "soundName", "soundChannel", "fallbackSoundKitID",
    "cutoffPreviousSound", "cutoffFadeTime",
    -- TTS defaults
    "ttsVoiceOverride", "ttsRateOverride",
    -- Sorting / zone gates
    "sortByName",
    "enabledInWorld", "enabledInDungeons", "enabledInRaids",
    "enabledInArenas", "enabledInBattlegrounds", "enabledInScenarios",
    -- Master enable
    "enabled",
}

-- Per-spell maps. These are tables keyed by spellID-string. Each is
-- copied wholesale.
local EXPORTED_PER_SPELL_MAPS = {
    "whitelist",
    "spellTriggers",
    "spellSounds",
    "spellTTS",
    "spellIconDisabled",
    "spellSoundDisabled",
    "spellDelayMode",
    "spellDelaySeconds",
}

-- ===================================================================
-- BUILD EXPORT PAYLOAD
-- Used both by direct export AND by the Master export bundler.
-- opts (optional):
--   includeGlobals   = bool (default true)
--   includePerSpell  = bool (default true)
--   spellFilter      = set of spellID-strings to limit perSpell maps to
-- ===================================================================

function IE.GetExportPayloadForMaster(opts)
    local db = GetCRDB()
    if not db then return nil, "Cooldown Reminder DB not available" end
    opts = opts or {}
    local includeGlobals  = (opts.includeGlobals  ~= false)
    local includePerSpell = (opts.includePerSpell ~= false)
    local filter          = opts.spellFilter   -- nil = all

    local payload = {
        v        = EXPORT_VERSION,
        globals  = nil,
        perSpell = nil,
    }

    if includeGlobals then
        local g = {}
        for _, k in ipairs(EXPORTED_GLOBAL_KEYS) do
            local v = db[k]
            if v ~= nil then g[k] = DeepCopy(v) end
        end
        payload.globals = g
    end

    if includePerSpell then
        local ps = {}
        for _, mapName in ipairs(EXPORTED_PER_SPELL_MAPS) do
            local src = db[mapName]
            if type(src) == "table" then
                local out = {}
                for spellKey, value in pairs(src) do
                    if not filter or filter[tostring(spellKey)] then
                        out[spellKey] = DeepCopy(value)
                    end
                end
                ps[mapName] = out
            end
        end
        payload.perSpell = ps
    end

    return payload, nil
end

-- ===================================================================
-- EXPORT — produces a portable string
-- ===================================================================

function IE.ExportSelected(opts)
    local payload, err = IE.GetExportPayloadForMaster(opts)
    if not payload then return nil, err end

    -- Wrap in standard envelope (matches Bars structure for consistency)
    local exportData = {
        prefix      = EXPORT_PREFIX,
        version     = EXPORT_VERSION,
        timestamp   = time(),
        exportedBy  = UnitName("player") or "Unknown",
        realm       = GetRealmName() or "Unknown",
        payload     = payload,
    }

    -- Count entries for preview metadata
    if payload.perSpell and payload.perSpell.whitelist then
        local n = 0
        for _ in pairs(payload.perSpell.whitelist) do n = n + 1 end
        exportData.spellCount = n
    end

    local serialized = AceSerializer:Serialize(exportData)
    if not serialized then return nil, "Serialization failed" end

    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    if not compressed then return nil, "Compression failed" end

    local encoded = LibDeflate:EncodeForPrint(compressed)
    if not encoded then return nil, "Encoding failed" end

    return encoded, nil
end

-- ===================================================================
-- PARSE — rebuilds the envelope from a string
-- Required by ArcUI_UnifiedImportExport's TryDetect dispatcher: returns
-- nil + err for "not my prefix" or actual decode failures, returns the
-- envelope table on success.
-- ===================================================================

function IE.ParseImportString(importString)
    if not importString or importString == "" then
        return nil, "Empty import string"
    end
    importString = importString:gsub("^%s+", ""):gsub("%s+$", "")

    local decoded = LibDeflate:DecodeForPrint(importString)
    if not decoded then
        return nil, "Invalid import string (decode failed)"
    end

    local decompressed = LibDeflate:DecompressDeflate(decoded)
    if not decompressed then
        return nil, "Invalid import string (decompress failed)"
    end

    local ok, data = AceSerializer:Deserialize(decompressed)
    if not ok or type(data) ~= "table" then
        return nil, "Invalid import string (deserialize failed)"
    end

    -- Magic-prefix check is what TryDetect relies on. If this string is
    -- meant for a different module (Bars/CDM/Master), return nil and the
    -- dispatcher will try the next module.
    if data.prefix ~= EXPORT_PREFIX then
        return nil, "Wrong format (not an ArcUI Cooldown Reminder export)"
    end

    if type(data.payload) ~= "table" then
        return nil, "Invalid payload"
    end

    return data, nil
end

-- ===================================================================
-- IMPORT PREVIEW — short human-readable summary for the unified UI
-- ===================================================================

function IE.GenerateImportPreview(data)
    if not data then return "No data" end
    local p = data.payload or {}

    local lines = { "|cff00ff00Valid Cooldown Reminder export|r", "" }

    table.insert(lines, "|cff888888From:|r " ..
        (data.exportedBy or "?") .. " - " .. (data.realm or "?"))
    if data.timestamp then
        table.insert(lines, "|cff888888Date:|r " ..
            date("%Y-%m-%d %H:%M", data.timestamp))
    end
    table.insert(lines, "|cff888888Version:|r " .. tostring(data.version or "?"))
    table.insert(lines, "")

    table.insert(lines, "|cff00ccffContents:|r")

    if p.globals then
        local n = 0
        for _ in pairs(p.globals) do n = n + 1 end
        table.insert(lines, "  Global settings: |cffffffff" .. n .. "|r fields")
    else
        table.insert(lines, "  Global settings: |cff666666not included|r")
    end

    if p.perSpell then
        local wlCount, trigCount = 0, 0
        if p.perSpell.whitelist then
            for _ in pairs(p.perSpell.whitelist) do wlCount = wlCount + 1 end
        end
        if p.perSpell.spellTriggers then
            for _ in pairs(p.perSpell.spellTriggers) do trigCount = trigCount + 1 end
        end
        table.insert(lines, "  Tracked reminders: |cffffffff" .. wlCount .. "|r")
        table.insert(lines, "  Spells with triggers: |cffffffff" .. trigCount .. "|r")
    else
        table.insert(lines, "  Per-spell data: |cff666666not included|r")
    end

    return table.concat(lines, "\n")
end

-- ===================================================================
-- IMPORT — applies a parsed payload to the live DB
--
-- opts:
--   importMode = "merge" (default) | "replace"
--     merge   = keep existing reminders; overwrite same-spellID entries
--               with imported version; add new entries from import.
--     replace = wipe all per-spell data first, then apply import.
--   importGlobals  = bool (default true)
--   importPerSpell = bool (default true)
--
-- Returns success, message.
-- ===================================================================

function IE.Import(data, opts)
    if not data or type(data) ~= "table" then
        return false, "No import data"
    end
    local payload = data.payload or data  -- accept either envelope or raw payload
    if type(payload) ~= "table" then
        return false, "Invalid payload"
    end
    opts = opts or {}
    local mode             = opts.importMode or "merge"
    local importGlobals    = (opts.importGlobals  ~= false)
    local importPerSpell   = (opts.importPerSpell ~= false)

    local db = GetCRDB()
    if not db then return false, "Cooldown Reminder DB not available" end

    local applied = 0

    -- ── Globals ─────────────────────────────────────────────────────
    if importGlobals and payload.globals then
        for k, v in pairs(payload.globals) do
            -- Whitelist guard: only import keys we actually expect, so
            -- a malformed/malicious payload can't shove arbitrary
            -- fields onto the AceDB table.
            for _, allowed in ipairs(EXPORTED_GLOBAL_KEYS) do
                if k == allowed then
                    db[k] = DeepCopy(v)
                    applied = applied + 1
                    break
                end
            end
        end
    end

    -- ── Per-spell ───────────────────────────────────────────────────
    if importPerSpell and payload.perSpell then
        if mode == "replace" then
            -- Wipe existing per-spell maps before importing
            for _, mapName in ipairs(EXPORTED_PER_SPELL_MAPS) do
                if type(db[mapName]) == "table" then
                    wipe(db[mapName])
                end
            end
        end
        for _, mapName in ipairs(EXPORTED_PER_SPELL_MAPS) do
            local src = payload.perSpell[mapName]
            if type(src) == "table" then
                if type(db[mapName]) ~= "table" then db[mapName] = {} end
                local dst = db[mapName]
                for spellKey, value in pairs(src) do
                    dst[spellKey] = DeepCopy(value)
                    applied = applied + 1
                end
            end
        end
    end

    -- Apply settings live (animation params, position, etc.)
    if ns.CooldownReminder and ns.CooldownReminder.ApplySettings then
        ns.CooldownReminder.ApplySettings()
    end
    -- Rebuild engine tracking so newly-imported spells start watching.
    if ns.CooldownReminder and ns.CooldownReminder.Engine
       and ns.CooldownReminder.Engine.RebuildTrackedSpells then
        ns.CooldownReminder.Engine:RebuildTrackedSpells("import")
    end

    -- Refresh AceConfig so options panel reflects the new state.
    local ACR = LibStub("AceConfigRegistry-3.0", true)
    if ACR then ACR:NotifyChange("ArcUI") end

    return true, string.format("Imported %d entries (mode=%s)", applied, mode)
end

-- ===================================================================
-- EXPORT UI STATE — backs the AceConfig options tab
-- ===================================================================

local exportUIState = {
    includeGlobals  = true,
    includePerSpell = true,
    lastExportString = "",
}

-- ===================================================================
-- OPTIONS TABLE — exposed as ns.CRImportExport.GetOptionsTable()
-- so the main ArcUI options UI can hang it under a tab. Mirrors how
-- BarsImportExport.GetOptionsTable() works.
-- Returns a self-contained AceConfig group with EXPORT and IMPORT
-- sub-sections. The IMPORT side delegates to the Unified importer
-- by directing the user there (we don't duplicate the paste/parse UI
-- here; the unified one already handles all four module types).
--
-- IE.GetExportOnlyOptionsTable() returns ONLY the export half — used
-- when CR sits in the dedicated Import/Export section alongside CDM
-- Export, Bars Export, Master Export, and the unified Import tab. In
-- that layout the import pointer is redundant (the unified Import tab
-- is right there as a sibling), so the export-only accessor leaves
-- the pointer out for a cleaner panel.
-- ===================================================================

-- Build the EXPORT-side args table. Shared by both accessors below so
-- they stay in lock-step. The arg keys are unique to avoid collisions
-- when the table is spliced into a parent options group.
local function BuildExportArgs()
    return {
        exportHeader = {
            type  = "header",
            name  = "Export Cooldown Reminder Settings",
            order = 1,
        },
        exportDesc = {
            type  = "description",
            name  = "Generates a portable string containing your Cooldown Reminder settings. Pick which slices to include below, then click Generate.",
            order = 2,
        },
        includeGlobals = {
            type   = "toggle",
            name   = "Include Global Settings",
            desc   = "Include animation, queue/replace mode, position, audio, and other global tunables.",
            order  = 3,
            width  = 1.5,
            get    = function() return exportUIState.includeGlobals end,
            set    = function(_, v) exportUIState.includeGlobals = v end,
        },
        includePerSpell = {
            type   = "toggle",
            name   = "Include Per-Spell Reminders",
            desc   = "Include the list of tracked spells/items, their per-trigger configs (animation, glow, priority, sound), and per-spell overrides.",
            order  = 4,
            width  = 1.5,
            get    = function() return exportUIState.includePerSpell end,
            set    = function(_, v) exportUIState.includePerSpell = v end,
        },
        generateExport = {
            type  = "execute",
            name  = "Generate Export String",
            order = 5,
            width = 1.0,
            func  = function()
                if not exportUIState.includeGlobals
                   and not exportUIState.includePerSpell then
                    exportUIState.lastExportString =
                        "|cffff6600Select at least one slice to export.|r"
                    return
                end
                local str, err = IE.ExportSelected({
                    includeGlobals  = exportUIState.includeGlobals,
                    includePerSpell = exportUIState.includePerSpell,
                })
                if str then
                    exportUIState.lastExportString = str
                else
                    exportUIState.lastExportString =
                        "|cffff0000Error: " .. tostring(err) .. "|r"
                end
            end,
        },
        exportString = {
            type      = "input",
            name      = "Export String (copy this)",
            order     = 6,
            multiline = 8,
            width     = "full",
            get       = function() return exportUIState.lastExportString or "" end,
            set       = function(_, _) end,  -- read-only
        },
    }
end

-- Export-only group, for slotting into the dedicated Import/Export
-- section of ArcUI_Options.lua alongside the other Export tabs.
function IE.GetExportOnlyOptionsTable()
    return {
        type  = "group",
        name  = "Cooldown Reminder Export",
        order = 95,
        args  = BuildExportArgs(),
    }
end

-- Standalone group for embedding inside the Cooldown Reminder panel
-- itself (kept for backwards compatibility — the dedicated tab in
-- ArcUI_Options.lua is the primary location).
function IE.GetOptionsTable()
    local args = BuildExportArgs()
    -- Tail-on the import-pointer block (it's only useful when this
    -- table is rendered AWAY from the dedicated Import/Export
    -- section).
    args.importHeader = {
        type  = "header",
        name  = "Import",
        order = 20,
    }
    args.importPointer = {
        type  = "description",
        name  = "To import a Cooldown Reminder string, use the |cff00ccffImport|r tab in the main ArcUI Import/Export section. The type is auto-detected and the right options will appear after you paste.",
        order = 21,
        fontSize = "medium",
    }
    return {
        type  = "group",
        name  = "Import / Export",
        order = 95,
        args  = args,
    }
end

-- Match the naming convention used by the other Import/Export modules
-- (ns.GetCDMExportOnlyOptionsTable, ns.GetBarsExportOnlyOptionsTable,
-- ns.GetCDMMasterExportOptionsTable). ArcUI_Options.lua slots this
-- into the Import/Export section the same way as the others.
ns.GetCRExportOnlyOptionsTable = IE.GetExportOnlyOptionsTable