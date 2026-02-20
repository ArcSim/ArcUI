-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Data Repair & Cleanup Module
-- Removes bloated empty bar configs from SavedVariables
-- Fixes CDM profile corruption
-- Version: 2.0
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
    
    -- A bar is empty if tracking is disabled AND no spell/buff/cooldown is configured
    -- This protects bars that are temporarily disabled but have real config
    if bar.tracking.enabled then return false end
    
    local hasSpell = bar.tracking.spellID and bar.tracking.spellID > 0
    local hasBuff = bar.tracking.buffName and bar.tracking.buffName ~= ""
    local hasCooldown = bar.tracking.cooldownID and bar.tracking.cooldownID > 0
    local hasCustom = bar.tracking.customEnabled and bar.tracking.customSpellID and bar.tracking.customSpellID > 0
    
    return not hasSpell and not hasBuff and not hasCooldown and not hasCustom
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
-- AUTO CLEANUP: Called from Options.lua after DB init
-- Runs every login — scan is fast (just iterates existing entries)
-- ═══════════════════════════════════════════════════════════════════════════
function DR.RunAutoCleanup()
    local totalRemoved = 0
    
    local bars = CleanEmptyBars()
    local resources = CleanEmptyResourceBars()
    local cooldowns = CleanEmptyCooldownBars()
    local profiles = FixMissingActiveProfile(true)  -- silent on auto cleanup
    
    totalRemoved = bars + resources + cooldowns + profiles
    
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
    if msg == "emergency" then
        DR.EmergencyRepair()
    else
        local count = DR.RunAutoCleanup()
        if count == 0 then
            PrintMsg("No repairs needed - data looks healthy!")
        else
            PrintMsg("|cff00ff00Completed " .. count .. " repairs|r")
        end
    end
end

-- Export
ns.DataRepair = DR