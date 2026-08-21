-- ===================================================================
-- ArcUI_Castbar_ImportExport.lua
-- Import/Export for the ArcUI player Castbar configuration (db.castbars[1]).
--
-- Exposes ns.CastbarImportExport with the surface ArcUI_UnifiedImportExport.lua
-- expects:
--   ParseImportString(str)       -> data, err   (validates ARCUI_CASTBAR prefix)
--   ExportSelected(opts)         -> string, err
--   Import(data, opts)           -> success, msg
--   GenerateImportPreview(data)  -> preview string
-- and ns.GetCastbarExportOnlyOptionsTable() for the Import/Export options section.
--
-- Pattern intentionally mirrors ArcUI_CR_ImportExport.lua:
--   AceSerializer:Serialize -> LibDeflate:CompressDeflate -> EncodeForPrint
-- The whole castbar config table is a single self-contained slice, so export is
-- a deep copy of db.castbars[1] and import replaces that table's contents.
-- ===================================================================

local ADDON, ns = ...
ns.CastbarImportExport = ns.CastbarImportExport or {}
local IE = ns.CastbarImportExport

local LibDeflate    = LibStub("LibDeflate")
local AceSerializer = LibStub("AceSerializer-3.0")

local EXPORT_VERSION = 1
local EXPORT_PREFIX  = "ARCUI_CASTBAR"

-- ===================================================================
-- DB ACCESS — mirrors ns.Castbar's own accessor so we read the exact
-- same table the runtime does (instance 1, today's single bar).
-- ===================================================================
local function GetCastbarDB()
    -- Resolve via the shared-aware store so shared-castbar mode (account-wide) is honored:
    -- export emits the active (shared or per-character) look, import writes to the same one.
    local db = ns.API and ns.API.GetCastbarStore and ns.API.GetCastbarStore()
    return db and db.castbars and db.castbars[1]
end

-- ===================================================================
-- DEEP COPY — same shape as the other I/E modules
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
-- BUILD EXPORT PAYLOAD
-- The castbar config is one table. We deep-copy its STORED keys (pairs
-- only sees raw values, not AceDB defaults), so the export carries the
-- user's customizations and the importer's defaults fill the rest.
-- ===================================================================
function IE.GetExportPayload()
    local cfg = GetCastbarDB()
    if not cfg then return nil, "Castbar config not available" end
    -- Skip transient "_"-prefixed UI state (e.g. _saveSkinNameInput, the remembered
    -- skin-dropdown selection) so shared strings carry only real config.
    local out = {}
    for k, v in pairs(cfg) do
        if not (type(k) == "string" and k:sub(1, 1) == "_") then
            out[k] = DeepCopy(v)
        end
    end
    -- Record the author's UIParent size so the importer can place the bar in the
    -- same spot at a different interface scale. barPosition is stored as absolute
    -- UIParent units, and UIParent's WIDTH in units changes with the UI scale, so
    -- the raw numbers are only meaningful alongside the screen they came from.
    return { v = EXPORT_VERSION, config = out,
             uiW = UIParent and UIParent:GetWidth() or nil,
             uiH = UIParent and UIParent:GetHeight() or nil }, nil
end

-- ===================================================================
-- EXPORT — produces a portable string
-- ===================================================================
function IE.ExportSelected(opts)
    local payload, err = IE.GetExportPayload()
    if not payload then return nil, err end

    local exportData = {
        prefix     = EXPORT_PREFIX,
        version    = EXPORT_VERSION,
        timestamp  = time(),
        exportedBy = UnitName("player") or "Unknown",
        realm      = GetRealmName() or "Unknown",
        payload    = payload,
    }

    local serialized = AceSerializer:Serialize(exportData)
    if not serialized then return nil, "Serialization failed" end

    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    if not compressed then return nil, "Compression failed" end

    local encoded = LibDeflate:EncodeForPrint(compressed)
    if not encoded then return nil, "Encoding failed" end

    return encoded, nil
end

-- ===================================================================
-- PARSE — rebuilds the envelope from a string. Returns nil + err for
-- "not my prefix" so UnifiedIE's TryDetect can fall through to the next
-- module; returns the envelope table on success.
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

    if data.prefix ~= EXPORT_PREFIX then
        return nil, "Wrong format (not an ArcUI Castbar export)"
    end

    if type(data.payload) ~= "table" or type(data.payload.config) ~= "table" then
        return nil, "Invalid payload"
    end

    return data, nil
end

-- ===================================================================
-- IMPORT PREVIEW — short human-readable summary for the unified UI
-- ===================================================================
function IE.GenerateImportPreview(data)
    if not data then return "No data" end
    local cfg = (data.payload and data.payload.config) or {}

    local lines = { "|cff00ff00Valid Castbar export|r", "" }
    table.insert(lines, "|cff888888From:|r " ..
        (data.exportedBy or "?") .. " - " .. (data.realm or "?"))
    if data.timestamp then
        table.insert(lines, "|cff888888Date:|r " ..
            date("%Y-%m-%d %H:%M", data.timestamp))
    end
    table.insert(lines, "|cff888888Version:|r " .. tostring(data.version or "?"))
    table.insert(lines, "")
    table.insert(lines, "|cff00ccffContents:|r")
    table.insert(lines, string.format("  Size: |cffffffff%s x %s|r",
        tostring(cfg.width or "default"), tostring(cfg.height or "default")))
    table.insert(lines, "  Texture: |cffffffff" .. tostring(cfg.texture or "default") .. "|r")

    local profCount = 0
    if type(cfg.profiles) == "table" then
        for _ in pairs(cfg.profiles) do profCount = profCount + 1 end
    end
    table.insert(lines, "  Cast-type profiles: |cffffffff" .. profCount .. "|r")

    local thrCount = 0
    if type(cfg.colorThresholds) == "table" then thrCount = #cfg.colorThresholds end
    table.insert(lines, "  Color thresholds: |cffffffff" .. thrCount .. "|r")

    table.insert(lines, "")
    table.insert(lines, "|cffffcc00Importing replaces your current castbar settings.|r")
    return table.concat(lines, "\n")
end

-- ===================================================================
-- IMPORT — replaces the live castbar config with the imported one.
-- The castbar is a single config, so the only sensible mode is replace:
-- clear the stored keys (AceDB defaults then back-fill anything the
-- export omitted) and deep-copy the imported config in. Returns success, msg.
-- ===================================================================
function IE.Import(data, opts)
    if not data or type(data) ~= "table" then
        return false, "No import data"
    end
    local payload = data.payload or data
    local config  = payload and payload.config
    if type(config) ~= "table" then
        return false, "Invalid payload"
    end

    local cfg = GetCastbarDB()
    if not cfg then return false, "Castbar config not available" end

    -- UI SCALE PORTABILITY. barPosition is absolute UIParent units (frame:GetPoint),
    -- and UIParent's width in units changes with the interface scale: a lower scale
    -- fits MORE units across the same screen. So a string authored at one scale put
    -- the bar somewhere else on import, and at a big enough difference off screen
    -- entirely. Scale the offsets by the ratio of the two screens.
    -- Strings made before this shipped carry no uiW/uiH and are left EXACTLY as they
    -- were, so nothing that imports correctly today changes.
    local pos = config.barPosition
    if type(pos) == "table" and tonumber(pos.x) and tonumber(pos.y) then
        local srcW, srcH = tonumber(payload.uiW), tonumber(payload.uiH)
        local dstW = UIParent and UIParent:GetWidth()
        local dstH = UIParent and UIParent:GetHeight()
        if srcW and srcH and srcW > 0 and srcH > 0 and dstW and dstH and dstW > 0 and dstH > 0 then
            pos.x = math.floor(tonumber(pos.x) * (dstW / srcW) + 0.5)
            pos.y = math.floor(tonumber(pos.y) * (dstH / srcH) + 0.5)
        end
    end

    wipe(cfg)
    local applied = 0
    for k, v in pairs(config) do
        cfg[k] = DeepCopy(v)
        applied = applied + 1
    end

    -- Apply live so the bar reflects the imported look immediately.
    if ns.Castbar and ns.Castbar.ApplyAppearance then
        ns.Castbar.ApplyAppearance()
    end

    -- Refresh AceConfig so the options panel shows the new values.
    local ACR = LibStub("AceConfigRegistry-3.0", true)
    if ACR then ACR:NotifyChange("ArcUI") end

    return true, string.format("Imported castbar settings (%d fields)", applied)
end

-- ===================================================================
-- EXPORT UI — backs the AceConfig Import/Export section tab
-- ===================================================================
local exportUIState = { lastExportString = "" }

local function BuildExportArgs()
    return {
        exportHeader = {
            type  = "header",
            name  = "Export Castbar Settings",
            order = 1,
        },
        exportDesc = {
            type  = "description",
            name  = "Generates a portable string with your entire Castbar configuration (size, colors, fonts, per-cast-type profiles, thresholds, position). Share it or load it on another character. Click Generate, then copy the string.",
            order = 2,
        },
        generateExport = {
            type  = "execute",
            name  = "Generate Export String",
            order = 3,
            width = 1.0,
            func  = function()
                local str, err = IE.ExportSelected()
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
            order     = 4,
            multiline = 8,
            width     = "full",
            get       = function() return exportUIState.lastExportString or "" end,
            set       = function() end,  -- read-only
        },
        importPointer = {
            type     = "description",
            name     = "\nTo import a Castbar string, use the |cff00ccffImport|r tab. The type is auto-detected after you paste.",
            order    = 5,
            fontSize = "medium",
        },
    }
end

function IE.GetExportOnlyOptionsTable()
    return {
        type  = "group",
        name  = "Castbar Export",
        order = 96,
        args  = BuildExportArgs(),
    }
end

-- Match the naming convention of the other Import/Export modules
-- (ns.GetCRExportOnlyOptionsTable, ns.GetBarsExportOnlyOptionsTable, ...).
ns.GetCastbarExportOnlyOptionsTable = IE.GetExportOnlyOptionsTable
