-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI CDM Import/Export Module
-- Comprehensive export/import of all CDM settings including:
--   - Group layouts and positions (CDMGroups)
--   - Per-icon visual settings (CDMEnhance iconSettings)
--   - Global aura/cooldown defaults (CDMEnhance)
--   - Group-level settings (spacing, scale, direction)
--   - Layout profiles with talent conditions
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON_NAME, ns = ...

ns.CDMImportExport = ns.CDMImportExport or {}
local IE = ns.CDMImportExport

-- Use shared helpers (dynamic lookup to handle load order)
local function GetShared()
    return ns.CDMShared
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local EXPORT_VERSION = 1  -- Increment when export format changes
local EXPORT_PREFIX = "ARCCDM"  -- Identifier for validation
local MSG_PREFIX = "|cff00ccffArcUI|r: "

-- CDM native layout field IDs (matches Blizzard's serialization format)
local CDM_SAVE_FIELD_LAYOUT_ID_DATA = 4  -- layoutID -> name mapping
local CDM_ENCODING_DELIMITER = "|"

-- Decode a CDM native layout string and return the table
-- Uses Blizzard's own C_EncodingUtil (same as CooldownViewerDataStoreSerializationMixin)
local function DecodeCDMLayoutString(str)
    if type(str) ~= "string" or str == "" then return nil end
    local delimIdx = str:find(CDM_ENCODING_DELIMITER, 1, true)
    if not delimIdx then return nil end
    local payload = str:sub(delimIdx + 1)
    local ok, result = pcall(function()
        local decoded = C_EncodingUtil.DecodeBase64(payload)
        local inflated = decoded and C_EncodingUtil.DecompressString(decoded, Enum.CompressionMethod.Deflate)
        return inflated and C_EncodingUtil.DeserializeCBOR(inflated) or nil
    end)
    return ok and type(result) == "table" and result or nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DEPENDENCIES
-- ═══════════════════════════════════════════════════════════════════════════

local LibDeflate
local function GetLibDeflate()
    if not LibDeflate then
        LibDeflate = LibStub and LibStub("LibDeflate", true)
    end
    return LibDeflate
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

-- Deep merge: source keys overwrite dest keys, tables recurse.
-- Used to bake globals into per-icon settings during flatten import.
local function DeepMergeImport(dest, source)
    if not source then return dest end
    if not dest then return DeepCopy(source) end
    local result = DeepCopy(dest)
    for k, v in pairs(source) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = DeepMergeImport(result[k], v)
        elseif v ~= nil then
            result[k] = v
        end
    end
    return result
end

-- Canonical copy of a raw layoutData table (DB or imported).
-- Single source of truth for all group layout fields — add new fields here only.
-- This is intentionally a flat copy (not tied to a runtime group object) so it works
-- in import/export contexts where only raw DB data is available.
local function CopyLayoutData(src)
    if not src then return {} end
    return {
        -- Position
        position             = src.position and DeepCopy(src.position) or { x = 0, y = 0 },
        -- Grid
        gridRows             = src.gridRows or 2,
        gridCols             = src.gridCols or 4,
        iconSize             = src.iconSize or 36,
        iconWidth            = src.iconWidth or 36,
        iconHeight           = src.iconHeight or 36,
        spacing              = src.spacing or 2,
        spacingX             = src.spacingX,
        spacingY             = src.spacingY,
        separateSpacing      = src.separateSpacing,
        alignment            = src.alignment,
        horizontalGrowth     = src.horizontalGrowth,
        verticalGrowth       = src.verticalGrowth,
        -- Appearance
        showBorder           = src.showBorder,
        showBackground       = src.showBackground,
        autoReflow           = src.autoReflow,
        dynamicLayout        = src.dynamicLayout,
        dynamicContainerSize = src.dynamicContainerSize,
        lockGridSize         = src.lockGridSize,
        containerPadding     = src.containerPadding,
        borderColor          = src.borderColor and DeepCopy(src.borderColor) or { r = 0.5, g = 0.5, b = 0.5, a = 1 },
        bgColor              = src.bgColor and DeepCopy(src.bgColor) or { r = 0, g = 0, b = 0, a = 0.6 },
        -- Visibility
        visibility           = src.visibility or "always",
        visibilityLogic      = src.visibilityLogic,
        hiddenAlpha          = src.hiddenAlpha,
        -- Frame strata
        frameStrata          = src.frameStrata,
        frameLevel           = src.frameLevel,
        -- Anchoring
        anchor               = src.anchor,
    }
end

local function PrintMsg(msg)
    print(MSG_PREFIX .. msg)
end

-- Convert specKey (e.g. "class_7_spec_2") to human-readable display name
local function SpecKeyToDisplayName(specKey)
    if not specKey then return "Unknown Spec" end
    local classID, specIdx = specKey:match("^class_(%d+)_spec_(%d+)$")
    classID = tonumber(classID)
    specIdx = tonumber(specIdx)
    if not classID or not specIdx then return specKey end
    local className = select(1, GetClassInfo(classID)) or ("Class " .. classID)
    -- Try to get spec name for this class+specIdx
    local specName
    local numSpecs = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID) or 0
    if numSpecs >= specIdx then
        specName = select(2, GetSpecializationInfoForClassID(classID, specIdx))
    end
    specName = specName or ("Spec " .. specIdx)
    return className .. " - " .. specName
end

-- Serialize table to string (simple Lua serialization)
local function SerializeTable(tbl, indent)
    indent = indent or ""
    local parts = {}
    
    if type(tbl) ~= "table" then
        if type(tbl) == "string" then
            return string.format("%q", tbl)
        elseif type(tbl) == "number" or type(tbl) == "boolean" then
            return tostring(tbl)
        elseif tbl == nil then
            return "nil"
        else
            return "nil"  -- Skip unsupported types
        end
    end
    
    table.insert(parts, "{")
    local nextIndent = indent .. " "
    local items = {}
    
    -- Handle both array and hash parts
    local arrayLen = #tbl
    local hasArrayPart = arrayLen > 0
    
    -- Array part first
    for i = 1, arrayLen do
        local v = tbl[i]
        if v ~= nil then
            table.insert(items, SerializeTable(v, nextIndent))
        end
    end
    
    -- Hash part
    for k, v in pairs(tbl) do
        -- Skip array indices we already handled
        if type(k) ~= "number" or k < 1 or k > arrayLen or math.floor(k) ~= k then
            local keyStr
            if type(k) == "string" then
                -- Use simple key format if valid identifier, else use brackets
                if k:match("^[%a_][%w_]*$") then
                    keyStr = k
                else
                    keyStr = "[" .. string.format("%q", k) .. "]"
                end
            elseif type(k) == "number" then
                keyStr = "[" .. tostring(k) .. "]"
            else
                keyStr = "[" .. string.format("%q", tostring(k)) .. "]"
            end
            table.insert(items, keyStr .. "=" .. SerializeTable(v, nextIndent))
        end
    end
    
    if #items > 0 then
        table.insert(parts, table.concat(items, ","))
    end
    table.insert(parts, "}")
    
    return table.concat(parts)
end

-- Deserialize string back to table
local function DeserializeTable(str)
    if not str or str == "" then return nil, "Empty string" end
    
    -- Security: Only allow specific patterns (no function calls, etc.)
    local sanitized = str:gsub("%s+", " ")
    
    -- Check for dangerous patterns
    -- More precise checks to avoid false positives while catching actual threats
    if sanitized:match("[%[%]]+%s*function") or 
       sanitized:match("loadstring") or 
       sanitized:match("dofile") or
       sanitized:match("require%s*%(") or
       sanitized:match("require%s*%[") or
       sanitized:match("_G%s*[%[%.]") or  -- _G[ or _G. (actual global access)
       sanitized:match("getfenv") or
       sanitized:match("setfenv") or
       sanitized:match("rawget") or
       sanitized:match("rawset") then
        return nil, "Invalid data: potentially unsafe content"
    end
    
    -- Wrap in return statement for loadstring
    local func, err = loadstring("return " .. str)
    if not func then
        return nil, "Parse error: " .. tostring(err)
    end
    
    -- Execute in protected environment
    setfenv(func, {})
    local ok, result = pcall(func)
    if not ok then
        return nil, "Execution error: " .. tostring(result)
    end
    
    return result, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EXPORT FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Build export data structure from current settings
local function BuildExportData(options)
    options = options or {}
    local Shared = GetShared()
    
    if not Shared then
        print(MSG_PREFIX .. "|cffff0000ERROR: CDMShared not available!|r")
        return nil
    end
    
    local exportData = {
        version = EXPORT_VERSION,
        prefix = EXPORT_PREFIX,
        timestamp = time(),
        exportedBy = UnitName("player") or "Unknown",
        realm = GetRealmName() or "Unknown",
    }
    
    -- Get current spec key
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    if currentSpec then
        exportData.sourceSpec = currentSpec
    end
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- CDMGroups Data (group layouts, positions, free icons, iconSettings, groupSettings)
    -- Uses character-specific storage via Shared.GetCDMGroupsDB()
    -- iconSettings and groupSettings are now stored per-spec alongside layouts
    -- ─────────────────────────────────────────────────────────────────────────
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    
    if cdmGroupsDB then
        -- Export current spec data
        if cdmGroupsDB.specData and currentSpec and cdmGroupsDB.specData[currentSpec] then
            local specData = cdmGroupsDB.specData[currentSpec]
            
            -- ═══════════════════════════════════════════════════════════════════════════
            -- PRE-EXPORT: Flush runtime Arc Aura positions to profile's savedPositions
            -- Arc Aura frames in CDMGroups may have runtime group membership that hasn't
            -- been persisted to the profile's savedPositions (e.g., after RegisterExternalFrame
            -- or after the user assigns icons to groups). Sync them now so export is complete.
            -- ═══════════════════════════════════════════════════════════════════════════
            local activeProfileName = specData.activeProfile or "Default"
            local profile = specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
            
            if profile and ns.CDMGroups and ns.CDMGroups.groups then
                if not profile.savedPositions then profile.savedPositions = {} end
                
                local flushedCount = 0
                for groupName, group in pairs(ns.CDMGroups.groups) do
                    if group.members then
                        for cdID, member in pairs(group.members) do
                            -- Flush any arc_ IDs that are in runtime groups but missing from profile savedPositions
                            if type(cdID) == "string" and cdID:find("^arc_") then
                                local existing = profile.savedPositions[cdID]
                                -- Always update to current runtime state (group may have changed)
                                profile.savedPositions[cdID] = {
                                    type = "group",
                                    target = groupName,
                                    row = member.row or 0,
                                    col = member.col or 0,
                                    gridSlot = member.gridSlot,
                                }
                                flushedCount = flushedCount + 1
                            end
                        end
                    end
                end
                
                -- Also flush free arc_ icons
                if ns.CDMGroups.freeIcons then
                    for cdID, freeData in pairs(ns.CDMGroups.freeIcons) do
                        if type(cdID) == "string" and cdID:find("^arc_") then
                            profile.savedPositions[cdID] = {
                                type = "free",
                                x = freeData.x or 0,
                                y = freeData.y or 0,
                                iconSize = freeData.iconSize or 36,
                            }
                            flushedCount = flushedCount + 1
                        end
                    end
                end
                
                if flushedCount > 0 then
                    -- Debug: uncomment to see flush count
                    -- print(MSG_PREFIX .. "Flushed " .. flushedCount .. " Arc Aura positions to profile")
                end
            end
            
            -- Build layoutProfiles with ONLY the active profile
            local exportedLayoutProfiles = nil
            if profile then
                exportedLayoutProfiles = {
                    [activeProfileName] = DeepCopy(profile)
                }
            end
            
            -- iconSettings is now in profile, but we also export at top level for backwards compatibility
            local exportedIconSettings = nil
            if options.includeIconSettings ~= false and profile and profile.iconSettings then
                exportedIconSettings = DeepCopy(profile.iconSettings)
            end
            
            -- Export global icon settings (stored at root of cdmGroups, not per-spec)
            -- These include: disableTooltips, clickThrough
            local exportedGlobalIconSettings = nil
            if options.includeGroupSettings ~= false then
                exportedGlobalIconSettings = {
                    disableTooltips = cdmGroupsDB.disableTooltips,
                    clickThrough = cdmGroupsDB.clickThrough,
                }
            end
            
            exportData.cdmGroups = {
                -- DEPRECATED: Don't export specData.groups (has runtime data)
                groups = nil,
                -- Export positions from PROFILE (the authoritative source)
                savedPositions = (options.includePositions ~= false) and profile and profile.savedPositions and DeepCopy(profile.savedPositions) or nil,
                freeIcons = (options.includePositions ~= false) and profile and profile.freeIcons and DeepCopy(profile.freeIcons) or nil,
                -- Export ONLY the active profile (not all profiles)
                layoutProfiles = exportedLayoutProfiles,
                activeProfile = activeProfileName,
                -- Export iconSettings at TOP LEVEL for backwards compat with old imports
                -- (Also in profile.iconSettings within layoutProfiles above)
                iconSettings = exportedIconSettings,
                groupSettings = (options.includeGroupSettings ~= false) and specData.groupSettings and DeepCopy(specData.groupSettings) or nil,
                keepCDMStyle = specData.keepCDMStyle or nil,
                -- Global icon settings (tooltips, click-through) - stored at root, not per-spec
                globalIconSettings = exportedGlobalIconSettings,
            }
            
            -- Clean runtime data from layout profiles (shouldn't have any, but be safe)
            if exportData.cdmGroups.layoutProfiles then
                for profileName, profileData in pairs(exportData.cdmGroups.layoutProfiles) do
                    if profileData.groupLayouts then
                        for gName, gLayout in pairs(profileData.groupLayouts) do
                            gLayout.members = nil
                            gLayout.grid = nil
                            gLayout.container = nil
                            gLayout.dragBar = nil
                        end
                    end
                end
            end
            
            -- ─────────────────────────────────────────────────────────────────
            -- GLOBAL GROUP LAYOUTS: embed referenced layouts into export string
            -- If the exported profile links to a named global layout via
            -- groupLayoutName, pull that layout's data from the global DB and
            -- embed it. The importer can then recreate it in their own global DB
            -- rather than ending up with an empty profile.
            -- ─────────────────────────────────────────────────────────────────
            if exportData.cdmGroups.layoutProfiles then
                local _glDB = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                if _glDB then
                    local globalGroupLayouts = {}
                    for _, profileData in pairs(exportData.cdmGroups.layoutProfiles) do
                        local linkedName = profileData.groupLayoutName
                        if linkedName and _glDB[linkedName] and not globalGroupLayouts[linkedName] then
                            -- Deep copy, strip runtime-only fields
                            local layoutCopy = DeepCopy(_glDB[linkedName])
                            for _, groupData in pairs(layoutCopy) do
                                if type(groupData) == "table" then
                                    groupData.members = nil
                                    groupData.grid = nil
                                    groupData.container = nil
                                    groupData.dragBar = nil
                                end
                            end
                            globalGroupLayouts[linkedName] = layoutCopy
                        end
                    end
                    if next(globalGroupLayouts) then
                        exportData.cdmGroups.globalGroupLayouts = globalGroupLayouts
                    end
                end
            end
        end
    end
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- CDMEnhance Data (global defaults ONLY - shared across all specs)
    -- iconSettings and groupSettings are now in cdmGroups above (per-spec)
    -- ─────────────────────────────────────────────────────────────────────────
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
        local cdmEnhance = ns.db.profile.cdmEnhance
        
        exportData.cdmEnhance = {
            -- Global defaults for auras and cooldowns (SHARED across all specs)
            globalAuraSettings = (options.includeGlobalSettings ~= false) and cdmEnhance.globalAuraSettings and DeepCopy(cdmEnhance.globalAuraSettings) or nil,
            globalCooldownSettings = (options.includeGlobalSettings ~= false) and cdmEnhance.globalCooldownSettings and DeepCopy(cdmEnhance.globalCooldownSettings) or nil,
            
            -- Global toggle states
            globalApplyScale = cdmEnhance.globalApplyScale,
            globalApplyHideShadow = cdmEnhance.globalApplyHideShadow,
            disableRightClickSelect = cdmEnhance.disableRightClickSelect,
            lockGridSize = cdmEnhance.lockGridSize,
            -- Master customization toggles
            enableAuraCustomization = cdmEnhance.enableAuraCustomization,
            enableCooldownCustomization = cdmEnhance.enableCooldownCustomization,
        }
    end
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- Arc Auras Data (per-character item tracking)
    -- Includes tracked items (trinkets, consumables) and their positions
    -- ─────────────────────────────────────────────────────────────────────────
    if ns.db and ns.db.char and ns.db.char.arcAuras then
        local arcAuras = ns.db.char.arcAuras
        
        -- Always emit arcAuras block so importers know to wipe their existing icons
        -- even when the exporter has deleted everything (empty tables are intentional)
        if options.includeArcAuras ~= false then
            exportData.arcAuras = {
                trackedItems = arcAuras.trackedItems and DeepCopy(arcAuras.trackedItems) or {},
                trackedSpells = arcAuras.trackedSpells and DeepCopy(arcAuras.trackedSpells) or {},
                positions = arcAuras.positions and DeepCopy(arcAuras.positions) or nil,
                globalSettings = arcAuras.globalSettings and next(arcAuras.globalSettings) and DeepCopy(arcAuras.globalSettings) or nil,
                enabled = arcAuras.enabled,
                autoTrackEquippedTrinkets = arcAuras.autoTrackEquippedTrinkets,
                autoTrackSlots = arcAuras.autoTrackSlots and DeepCopy(arcAuras.autoTrackSlots) or nil,
                onlyOnUseTrinkets = arcAuras.onlyOnUseTrinkets,
                -- Custom Icons (Arc Auras timer-driven icons): user-defined
                -- timers with start/end triggers. DeepCopy so importers get
                -- their own mutable copy. Empty table is intentional — lets
                -- importers know to wipe their existing custom timers.
                customTimers = arcAuras.customTimers and DeepCopy(arcAuras.customTimers) or {},
            }
        end
    end
    
    -- ─────────────────────────────────────────────────────────────────────────
    -- CDM Active Layout (single layout export string - same format as Blizzard
    -- "Copy to Clipboard". Only the current spec's active layout, not all layouts.
    -- ─────────────────────────────────────────────────────────────────────────
    if options.includeCDMLayout ~= false then
        local ok, layoutStr, layoutName = pcall(function()
            local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
            local mgr = dp and dp:GetLayoutManager()
            local activeLayoutID = mgr and mgr:GetActiveLayoutID()
            if not activeLayoutID then return nil, nil end
            local serializer = CooldownViewerSettings:GetSerializer()
            local str = serializer and serializer:SerializeLayouts(activeLayoutID) or nil
            if not str then return nil, nil end
            -- Decode the single-layout string to extract the name from LAYOUT_NAMES
            -- Avoids any secret comparison — the name is just a plain string in the decoded table
            local name = nil
            local decoded = DecodeCDMLayoutString(str)
            if decoded then
                local names = decoded[CDM_SAVE_FIELD_LAYOUT_ID_DATA]
                if names then
                    for _, n in pairs(names) do
                        name = n  -- only one entry in a single-layout export
                        break
                    end
                end
            end
            return str, name
        end)
        if ok and layoutStr and layoutStr ~= "" then
            exportData.cdmNativeLayout = layoutStr
            exportData.cdmNativeLayoutName = layoutName
        end
    end

    return exportData
end

-- Export settings to compressed base64 string
function IE.Export(options)
    local LD = GetLibDeflate()
    if not LD then
        return nil, "LibDeflate not available"
    end
    
    -- Build export data
    local exportData = BuildExportData(options)
    if not exportData then
        return nil, "Failed to build export data"
    end
    
    -- Serialize to string
    local serialized = SerializeTable(exportData)
    if not serialized then
        return nil, "Failed to serialize data"
    end
    
    -- Compress with LibDeflate
    local compressed = LD:CompressDeflate(serialized)
    if not compressed then
        return nil, "Failed to compress data"
    end
    
    -- Encode to base64 for clipboard-safe output
    local encoded = LD:EncodeForPrint(compressed)
    if not encoded then
        return nil, "Failed to encode data"
    end
    
    return encoded, nil
end

-- Get export data statistics (for UI display)
function IE.GetExportStats()
    local Shared = GetShared()
    local stats = {
        groups = 0,
        savedPositions = 0,
        freeIcons = 0,
        iconSettings = 0,
        layoutProfiles = 0,
        hasGlobalAura = false,
        hasGlobalCooldown = false,
        hasGroupSettings = false,
    }
    
    if not Shared then return stats end
    
    -- CDMGroups stats (character-specific storage)
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    if cdmGroupsDB then
        local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
        
        if cdmGroupsDB.specData and currentSpec and cdmGroupsDB.specData[currentSpec] then
            local specData = cdmGroupsDB.specData[currentSpec]
            
            -- Count layout profiles
            if specData.layoutProfiles then
                for _ in pairs(specData.layoutProfiles) do
                    stats.layoutProfiles = stats.layoutProfiles + 1
                end
            end
            
            -- Get active profile for stats
            local activeProfileName = specData.activeProfile or "Default"
            local profile = specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
            
            if profile then
                -- Count groups from profile.groupLayouts
                if profile.groupLayouts then
                    for _ in pairs(profile.groupLayouts) do
                        stats.groups = stats.groups + 1
                    end
                end
                
                -- Count positions from profile.savedPositions
                if profile.savedPositions then
                    for _ in pairs(profile.savedPositions) do
                        stats.savedPositions = stats.savedPositions + 1
                    end
                end
                
                -- Count free icons from profile.freeIcons
                if profile.freeIcons then
                    for _ in pairs(profile.freeIcons) do
                        stats.freeIcons = stats.freeIcons + 1
                    end
                end
                
                -- Count iconSettings from profile.iconSettings (NEW location)
                if profile.iconSettings then
                    for _ in pairs(profile.iconSettings) do
                        stats.iconSettings = stats.iconSettings + 1
                    end
                end
            end
            
            -- groupSettings is still at specData level
            stats.hasGroupSettings = specData.groupSettings and next(specData.groupSettings) ~= nil
        end
    end
    
    -- CDMEnhance stats (global defaults only - shared)
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
        local cdmEnhance = ns.db.profile.cdmEnhance
        
        stats.hasGlobalAura = cdmEnhance.globalAuraSettings and next(cdmEnhance.globalAuraSettings) ~= nil
        stats.hasGlobalCooldown = cdmEnhance.globalCooldownSettings and next(cdmEnhance.globalCooldownSettings) ~= nil
    end
    
    -- Arc Auras stats (per-character)
    stats.arcAuras = 0
    if ns.db and ns.db.char and ns.db.char.arcAuras and ns.db.char.arcAuras.trackedItems then
        for _ in pairs(ns.db.char.arcAuras.trackedItems) do
            stats.arcAuras = stats.arcAuras + 1
        end
    end
    stats.arcAurasSpells = 0
    if ns.db and ns.db.char and ns.db.char.arcAuras and ns.db.char.arcAuras.trackedSpells then
        for _ in pairs(ns.db.char.arcAuras.trackedSpells) do
            stats.arcAurasSpells = stats.arcAurasSpells + 1
        end
    end

    -- CDM native layout - fetch actual active layout name same as BuildExportData
    local cdmAvail = CooldownViewerSettings and CooldownViewerSettings.GetDataProvider ~= nil
    if cdmAvail then
        local ok, name = pcall(function()
            local dp = CooldownViewerSettings:GetDataProvider()
            local mgr = dp and dp:GetLayoutManager()
            local activeLayoutID = mgr and mgr:GetActiveLayoutID()
            if not activeLayoutID then return nil end
            local serializer = CooldownViewerSettings:GetSerializer()
            local str = serializer and serializer:SerializeLayouts(activeLayoutID) or nil
            if not str then return nil end
            local decoded = DecodeCDMLayoutString(str)
            local names = decoded and decoded[CDM_SAVE_FIELD_LAYOUT_ID_DATA]
            if names then
                for _, n in pairs(names) do return n end
            end
            return nil
        end)
        stats.hasCDMNativeLayout = true
        stats.cdmNativeLayoutName = (ok and name) or nil
    else
        stats.hasCDMNativeLayout = false
    end

    return stats
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMPORT FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Validate import data structure
local function ValidateImportData(data)
    if type(data) ~= "table" then
        return false, "Invalid data format"
    end
    
    if data.prefix ~= EXPORT_PREFIX then
        return false, "Invalid export prefix - this doesn't appear to be ArcUI CDM data"
    end
    
    if not data.version then
        return false, "Missing version number"
    end
    
    if data.version > EXPORT_VERSION then
        return false, "Export version " .. data.version .. " is newer than supported version " .. EXPORT_VERSION
    end
    
    return true, nil
end

-- Parse import string and return data structure (for preview)
function IE.ParseImportString(importString)
    if not importString or importString == "" then
        return nil, "Empty import string"
    end
    
    -- Clean up the string (remove whitespace, newlines)
    importString = importString:gsub("%s+", "")
    
    local LD = GetLibDeflate()
    if not LD then
        return nil, "LibDeflate not available"
    end
    
    -- Decode from base64
    local decoded = LD:DecodeForPrint(importString)
    if not decoded then
        return nil, "Failed to decode data - invalid format"
    end
    
    -- Decompress
    local decompressed = LD:DecompressDeflate(decoded)
    if not decompressed then
        return nil, "Failed to decompress data - corrupted or invalid"
    end
    
    -- Deserialize
    local data, err = DeserializeTable(decompressed)
    if not data then
        return nil, "Failed to parse data: " .. (err or "unknown error")
    end
    
    -- Validate
    local valid, validErr = ValidateImportData(data)
    if not valid then
        return nil, validErr
    end
    
    return data, nil
end

-- Get import data statistics (for preview UI)
function IE.GetImportStats(data)
    if not data then return nil end
    
    local stats = {
        version = data.version,
        timestamp = data.timestamp,
        exportedBy = data.exportedBy,
        realm = data.realm,
        sourceSpec = data.sourceSpec,
        groups = 0,
        savedPositions = 0,
        freeIcons = 0,
        iconSettings = 0,
        layoutProfiles = 0,
        hasGlobalAuraSettings = false,
        hasGlobalCooldownSettings = false,
        hasGroupSettings = false,
    }
    
    if data.cdmGroups then
        -- Count groups from layoutProfiles.groupLayouts (groups field is deprecated)
        if data.cdmGroups.layoutProfiles then
            for profileName, profileData in pairs(data.cdmGroups.layoutProfiles) do
                if profileData.groupLayouts then
                    for _ in pairs(profileData.groupLayouts) do
                        stats.groups = stats.groups + 1
                    end
                    break  -- Only count first profile (the exported active profile)
                end
            end
        end
        -- LEGACY: Old exports had groups at top level
        if stats.groups == 0 and data.cdmGroups.groups then
            for _ in pairs(data.cdmGroups.groups) do
                stats.groups = stats.groups + 1
            end
        end
        
        if data.cdmGroups.savedPositions then
            for _ in pairs(data.cdmGroups.savedPositions) do
                stats.savedPositions = stats.savedPositions + 1
            end
        end
        
        if data.cdmGroups.freeIcons then
            for _ in pairs(data.cdmGroups.freeIcons) do
                stats.freeIcons = stats.freeIcons + 1
            end
        end
        
        if data.cdmGroups.layoutProfiles then
            for _ in pairs(data.cdmGroups.layoutProfiles) do
                stats.layoutProfiles = stats.layoutProfiles + 1
            end
        end
        
        -- Check iconSettings at TOP LEVEL (legacy exports + new backwards compat export)
        if data.cdmGroups.iconSettings then
            for _ in pairs(data.cdmGroups.iconSettings) do
                stats.iconSettings = stats.iconSettings + 1
            end
        end
        
        -- Also check iconSettings INSIDE layoutProfiles (new format)
        if stats.iconSettings == 0 and data.cdmGroups.layoutProfiles then
            local profileName = data.cdmGroups.activeProfile or "Default"
            local profileData = data.cdmGroups.layoutProfiles[profileName]
            if profileData and profileData.iconSettings then
                for _ in pairs(profileData.iconSettings) do
                    stats.iconSettings = stats.iconSettings + 1
                end
            end
        end
        
        -- groupSettings are at specData level
        stats.hasGroupSettings = data.cdmGroups.groupSettings ~= nil
    end
    
    if data.cdmEnhance then
        -- BACKWARDS COMPAT: Old exports had iconSettings in cdmEnhance
        if data.cdmEnhance.iconSettings and stats.iconSettings == 0 then
            for _ in pairs(data.cdmEnhance.iconSettings) do
                stats.iconSettings = stats.iconSettings + 1
            end
        end
        
        stats.hasGlobalAuraSettings = data.cdmEnhance.globalAuraSettings ~= nil
        stats.hasGlobalCooldownSettings = data.cdmEnhance.globalCooldownSettings ~= nil
        
        -- BACKWARDS COMPAT: Old exports had groupSettings in cdmEnhance
        if not stats.hasGroupSettings then
            stats.hasGroupSettings = data.cdmEnhance.groupSettings ~= nil
        end
    end
    
    -- Arc Auras stats
    stats.arcAuras = 0
    if data.arcAuras and data.arcAuras.trackedItems then
        for _ in pairs(data.arcAuras.trackedItems) do
            stats.arcAuras = stats.arcAuras + 1
        end
    end
    stats.arcAurasSpells = 0
    if data.arcAuras and data.arcAuras.trackedSpells then
        for _ in pairs(data.arcAuras.trackedSpells) do
            stats.arcAurasSpells = stats.arcAurasSpells + 1
        end
    end

    -- CDM native layout
    stats.hasCDMNativeLayout = data.cdmNativeLayout ~= nil and data.cdmNativeLayout ~= ""
    stats.cdmNativeLayoutName = data.cdmNativeLayoutName

    return stats
end

-- Apply imported data to current settings
function IE.Import(importString, options)
    options = options or {}
    
    -- Parse and validate
    local data, err = IE.ParseImportString(importString)
    if not data then
        return false, err
    end
    
    -- Check database availability
    if not ns.db then
        return false, "Database not ready"
    end
    
    -- Get current spec - calculate if not determined yet
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    if not currentSpec then
        local specIdx = GetSpecialization() or 1
        local _, _, classID = UnitClass("player")
        classID = classID or 0
        currentSpec = "class_" .. classID .. "_spec_" .. specIdx
        if ns.CDMGroups then
            ns.CDMGroups.currentSpec = currentSpec
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SPEC GUARD: Block imports from a different spec to prevent profile corruption
    -- ═══════════════════════════════════════════════════════════════════════════
    if data.sourceSpec and data.sourceSpec ~= currentSpec then
        local sourceDisplay = SpecKeyToDisplayName(data.sourceSpec)
        local currentDisplay = SpecKeyToDisplayName(currentSpec)
        return false, string.format(
            "|cffff4444Wrong Spec!|r This export is for |cffffd100%s|r but you are currently playing |cffffd100%s|r. " ..
            "Switch to the correct spec before importing.",
            sourceDisplay, currentDisplay
        )
    end

    local importedCounts = {
        groups = 0,
        savedPositions = 0,
        iconSettings = 0,
        layoutProfiles = 0,
        arcAuras = 0,
    }
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SIMPLIFIED IMPORT: Just add profiles to the database
    -- ═══════════════════════════════════════════════════════════════════════════
    if data.cdmGroups then
        -- Ensure database structure exists (robust for fresh load)
        if not ns.db.char then ns.db.char = {} end
        if not ns.db.char.cdmGroups then
            ns.db.char.cdmGroups = {
                specData = {},
                specInheritedFrom = {},
                enabled = true,
            }
        end
        
        local cdmGroupsDB = ns.db.char.cdmGroups
        if not cdmGroupsDB.specData then cdmGroupsDB.specData = {} end
        
        -- Ensure specData for current spec exists (no activeProfile yet — set after import)
        if not cdmGroupsDB.specData[currentSpec] then
            cdmGroupsDB.specData[currentSpec] = {
                layoutProfiles = {},
            }
        end
        
        local specData = cdmGroupsDB.specData[currentSpec]
        
        -- Ensure layoutProfiles exists
        if not specData.layoutProfiles then
            specData.layoutProfiles = {}
        end
        
        -- NOTE: Do NOT pre-create a "Default" profile here.
        -- The import data arrives below and creates the real profiles.
        -- Pre-creating an empty Default causes EnsureLayoutProfiles to
        -- fill it with wrong default groups on next load.
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- IMPORT PROFILES (REPLACE mode - wipe existing profile if same name)
        -- Full replacement ensures the importer gets an exact copy of the export.
        -- Old profiles with different names are preserved for safety.
        -- ═══════════════════════════════════════════════════════════════════════════
        local importedProfileName = nil
        local exportedBy = data.exportedBy or "Imported"
        
        if data.cdmGroups.layoutProfiles then
            for profileName, profileData in pairs(data.cdmGroups.layoutProfiles) do
                local finalName = profileName
                
                -- If profile name already exists, REPLACE it entirely
                -- This gives the importer an exact copy of the exporter's setup
                if specData.layoutProfiles[profileName] then
                    print(MSG_PREFIX .. "|cffFFFF00Replacing existing profile '|r" .. profileName .. "|cffFFFF00' with imported data|r")
                    -- Wipe the old profile before deep-copying new data
                    wipe(specData.layoutProfiles[profileName])
                    specData.layoutProfiles[profileName] = nil
                end
                
                -- Import the profile
                specData.layoutProfiles[finalName] = DeepCopy(profileData)
                importedCounts.layoutProfiles = importedCounts.layoutProfiles + 1
                importedProfileName = importedProfileName or finalName
                
                -- Count groups and positions in imported profile
                if profileData.groupLayouts then
                    for _ in pairs(profileData.groupLayouts) do
                        importedCounts.groups = importedCounts.groups + 1
                    end
                end
                if profileData.savedPositions then
                    for _ in pairs(profileData.savedPositions) do
                        importedCounts.savedPositions = importedCounts.savedPositions + 1
                    end
                end
                if profileData.iconSettings then
                    for _ in pairs(profileData.iconSettings) do
                        importedCounts.iconSettings = importedCounts.iconSettings + 1
                    end
                end
            end
        end
        
        -- Use activeProfile from import if available
        if not importedProfileName then
            importedProfileName = data.cdmGroups.activeProfile
        end
        
        -- Default to "Default" if nothing imported
        importedProfileName = importedProfileName or "Default"
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- REPAIR: Ensure all profiles have valid groupLayouts
        -- ═══════════════════════════════════════════════════════════════════════════
        local DEFAULT_GROUPS = ns.CDMGroups and ns.CDMGroups.DEFAULT_GROUPS
        
        for profileName, profileData in pairs(specData.layoutProfiles) do
            -- Ensure required tables exist
            if not profileData.savedPositions then profileData.savedPositions = {} end
            if not profileData.freeIcons then profileData.freeIcons = {} end
            if not profileData.iconSettings then profileData.iconSettings = {} end
            
            -- If groupLayouts is empty AND not linked to a Group Layout, populate from DEFAULT_GROUPS
            if (not profileData.groupLayouts or not next(profileData.groupLayouts)) and not profileData.groupLayoutName then
                print(MSG_PREFIX .. "|cffff8800[Repair]|r Profile '" .. profileName .. "' has no groups - adding defaults")
                profileData.groupLayouts = {}
                if DEFAULT_GROUPS then
                    for groupName, groupData in pairs(DEFAULT_GROUPS) do
                        local layout = groupData.layout
                        profileData.groupLayouts[groupName] = {
                            position = groupData.position and DeepCopy(groupData.position) or { x = 0, y = 100 },
                            gridRows = layout and layout.gridRows or 2,
                            gridCols = layout and layout.gridCols or 4,
                            iconSize = layout and layout.iconSize or 36,
                            iconWidth = layout and layout.iconWidth or 36,
                            iconHeight = layout and layout.iconHeight or 36,
                            spacing = layout and layout.spacing or 2,
                            spacingX = layout and layout.spacingX,
                            spacingY = layout and layout.spacingY,
                            separateSpacing = layout and layout.separateSpacing,
                            alignment = layout and layout.alignment,
                            horizontalGrowth = layout and layout.horizontalGrowth,
                            verticalGrowth = layout and layout.verticalGrowth,
                            showBorder = groupData.showBorder or false,
                            showBackground = groupData.showBackground or false,
                            autoReflow = groupData.autoReflow or false,
                            dynamicLayout = groupData.dynamicLayout or false,
                            dynamicContainerSize = groupData.dynamicContainerSize,
                            lockGridSize = groupData.lockGridSize or false,
                            containerPadding = groupData.containerPadding or 0,
                            borderColor = groupData.borderColor and DeepCopy(groupData.borderColor) or { r = 0.5, g = 0.5, b = 0.5, a = 1 },
                            bgColor = groupData.bgColor and DeepCopy(groupData.bgColor) or { r = 0, g = 0, b = 0, a = 0.6 },
                            visibility = groupData.visibility or "always",
                        }
                    end
                else
                    -- Fallback (no DEFAULT_GROUPS available)
                    local fallbackDefaults = { iconWidth = 36, iconHeight = 36, showBorder = false, showBackground = false, autoReflow = false, containerPadding = 0, borderColor = { r = 0.5, g = 0.5, b = 0.5, a = 1 }, bgColor = { r = 0, g = 0, b = 0, a = 0.6 }, visibility = "always" }
                    local function MakeFallback(x, y)
                        local g = { position = { x = x, y = y }, gridRows = 2, gridCols = 4, iconSize = 36, spacing = 2 }
                        for k, v in pairs(fallbackDefaults) do g[k] = type(v) == "table" and DeepCopy(v) or v end
                        return g
                    end
                    profileData.groupLayouts = {
                        ["Essential"] = MakeFallback(0, 100),
                        ["Utility"] = MakeFallback(0, 0),
                        ["Buffs"] = MakeFallback(0, 200),
                    }
                end
            end
        end
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- BACKWARDS COMPAT: Merge top-level iconSettings into imported profile
        -- Old exports stored iconSettings at cdmGroups root level, not inside profiles.
        -- This includes customLabel settings which need to be preserved.
        -- ═══════════════════════════════════════════════════════════════════════════
        if data.cdmGroups.iconSettings and next(data.cdmGroups.iconSettings) then
            local targetProfile = specData.layoutProfiles[importedProfileName]
            if targetProfile then
                if not targetProfile.iconSettings then
                    targetProfile.iconSettings = {}
                end
                -- Merge each icon's settings (don't overwrite if already exists in profile)
                for cdID, settings in pairs(data.cdmGroups.iconSettings) do
                    if not targetProfile.iconSettings[cdID] then
                        targetProfile.iconSettings[cdID] = DeepCopy(settings)
                    end
                end
            end
        end
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- GLOBAL GROUP LAYOUTS: write embedded layouts into importer's global DB
        -- For each layout in data.cdmGroups.globalGroupLayouts:
        --   No conflict  → write directly, profile groupLayoutName links automatically
        --   Conflict     → apply the user's chosen resolution from layoutConflictResolutions:
        --                  "overwrite" → replace only that one layout's data
        --                  "copy"      → write under options.layoutConflictResolutions[name].copyName
        --                               and patch imported profile's groupLayoutName to the new name
        -- ═══════════════════════════════════════════════════════════════════════════
        if data.cdmGroups.globalGroupLayouts and next(data.cdmGroups.globalGroupLayouts) then
            local _glDB = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
            if _glDB then
                local conflicts = options.layoutConflictResolutions or {}
                for layoutName, layoutData in pairs(data.cdmGroups.globalGroupLayouts) do
                    local existing = _glDB[layoutName]
                    if not existing then
                        -- No conflict — write straight in
                        _glDB[layoutName] = DeepCopy(layoutData)
                    else
                        local resolution = conflicts[layoutName]
                        local mode = resolution and resolution.mode
                        if mode == "overwrite" then
                            -- Replace ONLY this layout's data, leave all other layouts untouched
                            wipe(_glDB[layoutName])
                            for k, v in pairs(layoutData) do
                                _glDB[layoutName][k] = DeepCopy(v)
                            end
                        elseif mode == "copy" then
                            local copyName = resolution.copyName
                            if copyName and copyName ~= "" then
                                -- Write under the new name
                                _glDB[copyName] = DeepCopy(layoutData)
                                -- Patch the imported profile's groupLayoutName to point at the copy
                                local importedProfile = specData.layoutProfiles[importedProfileName]
                                if importedProfile and importedProfile.groupLayoutName == layoutName then
                                    importedProfile.groupLayoutName = copyName
                                end
                            end
                        end
                        -- If no resolution provided (shouldn't happen in normal flow) → skip silently
                    end
                end
            end
        end
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- SET ACTIVE PROFILE to the imported one
        -- ═══════════════════════════════════════════════════════════════════════════
        specData.activeProfile = importedProfileName
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- IMPORT GROUP SETTINGS (scale, padding, direction, rowLimit for aura/cooldown/utility)
        -- These are at specData level, not profile level
        -- ═══════════════════════════════════════════════════════════════════════════
        if data.cdmGroups.groupSettings then
            specData.groupSettings = DeepCopy(data.cdmGroups.groupSettings)
        end

        -- keepCDMStyle is stored at specData level (per character, per spec)
        if data.cdmGroups.keepCDMStyle ~= nil then
            specData.keepCDMStyle = data.cdmGroups.keepCDMStyle or nil
        end
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- IMPORT GLOBAL ICON SETTINGS (tooltips, click-through)
        -- These are at cdmGroups root level, not per-spec
        -- ═══════════════════════════════════════════════════════════════════════════
        if data.cdmGroups.globalIconSettings then
            local globalSettings = data.cdmGroups.globalIconSettings
            if globalSettings.disableTooltips ~= nil then
                cdmGroupsDB.disableTooltips = globalSettings.disableTooltips
            end
            if globalSettings.clickThrough ~= nil then
                cdmGroupsDB.clickThrough = globalSettings.clickThrough
            end
            
            -- Refresh cached settings so changes take effect
            if ns.CDMGroups and ns.CDMGroups.RefreshCachedLayoutSettings then
                ns.CDMGroups.RefreshCachedLayoutSettings()
            end
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- IMPORT CDM ENHANCE SETTINGS (global aura/cooldown visuals)
    -- These are in ns.db.profile.cdmEnhance
    -- ═══════════════════════════════════════════════════════════════════════════
    if data.cdmEnhance then
        if not ns.db.profile then ns.db.profile = {} end
        if not ns.db.profile.cdmEnhance then
            ns.db.profile.cdmEnhance = {}
        end
        
        local cdmEnhance = ns.db.profile.cdmEnhance
        
        local flattenGlobals = options.importFlattenGlobals and options.importGlobalSettings

        if flattenGlobals then
            -- ── FLATTEN MODE ──────────────────────────────────────────────────
            -- Bake imported globals into each icon's per-icon settings so the
            -- profile looks exactly as intended, without touching the user's own
            -- globalAuraSettings / globalCooldownSettings.
            --
            -- IMPORTANT: Only touches the single imported profile (importedProfileName).
            -- All other profiles the user already had are completely untouched.
            --
            -- Iterates savedPositions (every icon in the profile) not just the
            -- existing iconSettings entries, so icons that were using globals with
            -- zero per-icon overrides also get a baked entry. Per-icon overrides
            -- always win (globals applied first, per-icon merged on top).
            -- ──────────────────────────────────────────────────────────────────
            local importedAuraGlobals     = data.cdmEnhance.globalAuraSettings
            local importedCooldownGlobals = data.cdmEnhance.globalCooldownSettings

            if (importedAuraGlobals and next(importedAuraGlobals))
            or (importedCooldownGlobals and next(importedCooldownGlobals)) then
                local Shared = GetShared()
                local specDataNow = ns.db.char.cdmGroups
                    and ns.db.char.cdmGroups.specData
                    and ns.db.char.cdmGroups.specData[currentSpec]

                -- ONLY touch the profile we just imported — no other profiles
                local importedProfile = specDataNow
                    and specDataNow.layoutProfiles
                    and specDataNow.layoutProfiles[importedProfileName]

                if importedProfile then
                    if not importedProfile.iconSettings then
                        importedProfile.iconSettings = {}
                    end

                    -- Build the full set of cdIDs to bake:
                    -- savedPositions covers every icon in the profile (group + free).
                    -- This catches icons with NO existing per-icon entry, not just ones
                    -- that already have overrides.
                    local allCDIDs = {}
                    if importedProfile.savedPositions then
                        for cdID in pairs(importedProfile.savedPositions) do
                            allCDIDs[tostring(cdID)] = true
                        end
                    end
                    -- Also include any existing per-icon entries (may cover arc_ IDs
                    -- stored as strings that aren't numeric savedPositions keys)
                    for cdID in pairs(importedProfile.iconSettings) do
                        allCDIDs[tostring(cdID)] = true
                    end

                    for cdIDStr in pairs(allCDIDs) do
                        -- Determine aura vs cooldown for this icon
                        local isAura = false
                        if not cdIDStr:match("^arc_") then
                            if Shared and Shared.SafeGetCDMInfo and Shared.IsAuraCategory then
                                local cdInfo = Shared.SafeGetCDMInfo(tonumber(cdIDStr) or cdIDStr)
                                if cdInfo then
                                    isAura = Shared.IsAuraCategory(cdInfo.category)
                                end
                            end
                        end

                        local globalsToApply = isAura and importedAuraGlobals or importedCooldownGlobals
                        if globalsToApply and next(globalsToApply) then
                            local existingPerIcon = importedProfile.iconSettings[cdIDStr]
                            -- Globals are base, per-icon overrides win on top
                            local baked = DeepMergeImport(DeepCopy(globalsToApply), existingPerIcon)
                            importedProfile.iconSettings[cdIDStr] = baked
                        end
                    end
                end
            end
            -- Don't write globals to cdmEnhance — user's own globals stay intact
        else
            -- Import global aura settings
            if data.cdmEnhance.globalAuraSettings then
                cdmEnhance.globalAuraSettings = DeepCopy(data.cdmEnhance.globalAuraSettings)
            end
            
            -- Import global cooldown settings  
            if data.cdmEnhance.globalCooldownSettings then
                cdmEnhance.globalCooldownSettings = DeepCopy(data.cdmEnhance.globalCooldownSettings)
            end
        end
        
        -- Import other CDMEnhance flags
        if data.cdmEnhance.globalApplyScale ~= nil then
            cdmEnhance.globalApplyScale = data.cdmEnhance.globalApplyScale
        end
        if data.cdmEnhance.globalApplyHideShadow ~= nil then
            cdmEnhance.globalApplyHideShadow = data.cdmEnhance.globalApplyHideShadow
        end
        if data.cdmEnhance.disableRightClickSelect ~= nil then
            cdmEnhance.disableRightClickSelect = data.cdmEnhance.disableRightClickSelect
        end
        if data.cdmEnhance.lockGridSize ~= nil then
            cdmEnhance.lockGridSize = data.cdmEnhance.lockGridSize
        end
        -- Master customization toggles
        if data.cdmEnhance.enableAuraCustomization ~= nil then
            cdmEnhance.enableAuraCustomization = data.cdmEnhance.enableAuraCustomization
        end
        if data.cdmEnhance.enableCooldownCustomization ~= nil then
            cdmEnhance.enableCooldownCustomization = data.cdmEnhance.enableCooldownCustomization
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- IMPORT ARC AURAS (if present)
    -- ═══════════════════════════════════════════════════════════════════════════
    if data.arcAuras then
        if not ns.db.char then ns.db.char = {} end
        if not ns.db.char.arcAuras then
            ns.db.char.arcAuras = {
                enabled = false,
                trackedItems = {},
                trackedSpells = {},
                positions = {},
            }
        end
        
        local arcAuras = ns.db.char.arcAuras
        
        -- If the export has arcAuras disabled, treat as a full wipe —
        -- the exporter intended Arc Auras to be off with no tracked icons.
        -- Clear everything and set enabled=false, don't import any items/spells.
        if data.arcAuras.enabled == false then
            wipe(arcAuras.trackedItems)
            wipe(arcAuras.trackedSpells)
            if arcAuras.positions then wipe(arcAuras.positions) end
            if arcAuras.customTimers then wipe(arcAuras.customTimers) end
            arcAuras.enabled = false
        else
        
        -- Add tracked items (REPLACE existing - wipe first to prevent duplicates from old items surviving)
        if data.arcAuras.trackedItems then
            wipe(arcAuras.trackedItems)
            for arcID, config in pairs(data.arcAuras.trackedItems) do
                arcAuras.trackedItems[arcID] = DeepCopy(config)
                importedCounts.arcAuras = importedCounts.arcAuras + 1
            end
        end
        
        -- Add tracked spell cooldowns (REPLACE existing)
        if data.arcAuras.trackedSpells then
            if not arcAuras.trackedSpells then
                arcAuras.trackedSpells = {}
            else
                wipe(arcAuras.trackedSpells)
            end
            for arcID, config in pairs(data.arcAuras.trackedSpells) do
                arcAuras.trackedSpells[arcID] = DeepCopy(config)
                importedCounts.arcAuras = importedCounts.arcAuras + 1
            end
        end
        
        -- Add positions (REPLACE existing)
        if data.arcAuras.positions then
            wipe(arcAuras.positions)
            for arcID, pos in pairs(data.arcAuras.positions) do
                arcAuras.positions[arcID] = DeepCopy(pos)
            end
        end
        
        -- Set enabled (use ~= nil to handle false correctly)
        if data.arcAuras.enabled ~= nil then
            arcAuras.enabled = data.arcAuras.enabled
        end
        
        -- Restore global visual settings for Arc Aura frames
        if data.arcAuras.globalSettings then
            if not arcAuras.globalSettings then arcAuras.globalSettings = {} end
            wipe(arcAuras.globalSettings)
            for k, v in pairs(data.arcAuras.globalSettings) do
                arcAuras.globalSettings[k] = DeepCopy(v)
            end
        end
        
        -- Restore auto-track settings
        if data.arcAuras.autoTrackEquippedTrinkets ~= nil then
            arcAuras.autoTrackEquippedTrinkets = data.arcAuras.autoTrackEquippedTrinkets
        end
        if data.arcAuras.autoTrackSlots then
            arcAuras.autoTrackSlots = DeepCopy(data.arcAuras.autoTrackSlots)
        end
        if data.arcAuras.onlyOnUseTrinkets ~= nil then
            arcAuras.onlyOnUseTrinkets = data.arcAuras.onlyOnUseTrinkets
        end

        -- Custom Icons (Arc Auras timer-driven icons). Mirror the
        -- trackedSpells pattern: wipe existing then replace. Each config
        -- may carry the new-shape startTrigger/endTrigger fields or the
        -- legacy triggerType/resetOn* bools — the timer engine's
        -- NormalizeConfigTriggers handles both on frame creation.
        if data.arcAuras.customTimers then
            if not arcAuras.customTimers then
                arcAuras.customTimers = {}
            else
                wipe(arcAuras.customTimers)
            end
            for arcID, config in pairs(data.arcAuras.customTimers) do
                arcAuras.customTimers[arcID] = DeepCopy(config)
                importedCounts.arcAuras = importedCounts.arcAuras + 1
            end
            -- Ask the timer engine to tear down its existing frames and
            -- rebuild from the freshly-imported config table.
            if ns.ArcAurasTimer and ns.ArcAurasTimer.RebuildAll then
                ns.ArcAurasTimer.RebuildAll()
            end
        end
        
        -- Also copy to target profile for profile system
        local cdmGroupsDB = ns.db.char.cdmGroups
        if cdmGroupsDB and cdmGroupsDB.specData and cdmGroupsDB.specData[currentSpec] then
            local specData = cdmGroupsDB.specData[currentSpec]
            local targetProfile = specData.layoutProfiles and specData.layoutProfiles[specData.activeProfile or "Default"]
            if targetProfile then
                targetProfile.arcAuras = {
                    trackedItems = DeepCopy(arcAuras.trackedItems),
                    trackedSpells = arcAuras.trackedSpells and DeepCopy(arcAuras.trackedSpells) or nil,
                    positions = DeepCopy(arcAuras.positions),
                    globalSettings = arcAuras.globalSettings and next(arcAuras.globalSettings) and DeepCopy(arcAuras.globalSettings) or nil,
                    enabled = arcAuras.enabled,
                    autoTrackEquippedTrinkets = arcAuras.autoTrackEquippedTrinkets,
                    autoTrackSlots = arcAuras.autoTrackSlots and DeepCopy(arcAuras.autoTrackSlots) or nil,
                    onlyOnUseTrinkets = arcAuras.onlyOnUseTrinkets,
                    customTimers = arcAuras.customTimers and DeepCopy(arcAuras.customTimers) or nil,
                }
            end
        end
        end -- end else (arcAuras.enabled ~= false)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- CDM Native Layout
    -- ═══════════════════════════════════════════════════════════════════════════
    local importedCDMLayoutID = nil
    if data.cdmNativeLayout and data.cdmNativeLayout ~= "" then
        if options.includeCDMLayout ~= false and options.cdmAction ~= "ignore" then
            local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
            local mgr = dp and dp:GetLayoutManager()
            if mgr then
                local ok, err = pcall(function()
                    local newLayoutIDs = mgr:CreateLayoutsFromSerializedData(data.cdmNativeLayout)
                    -- Restore layout name (Blizzard's import strips it)
                    local sourceName = data.cdmNativeLayoutName
                    if sourceName and newLayoutIDs then
                        for _, layoutID in ipairs(newLayoutIDs) do
                            local layout = mgr:GetLayout(layoutID)
                            if layout then
                                local nameOk = pcall(function() mgr:RenameLayout(layoutID, sourceName) end)
                                if not nameOk then
                                    mgr:RenameLayout(layoutID, sourceName .. " (imported)")
                                end
                            end
                        end
                    end
                    -- Live switch so ArcUI imports into the correct CDM layout.
                    -- SV persistence is handled by the deferred write after LoadProfile.
                    if newLayoutIDs and newLayoutIDs[1] then
                        importedCDMLayoutID = newLayoutIDs[1]
                        dp:SetActiveLayoutByID(newLayoutIDs[1])
                    end
                end)
                if ok then
                    importedCounts.cdmNativeLayout = true
                else
                    PrintMsg("|cffff8800CDM layout could not be applied: " .. tostring(err) .. "|r")
                end
            end
        end
    end

    -- ═══════════════════════════════════════════════════════════════════════════
    -- POST-IMPORT: Clear cache and load the profile
    -- ═══════════════════════════════════════════════════════════════════════════
    
    -- Clear any cached database references
    local Shared = GetShared()
    if Shared and Shared.ClearDBCache then
        Shared.ClearDBCache()
    end
    
    -- Invalidate CDMEnhance settings cache
    if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
        ns.CDMEnhance.InvalidateCache()
    end
    
    -- Get the profile name to load
    local profileToLoad = "Default"
    if ns.db.char.cdmGroups and ns.db.char.cdmGroups.specData and ns.db.char.cdmGroups.specData[currentSpec] then
        profileToLoad = ns.db.char.cdmGroups.specData[currentSpec].activeProfile or "Default"
    end
    
    -- Load the imported profile
    if ns.CDMGroups and ns.CDMGroups.LoadProfile then
        local capturedCDMLayoutID = importedCDMLayoutID
        C_Timer.After(0.2, function()
            PrintMsg("Loading profile '" .. profileToLoad .. "'...")
            ns.CDMGroups.LoadProfile(profileToLoad)
            -- Deferred SV write: something in the post-import chain overwrites the CDM active layout
            -- in SV. Writing 0.1s after LoadProfile ensures our new layout ID persists to reload.
            if capturedCDMLayoutID then
                C_Timer.After(0.1, function()
                    local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
                    local mgr = dp and dp:GetLayoutManager()
                    if mgr then
                        local newLayout = mgr:GetLayout(capturedCDMLayoutID)
                        if newLayout then
                            mgr:SetPreviouslyActiveLayout(newLayout)
                            mgr:SetHasPendingChanges(true, false)
                            mgr:GetSerializer():WriteData()
                            mgr:SetHasPendingChanges(false)
                        end
                    end
                end)
            end
        end)
    end
    
    -- Push imported profiles to shared so all synced alts receive them
    local SP = ns.CDMSharedProfiles
    if SP and SP.IsEnabled and SP.Push then
        local _, _, myClassID = UnitClass("player")
        if ns.db.char.cdmGroups and ns.db.char.cdmGroups.specData then
            for specKey in pairs(ns.db.char.cdmGroups.specData) do
                local classID = tonumber(specKey:match("^class_(%d+)_spec_"))
                if classID == myClassID and SP.IsEnabled(specKey) then
                    SP.Push(specKey)
                end
            end
        end
    end
    
    -- Notify FrameController that layout changed
    if ns.FrameController and ns.FrameController.OnLayoutChange then
        ns.FrameController.OnLayoutChange()
    end
    
    return true, importedCounts
end


-- ═══════════════════════════════════════════════════════════════════════════
-- ACCOUNT IMPORT FUNCTIONS
-- Import group layouts from other specs/characters on the same account
-- ═══════════════════════════════════════════════════════════════════════════

-- Class names for fallback display
local CLASS_NAMES = {
    [1] = "Warrior",
    [2] = "Paladin",
    [3] = "Hunter",
    [4] = "Rogue",
    [5] = "Priest",
    [6] = "Death Knight",
    [7] = "Shaman",
    [8] = "Mage",
    [9] = "Warlock",
    [10] = "Monk",
    [11] = "Druid",
    [12] = "Demon Hunter",
    [13] = "Evoker",
}

-- Class file names for RAID_CLASS_COLORS lookup
local CLASS_FILES = {
    [1] = "WARRIOR",
    [2] = "PALADIN", 
    [3] = "HUNTER",
    [4] = "ROGUE",
    [5] = "PRIEST",
    [6] = "DEATHKNIGHT",
    [7] = "SHAMAN",
    [8] = "MAGE",
    [9] = "WARLOCK",
    [10] = "MONK",
    [11] = "DRUID",
    [12] = "DEMONHUNTER",
    [13] = "EVOKER",
}

-- Get available layouts for import from both character and account-wide data
function IE.GetAvailableLayoutsForImport()
    local layouts = {}
    
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    local currentProfile = (ns.CDMGroups and ns.CDMGroups.GetActiveProfileName) and ns.CDMGroups.GetActiveProfileName() or "Default"
    local currentCharKey = ns.db and ns.db.keys and ns.db.keys.char  -- e.g., "Arcgem - Anasterian"
    
    -- Helper to add layouts from a specData table
    local function AddLayoutsFromSpecData(specData, charKey, isCurrentChar)
        if not specData then return end
        
        for specKey, data in pairs(specData) do
            -- Parse spec key: "class_7_spec_2" -> classID=7, specIndex=2
            local classID, specIndex = specKey:match("class_(%d+)_spec_(%d+)")
            classID = tonumber(classID)
            specIndex = tonumber(specIndex)
            
            local hasLegacyGroups = data.groups and next(data.groups)
            local hasProfiles = data.layoutProfiles and next(data.layoutProfiles)
            if classID and specIndex and (hasLegacyGroups or hasProfiles) then
                -- Get spec name using API
                local specName = "Spec " .. specIndex
                if GetSpecializationInfoForClassID then
                    local _, name = GetSpecializationInfoForClassID(classID, specIndex)
                    if name then specName = name end
                end
                
                -- Get character name from the data, or parse from charKey
                local charName = data.characterName
                if not charName and charKey then
                    charName = charKey:match("^([^%-]+)") or "Unknown"
                end
                charName = charName or CLASS_NAMES[classID] or "Unknown"
                
                -- Get class color
                local classFile = CLASS_FILES[classID]
                local classColor = RAID_CLASS_COLORS and classFile and RAID_CLASS_COLORS[classFile]
                local colorHex = classColor and classColor:GenerateHexColor() or "ffffffff"
                
                -- Add the Default/base layout (legacy only — requires specData.groups)
                if hasLegacyGroups then
                    local layoutKey = (charKey or "current") .. "||" .. specKey .. "||Default"
                    local isCurrentDefault = (isCurrentChar and specKey == currentSpec and currentProfile == "Default")
                    if not isCurrentDefault then
                        local alreadyAdded = false
                        for _, existing in ipairs(layouts) do
                            if existing.key == layoutKey then alreadyAdded = true; break end
                        end
                        if not alreadyAdded then
                            table.insert(layouts, {
                                key = layoutKey,
                                specKey = specKey,
                                profileName = "Default",
                                charKey = charKey,
                                isCurrentChar = isCurrentChar,
                                displayName = "|c" .. colorHex .. charName .. "|r - " .. specName,
                                charName = charName,
                                specName = specName,
                                classID = classID,
                                colorHex = colorHex,
                                isDefault = true,
                                isArcProfile = false,
                            })
                        end
                    end
                end
                
                -- Add Arc Manager Profiles (new format — groupLayouts inside each profile)
                if data.layoutProfiles then
                    for profileName, profileData in pairs(data.layoutProfiles) do
                        local isCurrentProfile = (isCurrentChar and specKey == currentSpec and profileName == currentProfile)
                        if not isCurrentProfile then
                            local _hglLDB = profileData.groupLayoutName and ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                            local _hglSrc = (_hglLDB and _hglLDB[profileData.groupLayoutName]) or profileData.groupLayouts
                            local hasGroupLayouts = _hglSrc and next(_hglSrc)
                            -- Legacy fallback: accept profiles whose spec has old specData.groups
                            if hasGroupLayouts or hasLegacyGroups then
                                local profileKey = (charKey or "current") .. "||" .. specKey .. "||" .. profileName
                                local alreadyAdded = false
                                for _, existing in ipairs(layouts) do
                                    if existing.key == profileKey then alreadyAdded = true; break end
                                end
                                if not alreadyAdded then
                                    local groupCount = 0
                                    local groupSource = hasGroupLayouts and _hglSrc or data.groups
                                    if groupSource then
                                        for _ in pairs(groupSource) do groupCount = groupCount + 1 end
                                    end
                                    local groupInfo = " |cff888888(" .. groupCount .. " groups)|r"
                                    table.insert(layouts, {
                                        key = profileKey,
                                        specKey = specKey,
                                        profileName = profileName,
                                        charKey = charKey,
                                        isCurrentChar = isCurrentChar,
                                        displayName = "|cff00ccff" .. profileName .. "|r" .. groupInfo .. " |cff888888(" .. charName .. " - " .. specName .. ")|r |cffff9900[Profile]|r",
                                        charName = charName,
                                        specName = specName,
                                        classID = classID,
                                        colorHex = colorHex,
                                        isDefault = false,
                                        isArcProfile = true,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Access ALL characters via ns.db.sv.char (raw SavedVariables table)
    if ns.db and ns.db.sv and ns.db.sv.char then
        for charKey, charData in pairs(ns.db.sv.char) do
            if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
                local isCurrentChar = (charKey == currentCharKey)
                AddLayoutsFromSpecData(charData.cdmGroups.specData, charKey, isCurrentChar)
            end
        end
    end
    
    -- Sort: Specs first, then Arc Profiles; current char first, then by class/char/spec
    local _, _, myClassID = UnitClass("player")
    myClassID = myClassID or 0
    
    table.sort(layouts, function(a, b) 
        -- Spec layouts before Arc Profiles
        if a.isArcProfile ~= b.isArcProfile then
            return not a.isArcProfile
        end
        -- Current character first
        if a.isCurrentChar ~= b.isCurrentChar then
            return a.isCurrentChar
        end
        -- Same class as current character first
        local aIsMyClass = (a.classID == myClassID)
        local bIsMyClass = (b.classID == myClassID)
        if aIsMyClass ~= bIsMyClass then
            return aIsMyClass
        end
        -- Then by character name
        if a.charName ~= b.charName then
            return a.charName < b.charName
        end
        -- Default profiles before custom profiles
        if a.isDefault ~= b.isDefault then
            return a.isDefault
        end
        -- Then by spec/profile name
        if a.isDefault then
            return a.specName < b.specName
        else
            return a.profileName < b.profileName
        end
    end)
    
    return layouts
end

-- Import group layout structure from another spec/character
-- importKey format: "charKey||specKey||profileName" (e.g., "Arcgem - Anasterian||class_7_spec_2||Test1")
function IE.ImportLayoutFromAccount(importKey)
    -- Parse import key using || delimiter
    local charKey, specKey, profileName = importKey:match("^(.-)%|%|(.-)%|%|(.+)$")
    if not charKey or not specKey or not profileName then
        -- Try legacy format for backwards compatibility
        local sourceType, legacySpecKey, legacyProfileName = importKey:match("^(%a+):(.+):([^:]+)$")
        if sourceType and legacySpecKey and legacyProfileName then
            -- Legacy format - assume current character
            charKey = ns.db and ns.db.keys and ns.db.keys.char
            specKey = legacySpecKey
            profileName = legacyProfileName
        else
            PrintMsg("Invalid import key format")
            return false
        end
    end
    
    -- Get source database from the specific character's data
    local sourceSpecData
    if ns.db and ns.db.sv and ns.db.sv.char and ns.db.sv.char[charKey] then
        local charData = ns.db.sv.char[charKey]
        if charData.cdmGroups and charData.cdmGroups.specData then
            sourceSpecData = charData.cdmGroups.specData[specKey]
        end
    end
    
    if not sourceSpecData then
        PrintMsg("Source spec has no saved data (char: " .. (charKey or "nil") .. ", spec: " .. (specKey or "nil") .. ")")
        return false
    end
    
    -- Get profile data
    if not sourceSpecData.layoutProfiles or not sourceSpecData.layoutProfiles[profileName] then
        PrintMsg("Profile '" .. profileName .. "' not found in source")
        return false
    end
    
    local profileData = sourceSpecData.layoutProfiles[profileName]
    local sourceGroups
    local sourceName = "'" .. profileName .. "' profile"
    
    -- Check if profile has groupLayouts
    if profileData.groupLayouts and next(profileData.groupLayouts) then
        sourceGroups = {}
        for groupName, layoutData in pairs(profileData.groupLayouts) do
            sourceGroups[groupName] = CopyLayoutData(layoutData)
        end
    elseif sourceSpecData.groups and next(sourceSpecData.groups) then
        -- LEGACY FALLBACK: Use specData.groups for old profiles that didn't save groupLayouts
        sourceGroups = DeepCopy(sourceSpecData.groups)
        sourceName = "'" .. profileName .. "' profile (legacy format)"
        PrintMsg("Using legacy specData.groups for profile import")
    else
        PrintMsg("Profile '" .. profileName .. "' has no saved group layouts")
        return false
    end
    
    if not sourceGroups or not next(sourceGroups) then
        PrintMsg("No groups to import")
        return false
    end
    
    -- Need CDMGroups module for the actual import
    if not ns.CDMGroups then
        PrintMsg("CDMGroups module not available")
        return false
    end
    
    local currentSpec = ns.CDMGroups.currentSpec
    local GetSpecData = ns.CDMGroups.GetSpecData
    if not GetSpecData then
        PrintMsg("GetSpecData not available")
        return false
    end
    
    local currentSpecData = GetSpecData(currentSpec)
    if not currentSpecData then
        PrintMsg("Current spec data not available")
        return false
    end
    
    -- Step 1: Hide and clean up ALL existing group elements (including control buttons!)
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        -- Hide and orphan edge arrows first - they're parented to UIParent, not container!
        if group.edgeArrows then
            for _, arrow in pairs(group.edgeArrows) do
                if arrow then
                    arrow:ClearAllPoints()
                    arrow:Hide()
                    arrow:SetParent(nil)
                end
            end
        end
        
        -- Hide and orphan drag toggle button (parented to UIParent!)
        if group.dragToggleBtn then
            group.dragToggleBtn:ClearAllPoints()
            group.dragToggleBtn:Hide()
            group.dragToggleBtn:SetParent(nil)
        end
        
        -- Hide and orphan drag bar
        if group.dragBar then
            group.dragBar:ClearAllPoints()
            group.dragBar:Hide()
            group.dragBar:SetParent(nil)
        end
        
        -- Hide and orphan selection highlight
        if group.selectionHighlight then
            group.selectionHighlight:ClearAllPoints()
            group.selectionHighlight:Hide()
            group.selectionHighlight:SetParent(nil)
        end
        
        -- Hide and orphan container last
        if group.container then
            group.container:ClearAllPoints()
            group.container:Hide()
            group.container:SetParent(nil)
        end
        
        -- Notify EditModeContainers to clean up wrapper for this group
        if ns.EditModeContainers and ns.EditModeContainers.OnGroupDeleted then
            ns.EditModeContainers.OnGroupDeleted(groupName)
        end
    end
    
    -- Step 2: Release all icons back to CDM (this also wipes ns.CDMGroups.groups)
    if ns.CDMGroups.ReleaseAllIcons then
        ns.CDMGroups.ReleaseAllIcons()
    end
    
    if ns.CDMGroups.savedPositions then wipe(ns.CDMGroups.savedPositions) end
    if ns.CDMGroups.freeIcons then wipe(ns.CDMGroups.freeIcons) end
    
    -- Step 3: Get current profile and update groupLayouts (single source of truth)
    local activeProfileName = currentSpecData.activeProfile or "Default"
    local profile = currentSpecData.layoutProfiles and currentSpecData.layoutProfiles[activeProfileName]
    if profile then
        -- Clear savedPositions and freeIcons (these are cooldownID specific)
        profile.savedPositions = {}
        profile.freeIcons = {}
        
        -- CRITICAL: Update runtime savedPositions to point to profile's table
        ns.CDMGroups.savedPositions = profile.savedPositions
        if ns.CDMGroups.specSavedPositions and currentSpec then
            ns.CDMGroups.specSavedPositions[currentSpec] = profile.savedPositions
        end
        
        -- CRITICAL: Update groupLayouts - global if linked, else own
        local _importTarget
        if profile.groupLayoutName then
            local _ldb = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
            if _ldb then
                if not _ldb[profile.groupLayoutName] then _ldb[profile.groupLayoutName] = {} end
                _importTarget = _ldb[profile.groupLayoutName]
                for k in pairs(_importTarget) do _importTarget[k] = nil end
            end
        end
        if not _importTarget then
            profile.groupLayouts = {}
            _importTarget = profile.groupLayouts
        end
        for groupName, groupData in pairs(sourceGroups) do
            _importTarget[groupName] = CopyLayoutData(groupData)
        end
    end
    -- Also clear runtime tables
    currentSpecData.freeIcons = {}
    
    -- Step 4: Recreate groups from active layout source
    local _step4Profile = profile
    local _step4Src
    if _step4Profile and _step4Profile.groupLayoutName then
        local _ldb = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
        _step4Src = _ldb and _ldb[_step4Profile.groupLayoutName]
    end
    _step4Src = _step4Src or (_step4Profile and _step4Profile.groupLayouts) or {}
    for groupName, _ in pairs(_step4Src) do
        if ns.CDMGroups.CreateGroup then
            ns.CDMGroups.CreateGroup(groupName)
        end
    end
    
    -- Step 5: Update shortcuts
    if ns.CDMGroups.specGroups then
        ns.CDMGroups.specGroups[currentSpec] = ns.CDMGroups.groups
    end
    -- REMOVED: specSavedPositions no longer used - savedPositions points directly to specData
    if ns.CDMGroups.specFreeIcons then
        ns.CDMGroups.specFreeIcons[currentSpec] = ns.CDMGroups.freeIcons
    end
    
    -- CRITICAL: Notify FrameController that layout changed (ensures hidden frames get fixed)
    if ns.FrameController and ns.FrameController.OnLayoutChange then
        ns.FrameController.OnLayoutChange()
    end
    
    -- Step 6: Scan and auto-assign icons
    C_Timer.After(0.3, function()
        if ns.CDMGroups.ScanAllViewers then
            ns.CDMGroups.ScanAllViewers()
        end
        if ns.CDMGroups.AutoAssignNewIcons then
            ns.CDMGroups.AutoAssignNewIcons()
        end
        
        -- Layout all groups
        for _, group in pairs(ns.CDMGroups.groups or {}) do
            if group.Layout then group:Layout() end
        end
        
        -- Reflow icons for groups with Fill Gaps enabled
        for _, group in pairs(ns.CDMGroups.groups or {}) do
            if group.autoReflow and group.ReflowIcons then
                group:ReflowIcons()
            end
        end
        
        -- Update visibility
        if ns.CDMGroups.UpdateGroupVisibility then
            ns.CDMGroups.UpdateGroupVisibility()
        end
        
        -- Force CDMEnhance refresh
        if ns.CDMEnhance and ns.CDMEnhance.RefreshAllIcons then
            ns.CDMEnhance.RefreshAllIcons()
        end
    end)
    
    -- Parse source spec for display
    local classID, specIndex = specKey:match("class_(%d+)_spec_(%d+)")
    classID = tonumber(classID)
    specIndex = tonumber(specIndex)
    
    -- Get spec name
    local specName = "Spec " .. (specIndex or "?")
    if GetSpecializationInfoForClassID and classID and specIndex then
        local _, name = GetSpecializationInfoForClassID(classID, specIndex)
        if name then specName = name end
    end
    
    -- Get character name from source data
    local charName = sourceSpecData.characterName or CLASS_NAMES[classID] or "Unknown"
    
    local groupCount = 0
    if profile and profile.groupLayouts then
        for _ in pairs(profile.groupLayouts) do groupCount = groupCount + 1 end
    end
    
    PrintMsg("Imported " .. groupCount .. " groups from " .. charName .. " " .. specName .. " (" .. sourceName .. ")")
    PrintMsg("Icons will be auto-assigned to groups")
    
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UI STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- Collapsible sections state
local collapsedSections = {
    arcManagerProfiles = true,  -- Start collapsed
    quickImport = true,      -- Start collapsed (formerly "Account Import")
    externalExport = true,
    statsOverview = true,
    exportOptions = true,
    importOptions = true,
}

-- Import/Export state
local uiState = {
    exportString = "",
    importString = "",
    importPreview = nil,
    importError = nil,
    -- Export options
    exportGroupLayouts = true,
    exportPositions = true,
    exportIconSettings = true,
    exportGlobalSettings = true,
    exportGroupSettings = true,
    exportProfiles = true,
    exportArcAuras = true,
    -- Import options (what to import)
    importGroupLayouts = true,
    importPositions = true,
    importIconSettings = true,
    importGlobalSettings = true,
    importFlattenGlobals = false,
    importGroupSettings = true,
    importProfiles = true,
    -- Global Group Layout conflict resolution
    -- { [layoutName] = "overwrite" | "copy", copyName = "..." }
    layoutConflictResolutions = {},
    -- Quick Import selection (formerly Account Import)
    selectedAccountImport = nil,
    -- Group Templates state
    selectedGroupTemplate = nil,
    newTemplateName = "",
    newTemplateDesc = "",
    saveTemplateMode = "new",  -- "new" or "update"
    updateTemplateName = nil,
    -- Unified Load Group Layout selection
    selectedLayoutSource = nil,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- GROUP TEMPLATES SYSTEM
-- Account-wide shareable group layouts (no cooldownID data)
-- ═══════════════════════════════════════════════════════════════════════════

-- Get list of all Group Templates with metadata
function IE.GetGroupTemplates()
    local Shared = GetShared()
    if not Shared then return {} end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB then return {} end
    
    local templates = {}
    for name, data in pairs(templatesDB) do
        local groupCount = 0
        if data.groups then
            for _ in pairs(data.groups) do groupCount = groupCount + 1 end
        end
        table.insert(templates, {
            name = name,
            displayName = data.displayName or name,
            description = data.description or "",
            createdBy = data.createdBy or "Unknown",
            createdAt = data.createdAt or 0,
            groupCount = groupCount,
        })
    end
    
    -- Sort by name
    table.sort(templates, function(a, b) return a.name < b.name end)
    
    return templates
end

-- Get templates formatted for dropdown
function IE.GetGroupTemplatesForDropdown()
    local templates = IE.GetGroupTemplates()
    local vals = { [""] = "|cff888888Select a template...|r" }
    
    for _, t in ipairs(templates) do
        local label = t.displayName
        if t.groupCount > 0 then
            label = label .. " |cff888888(" .. t.groupCount .. " groups)|r"
        end
        vals[t.name] = label
    end
    
    return vals
end

-- Get ALL layout sources (templates + other specs) for unified dropdown
-- Returns: values table for dropdown, and a lookup table for source info
function IE.GetAllLayoutSources()
    local vals = {}
    local sourceInfo = {}  -- Lookup table: key -> { type = "template" or "spec", ... }
    
    -- Add placeholder
    vals[""] = "|cff666666Select a source...|r"
    
    -- Add saved templates first (with [Template] suffix to distinguish)
    local templates = IE.GetGroupTemplates()
    for _, t in ipairs(templates) do
        local groupInfo = t.groupCount > 0 and (" |cff888888(" .. t.groupCount .. " groups)|r") or ""
        local key = "template:" .. t.name
        vals[key] = "|cff00ccff" .. t.displayName .. "|r" .. groupInfo .. " |cff666666[Template]|r"
        sourceInfo[key] = {
            type = "template",
            name = t.name,
            displayName = t.displayName,
            groupCount = t.groupCount,
        }
    end
    
    -- Add other specs/profiles (character - spec format)
    local layouts = IE.GetAvailableLayoutsForImport()
    for _, layout in ipairs(layouts) do
        local key = "spec:" .. layout.key
        vals[key] = layout.displayName
        sourceInfo[key] = {
            type = "spec",
            importKey = layout.key,
            displayName = layout.displayName,
            charName = layout.charName,
            specName = layout.specName,
            isArcProfile = layout.isArcProfile,
        }
    end
    
    return vals, sourceInfo
end

-- Get Arc Manager Profiles only (for the profiles dropdown)
-- Returns array of profile info objects from ALL characters on the account
function IE.GetAvailableProfiles()
    local profiles = {}
    
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    local currentProfile = (ns.CDMGroups and ns.CDMGroups.GetActiveProfileName) and ns.CDMGroups.GetActiveProfileName() or "Default"
    local currentCharKey = ns.db and ns.db.keys and ns.db.keys.char  -- e.g., "Arcgem - Anasterian"
    
    -- Helper to add profiles from a specData table
    local function AddProfilesFromSpecData(specData, charKey, isCurrentChar)
        if not specData then return end
        
        for specKey, data in pairs(specData) do
            -- Parse spec key: "class_7_spec_2" -> classID=7, specIndex=2
            local classID, specIndex = specKey:match("class_(%d+)_spec_(%d+)")
            classID = tonumber(classID)
            specIndex = tonumber(specIndex)
            
            -- NOTE: Do NOT deduplicate by shared spec here — users must be able to
            -- see all characters' profiles in the load dropdown regardless of
            -- whether shared sync is enabled. The alreadyAdded key check below
            -- prevents true duplicates (same charKey+specKey+profileName).
            if classID and specIndex and data.layoutProfiles then
                -- Get spec name using API
                local specName = "Spec " .. specIndex
                if GetSpecializationInfoForClassID then
                    local _, name = GetSpecializationInfoForClassID(classID, specIndex)
                    if name then specName = name end
                end
                
                -- Get character name from the data, or parse from charKey
                local charName = data.characterName
                if not charName and charKey then
                    charName = charKey:match("^([^%-]+)") or "Unknown"
                end
                charName = charName or CLASS_NAMES[classID] or "Unknown"
                
                -- Get class color
                local classFile = CLASS_FILES[classID]
                local classColor = RAID_CLASS_COLORS and classFile and RAID_CLASS_COLORS[classFile]
                local colorHex = classColor and classColor:GenerateHexColor() or "ffffffff"
                
                -- Add all profiles with saved layouts
                for profileName, profileData in pairs(data.layoutProfiles) do
                    -- Skip if it's our current spec+profile on current character (can't load what's already loaded)
                    local isCurrentProfile = (isCurrentChar and specKey == currentSpec and profileName == currentProfile)
                    if not isCurrentProfile then
                        -- Check for groupLayouts in profile (or global if linked)
                        local _hgpLDB = profileData.groupLayoutName and ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                        local _hgpSrc = (_hgpLDB and _hgpLDB[profileData.groupLayoutName]) or profileData.groupLayouts
                        local hasGroupLayouts = _hgpSrc and next(_hgpSrc)
                        
                        -- LEGACY FALLBACK: Also check specData.groups for old profiles that didn't save groupLayouts
                        -- This allows us to still show these profiles in the dropdown
                        local hasLegacyGroups = data.groups and next(data.groups)
                        
                        if hasGroupLayouts or hasLegacyGroups then
                            -- Use || as delimiter since charKey can contain special characters
                            local profileKey = (charKey or "current") .. "||" .. specKey .. "||" .. profileName
                            
                            -- Check if we already added this exact profile
                            local alreadyAdded = false
                            for _, existing in ipairs(profiles) do
                                if existing.key == profileKey then
                                    alreadyAdded = true
                                    break
                                end
                            end
                            
                            if not alreadyAdded then
                                -- Count groups - prefer profile.groupLayouts, fall back to specData.groups
                                local groupCount = 0
                                local groupSource = hasGroupLayouts and _hgpSrc or data.groups
                                if groupSource then
                                    for _ in pairs(groupSource) do
                                        groupCount = groupCount + 1
                                    end
                                end
                                
                                -- Add marker if using legacy data
                                local legacyMarker = ""
                                if not hasGroupLayouts and hasLegacyGroups then
                                    legacyMarker = " |cffff8800[legacy]|r"
                                end
                                
                                -- Format: "ProfileName (3 groups) - CharName SpecName"
                                table.insert(profiles, {
                                    key = profileKey,
                                    specKey = specKey,
                                    profileName = profileName,
                                    charKey = charKey,
                                    isCurrentChar = isCurrentChar,
                                    isLegacy = not hasGroupLayouts and hasLegacyGroups,
                                    displayName = "|cff00ccff" .. profileName .. "|r |cff888888(" .. groupCount .. " groups)|r" .. legacyMarker .. " - |c" .. colorHex .. charName .. "|r " .. specName,
                                    charName = charName,
                                    specName = specName,
                                    classID = classID,
                                    groupCount = groupCount,
                                })
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Access ALL characters via ns.db.sv.char (raw SavedVariables table)
    -- This gives us access to all characters' data, not just the current one
    if ns.db and ns.db.sv and ns.db.sv.char then
        for charKey, charData in pairs(ns.db.sv.char) do
            -- Each character has their own cdmGroups.specData
            if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
                local isCurrentChar = (charKey == currentCharKey)
                AddProfilesFromSpecData(charData.cdmGroups.specData, charKey, isCurrentChar)
            end
        end
    end
    
    -- Sort: current character first, then by char name, then by profile name
    local _, _, myClassID = UnitClass("player")
    myClassID = myClassID or 0
    
    table.sort(profiles, function(a, b) 
        -- Current character first
        if a.isCurrentChar ~= b.isCurrentChar then
            return a.isCurrentChar
        end
        -- Same class as current character first
        local aIsMyClass = (a.classID == myClassID)
        local bIsMyClass = (b.classID == myClassID)
        if aIsMyClass ~= bIsMyClass then
            return aIsMyClass
        end
        -- Then by character name
        if a.charName ~= b.charName then
            return a.charName < b.charName
        end
        -- Then by spec
        if a.specName ~= b.specName then
            return a.specName < b.specName
        end
        -- Then by profile name
        return a.profileName < b.profileName
    end)
    
    return profiles
end

-- Cache for source info lookup (refreshed when dropdown values are built)
local cachedSourceInfo = {}

-- Save current groups as a Group Template
function IE.SaveGroupTemplate(name, description, silent)
    if not name or name == "" then
        if not silent then PrintMsg("Template name cannot be empty") end
        return false
    end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB then return false end
    
    if not ns.CDMGroups or not ns.CDMGroups.groups then
        if not silent then PrintMsg("No groups to save") end
        return false
    end
    
    -- Build group data (NO cooldownID data - just structure)
    local groups = {}
    for groupName, group in pairs(ns.CDMGroups.groups) do
        if group.layout then
            groups[groupName] = {
                -- Position
                position = group.position and { x = group.position.x, y = group.position.y },
                -- Grid settings
                gridRows = group.layout.gridRows,
                gridCols = group.layout.gridCols,
                -- Layout settings
                iconSize = group.layout.iconSize,
                iconWidth = group.layout.iconWidth,
                iconHeight = group.layout.iconHeight,
                spacing = group.layout.spacing,
                spacingX = group.layout.spacingX,
                spacingY = group.layout.spacingY,
                separateSpacing = group.layout.separateSpacing,
                alignment = group.layout.alignment,
                horizontalGrowth = group.layout.horizontalGrowth,
                verticalGrowth = group.layout.verticalGrowth,
                -- Appearance
                showBorder = group.showBorder,
                showBackground = group.showBackground,
                autoReflow = group.autoReflow,
                dynamicLayout = group.dynamicLayout,
                dynamicContainerSize = group.dynamicContainerSize,
                lockGridSize = group.lockGridSize,
                containerPadding = group.containerPadding,
                borderColor = group.borderColor and DeepCopy(group.borderColor),
                bgColor = group.bgColor and DeepCopy(group.bgColor),
                -- Visibility
                visibility = group.visibility,
            }
        end
    end
    
    if not next(groups) then
        if not silent then PrintMsg("No groups to save") end
        return false
    end
    
    -- Get character info
    local playerName = UnitName("player") or "Unknown"
    local realmName = GetRealmName() or "Unknown"
    
    -- Save template
    templatesDB[name] = {
        displayName = name,
        description = description or "",
        createdBy = playerName .. "-" .. realmName,
        createdAt = time(),
        groups = groups,
    }
    
    if not silent then
        PrintMsg("Saved Group Template '" .. name .. "'")
    end
    return true
end

-- Delete a Group Template
function IE.DeleteGroupTemplate(name)
    if not name or name == "" then return false end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB then return false end
    
    if not templatesDB[name] then
        PrintMsg("Template '" .. name .. "' not found")
        return false
    end
    
    -- If this was the default, clear the default setting
    local settings = Shared.GetGroupTemplateSettings()
    if settings and settings.defaultTemplate == name then
        settings.defaultTemplate = nil
    end
    
    templatesDB[name] = nil
    PrintMsg("Deleted Group Template '" .. name .. "'")
    return true
end

-- Load a Group Template into current spec (replaces current groups)
function IE.LoadGroupTemplate(name)
    if not name or name == "" then return false end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB or not templatesDB[name] then
        PrintMsg("Template '" .. name .. "' not found")
        return false
    end
    
    local template = templatesDB[name]
    if not template.groups or not next(template.groups) then
        PrintMsg("Template has no groups")
        return false
    end
    
    if not ns.CDMGroups then
        PrintMsg("CDMGroups module not available")
        return false
    end
    
    -- Use the same import logic as ImportLayoutFromAccount
    -- Step 1: Hide and cleanup existing groups
    for groupName, group in pairs(ns.CDMGroups.groups or {}) do
        -- Hide and orphan edge arrows first - they're parented to UIParent, not container!
        if group.edgeArrows then
            for _, arrow in pairs(group.edgeArrows) do
                if arrow then
                    arrow:ClearAllPoints()
                    arrow:Hide()
                    arrow:SetParent(nil)
                end
            end
        end
        
        -- Hide and orphan drag toggle button (parented to UIParent!)
        if group.dragToggleBtn then
            group.dragToggleBtn:ClearAllPoints()
            group.dragToggleBtn:Hide()
            group.dragToggleBtn:SetParent(nil)
        end
        
        -- Hide and orphan drag bar
        if group.dragBar then
            group.dragBar:ClearAllPoints()
            group.dragBar:Hide()
            group.dragBar:SetParent(nil)
        end
        
        -- Hide and orphan selection highlight
        if group.selectionHighlight then
            group.selectionHighlight:ClearAllPoints()
            group.selectionHighlight:Hide()
            group.selectionHighlight:SetParent(nil)
        end
        
        -- Hide and orphan container last
        if group.container then
            group.container:ClearAllPoints()
            group.container:Hide()
            group.container:SetParent(nil)
        end
        
        -- Notify EditModeContainers to clean up wrapper for this group
        if ns.EditModeContainers and ns.EditModeContainers.OnGroupDeleted then
            ns.EditModeContainers.OnGroupDeleted(groupName)
        end
    end
    
    -- Step 2: Release all icons back to CDM
    if ns.CDMGroups.ReleaseAllIcons then
        ns.CDMGroups.ReleaseAllIcons()
    end
    
    -- Step 3: Clear runtime data
    wipe(ns.CDMGroups.groups)
    wipe(ns.CDMGroups.savedPositions)
    wipe(ns.CDMGroups.freeIcons)
    
    -- Step 4: Get current spec data and update groups
    local specData = ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData()
    if specData then
        -- CRITICAL FIX: Update profile.groupLayouts (single source of truth)
        local activeProfileName = specData.activeProfile or "Default"
        local profile = specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
        if profile then
            profile.savedPositions = {}
            profile.freeIcons = {}
            
            -- CRITICAL: Update runtime savedPositions to point to profile's table
            ns.CDMGroups.savedPositions = profile.savedPositions
            local specKey = ns.CDMGroups.currentSpec
            if ns.CDMGroups.specSavedPositions and specKey then
                ns.CDMGroups.specSavedPositions[specKey] = profile.savedPositions
            end
            
            -- CRITICAL: Update groupLayouts - global if linked, else own
            local _import2Target
            if profile.groupLayoutName then
                local _ldb2 = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                if _ldb2 then
                    if not _ldb2[profile.groupLayoutName] then _ldb2[profile.groupLayoutName] = {} end
                    _import2Target = _ldb2[profile.groupLayoutName]
                    for k in pairs(_import2Target) do _import2Target[k] = nil end
                end
            end
            if not _import2Target then
                profile.groupLayouts = {}
                _import2Target = profile.groupLayouts
            end
            for groupName, layoutData in pairs(template.groups) do
                _import2Target[groupName] = CopyLayoutData(layoutData)
            end
        end
        -- Clear runtime freeIcons table
        specData.freeIcons = {}
    end
    
    -- Step 5: Create group containers
    for groupName, _ in pairs(template.groups) do
        ns.CDMGroups.CreateGroup(groupName)
    end
    
    -- Step 6: Update shortcuts
    local specKey = ns.CDMGroups.currentSpec
    if specKey then
        ns.CDMGroups.specGroups = ns.CDMGroups.specGroups or {}
        ns.CDMGroups.specGroups[specKey] = ns.CDMGroups.groups
        -- REMOVED: specSavedPositions no longer used - savedPositions points directly to specData
        ns.CDMGroups.specFreeIcons = ns.CDMGroups.specFreeIcons or {}
        ns.CDMGroups.specFreeIcons[specKey] = ns.CDMGroups.freeIcons
    end
    
    -- CRITICAL: Notify FrameController that layout changed (ensures hidden frames get fixed)
    if ns.FrameController and ns.FrameController.OnLayoutChange then
        ns.FrameController.OnLayoutChange()
    end
    
    -- Step 7: Scan and auto-assign icons
    C_Timer.After(0.3, function()
        if ns.CDMGroups.ScanAllViewers then ns.CDMGroups.ScanAllViewers() end
        if ns.CDMGroups.AutoAssignNewIcons then ns.CDMGroups.AutoAssignNewIcons() end
        
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.Layout then group:Layout() end
        end
        
        -- Reflow icons for groups with Fill Gaps enabled
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.autoReflow and group.ReflowIcons then
                group:ReflowIcons()
            end
        end
        
        if ns.CDMGroups.UpdateGroupVisibility then
            ns.CDMGroups.UpdateGroupVisibility()
        end
        
        if ns.CDMEnhance and ns.CDMEnhance.RefreshAllIcons then
            ns.CDMEnhance.RefreshAllIcons()
        end
    end)
    
    -- Step 8: Store loaded template name in spec data
    if specData then
        specData.loadedTemplateName = name
        
        -- Check if this template is linked by any other spec - if so, auto-link this spec too
        if IE.IsTemplateLinkedByAnySpec and IE.IsTemplateLinkedByAnySpec(name) then
            specData.linkedTemplateName = name
            PrintMsg("Auto-linked to template '" .. name .. "' (shared with other specs)")
        end
    end
    
    PrintMsg("Loaded Group Template '" .. name .. "'")
    
    -- Notify UI to refresh immediately
    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
    if AceConfigRegistry then
        AceConfigRegistry:NotifyChange("ArcUI")
    end
    
    return true
end

-- Get template info
function IE.GetGroupTemplateInfo(name)
    if not name or name == "" then return nil end
    
    local Shared = GetShared()
    if not Shared then return nil end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB or not templatesDB[name] then return nil end
    
    local data = templatesDB[name]
    local groupCount = 0
    local groupNames = {}
    if data.groups then
        for gName in pairs(data.groups) do
            groupCount = groupCount + 1
            table.insert(groupNames, gName)
        end
    end
    table.sort(groupNames)
    
    return {
        name = name,
        displayName = data.displayName or name,
        description = data.description or "",
        createdBy = data.createdBy or "Unknown",
        createdAt = data.createdAt or 0,
        groupCount = groupCount,
        groupNames = groupNames,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LINKED TEMPLATE SYSTEM
-- Auto-save changes to a linked template
-- ═══════════════════════════════════════════════════════════════════════════

-- Debounce timer for auto-save
local autoSaveTimer = nil
local AUTO_SAVE_DELAY = 2.0  -- Wait 2 seconds after last change before saving

-- Get the currently loaded template name for this spec
function IE.GetLoadedTemplateName()
    if not ns.CDMGroups or not ns.CDMGroups.GetSpecData then return nil end
    local specData = ns.CDMGroups.GetSpecData()
    return specData and specData.loadedTemplateName or nil
end

-- Set the loaded template name (called when loading a template)
function IE.SetLoadedTemplateName(name)
    if not ns.CDMGroups or not ns.CDMGroups.GetSpecData then return end
    local specData = ns.CDMGroups.GetSpecData()
    if specData then
        specData.loadedTemplateName = name
    end
end

-- Clear the loaded template name (e.g., when groups are manually modified)
function IE.ClearLoadedTemplateName()
    IE.SetLoadedTemplateName(nil)
end

-- Get the linked template name (auto-save target)
function IE.GetLinkedTemplateName()
    if not ns.CDMGroups or not ns.CDMGroups.GetSpecData then return nil end
    local specData = ns.CDMGroups.GetSpecData()
    return specData and specData.linkedTemplateName or nil
end

-- Set the linked template (will auto-save changes to this template)
function IE.SetLinkedTemplateName(name)
    if not ns.CDMGroups or not ns.CDMGroups.GetSpecData then return end
    local specData = ns.CDMGroups.GetSpecData()
    if specData then
        specData.linkedTemplateName = name
        if name then
            PrintMsg("Linked to template '" .. name .. "' - changes will auto-save")
        else
            PrintMsg("Unlinked from template - changes will not auto-save")
        end
    end
end

-- Unlink from any template
function IE.UnlinkTemplate()
    IE.SetLinkedTemplateName(nil)
end

-- Check if a template is linked by any spec (across all characters on this account)
-- Returns true if any spec has this template linked
function IE.IsTemplateLinkedByAnySpec(templateName)
    if not templateName or templateName == "" then return false end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local db = Shared.GetCDMGroupsDB()
    if not db or not db.specData then return false end
    
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    
    for specKey, specData in pairs(db.specData) do
        -- Skip current spec (we're asking about OTHER specs)
        if specKey ~= currentSpec and specData.linkedTemplateName == templateName then
            return true
        end
    end
    
    return false
end

-- Get all specs that have a template linked
-- Returns array of spec keys
function IE.GetSpecsLinkedToTemplate(templateName)
    if not templateName or templateName == "" then return {} end
    
    local Shared = GetShared()
    if not Shared then return {} end
    
    local db = Shared.GetCDMGroupsDB()
    if not db or not db.specData then return {} end
    
    local linkedSpecs = {}
    for specKey, specData in pairs(db.specData) do
        if specData.linkedTemplateName == templateName then
            table.insert(linkedSpecs, specKey)
        end
    end
    
    return linkedSpecs
end

-- Auto-save current groups to linked template (with debouncing)
function IE.TriggerAutoSave()
    local linkedName = IE.GetLinkedTemplateName()
    if not linkedName then return end
    
    -- Cancel existing timer if any
    if autoSaveTimer then
        autoSaveTimer:Cancel()
        autoSaveTimer = nil
    end
    
    -- Start new debounce timer
    autoSaveTimer = C_Timer.NewTimer(AUTO_SAVE_DELAY, function()
        autoSaveTimer = nil
        IE.AutoSaveToLinkedTemplate()
    end)
end

-- Actually perform the auto-save
function IE.AutoSaveToLinkedTemplate()
    local linkedName = IE.GetLinkedTemplateName()
    if not linkedName or linkedName == "" then return false end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB or not templatesDB[linkedName] then
        -- Template was deleted, unlink
        IE.UnlinkTemplate()
        return false
    end
    
    -- Get existing description
    local existingData = templatesDB[linkedName]
    local description = existingData and existingData.description or ""
    
    -- Save silently (don't print message for auto-save)
    local success = IE.SaveGroupTemplate(linkedName, description, true)  -- true = silent
    
    if success then
        -- Also update loadedTemplateName since we just saved to it
        IE.SetLoadedTemplateName(linkedName)
        
        -- Sync to other specs that have this template linked
        -- They will pick up changes on next spec switch
        -- (The template data is shared, so they'll automatically get updates)
    end
    
    return success
end

-- Check if a template exists
function IE.TemplateExists(name)
    if not name or name == "" then return false end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    return templatesDB and templatesDB[name] ~= nil
end

-- Sync current spec to its linked template (reload groups from template)
-- Call this after spec switch if the spec has a linked template
-- Returns true if sync was performed
function IE.SyncToLinkedTemplate()
    local linkedName = IE.GetLinkedTemplateName()
    if not linkedName or linkedName == "" then return false end
    
    -- Check if template still exists
    if not IE.TemplateExists(linkedName) then
        -- Template was deleted, unlink
        IE.UnlinkTemplate()
        return false
    end
    
    -- Reload from template (this will update the groups to match the template)
    local success = IE.LoadGroupTemplate(linkedName)
    if success then
        -- Re-set the linked name (LoadGroupTemplate may have already done this via auto-link detection)
        local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData()
        if specData then
            specData.linkedTemplateName = linkedName
        end
    end
    
    return success
end

-- Check if current spec should sync to linked template
-- Returns linked template name if sync needed, nil otherwise
function IE.ShouldSyncToLinkedTemplate()
    local linkedName = IE.GetLinkedTemplateName()
    if not linkedName or linkedName == "" then return nil end
    
    if not IE.TemplateExists(linkedName) then
        return nil
    end
    
    return linkedName
end

-- Create default Group Template on first load
function IE.EnsureDefaultTemplate()
    local Shared = GetShared()
    if not Shared then return end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB then return end
    
    -- Only create if no templates exist at all
    if next(templatesDB) then return end
    
    -- Create "Default" template from DEFAULT_GROUPS
    local DEFAULT_GROUPS = {
        Buffs = {
            position = { x = 0, y = 200 },
            gridRows = 2, gridCols = 4,
            iconSize = 36, iconWidth = 36, iconHeight = 36,
            spacing = 2,
            showBorder = false, showBackground = false,
            autoReflow = false, lockGridSize = false,
            containerPadding = 0,
            borderColor = { r = 0.3, g = 0.8, b = 0.3, a = 1 },
            bgColor = { r = 0, g = 0, b = 0, a = 0.6 },
            visibility = "always",
        },
        Essential = {
            position = { x = 0, y = 100 },
            gridRows = 2, gridCols = 4,
            iconSize = 36, iconWidth = 36, iconHeight = 36,
            spacing = 2,
            showBorder = false, showBackground = false,
            autoReflow = false, lockGridSize = false,
            containerPadding = 0,
            borderColor = { r = 0.8, g = 0.6, b = 0.2, a = 1 },
            bgColor = { r = 0, g = 0, b = 0, a = 0.6 },
            visibility = "always",
        },
        Utility = {
            position = { x = 0, y = 0 },
            gridRows = 2, gridCols = 4,
            iconSize = 36, iconWidth = 36, iconHeight = 36,
            spacing = 2,
            showBorder = false, showBackground = false,
            autoReflow = false, lockGridSize = false,
            containerPadding = 0,
            borderColor = { r = 0.3, g = 0.6, b = 0.9, a = 1 },
            bgColor = { r = 0, g = 0, b = 0, a = 0.6 },
            visibility = "always",
        },
    }
    
    templatesDB["Default"] = {
        displayName = "Default",
        description = "Default 3-group layout (Buffs, Essential, Utility)",
        createdBy = "System",
        createdAt = time(),
        groups = DEFAULT_GROUPS,
    }
    
    print("|cff00ccffArcUI|r: Created default Group Template")
end

-- Save another spec's layout as a Group Template
-- layoutKey format: "charKey||specKey||profileName" (e.g., "Arcgem - Anasterian||class_7_spec_2||Default")
function IE.SaveSpecAsTemplate(layoutKey, templateName)
    if not layoutKey or layoutKey == "" then return false end
    if not templateName or templateName == "" then
        PrintMsg("Template name cannot be empty")
        return false
    end
    
    local Shared = GetShared()
    if not Shared then return false end
    
    local templatesDB = Shared.GetGroupTemplatesDB()
    if not templatesDB then return false end
    
    -- Parse the layout key (new format with || delimiter)
    local charKey, specKey, profileName = layoutKey:match("^(.-)%|%|(.-)%|%|(.+)$")
    if not charKey or not specKey then
        -- Try legacy format for backwards compatibility
        local sourceType, legacySpecKey, legacyProfileName = layoutKey:match("^(%w+):([^:]+):(.+)$")
        if sourceType and legacySpecKey then
            charKey = ns.db and ns.db.keys and ns.db.keys.char
            specKey = legacySpecKey
            profileName = legacyProfileName
        else
            PrintMsg("Invalid layout key")
            return false
        end
    end
    
    -- Get the source data from the specific character
    local sourceSpecData = nil
    if ns.db and ns.db.sv and ns.db.sv.char and ns.db.sv.char[charKey] then
        local charData = ns.db.sv.char[charKey]
        if charData.cdmGroups and charData.cdmGroups.specData then
            sourceSpecData = charData.cdmGroups.specData[specKey]
        end
    end
    
    if not sourceSpecData then
        PrintMsg("Source spec data not found")
        return false
    end
    
    -- Get groups from the appropriate source
    local sourceGroups = nil
    if profileName == "Default" then
        -- Use the spec's base groups
        sourceGroups = sourceSpecData.groups
    else
        -- Use a specific profile's groupLayouts (or global if linked)
        if sourceSpecData.layoutProfiles and sourceSpecData.layoutProfiles[profileName] then
            local _sp = sourceSpecData.layoutProfiles[profileName]
            if _sp.groupLayoutName then
                local _ldb = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                sourceGroups = _ldb and _ldb[_sp.groupLayoutName]
            end
            if not sourceGroups then sourceGroups = _sp.groupLayouts end
        end
    end
    
    if not sourceGroups or not next(sourceGroups) then
        PrintMsg("No groups found in source layout")
        return false
    end
    
    -- Build group data (NO cooldownID data - just structure)
    local groups = {}
    for groupName, group in pairs(sourceGroups) do
        -- Handle both runtime group format and profile groupLayouts format
        local layout = group.layout or group
        groups[groupName] = {
            -- Position
            position = group.position and { x = group.position.x, y = group.position.y },
            -- Grid settings
            gridRows = layout.gridRows or 2,
            gridCols = layout.gridCols or 4,
            -- Layout settings
            iconSize = layout.iconSize or 36,
            iconWidth = layout.iconWidth or 36,
            iconHeight = layout.iconHeight or 36,
            spacing = layout.spacing or 2,
            spacingX = layout.spacingX,
            spacingY = layout.spacingY,
            separateSpacing = layout.separateSpacing,
            alignment = layout.alignment,
            horizontalGrowth = layout.horizontalGrowth,
            verticalGrowth = layout.verticalGrowth,
            -- Appearance
            showBorder = group.showBorder,
            showBackground = group.showBackground,
            autoReflow = group.autoReflow,
            dynamicLayout = group.dynamicLayout,
            dynamicContainerSize = group.dynamicContainerSize,
            lockGridSize = group.lockGridSize,
            containerPadding = group.containerPadding,
            borderColor = group.borderColor and DeepCopy(group.borderColor),
            bgColor = group.bgColor and DeepCopy(group.bgColor),
            -- Visibility
            visibility = group.visibility or "always",
        }
    end
    
    if not next(groups) then
        PrintMsg("Failed to extract groups from source")
        return false
    end
    
    -- Get source info for metadata
    local charName = sourceSpecData.characterName or "Unknown"
    local classID = tonumber(specKey:match("class_(%d+)"))
    local specIndex = tonumber(specKey:match("spec_(%d+)"))
    local specName = "Unknown Spec"
    if classID and specIndex and GetSpecializationInfoForClassID then
        local _, name = GetSpecializationInfoForClassID(classID, specIndex)
        if name then specName = name end
    end
    
    -- Save template
    templatesDB[templateName] = {
        displayName = templateName,
        description = "Imported from " .. charName .. " - " .. specName,
        createdBy = charName,
        createdAt = time(),
        groups = groups,
    }
    
    PrintMsg("Saved template '" .. templateName .. "' from " .. charName .. " " .. specName)
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS TABLE FOR ACECONFIG
-- ═══════════════════════════════════════════════════════════════════════════

local function GetOptionsTable()
    local Shared = GetShared()
    
    local options = {
        type = "group",
        name = "Profiles & Import/Export",
        args = {
            -- ═══════════════════════════════════════════════════════════════════
            -- HEADER
            -- ═══════════════════════════════════════════════════════════════════
            headerDesc = {
                type = "description",
                name = "|cffffd100Manage Arc Manager Profiles and import/export settings.|r",
                fontSize = "medium",
                order = 1,
            },
            spacer1 = {
                type = "description",
                name = " ",
                order = 2,
            },
            
            -- ═══════════════════════════════════════════════════════════════════
            -- ARC MANAGER PROFILES (Per-spec profiles with talent conditions)
            -- Moved from Groups tab - full profile management
            -- ═══════════════════════════════════════════════════════════════════
            arcProfilesToggle = {
                type = "toggle",
                name = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    return "Arc Manager Profiles |cff00ff00[" .. active .. "]|r"
                end,
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                order = 15,
                width = "full",
                get = function() return not collapsedSections.arcManagerProfiles end,
                set = function(_, v) collapsedSections.arcManagerProfiles = not v end,
            },
            arcProfilesDesc = {
                type = "description",
                name = "|cffaaaaaaPer-spec profiles with full layout snapshots. Supports talent-based auto-switching.|r",
                order = 15.1,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.arcManagerProfiles end,
            },
            arcProfileSelect = {
                type = "select",
                name = "Profile",
                desc = "Select a layout profile. Profiles can store different icon arrangements.",
                order = 15.2,
                width = 1.0,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                values = function()
                    local vals = {}
                    if ns.CDMGroups and ns.CDMGroups.GetProfileNames then
                        for _, name in ipairs(ns.CDMGroups.GetProfileNames()) do
                            vals[name] = name
                        end
                    else
                        vals["Default"] = "Default"
                    end
                    return vals
                end,
                get = function()
                    return ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                end,
                set = function(_, val)
                    if ns.CDMGroups and ns.CDMGroups.LoadProfile then
                        -- Flush any pending auto-save so no changes are lost on switch
                        if ns.CDMGroups.SaveGroupLayoutsToActiveProfile then
                            ns.CDMGroups.SaveGroupLayoutsToActiveProfile()
                        end
                        ns.CDMGroups.LoadProfile(val)
                    end
                end,
            },
            arcProfileNewBtn = {
                type = "execute",
                name = "|cff88ff88+ New|r",
                desc = "Create a new profile from current layout",
                order = 15.3,
                width = 0.45,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                func = function()
                    StaticPopupDialogs["ARCUI_ARC_NEW_PROFILE"] = {
                        text = "Enter name for new profile:",
                        button1 = "Create",
                        button2 = "Cancel",
                        hasEditBox = true,
                        OnAccept = function(self)
                            local name = self.EditBox:GetText()
                            if name and name ~= "" then
                                if ns.CDMGroups and ns.CDMGroups.CreateProfile then
                                    ns.CDMGroups.CreateProfile(name)
                                    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                                    if AceConfigRegistry then
                                        AceConfigRegistry:NotifyChange("ArcUI")
                                    end
                                end
                            end
                        end,
                        OnShow = function(self)
                            self:SetFrameStrata("FULLSCREEN_DIALOG")
                            self.EditBox:SetText("")
                            self.EditBox:SetFocus()
                        end,
                        EditBoxOnTextChanged = function(self)
                            -- Validation handled in OnAccept
                        end,
                        EditBoxOnEnterPressed = function(self)
                            local parent = self:GetParent()
                            local name = self:GetText()
                            if name and name ~= "" then
                                if ns.CDMGroups and ns.CDMGroups.CreateProfile then
                                    ns.CDMGroups.CreateProfile(name)
                                    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                                    if AceConfigRegistry then
                                        AceConfigRegistry:NotifyChange("ArcUI")
                                    end
                                end
                            end
                            parent:Hide()
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = true,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("ARCUI_ARC_NEW_PROFILE")
                end,
            },
            arcProfileDeleteBtn = {
                type = "execute",
                name = "|cffff8888Delete|r",
                desc = "Delete the selected profile",
                order = 15.4,
                width = 0.45,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                disabled = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    return active == "Default"
                end,
                func = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    if active == "Default" then return end
                    
                    StaticPopupDialogs["ARCUI_ARC_DELETE_PROFILE"] = {
                        text = "Delete profile '" .. active .. "'?",
                        button1 = "Delete",
                        button2 = "Cancel",
                        OnAccept = function()
                            if ns.CDMGroups and ns.CDMGroups.DeleteProfile then
                                ns.CDMGroups.DeleteProfile(active)
                                local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                                if AceConfigRegistry then
                                    AceConfigRegistry:NotifyChange("ArcUI")
                                end
                            end
                        end,
                        OnShow = function(self)
                            self:SetFrameStrata("FULLSCREEN_DIALOG")
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = true,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("ARCUI_ARC_DELETE_PROFILE")
                end,
            },
            arcProfileSaveBtn = {
                type = "execute",
                name = "Save Layout",
                desc = "Save current icon layout to the active profile",
                order = 15.5,
                width = 0.6,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                func = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    if ns.CDMGroups and ns.CDMGroups.SaveCurrentToProfile then
                        ns.CDMGroups._explicitSaveRequested = true
                        ns.CDMGroups.SaveCurrentToProfile(active)
                        ns.CDMGroups._explicitSaveRequested = nil
                    end
                end,
            },
            arcProfileTalentConditionsBtn = {
                type = "execute",
                name = "Talent Conditions |cffff6666[Disabled]|r",
                desc = "Talent-based profile auto-switching is under construction",
                order = 15.6,
                width = 0.85,
                hidden = function() return true end,  -- DISABLED: Talent profile switching under construction
                func = function()
                    PrintMsg("Talent-based profile switching is currently under construction.")
                end,
            },
            arcProfileTalentConditionsSummary = {
                type = "description",
                name = "|cffff6666Talent-based auto-switching is under construction.|r",
                order = 15.7,
                fontSize = "medium",
                hidden = function() return true end,  -- DISABLED: Talent profile switching under construction
            },
            arcProfileRenameBtn = {
                type = "execute",
                name = "Rename",
                desc = "Rename the current profile",
                order = 15.8,
                width = 0.5,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                disabled = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    return active == "Default"
                end,
                func = function()
                    local active = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"
                    if active == "Default" then return end
                    
                    StaticPopupDialogs["ARCUI_ARC_RENAME_PROFILE"] = {
                        text = "Enter new name for profile '" .. active .. "':",
                        button1 = "Rename",
                        button2 = "Cancel",
                        hasEditBox = true,
                        OnAccept = function(self)
                            local newName = self.EditBox:GetText()
                            if newName and newName ~= "" then
                                if ns.CDMGroups and ns.CDMGroups.RenameProfile then
                                    local success, err = ns.CDMGroups.RenameProfile(active, newName)
                                    if not success then
                                        PrintMsg(err or "Failed to rename profile")
                                    end
                                    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                                    if AceConfigRegistry then
                                        AceConfigRegistry:NotifyChange("ArcUI")
                                    end
                                end
                            end
                        end,
                        OnShow = function(self)
                            self:SetFrameStrata("FULLSCREEN_DIALOG")
                            self.EditBox:SetText(active)
                            self.EditBox:HighlightText()
                            self.EditBox:SetFocus()
                        end,
                        EditBoxOnEnterPressed = function(self)
                            local parent = self:GetParent()
                            local newName = self:GetText()
                            if newName and newName ~= "" then
                                if ns.CDMGroups and ns.CDMGroups.RenameProfile then
                                    local success, err = ns.CDMGroups.RenameProfile(active, newName)
                                    if not success then
                                        PrintMsg(err or "Failed to rename profile")
                                    end
                                    local AceConfigRegistry = LibStub("AceConfigRegistry-3.0", true)
                                    if AceConfigRegistry then
                                        AceConfigRegistry:NotifyChange("ArcUI")
                                    end
                                end
                            end
                            parent:Hide()
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = true,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("ARCUI_ARC_RENAME_PROFILE")
                end,
            },
            arcProfileResetDefaultBtn = {
                type = "execute",
                name = "|cffff9900Reset Default|r",
                desc = "Reset the Default profile to factory settings (empty layout with default groups)",
                order = 15.9,
                width = 0.7,
                hidden = function() return collapsedSections.arcManagerProfiles end,
                func = function()
                    StaticPopupDialogs["ARCUI_ARC_RESET_DEFAULT"] = {
                        text = "|cffff9900Warning:|r This will reset the Default profile to factory settings.\n\nAll icon positions and settings in the Default profile will be lost.\n\nAre you sure?",
                        button1 = "Reset",
                        button2 = "Cancel",
                        OnAccept = function()
                            if ns.CDMGroups and ns.CDMGroups.ResetDefaultProfile then
                                ns.CDMGroups.ResetDefaultProfile()
                                
                                -- Show reload prompt
                                StaticPopupDialogs["ARCUI_ARC_RESET_RELOAD"] = {
                                    text = "Default profile has been reset.\n\nPlease reload your UI to complete the reset.",
                                    button1 = "Reload Now",
                                    button2 = "Later",
                                    OnAccept = function()
                                        ReloadUI()
                                    end,
                                    OnShow = function(self)
                                        self:SetFrameStrata("FULLSCREEN_DIALOG")
                                    end,
                                    timeout = 0,
                                    whileDead = true,
                                    hideOnEscape = true,
                                    preferredIndex = 3,
                                }
                                StaticPopup_Show("ARCUI_ARC_RESET_RELOAD")
                            end
                        end,
                        OnShow = function(self)
                            self:SetFrameStrata("FULLSCREEN_DIALOG")
                        end,
                        timeout = 0,
                        whileDead = true,
                        hideOnEscape = true,
                        preferredIndex = 3,
                    }
                    StaticPopup_Show("ARCUI_ARC_RESET_DEFAULT")
                end,
            },
            
            -- ═══════════════════════════════════════════════════════════════════
            -- GROUP LAYOUT LINK STATUS (inline under profile row)
            -- ═══════════════════════════════════════════════════════════════════
            arcProfileGroupLayoutLinked = {
                type = "description",
                name = function()
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    if linked then
                        return "|cff00ccffGroup Layout: " .. linked .. "|r"
                    end
                    return ""
                end,
                order = 15.95,
                width = "full",
                fontSize = "small",
                hidden = function()
                    if collapsedSections.arcManagerProfiles then return true end
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    return not linked
                end,
            },

            -- ═══════════════════════════════════════════════════════════════════
            -- EXTERNAL EXPORT/IMPORT (Collapsible)
            -- ═══════════════════════════════════════════════════════════════════
            externalExportToggle = {
                type = "toggle",
                name = "External Export/Import",
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                order = 20,
                width = "full",
                get = function() return not collapsedSections.externalExport end,
                set = function(_, v) collapsedSections.externalExport = not v end,
            },
            externalExportDesc = {
                type = "description",
                name = "|cffaaaaaaShare settings with others via export strings or backup/restore your configuration.|r",
                order = 21,
                width = "full",
                fontSize = "small",
                hidden = function() return collapsedSections.externalExport end,
            },
            
            -- CURRENT SETTINGS STATS (Collapsible, inside External)
            statsToggle = {
                type = "toggle",
                name = "|cffffd100Current Settings Overview|r",
                desc = "Expand to see what's currently configured",
                dialogControl = "CollapsibleHeader",
                order = 30,
                width = "full",
                hidden = function() return collapsedSections.externalExport end,
                get = function() return not collapsedSections.statsOverview end,
                set = function(_, v) collapsedSections.statsOverview = not v end,
            },
            statsInfo = {
                type = "description",
                name = function()
                    local stats = IE.GetExportStats()
                    local specName = "Unknown"
                    if ns.CDMGroups and ns.CDMGroups.currentSpec then
                        local specIndex = GetSpecialization()
                        if specIndex and GetSpecializationInfo then
                            local _, name = GetSpecializationInfo(specIndex)
                            if name then specName = name end
                        else
                            specName = ns.CDMGroups.currentSpec
                        end
                    end
                    local activeProfile = ns.CDMGroups and ns.CDMGroups.GetActiveProfileName and ns.CDMGroups.GetActiveProfileName() or "Default"

                    local lines = {
                        "|cff888888Spec:|r           |cffffffff" .. specName .. "|r",
                        "|cff888888Active Profile:|r |cffffffff" .. activeProfile .. "|r",
                        "",
                        "|cff00ccffGroups:|r          |cffffffff" .. stats.groups .. "|r",
                        "|cff00ccffIcon Positions:|r  |cffffffff" .. stats.savedPositions .. "|r",
                        "|cff00ccffFree Icons:|r      |cffffffff" .. stats.freeIcons .. "|r",
                        "|cff00ccffLayout Profiles:|r |cffffffff" .. stats.layoutProfiles .. "|r",
                        "|cff00ccffIcon Settings:|r   |cffffffff" .. stats.iconSettings .. "|r",
                        "",
                        "|cff888888Global Aura Defaults:|r " .. (stats.hasGlobalAura and "|cff00ff00Yes|r" or "|cff666666No|r"),
                        "|cff888888Global CD Defaults:|r   " .. (stats.hasGlobalCooldown and "|cff00ff00Yes|r" or "|cff666666No|r"),
                        "|cff888888Group Settings:|r       " .. (stats.hasGroupSettings and "|cff00ff00Yes|r" or "|cff666666No|r"),
                    }
                    -- Add Arc Auras info if present
                    if (stats.arcAuras or 0) > 0 or (stats.arcAurasSpells or 0) > 0 then
                        table.insert(lines, "")
                        table.insert(lines, "|cff888888Arc Auras:|r")
                        if (stats.arcAuras or 0) > 0 then
                            table.insert(lines, "  Tracked Items:  |cffffffff" .. stats.arcAuras .. "|r")
                        end
                        if (stats.arcAurasSpells or 0) > 0 then
                            table.insert(lines, "  Tracked Spells: |cffffffff" .. stats.arcAurasSpells .. "|r")
                        end
                    end
                    -- CDM native layout
                    table.insert(lines, "")
                    if stats.hasCDMNativeLayout then
                        local name = stats.cdmNativeLayoutName or "Unknown"
                        table.insert(lines, "|cff888888CDM Layout:|r           |cff00ff00" .. name .. "|r")
                    else
                        table.insert(lines, "|cff888888CDM Layout:|r           |cff666666Not included|r")
                    end
                    return table.concat(lines, "\n")
                end,
                fontSize = "medium",
                order = 31,
                hidden = function() return collapsedSections.externalExport or collapsedSections.statsOverview end,
            },
            
            -- EXPORT SECTION
            exportHeader = {
                type = "header",
                name = "Export Settings",
                order = 40,
                hidden = function() return collapsedSections.externalExport end,
            },
            exportOptionsToggle = {
                type = "toggle",
                name = "|cffffd100Export Options|r",
                desc = "Expand to choose what to include in the export",
                dialogControl = "CollapsibleHeader",
                order = 41,
                width = "full",
                hidden = function() return collapsedSections.externalExport end,
                get = function() return not collapsedSections.exportOptions end,
                set = function(_, v) collapsedSections.exportOptions = not v end,
            },
            -- Export option checkboxes
            exportGroupLayouts = {
                type = "toggle",
                name = "Group Layouts",
                desc = "Include group structure (positions, sizes, appearance settings)",
                order = 42,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportGroupLayouts end,
                set = function(_, v) uiState.exportGroupLayouts = v end,
            },
            exportPositions = {
                type = "toggle",
                name = "Icon Positions",
                desc = "Include which icons are assigned to which groups and slots",
                order = 43,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportPositions end,
                set = function(_, v) uiState.exportPositions = v end,
            },
            exportIconSettings = {
                type = "toggle",
                name = "Icon Settings",
                desc = "Include per-icon visual customizations (borders, text, glows, etc.)",
                order = 44,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportIconSettings end,
                set = function(_, v) uiState.exportIconSettings = v end,
            },
            exportGlobalSettings = {
                type = "toggle",
                name = "Global Defaults",
                desc = "Include global aura and cooldown default settings",
                order = 45,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportGlobalSettings end,
                set = function(_, v) uiState.exportGlobalSettings = v end,
            },
            exportGroupSettings = {
                type = "toggle",
                name = "Group Settings",
                desc = "Include spacing, scale, and direction settings per viewer type",
                order = 46,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportGroupSettings end,
                set = function(_, v) uiState.exportGroupSettings = v end,
            },
            exportProfiles = {
                type = "toggle",
                name = "Layout Profiles",
                desc = "Include layout profiles with talent conditions",
                order = 47,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportProfiles end,
                set = function(_, v) uiState.exportProfiles = v end,
            },
            exportArcAuras = {
                type = "toggle",
                name = "Arc Auras",
                desc = "Include Arc Auras tracked spells and items. Uncheck this to exclude your trinkets/pots from the export.",
                order = 47.5,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
                get = function() return uiState.exportArcAuras end,
                set = function(_, v) uiState.exportArcAuras = v end,
            },
            exportSpacer = {
                type = "description",
                name = "",
                order = 48,
                hidden = function() return collapsedSections.externalExport or collapsedSections.exportOptions end,
            },
            -- Export button
            exportButton = {
                type = "execute",
                name = "|TInterface\\BUTTONS\\UI-GuildButton-PublicNote-Up:16|t Generate Export String",
                desc = "Generate export string with selected options",
                order = 50,
                width = 1.3,
                hidden = function() return collapsedSections.externalExport end,
                func = function()
                    local exportStr, err = IE.Export({
                        includePositions = uiState.exportPositions,
                        includeIconSettings = uiState.exportIconSettings,
                        includeGlobalSettings = uiState.exportGlobalSettings,
                        includeGroupSettings = uiState.exportGroupSettings,
                        includeArcAuras = uiState.exportArcAuras,
                    })
                    if exportStr then
                        uiState.exportString = exportStr
                        PrintMsg("|cff00ff00Export generated!|r Copy the string below.")
                        -- Apply WA-style hooks: re-assert text on any edit, highlight on click
                        C_Timer.After(0.05, function()
                            local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
                            local dlg = acd and acd.OpenFrames and acd.OpenFrames["ArcUI"]
                            if not dlg then return end
                            local snap = exportStr
                            local function FindEB(frame, depth)
                                if (depth or 0) > 12 then return nil end
                                if frame.GetObjectType and frame:GetObjectType() == "EditBox" and frame:IsVisible() then
                                    local t = frame:GetText()
                                    if t and #t > 20 and snap:sub(1,20) == t:sub(1,20) then return frame end
                                end
                                if frame.GetChildren then
                                    for _, child in ipairs({frame:GetChildren()}) do
                                        local found = FindEB(child, (depth or 0) + 1)
                                        if found then return found end
                                    end
                                end
                            end
                            local eb = FindEB(dlg.frame or dlg)
                            if eb then
                                -- WA pattern: re-assert string on any edit attempt, re-highlight on click
                                eb:SetScript("OnTextChanged", function()
                                    eb:SetText(snap)
                                    eb:HighlightText()
                                end)
                                eb:SetScript("OnMouseUp", function()
                                    eb:HighlightText()
                                end)
                                eb:HighlightText()
                                eb:SetFocus()
                            end
                        end)
                    else
                        uiState.exportString = "ERROR: " .. (err or "Unknown error")
                        PrintMsg("|cffff0000Export failed:|r " .. (err or "Unknown error"))
                    end
                end,
            },
            exportString = {
                type = "input",
                name = "Export String  (Ctrl+C to copy)",
                desc = "Copy this string to share your settings",
                order = 52,
                multiline = 6,
                width = "full",
                hidden = function() return collapsedSections.externalExport end,
                get = function() return uiState.exportString end,
                set = function(_, v) uiState.exportString = v end,
            },
            
            -- IMPORT SECTION
            importHeader = {
                type = "header",
                name = "Import Settings",
                order = 60,
                hidden = function() return collapsedSections.externalExport end,
            },
            importString = {
                type = "input",
                name = "Paste Export String Here",
                desc = "Paste an exported settings string to import",
                order = 61,
                multiline = 6,
                width = "full",
                hidden = function() return collapsedSections.externalExport end,
                get = function() return uiState.importString end,
                set = function(_, v)
                    uiState.importString = v
                    -- Auto-preview on paste
                    if v and v ~= "" then
                        local data, err = IE.ParseImportString(v)
                        if data then
                            uiState.importPreview = IE.GetImportStats(data)
                            uiState.importError = nil
                            -- Reset conflict resolutions and detect which layouts conflict
                            wipe(uiState.layoutConflictResolutions)
                            if data.cdmGroups and data.cdmGroups.globalGroupLayouts then
                                local _glDB = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                                for layoutName in pairs(data.cdmGroups.globalGroupLayouts) do
                                    if _glDB and _glDB[layoutName] then
                                        -- Conflict — default to overwrite, user can change
                                        uiState.layoutConflictResolutions[layoutName] = {
                                            mode = "overwrite",
                                            copyName = layoutName .. " (imported)",
                                        }
                                    end
                                end
                            end
                        else
                            uiState.importPreview = nil
                            uiState.importError = err
                            wipe(uiState.layoutConflictResolutions)
                        end
                    else
                        uiState.importPreview = nil
                        uiState.importError = nil
                        wipe(uiState.layoutConflictResolutions)
                    end
                end,
            },
            -- Preview info
            importPreviewInfo = {
                type = "description",
                name = function()
                    if uiState.importError then
                        return "|cffff0000Error:|r " .. uiState.importError
                    end
                    if not uiState.importPreview then
                        return "|cff888888Paste an export string above to see preview|r"
                    end
                    local p = uiState.importPreview
                    -- Spec mismatch check
                    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
                    if not currentSpec then
                        local specIdx = GetSpecialization() or 1
                        local _, _, classID = UnitClass("player")
                        currentSpec = "class_" .. (classID or 0) .. "_spec_" .. specIdx
                    end
                    if p.sourceSpec and p.sourceSpec ~= currentSpec then
                        local sourceDisplay = SpecKeyToDisplayName(p.sourceSpec)
                        local currentDisplay = SpecKeyToDisplayName(currentSpec)
                        return "|cffff4444Wrong Spec!|r\n\n" ..
                            "This export is for: |cffffd100" .. sourceDisplay .. "|r\n" ..
                            "You are playing:     |cffffd100" .. currentDisplay .. "|r\n\n" ..
                            "|cff888888Switch to the correct spec before importing.|r"
                    end
                    local timeStr = p.timestamp and date("%Y-%m-%d %H:%M", p.timestamp) or "Unknown"
                    local lines = {
                        "|cff00ff00Valid export detected!|r",
                        "",
                        "|cff888888From:|r " .. (p.exportedBy or "?") .. " - " .. (p.realm or "?"),
                        "|cff888888Date:|r " .. timeStr,
                        "|cff888888Version:|r " .. (p.version or "?"),
                        "",
                        "|cff00ccffContents:|r",
                        "  Groups: |cffffffff" .. p.groups .. "|r",
                        "  Icon Positions: |cffffffff" .. p.savedPositions .. "|r",
                        "  Free Icons: |cffffffff" .. p.freeIcons .. "|r",
                        "  Layout Profiles: |cffffffff" .. p.layoutProfiles .. "|r",
                        "  Icon Settings: |cffffffff" .. p.iconSettings .. "|r",
                        "  Global Defaults: " .. (p.hasGlobalAuraSettings and "|cff00ff00Aura|r " or "") .. (p.hasGlobalCooldownSettings and "|cff00ff00Cooldown|r" or ""),
                        "  Group Settings: " .. (p.hasGroupSettings and "|cff00ff00Yes|r" or "|cff666666No|r"),
                    }
                    -- Add Arc Auras info if present
                    if (p.arcAuras or 0) > 0 or (p.arcAurasSpells or 0) > 0 then
                        table.insert(lines, "")
                        table.insert(lines, "|cff00ccffArc Auras:|r")
                        if (p.arcAuras or 0) > 0 then
                            table.insert(lines, "  Tracked Items: |cffffffff" .. p.arcAuras .. "|r")
                        end
                        if (p.arcAurasSpells or 0) > 0 then
                            table.insert(lines, "  Tracked Spells: |cffffffff" .. p.arcAurasSpells .. "|r")
                        end
                    end
                    -- CDM native layout
                    table.insert(lines, "")
                    if p.hasCDMNativeLayout then
                        local name = p.cdmNativeLayoutName or "Unknown"
                        table.insert(lines, "|cff00ccffCDM Layout:|r      |cff00ff00" .. name .. "|r")
                    else
                        table.insert(lines, "|cff00ccffCDM Layout:|r      |cff666666Not included|r")
                    end
                    return table.concat(lines, "\n")
                end,
                fontSize = "medium",
                order = 62,
                hidden = function() return collapsedSections.externalExport end,
            },
            -- Import options
            importOptionsToggle = {
                type = "toggle",
                name = "|cffffd100Import Options|r",
                desc = "Expand to choose what to import and how",
                dialogControl = "CollapsibleHeader",
                order = 63,
                width = "full",
                hidden = function() return collapsedSections.externalExport end,
                get = function() return not collapsedSections.importOptions end,
                set = function(_, v) collapsedSections.importOptions = not v end,
            },
            importGroupLayouts = {
                type = "toggle",
                name = "Group Layouts",
                desc = "Import group structure",
                order = 65,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importGroupLayouts end,
                set = function(_, v) uiState.importGroupLayouts = v end,
            },
            importPositions = {
                type = "toggle",
                name = "Icon Positions",
                desc = "Import icon assignments",
                order = 66,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importPositions end,
                set = function(_, v) uiState.importPositions = v end,
            },
            importIconSettings = {
                type = "toggle",
                name = "Icon Settings",
                desc = "Import per-icon visual settings",
                order = 67,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importIconSettings end,
                set = function(_, v) uiState.importIconSettings = v end,
            },
            importGlobalSettings = {
                type = "toggle",
                name = "Global Defaults",
                desc = "Import global aura/cooldown defaults",
                order = 68,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importGlobalSettings end,
                set = function(_, v) uiState.importGlobalSettings = v end,
            },
            importFlattenGlobals = {
                type = "toggle",
                name = "Bake Globals into Icons",
                desc = "Instead of overwriting your Global Defaults, merge the imported globals into each icon's per-icon settings. " ..
                       "You get the profile looking exactly as intended but your own Global Defaults are untouched.",
                order = 68.5,
                width = 1.4,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                disabled = function() return not uiState.importGlobalSettings end,
                get = function() return uiState.importFlattenGlobals end,
                set = function(_, v) uiState.importFlattenGlobals = v end,
            },
            importGroupSettings = {
                type = "toggle",
                name = "Group Settings",
                desc = "Import spacing/scale/direction settings",
                order = 69,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importGroupSettings end,
                set = function(_, v) uiState.importGroupSettings = v end,
            },
            importProfiles = {
                type = "toggle",
                name = "Layout Profiles",
                desc = "Import layout profiles",
                order = 70,
                width = 0.7,
                hidden = function() return collapsedSections.externalExport or collapsedSections.importOptions end,
                get = function() return uiState.importProfiles end,
                set = function(_, v) uiState.importProfiles = v end,
            },
            importSpacer = {
                type = "description",
                name = "",
                order = 71,
                hidden = function() return collapsedSections.externalExport end,
            },
            
            -- ═══════════════════════════════════════════════════════════════
            -- GLOBAL GROUP LAYOUT CONFLICT RESOLUTION
            -- One block per conflicting layout name, shown between import
            -- options and the Import button. Each gives the user a choice:
            --   Overwrite  → replace only that layout's data
            --   Create copy → write under a new name (user-typed)
            -- Import button is blocked until all conflicts have a valid resolution.
            -- ═══════════════════════════════════════════════════════════════
            layoutConflictHeader = {
                type = "description",
                name = function()
                    if not next(uiState.layoutConflictResolutions) then return "" end
                    return "|cffffff00Global Group Layout Conflicts|r\n" ..
                           "|cff888888The following layouts from this export already exist in your account. " ..
                           "Choose how to handle each one:|r"
                end,
                order = 71.1,
                fontSize = "medium",
                hidden = function()
                    return collapsedSections.externalExport or not next(uiState.layoutConflictResolutions)
                end,
            },
            layoutConflictWidgets = {
                type = "group",
                name = "",
                order = 71.2,
                inline = true,
                hidden = function()
                    return collapsedSections.externalExport or not next(uiState.layoutConflictResolutions)
                end,
                args = (function()
                    -- Build dynamically — one block per conflicting layout
                    -- This closure runs once at options table build time.
                    -- The widgets use closures over layoutConflictResolutions so they
                    -- always reflect current state.
                    local conflictArgs = {}
                    -- We use a metatable trick: the args table is always the same table
                    -- reference, so we can populate it dynamically when needed.
                    -- AceConfig re-reads args on every NotifyChange.
                    setmetatable(conflictArgs, {
                        __index = function(t, k) return nil end,
                        __newindex = rawset,
                    })
                    -- Return a proxy that rebuilds on each access
                    return setmetatable({}, {
                        __index = function(_, k)
                            -- Rebuild on every widget access so new conflicts appear immediately
                            local args = {}
                            local order = 1
                            for layoutName, res in pairs(uiState.layoutConflictResolutions) do
                                local capName = layoutName  -- capture for closures
                                args["conflict_" .. order .. "_label"] = {
                                    type = "description",
                                    name = "|cffffd100\"" .. layoutName .. "\"|r",
                                    order = order,
                                    width = "full",
                                    fontSize = "medium",
                                }
                                args["conflict_" .. order .. "_mode"] = {
                                    type = "select",
                                    name = "Action",
                                    order = order + 0.1,
                                    width = 1.0,
                                    values = {
                                        overwrite = "Overwrite existing",
                                        copy = "Create a copy",
                                    },
                                    get = function()
                                        local r = uiState.layoutConflictResolutions[capName]
                                        return r and r.mode or "overwrite"
                                    end,
                                    set = function(_, val)
                                        if uiState.layoutConflictResolutions[capName] then
                                            uiState.layoutConflictResolutions[capName].mode = val
                                        end
                                        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                                    end,
                                }
                                args["conflict_" .. order .. "_copyName"] = {
                                    type = "input",
                                    name = "New Name",
                                    desc = "Name for the copy of this layout",
                                    order = order + 0.2,
                                    width = 1.2,
                                    hidden = function()
                                        local r = uiState.layoutConflictResolutions[capName]
                                        return not r or r.mode ~= "copy"
                                    end,
                                    get = function()
                                        local r = uiState.layoutConflictResolutions[capName]
                                        return r and r.copyName or ""
                                    end,
                                    set = function(_, val)
                                        if uiState.layoutConflictResolutions[capName] then
                                            uiState.layoutConflictResolutions[capName].copyName = val
                                        end
                                    end,
                                }
                                args["conflict_" .. order .. "_copyWarn"] = {
                                    type = "description",
                                    name = function()
                                        local r = uiState.layoutConflictResolutions[capName]
                                        if not r or r.mode ~= "copy" then return "" end
                                        local cn = r.copyName or ""
                                        if cn == "" then
                                            return "|cffff4444Please enter a name for the copy.|r"
                                        end
                                        local _glDB = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                                        if _glDB and _glDB[cn] then
                                            return "|cffff4444A layout named \"" .. cn .. "\" already exists.|r"
                                        end
                                        return "|cff00ff00Name is available.|r"
                                    end,
                                    order = order + 0.3,
                                    fontSize = "small",
                                    hidden = function()
                                        local r = uiState.layoutConflictResolutions[capName]
                                        return not r or r.mode ~= "copy"
                                    end,
                                }
                                order = order + 1
                            end
                            return args[k]
                        end,
                        __pairs = function(_)
                            local args = {}
                            local order = 1
                            for layoutName, res in pairs(uiState.layoutConflictResolutions) do
                                local capName = layoutName
                                args["conflict_" .. order .. "_label"] = true
                                args["conflict_" .. order .. "_mode"] = true
                                args["conflict_" .. order .. "_copyName"] = true
                                args["conflict_" .. order .. "_copyWarn"] = true
                                order = order + 1
                            end
                            return next, args, nil
                        end,
                    })
                end)(),
            },
            -- Import button
            importButton = {
                type = "execute",
                name = "|TInterface\\BUTTONS\\UI-GuildButton-PublicNote-Disabled:16|t Import Settings",
                desc = "Apply the imported settings",
                order = 72,
                width = 1.0,
                hidden = function() return collapsedSections.externalExport end,
                disabled = function()
                    if uiState.importPreview == nil then return true end
                    local p = uiState.importPreview
                    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
                    if not currentSpec then
                        local specIdx = GetSpecialization() or 1
                        local _, _, classID = UnitClass("player")
                        currentSpec = "class_" .. (classID or 0) .. "_spec_" .. specIdx
                    end
                    if p.sourceSpec and p.sourceSpec ~= currentSpec then return true end
                    -- Block if any layout conflict is in "copy" mode with empty or duplicate name
                    if next(uiState.layoutConflictResolutions) then
                        local _glDB = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                        for _, res in pairs(uiState.layoutConflictResolutions) do
                            if res.mode == "copy" then
                                local cn = res.copyName or ""
                                if cn == "" then return true end
                                if _glDB and _glDB[cn] then return true end
                            end
                        end
                    end
                    return false
                end,
                confirm = function()
                    return "This will REPLACE your current CDM settings with the imported ones.\n\nAre you sure?"
                end,
                func = function()
                    -- Pre-check: does this import include a CDM layout and are we at the cap?
                    local preview = uiState.importPreview
                    local hasCDMLayout = preview and preview.hasCDMNativeLayout
                    local cdmMaxed = false
                    if hasCDMLayout then
                        local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
                        local mgr = dp and dp:GetLayoutManager()
                        cdmMaxed = mgr and mgr:AreLayoutsFullyMaxed()
                    end

                    local function DoImport(cdmAction)
                        local success, result = IE.Import(uiState.importString, {
                            mergeMode = "replace",
                            importGroupLayouts = uiState.importGroupLayouts,
                            importPositions = uiState.importPositions,
                            importIconSettings = uiState.importIconSettings,
                            importGlobalSettings = uiState.importGlobalSettings,
                            importFlattenGlobals = uiState.importFlattenGlobals,
                            importGroupSettings = uiState.importGroupSettings,
                            importProfiles = uiState.importProfiles,
                            layoutConflictResolutions = uiState.layoutConflictResolutions,
                            cdmAction = cdmAction, -- "replace", "ignore", or nil (normal add)
                        })
                        if success then
                            PrintMsg("|cff00ff00Import successful!|r")
                            if type(result) == "table" then
                                PrintMsg(string.format("Imported: %d profiles, %d groups, %d positions, %d icon settings",
                                    result.layoutProfiles or 0, result.groups or 0, result.savedPositions or 0, result.iconSettings or 0))
                                if (result.arcAuras or 0) > 0 then
                                    PrintMsg(string.format("Arc Auras: %d tracked items/spells", result.arcAuras))
                                end
                                if result.cdmNativeLayout then
                                    PrintMsg("|cff00ff00CDM layout imported.|r")
                                end
                            end
                            uiState.importString = ""
                            uiState.importPreview = nil
                            uiState.importError = nil
                            wipe(uiState.layoutConflictResolutions)
                            StaticPopup_Show("ARCUI_RELOAD_AFTER_IMPORT")
                        else
                            PrintMsg("|cffff0000Import failed:|r " .. (result or "Unknown error"))
                        end
                    end

                    if cdmMaxed then
                        -- Block import until user decides: ignore CDM or cancel and delete a slot first
                        local layoutName = (preview and preview.cdmNativeLayoutName) or "Unknown"
                        StaticPopupDialogs["ARCUI_CDM_LAYOUT_MAXED"] = {
                            text = "|cff00ccffArcUI Import|r\n\nCDM layout limit reached (5/5).\n\n\"" .. layoutName .. "\" cannot be added.\n\nDelete a CDM layout in CDM settings first, then re-import — or ignore the CDM layout and import everything else now.",
                            button1 = "Ignore CDM Layout",
                            button2 = "I'll Delete One First",
                            OnAccept = function()
                                DoImport("ignore")
                            end,
                            OnCancel = function()
                                PrintMsg("|cffff8800Import cancelled. Delete a CDM layout in CDM settings, then re-import.|r")
                            end,
                            timeout = 0,
                            whileDead = true,
                            hideOnEscape = false,
                            preferredIndex = 3,
                        }
                        local popup = StaticPopup_Show("ARCUI_CDM_LAYOUT_MAXED")
                        if popup then
                            popup:ClearAllPoints()
                            popup:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                            popup:SetFrameStrata("FULLSCREEN_DIALOG")
                            popup:SetFrameLevel(100)
                        end
                    else
                        DoImport(nil)
                    end
                end,
            },
            clearImportBtn = {
                type = "execute",
                name = "Clear",
                desc = "Clear the import field",
                order = 73,
                width = 0.5,
                hidden = function() return collapsedSections.externalExport end,
                func = function()
                    uiState.importString = ""
                    uiState.importPreview = nil
                    uiState.importError = nil
                    wipe(uiState.layoutConflictResolutions)
                end,
            },
            
            -- HELP SECTION
            helpHeader = {
                type = "header",
                name = "Help",
                order = 80,
                hidden = function() return collapsedSections.externalExport end,
            },
            helpText = {
                type = "description",
                name = "|cffffd100What gets exported:|r\n\n" ..
                       "- |cff00ccffGroup Layouts|r - Container positions, sizes, rows/columns, borders, backgrounds\n" ..
                       "- |cff00ccffIcon Positions|r - Which icons are in which groups and their grid positions\n" ..
                       "- |cff00ccffIcon Settings|r - Per-icon borders, text styles, glows, state visuals\n" ..
                       "- |cff00ccffGlobal Defaults|r - Default settings for all auras/cooldowns\n" ..
                       "- |cff00ccffGroup Settings|r - Spacing, scale, direction per viewer type\n" ..
                       "- |cff00ccffGlobal Icon Settings|r - Tooltip visibility, click-through\n" ..
                       "- |cff00ccffLayout Profiles|r - Saved profiles with talent conditions\n\n" ..
                       "|cffffd100Note:|r Icon positions use internal cooldownIDs which are spec-specific.\n" ..
                       "Importing positions from a different spec may not work correctly.",
                fontSize = "medium",
                order = 81,
                hidden = function() return collapsedSections.externalExport end,
            },
        },
    }
    
    return options
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EXPORT FUNCTION FOR OPTIONS INTEGRATION
-- ═══════════════════════════════════════════════════════════════════════════

-- This is called by ArcUI_Options.lua to get the options table
function ns.GetCDMImportExportOptionsTable()
    return GetOptionsTable()
end

-- Expose for unified import window
IE.SpecKeyToDisplayName = SpecKeyToDisplayName

-- Profile Manager only (Arc Manager Profiles section) — for Icons > Profiles tab
function ns.GetCDMProfileManagerOnlyOptionsTable()
    local PROFILE_KEYS = {
        "arcProfilesToggle", "arcProfilesDesc", "arcProfileSelect",
        "arcProfileNewBtn", "arcProfileDeleteBtn", "arcProfileSaveBtn",
        "arcProfileTalentConditionsBtn", "arcProfileTalentConditionsSummary",
        "arcProfileRenameBtn", "arcProfileResetDefaultBtn", "arcProfileGroupLayoutLinked",
    }
    local full = GetOptionsTable()
    local args = {}
    for _, k in ipairs(PROFILE_KEYS) do
        if full.args[k] then
            args[k] = full.args[k]
        end
    end
    return {
        type = "group",
        name = "Arc Manager Profiles",
        args = args,
    }
end

-- Export only (no import section, no collapsible wrapper) — for Import/Export > CDM Export tab
function ns.GetCDMExportOnlyOptionsTable()
    local EXPORT_KEYS = {
        "externalExportToggle", "externalExportDesc",
        "statsToggle", "statsInfo",
        "exportHeader", "exportOptionsToggle",
        "exportGroupLayouts", "exportPositions", "exportIconSettings",
        "exportGlobalSettings", "exportGroupSettings", "exportProfiles",
        "exportSpacer", "exportButton", "exportString",
    }
    local full = GetOptionsTable()
    local args = {}
    for _, k in ipairs(EXPORT_KEYS) do
        if full.args[k] then
            args[k] = full.args[k]
        end
    end

    -- Drop the collapsible toggles — it's its own tab now
    args["externalExportToggle"] = nil
    args["externalExportDesc"] = nil
    args["statsToggle"] = nil

    -- Patch hidden functions: remove externalExport + statsOverview guards, keep exportOptions guard
    for _, entry in pairs(args) do
        local orig = entry.hidden
        if orig then
            entry.hidden = function()
                local savedExt = collapsedSections.externalExport
                local savedStats = collapsedSections.statsOverview
                collapsedSections.externalExport = false
                collapsedSections.statsOverview = false
                local result = orig()
                collapsedSections.externalExport = savedExt
                collapsedSections.statsOverview = savedStats
                return result
            end
        end
    end

    return {
        type = "group",
        name = "Icon Manager Export",
        args = args,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RELOAD CONFIRMATION POPUP
-- ═══════════════════════════════════════════════════════════════════════════

StaticPopupDialogs["ARCUI_RELOAD_AFTER_IMPORT"] = {
    text = "|cff00ccffArcUI|r CDM settings imported.\n\nReload UI to apply all changes?",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCUICDMEXPORT1 = "/arccdmexport"
SLASH_ARCUICDMEXPORT2 = "/cdmexport"
SlashCmdList["ARCUICDMEXPORT"] = function()
    -- Open options to Import/Export tab
    if ns.API and ns.API.OpenOptions then
        ns.API.OpenOptions()
        -- Navigate to the import/export panel
        C_Timer.After(0.1, function()
            local ACD = LibStub("AceConfigDialog-3.0", true)
            if ACD then
                ACD:SelectGroup("ArcUI", "icons", "profileManager")
            end
        end)
    else
        PrintMsg("Options not available yet.")
    end
end

SLASH_ARCUICDMIMPORT1 = "/arccdmimport"
SLASH_ARCUICDMIMPORT2 = "/cdmimport"
SlashCmdList["ARCUICDMIMPORT"] = function()
    -- Same as export, opens options to Import/Export tab
    if ns.API and ns.API.OpenOptions then
        ns.API.OpenOptions()
        C_Timer.After(0.1, function()
            local ACD = LibStub("AceConfigDialog-3.0", true)
            if ACD then
                ACD:SelectGroup("ArcUI", "icons", "profileManager")
            end
        end)
    else
        PrintMsg("Options not available yet.")
    end
end

-- Debug command to dump raw export data
SLASH_ARCUICDMDEBUGEXPORT1 = "/cdmdebug"
SlashCmdList["ARCUICDMDEBUGEXPORT"] = function(msg)
    local Shared = GetShared()
    PrintMsg("=== CDM Export Debug ===")
    
    if not Shared then
        PrintMsg("|cffff0000ERROR: CDMShared not available!|r")
        return
    end
    
    -- Get current spec data
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    PrintMsg("Current spec: " .. tostring(currentSpec))
    
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    if not cdmGroupsDB then
        PrintMsg("|cffff0000CDMGroups DB not available|r")
        return
    end
    
    PrintMsg("char.cdmGroups exists: " .. tostring(cdmGroupsDB ~= nil))
    PrintMsg("specData exists: " .. tostring(cdmGroupsDB.specData ~= nil))
    
    if currentSpec and cdmGroupsDB.specData and cdmGroupsDB.specData[currentSpec] then
        local specData = cdmGroupsDB.specData[currentSpec]
        PrintMsg("specData[" .. currentSpec .. "] contents:")
        
        local groupCount = 0
        if specData.groups then
            for _ in pairs(specData.groups) do groupCount = groupCount + 1 end
        end
        PrintMsg("  groups: " .. groupCount)
        
        local posCount = 0
        if specData.savedPositions then
            for _ in pairs(specData.savedPositions) do posCount = posCount + 1 end
        end
        PrintMsg("  savedPositions: " .. posCount)
        
        local freeCount = 0
        if specData.freeIcons then
            for _ in pairs(specData.freeIcons) do freeCount = freeCount + 1 end
        end
        PrintMsg("  freeIcons: " .. freeCount)
        
        local iconCount = 0
        if specData.iconSettings then
            for _ in pairs(specData.iconSettings) do iconCount = iconCount + 1 end
        end
        PrintMsg("  iconSettings: " .. iconCount)
        
        PrintMsg("  groupSettings exists: " .. tostring(specData.groupSettings ~= nil))
        
        -- Show first few iconSettings keys
        if specData.iconSettings and iconCount > 0 then
            local count = 0
            PrintMsg("  First 5 iconSettings keys:")
            for k, _ in pairs(specData.iconSettings) do
                count = count + 1
                if count <= 5 then
                    PrintMsg("    - " .. tostring(k))
                end
            end
        end
    else
        PrintMsg("|cffff0000specData[" .. tostring(currentSpec) .. "] is nil!|r")
    end
    
    -- Test actual export
    PrintMsg("")
    PrintMsg("Testing BuildExportData()...")
    local exportData = BuildExportData({})
    if exportData and exportData.cdmGroups then
        local iconCount = 0
        if exportData.cdmGroups.iconSettings then
            for _ in pairs(exportData.cdmGroups.iconSettings) do iconCount = iconCount + 1 end
        end
        PrintMsg("Export would include " .. iconCount .. " iconSettings")
    else
        PrintMsg("|cffff0000Export data or cdmGroups is nil!|r")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- END OF MODULE
-- ═══════════════════════════════════════════════════════════════════════════