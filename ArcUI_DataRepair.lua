-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Data Repair & Cleanup Module
-- Removes bloated empty bar configs from SavedVariables
-- Fixes CDM profile corruption
-- v3.1: SavedVariables compaction (strip/restore defaults on logout/login)
--       Ghost bar cleanup (enabled but no tracking data)
--
-- COMPACTION OVERVIEW:
--   Every bar config stores a full CopyTable() of 100+ display defaults,
--   even though users only customize a few values. With 22 characters
--   averaging 10+ bars each, this bloats the SV file from ~500 KB to 4+ MB
--   and wastes 15-25 MB of Lua memory at load time.
--
--   On PLAYER_LOGOUT: Strip display/behavior values matching defaults
--   On PLAYER_LOGIN:  Restore them from defaults before any rendering
--
--   SAFE BECAUSE:
--     - Restore runs in RunAutoCleanup() before Display.Init()
--     - All rendering code uses "or" fallbacks as secondary safety net
--     - Position/color tables only stripped if ENTIRE table matches defaults
--     - tracking, thresholds, stackColors, colorRanges, events untouched
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON_NAME, ns = ...

ns.DataRepair = ns.DataRepair or {}
local DR = ns.DataRepair

local MSG_PREFIX = "|cff00ccffArcUI|r |cffffaa00[DataRepair]|r: "

local function PrintMsg(msg)
    print(MSG_PREFIX .. msg)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPER: Check if a bar entry is an empty/unconfigured default
-- Returns true if the bar has no real tracking config (safe to remove)
-- ═══════════════════════════════════════════════════════════════════════════
local function IsEmptyBar(bar)
    if not bar or not bar.tracking then return true end
    
    -- Check if bar has any REAL tracking data configured
    local hasSpell = bar.tracking.spellID and bar.tracking.spellID > 0
    local hasBuff = bar.tracking.buffName and bar.tracking.buffName ~= "" 
                    and bar.tracking.buffName ~= "(Not configured yet)"
    local hasCooldown = bar.tracking.cooldownID and bar.tracking.cooldownID > 0
    local hasCustom = bar.tracking.customEnabled and bar.tracking.customSpellID 
                      and bar.tracking.customSpellID > 0
    local hasAnyTracking = hasSpell or hasBuff or hasCooldown or hasCustom
    
    -- A bar is empty if:
    --   1) tracking is disabled AND has no real config (safe to remove)
    --   2) tracking is enabled but has NO tracking data at all (ghost bar)
    if not hasAnyTracking then
        return true
    end
    
    return false
end

local function IsEmptyResourceBar(bar)
    if not bar or not bar.tracking then return true end
    if bar.tracking.enabled then return false end
    
    -- Resource bar is empty if no power type is configured
    local hasPower = bar.tracking.powerType and bar.tracking.powerType > 0
    local hasPowerName = bar.tracking.powerName and bar.tracking.powerName ~= ""
    local hasSecondary = bar.tracking.secondaryType and bar.tracking.secondaryType ~= ""
    
    return not hasPower and not hasPowerName and not hasSecondary
end

local function IsEmptyCooldownBar(bar)
    if not bar or not bar.tracking then return true end
    if bar.tracking.enabled then return false end
    
    return true  -- Legacy cooldownBars: if not enabled, it's unused
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLEANUP: Remove empty/unconfigured bars for current character
-- Old versions pre-created 20-30 empty bar slots per character.
-- All bar iteration uses pairs() so sparse arrays are safe.
-- GetBarConfig() auto-creates from defaults if accessed later.
-- InitializeNewCooldownBar() loops for i=1,500 checking nil → reuses slots.
-- ═══════════════════════════════════════════════════════════════════════════
local function CleanEmptyBars()
    if not ns.db or not ns.db.char or not ns.db.char.bars then
        return 0
    end
    
    local bars = ns.db.char.bars
    local removed = 0
    
    for i, bar in pairs(bars) do
        if type(i) == "number" and IsEmptyBar(bar) then
            bars[i] = nil
            removed = removed + 1
        end
    end
    
    return removed
end

local function CleanEmptyResourceBars()
    if not ns.db or not ns.db.char or not ns.db.char.resourceBars then
        return 0
    end
    
    local resourceBars = ns.db.char.resourceBars
    local removed = 0
    
    for i, bar in pairs(resourceBars) do
        if type(i) == "number" and IsEmptyResourceBar(bar) then
            resourceBars[i] = nil
            removed = removed + 1
        end
    end
    
    return removed
end

local function CleanEmptyCooldownBars()
    if not ns.db or not ns.db.char or not ns.db.char.cooldownBars then
        return 0
    end
    
    local cooldownBars = ns.db.char.cooldownBars
    local removed = 0
    
    for i, bar in pairs(cooldownBars) do
        if type(i) == "number" and IsEmptyCooldownBar(bar) then
            cooldownBars[i] = nil
            removed = removed + 1
        end
    end
    
    return removed
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REPAIR: Fix Missing CDM Profile
-- ═══════════════════════════════════════════════════════════════════════════
local function FixMissingActiveProfile(silent)
    if not ns.db or not ns.db.char or not ns.db.char.cdmGroups then
        return 0
    end
    
    local cdmGroups = ns.db.char.cdmGroups
    if not cdmGroups.specData then return 0 end
    
    local fixed = 0
    
    for specKey, specData in pairs(cdmGroups.specData) do
        if type(specData) == "table" and specData.layoutProfiles and specData.activeProfile then
            local activeProfile = specData.activeProfile
            if not specData.layoutProfiles[activeProfile] then
                if not silent then
                    PrintMsg("Profile '" .. activeProfile .. "' missing for " .. specKey)
                end
                
                if specData.layoutProfiles["Default"] then
                    specData.activeProfile = "Default"
                    if not silent then PrintMsg("Reset to 'Default' profile") end
                else
                    specData.layoutProfiles["Default"] = {
                        savedPositions = {},
                        freeIcons = {},
                        groupLayouts = {},
                        iconSettings = {},
                    }
                    specData.activeProfile = "Default"
                    if not silent then PrintMsg("Created new 'Default' profile") end
                end
                fixed = fixed + 1
            end
        end
    end
    
    return fixed
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SAVEDVARIABLES COMPACTION SYSTEM (v3.0)
-- ═══════════════════════════════════════════════════════════════════════════

-- Deep equality test for tables (used for atomic color/position comparison)
local function DeepEqual(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    
    local aLen, bLen = 0, 0
    for _ in pairs(a) do aLen = aLen + 1 end
    for _ in pairs(b) do bLen = bLen + 1 end
    if aLen ~= bLen then return false end
    
    for k, v in pairs(a) do
        if not DeepEqual(v, b[k]) then return false end
    end
    return true
end

-- Keys that are safe to recurse into (structural containers)
-- Everything else (colors, positions, etc.) is compared atomically
local SECTION_KEYS = {
    display = true,
    behavior = true,
}

-- Keys that must NEVER be stripped (identity/state fields)
local PRESERVE_KEYS = {
    enabled = true,
    _migrated = true,
    trackType = true,
    spellID = true,
    cooldownID = true,
    buffName = true,
    powerType = true,
    powerName = true,
    resourceCategory = true,
    secondaryType = true,
    selectedBar = true,
    selectedResourceBar = true,
    selectedCooldownBar = true,
    configVersion = true,
    showOnSpecs = true,
    showOnSpec = true,
    barType = true,
    barMode = true,
    timerID = true,
    triggerSpellID = true,
    triggerCooldownID = true,
    barName = true,
    preset = true,
    -- Position tables are NEVER stripped individually; they're compared
    -- atomically. But list the key names here so they aren't stripped
    -- even if they happen to match defaults (user's bar position matters).
    barPosition = true,
    textPosition = true,
    durationPosition = true,
    namePosition = true,
    barIconPosition = true,
    iconPosition = true,
    iconStackPosition = true,
    iconMultiPositions = true,
    -- Timer/cooldown bar FREE-mode text positions
    chargeTextPosition = true,
    timerTextPosition = true,
    nameTextPosition = true,
    -- Locked offsets (user-set)
    nameTextLockedOffset = true,
    durationTextLockedOffset = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- STRIP: Remove values matching defaults from a saved table
-- Only recurses into SECTION_KEYS (display, behavior).
-- All other table values (colors, etc.) are compared atomically.
-- Returns count of removed entries.
-- ═══════════════════════════════════════════════════════════════════════════
local function StripDefaults(saved, defaults, depth)
    if type(saved) ~= "table" or type(defaults) ~= "table" then return 0 end
    depth = depth or 0
    if depth > 6 then return 0 end
    
    local removed = 0
    
    for key, defaultVal in pairs(defaults) do
        if PRESERVE_KEYS[key] then
            -- Never strip these
        else
            local savedVal = saved[key]
            if savedVal ~= nil then
                if type(defaultVal) == "table" then
                    if type(savedVal) == "table" then
                        if SECTION_KEYS[key] then
                            -- Recurse into structural sections
                            removed = removed + StripDefaults(savedVal, defaultVal, depth + 1)
                            -- Remove empty section tables
                            if next(savedVal) == nil then
                                saved[key] = nil
                                removed = removed + 1
                            end
                        else
                            -- Atomic table comparison (colors, positions, etc.)
                            -- Only strip if the ENTIRE table matches
                            if DeepEqual(savedVal, defaultVal) then
                                saved[key] = nil
                                removed = removed + 1
                            end
                        end
                    end
                    -- If savedVal is not a table but default is, leave it alone
                else
                    -- Scalar comparison (number, string, boolean)
                    if savedVal == defaultVal then
                        saved[key] = nil
                        removed = removed + 1
                    end
                end
            end
        end
    end
    
    return removed
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FILL: Restore nil values from defaults (reverse of StripDefaults)
-- Only recurses into SECTION_KEYS. Restores missing table values as copies.
-- ═══════════════════════════════════════════════════════════════════════════
local function FillDefaults(saved, defaults, depth)
    if type(saved) ~= "table" or type(defaults) ~= "table" then return 0 end
    depth = depth or 0
    if depth > 6 then return 0 end
    
    local filled = 0
    
    for key, defaultVal in pairs(defaults) do
        if saved[key] == nil then
            -- Value is missing - restore from defaults
            if type(defaultVal) == "table" then
                saved[key] = CopyTable(defaultVal)
            else
                saved[key] = defaultVal
            end
            filled = filled + 1
        elseif type(defaultVal) == "table" and type(saved[key]) == "table" and SECTION_KEYS[key] then
            -- Recurse into structural sections to fill nested missing keys
            filled = filled + FillDefaults(saved[key], defaultVal, depth + 1)
        end
    end
    
    return filled
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GET DEFAULT TEMPLATES for each bar type
-- ═══════════════════════════════════════════════════════════════════════════
local function GetBarDefaults()
    return ns.DB_DEFAULTS and ns.DB_DEFAULTS.char and ns.DB_DEFAULTS.char.bars and ns.DB_DEFAULTS.char.bars[1]
end

local function GetResourceBarDefaults()
    return ns.DB_DEFAULTS and ns.DB_DEFAULTS.char and ns.DB_DEFAULTS.char.resourceBars and ns.DB_DEFAULTS.char.resourceBars[1]
end

local function GetLegacyCooldownBarDefaults()
    return ns.DB_DEFAULTS and ns.DB_DEFAULTS.char and ns.DB_DEFAULTS.char.cooldownBars and ns.DB_DEFAULTS.char.cooldownBars[1]
end

local function GetCooldownBarDisplayDefaults()
    -- Exposed by ArcUI_CooldownBars.lua (loads before DataRepair)
    return ns.CooldownBars and ns.CooldownBars.DISPLAY_DEFAULTS
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COMPACT: Strip defaults + remove ghost bars from a character's configs
-- Works on any character data table (current or other characters)
-- ═══════════════════════════════════════════════════════════════════════════
local function CompactCharacterBars(charData)
    if not charData then return 0 end
    local totalStripped = 0
    
    -- 0) Remove ghost/empty bars from ALL bar arrays
    --    (Same logic as CleanEmptyBars but works on raw charData, not ns.db)
    if charData.bars then
        for i, bar in pairs(charData.bars) do
            if type(i) == "number" and IsEmptyBar(bar) then
                charData.bars[i] = nil
                totalStripped = totalStripped + 1
            end
        end
    end
    if charData.resourceBars then
        for i, bar in pairs(charData.resourceBars) do
            if type(i) == "number" and IsEmptyResourceBar(bar) then
                charData.resourceBars[i] = nil
                totalStripped = totalStripped + 1
            end
        end
    end
    if charData.cooldownBars then
        for i, bar in pairs(charData.cooldownBars) do
            if type(i) == "number" and IsEmptyCooldownBar(bar) then
                charData.cooldownBars[i] = nil
                totalStripped = totalStripped + 1
            end
        end
    end
    
    -- 1) Buff/Debuff bars (bars[i])
    local barDefaults = GetBarDefaults()
    if barDefaults and charData.bars then
        for i, bar in pairs(charData.bars) do
            if type(i) == "number" and type(bar) == "table" then
                totalStripped = totalStripped + StripDefaults(bar, barDefaults)
            end
        end
    end
    
    -- 2) Resource bars (resourceBars[i])
    local resourceDefaults = GetResourceBarDefaults()
    if resourceDefaults and charData.resourceBars then
        for i, bar in pairs(charData.resourceBars) do
            if type(i) == "number" and type(bar) == "table" then
                totalStripped = totalStripped + StripDefaults(bar, resourceDefaults)
            end
        end
    end
    
    -- 3) Legacy cooldown bars (cooldownBars[i])
    local legacyDefaults = GetLegacyCooldownBarDefaults()
    if legacyDefaults and charData.cooldownBars then
        for i, bar in pairs(charData.cooldownBars) do
            if type(i) == "number" and type(bar) == "table" then
                totalStripped = totalStripped + StripDefaults(bar, legacyDefaults)
            end
        end
    end
    
    -- 4) CooldownBar configs (cooldownBarConfigs[spellID][barType])
    local displayDefaults = GetCooldownBarDisplayDefaults()
    if displayDefaults and charData.cooldownBarConfigs then
        -- Build a reference config matching the stored structure
        local cdBarRef = { display = displayDefaults }
        for spellID, barTypes in pairs(charData.cooldownBarConfigs) do
            if type(barTypes) == "table" then
                for barType, cfg in pairs(barTypes) do
                    if type(cfg) == "table" and cfg.display then
                        totalStripped = totalStripped + StripDefaults(cfg, cdBarRef)
                    end
                end
            end
        end
    end
    
    -- 5) Timer bar configs (timerBarConfigs[timerID])
    if displayDefaults and charData.timerBarConfigs then
        local timerRef = { display = displayDefaults }
        for timerID, cfg in pairs(charData.timerBarConfigs) do
            if type(cfg) == "table" and cfg.display then
                totalStripped = totalStripped + StripDefaults(cfg, timerRef)
            end
        end
    end
    
    return totalStripped
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESTORE: Fill defaults for current character's bar configs
-- Must run BEFORE any rendering code (called from RunAutoCleanup)
-- ═══════════════════════════════════════════════════════════════════════════
local function RestoreCurrentCharDefaults()
    if not ns.db or not ns.db.char then return 0 end
    local charData = ns.db.char
    local totalFilled = 0
    
    -- 1) Buff/Debuff bars
    local barDefaults = GetBarDefaults()
    if barDefaults and charData.bars then
        for i, bar in pairs(charData.bars) do
            if type(i) == "number" and type(bar) == "table" then
                totalFilled = totalFilled + FillDefaults(bar, barDefaults)
            end
        end
    end
    
    -- 2) Resource bars
    local resourceDefaults = GetResourceBarDefaults()
    if resourceDefaults and charData.resourceBars then
        for i, bar in pairs(charData.resourceBars) do
            if type(i) == "number" and type(bar) == "table" then
                totalFilled = totalFilled + FillDefaults(bar, resourceDefaults)
            end
        end
    end
    
    -- 3) Legacy cooldown bars
    local legacyDefaults = GetLegacyCooldownBarDefaults()
    if legacyDefaults and charData.cooldownBars then
        for i, bar in pairs(charData.cooldownBars) do
            if type(i) == "number" and type(bar) == "table" then
                totalFilled = totalFilled + FillDefaults(bar, legacyDefaults)
            end
        end
    end
    
    -- 4) CooldownBar configs
    local displayDefaults = GetCooldownBarDisplayDefaults()
    if displayDefaults and charData.cooldownBarConfigs then
        local cdBarRef = { display = displayDefaults }
        for spellID, barTypes in pairs(charData.cooldownBarConfigs) do
            if type(barTypes) == "table" then
                for barType, cfg in pairs(barTypes) do
                    if type(cfg) == "table" then
                        totalFilled = totalFilled + FillDefaults(cfg, cdBarRef)
                    end
                end
            end
        end
    end
    
    -- 5) Timer bar configs
    if displayDefaults and charData.timerBarConfigs then
        local timerRef = { display = displayDefaults }
        for timerID, cfg in pairs(charData.timerBarConfigs) do
            if type(cfg) == "table" then
                totalFilled = totalFilled + FillDefaults(cfg, timerRef)
            end
        end
    end
    
    return totalFilled
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDMGROUPS DEAD-WEIGHT CLEANUP
-- Strips migration flags, empty containers, and legacy duplicate fields
-- that were left behind by one-time migrations and early addon versions.
--
-- SAFE BECAUSE:
--   - Migration flags are boolean gates already passed on first login
--   - Empty containers are recreated on-demand by EnsureSpecData/GetSpecData
--   - Legacy spec-level fields are only stripped when the profile already
--     has the migrated data (migration ran successfully)
--   - Runs on ALL characters during PLAYER_LOGOUT (same as bar compaction)
-- ═══════════════════════════════════════════════════════════════════════════
local function CompactCDMGroupsData(charData)
    if not charData then return 0 end
    local stripped = 0
    
    -- 1) Empty importRestore table (pre-created but never populated for most chars)
    if charData.importRestore and type(charData.importRestore) == "table" and not next(charData.importRestore) then
        charData.importRestore = nil
        stripped = stripped + 1
    end
    
    local cdmGroups = charData.cdmGroups
    if not cdmGroups or type(cdmGroups) ~= "table" then return stripped end
    
    -- 2) Top-level migration flags on cdmGroups (checked once, never again)
    if cdmGroups.migratedFromProfile ~= nil then
        cdmGroups.migratedFromProfile = nil
        stripped = stripped + 1
    end
    if cdmGroups.migratedOldKeys and type(cdmGroups.migratedOldKeys) == "table" then
        cdmGroups.migratedOldKeys = nil
        stripped = stripped + 1
    end
    
    -- 3) Per-spec cleanup inside specData
    if not cdmGroups.specData or type(cdmGroups.specData) ~= "table" then return stripped end
    
    for specKey, specData in pairs(cdmGroups.specData) do
        if type(specData) == "table" then
            -- 3a) Migration flags (boolean gates, already passed)
            if specData.initialized ~= nil then
                specData.initialized = nil
                stripped = stripped + 1
            end
            if specData.migratedFromCDMEnhance ~= nil then
                specData.migratedFromCDMEnhance = nil
                stripped = stripped + 1
            end
            
            -- 3b) Empty groupSettings sub-tables
            --     Only strip sub-tables that are truly empty {}
            --     Leave sub-tables with actual data (e.g. keybinds with fontSize)
            if specData.groupSettings and type(specData.groupSettings) == "table" then
                local allEmpty = true
                for subKey, subTable in pairs(specData.groupSettings) do
                    if type(subTable) == "table" and not next(subTable) then
                        specData.groupSettings[subKey] = nil
                        stripped = stripped + 1
                    else
                        allEmpty = false
                    end
                end
                -- Remove parent if all children were empty
                if allEmpty and not next(specData.groupSettings) then
                    specData.groupSettings = nil
                    stripped = stripped + 1
                end
            end
            
            -- 3c) Legacy spec-level fields that have been migrated to layoutProfiles
            --     ONLY strip if the active profile already has the migrated data
            if specData.layoutProfiles and type(specData.layoutProfiles) == "table" then
                local activeProfile = specData.activeProfile or "Default"
                local profile = specData.layoutProfiles[activeProfile]
                
                if profile and type(profile) == "table" then
                    -- Legacy savedPositions → profile.savedPositions
                    if specData.savedPositions and type(specData.savedPositions) == "table" then
                        if profile.savedPositions and next(profile.savedPositions) then
                            -- Profile has data = migration ran successfully
                            specData.savedPositions = nil
                            stripped = stripped + 1
                        elseif not next(specData.savedPositions) then
                            -- Legacy is empty anyway, safe to remove
                            specData.savedPositions = nil
                            stripped = stripped + 1
                        end
                    end
                    
                    -- Legacy freeIcons → profile.freeIcons
                    if specData.freeIcons and type(specData.freeIcons) == "table" then
                        if profile.freeIcons and next(profile.freeIcons) then
                            specData.freeIcons = nil
                            stripped = stripped + 1
                        elseif not next(specData.freeIcons) then
                            specData.freeIcons = nil
                            stripped = stripped + 1
                        end
                    end
                    
                    -- Legacy groups → profile.groupLayouts
                    if specData.groups and type(specData.groups) == "table" then
                        if profile.groupLayouts and next(profile.groupLayouts) then
                            specData.groups = nil
                            stripped = stripped + 1
                        elseif not next(specData.groups) then
                            specData.groups = nil
                            stripped = stripped + 1
                        end
                    end
                    
                    -- Legacy spec-level iconSettings (code already nils this after migration,
                    -- but catch any stragglers from older versions)
                    if specData.iconSettings and type(specData.iconSettings) == "table" then
                        if profile.iconSettings and next(profile.iconSettings) then
                            specData.iconSettings = nil
                            stripped = stripped + 1
                        elseif not next(specData.iconSettings) then
                            specData.iconSettings = nil
                            stripped = stripped + 1
                        end
                    end
                end
            end
        end
    end
    
    return stripped
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COMPACT ALL CHARACTERS on logout
-- Walks the raw ArcUIDB.char table to strip ALL characters, not just current
-- ═══════════════════════════════════════════════════════════════════════════
local function CompactAllCharacters()
    local svTable = _G.ArcUIDB
    if not svTable or not svTable.char then return 0 end
    
    local totalStripped = 0
    local charCount = 0
    
    for charKey, charData in pairs(svTable.char) do
        if type(charData) == "table" then
            local stripped = CompactCharacterBars(charData)
            stripped = stripped + CompactCDMGroupsData(charData)
            totalStripped = totalStripped + stripped
            if stripped > 0 then
                charCount = charCount + 1
            end
        end
    end
    
    return totalStripped, charCount
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PURGE: Remove SavedVariables data for characters you no longer play
-- Usage: /arcrepair purge CharName - RealmName
-- ═══════════════════════════════════════════════════════════════════════════
function DR.PurgeCharacter(charKey)
    local svTable = _G.ArcUIDB
    if not svTable then
        PrintMsg("|cffff0000ArcUIDB not found|r")
        return false
    end
    
    -- Check char scope
    if svTable.char and svTable.char[charKey] then
        svTable.char[charKey] = nil
        PrintMsg("Purged char data for: " .. charKey)
    else
        PrintMsg("No char data found for: " .. charKey)
        return false
    end
    
    -- Check profileKeys (AceDB profile assignment)
    if svTable.profileKeys and svTable.profileKeys[charKey] then
        svTable.profileKeys[charKey] = nil
    end
    
    PrintMsg("|cff00ff00Successfully purged " .. charKey .. "|r - /reload to finalize")
    return true
end

function DR.ListCharacters()
    local svTable = _G.ArcUIDB
    if not svTable or not svTable.char then
        PrintMsg("No character data found")
        return
    end
    
    PrintMsg("Stored characters:")
    local currentChar = UnitName("player") .. " - " .. GetRealmName()
    
    for charKey, charData in pairs(svTable.char) do
        if type(charData) == "table" then
            -- Rough estimate of data size
            local entryCount = 0
            for _ in pairs(charData) do entryCount = entryCount + 1 end
            
            local marker = (charKey == currentChar) and " |cff00ff00(current)|r" or ""
            PrintMsg("  " .. charKey .. marker .. " (" .. entryCount .. " top-level entries)")
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO CLEANUP: Called from Options.lua after DB init
-- Runs every login — scan is fast (just iterates existing entries)
-- v3.0: Also restores compacted defaults before rendering
-- ═══════════════════════════════════════════════════════════════════════════
function DR.RunAutoCleanup()
    local totalRemoved = 0
    
    -- First: restore compacted defaults for current character
    -- This MUST happen before any rendering code reads config values
    local filled = RestoreCurrentCharDefaults()
    
    -- Then: clean empty/unconfigured entries
    local bars = CleanEmptyBars()
    local resources = CleanEmptyResourceBars()
    local cooldowns = CleanEmptyCooldownBars()
    local profiles = FixMissingActiveProfile(true)  -- silent on auto cleanup
    
    -- CDMGroups dead-weight cleanup (migration flags, empty containers, legacy dupes)
    local cdmCleaned = 0
    if ns.db and ns.db.char then
        cdmCleaned = CompactCDMGroupsData(ns.db.char)
    end
    
    totalRemoved = bars + resources + cooldowns + profiles + cdmCleaned
    
    return totalRemoved
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EMERGENCY REPAIR
-- ═══════════════════════════════════════════════════════════════════════════
function DR.EmergencyRepair()
    PrintMsg("Running emergency repair...")
    
    local repairCount = DR.RunAutoCleanup()
    
    -- Create current spec data if missing
    if ns.db and ns.db.char and ns.db.char.cdmGroups then
        local cdmGroups = ns.db.char.cdmGroups
        
        if not cdmGroups.specData then
            cdmGroups.specData = {}
            PrintMsg("Created missing specData table")
            repairCount = repairCount + 1
        end
        
        local specIdx = GetSpecialization() or 1
        local _, _, classID = UnitClass("player")
        classID = classID or 0
        local currentSpec = "class_" .. classID .. "_spec_" .. specIdx
        
        if not cdmGroups.specData[currentSpec] then
            cdmGroups.specData[currentSpec] = {
                iconSettings = {},
                layoutProfiles = {
                    ["Default"] = {
                        savedPositions = {},
                        freeIcons = {},
                        groupLayouts = {},
                        iconSettings = {},
                    },
                },
                activeProfile = "Default",
                groupSettings = {},
            }
            PrintMsg("Created specData for " .. currentSpec)
            repairCount = repairCount + 1
        end
    end
    
    if repairCount > 0 then
        PrintMsg("|cff00ff00Emergency repair: " .. repairCount .. " fixes|r")
        PrintMsg("Please /reload to apply changes")
    else
        PrintMsg("No repairs needed - data looks healthy!")
    end
    
    return repairCount
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════
SLASH_ARCUIREPAIR1 = "/arcuirepair"
SLASH_ARCUIREPAIR2 = "/arcrepair"
SlashCmdList["ARCUIREPAIR"] = function(msg)
    local cmd, arg = msg:match("^(%S*)%s*(.*)$")
    cmd = (cmd or ""):lower()
    
    if cmd == "emergency" then
        DR.EmergencyRepair()
    elseif cmd == "groupdump" then
        -- Dump live group layout values for debugging
        if ns.CDMGroups and ns.CDMGroups.groups then
            for name, g in pairs(ns.CDMGroups.groups) do
                PrintMsg(string.format("[%s] iconSize=%s iconWidth=%s spacing=%s containerPadding=%s cols=%s rows=%s",
                    name,
                    tostring(g.layout and g.layout.iconSize),
                    tostring(g.layout and g.layout.iconWidth),
                    tostring(g.layout and g.layout.spacing),
                    tostring(g.containerPadding),
                    tostring(g.layout and g.layout.gridCols),
                    tostring(g.layout and g.layout.gridRows)
                ))
                -- Also check member frame sizes
                local count = 0
                for cdID, member in pairs(g.members or {}) do
                    if member.frame and count < 2 then
                        local fw, fh = member.frame:GetSize()
                        PrintMsg(string.format("  frame[%s] size=%.1fx%.1f _cdmgSlotW=%s _cdmgTargetSize=%s",
                            tostring(cdID), fw, fh,
                            tostring(member.frame._cdmgSlotW),
                            tostring(member.frame._cdmgTargetSize)
                        ))
                        count = count + 1
                    end
                end
            end
        else
            PrintMsg("No CDMGroups groups found")
        end
    elseif cmd == "cdmclean" then
        -- Manual CDMGroups cleanup (preview what logout will strip)
        local svTable = _G.ArcUIDB
        if svTable and svTable.char then
            local totalStripped = 0
            local charCount = 0
            for charKey, charData in pairs(svTable.char) do
                if type(charData) == "table" then
                    local stripped = CompactCDMGroupsData(charData)
                    totalStripped = totalStripped + stripped
                    if stripped > 0 then
                        charCount = charCount + 1
                        PrintMsg("  " .. charKey .. ": " .. stripped .. " dead-weight entries removed")
                    end
                end
            end
            if totalStripped > 0 then
                PrintMsg("|cff00ff00Cleaned " .. totalStripped .. " entries across " .. charCount .. " character(s)|r")
                PrintMsg("Migration flags, empty containers, and legacy duplicates removed.")
            else
                PrintMsg("CDMGroups data is already clean!")
            end
        else
            PrintMsg("No character data found")
        end
    elseif cmd == "compact" then
        -- Manual compaction (preview what logout will do)
        local stripped, chars = CompactAllCharacters()
        if stripped > 0 then
            PrintMsg("|cff00ff00Compacted " .. stripped .. " default values across " .. chars .. " character(s)|r")
            PrintMsg("These will be restored on next login. /reload to see memory savings.")
        else
            PrintMsg("Already compact - no defaults to strip")
        end
    elseif cmd == "restore" then
        -- Manual restore (undo compaction for current char)
        local filled = RestoreCurrentCharDefaults()
        PrintMsg("Restored " .. filled .. " values for current character")
    elseif cmd == "purge" then
        if arg and arg ~= "" then
            DR.PurgeCharacter(arg)
        else
            PrintMsg("Usage: /arcrepair purge CharName - RealmName")
            PrintMsg("Use /arcrepair list to see stored characters")
        end
    elseif cmd == "list" then
        DR.ListCharacters()
    else
        local count = DR.RunAutoCleanup()
        if count == 0 then
            PrintMsg("No repairs needed - data looks healthy!")
        else
            PrintMsg("|cff00ff00Completed " .. count .. " repairs|r")
        end
        PrintMsg("Commands: compact, cdmclean, restore, purge, list, emergency")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PLAYER_LOGOUT: Compact SavedVariables before WoW writes them to disk
-- This strips default values from ALL characters' bar configs
-- ═══════════════════════════════════════════════════════════════════════════
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function(self, event)
    local stripped = CompactAllCharacters()
    -- No print - player is logging out, they won't see it
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO-INIT: Run cleanup + deferred border reapply on login
-- Pixel-snapped borders need a deferred reapply after the layout engine
-- finalizes frame positions, otherwise borders can misalign with fills.
-- ═══════════════════════════════════════════════════════════════════════════
local repairInitFrame = CreateFrame("Frame")
repairInitFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
repairInitFrame:SetScript("OnEvent", function(self, event)
    self:UnregisterAllEvents()

    C_Timer.After(0, function()
        if not ns.db then return end
        DR.RunAutoCleanup()

        -- Deferred reapply with layout nudge so pixel-snapped borders align
        C_Timer.After(0.5, function()
            if ns.Resources and ns.Resources.ApplyAllBars then
                ns.Resources.ApplyAllBars(true)
            end
            if ns.Display and ns.Display.ApplyAllBars then
                ns.Display.ApplyAllBars(true)
            end
            if ns.CooldownBars and ns.CooldownBars.ReapplyAllAppearance then
                ns.CooldownBars.ReapplyAllAppearance()
            end
        end)
    end)
end)

-- Export
ns.DataRepair = DR