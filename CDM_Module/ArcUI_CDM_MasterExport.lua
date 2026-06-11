-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI CDM Master Export Module
-- Global export/import of CDM icon profiles across all characters and specs
-- Scans ArcUIDB.char directly — no snapshot copies needed
-- Users cherry-pick which Arc Manager profiles to include (like bars export)
-- Import auto-routes profiles to the correct spec with rename-on-conflict
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON_NAME, ns = ...

ns.CDMMasterExport = ns.CDMMasterExport or {}
local ME = ns.CDMMasterExport

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local EXPORT_VERSION = 1
local EXPORT_PREFIX = "ARCMASTER"
local MSG_PREFIX = "|cff00ccffArcUI|r: "

-- ═══════════════════════════════════════════════════════════════════════════
-- DEPENDENCIES (lazy-loaded)
-- ═══════════════════════════════════════════════════════════════════════════

local LibSerialize
local LibDeflate
local uiState  -- forward declaration (populated below GetOptionsTable)

local function GetLibs()
    if not LibSerialize then
        LibSerialize = LibStub and LibStub("LibSerialize", true)
    end
    if not LibDeflate then
        LibDeflate = LibStub and LibStub("LibDeflate", true)
    end
    return LibSerialize, LibDeflate
end

-- Compression config: level 9 = max compression, smaller strings (same as WeakAuras)
local configForDeflate = { level = 9 }
local configForLS = { errorOnUnserializableType = false }

-- ═══════════════════════════════════════════════════════════════════════════
-- CLASS / SPEC DISPLAY HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local CLASS_INFO = {
    [1]  = { name = "Warrior",       token = "WARRIOR",      color = "ffc79c6e",
             specs = { "Arms", "Fury", "Protection" } },
    [2]  = { name = "Paladin",       token = "PALADIN",      color = "fff58cba",
             specs = { "Holy", "Protection", "Retribution" } },
    [3]  = { name = "Hunter",        token = "HUNTER",       color = "ffabd473",
             specs = { "Beast Mastery", "Marksmanship", "Survival" } },
    [4]  = { name = "Rogue",         token = "ROGUE",        color = "fffff569",
             specs = { "Assassination", "Outlaw", "Subtlety" } },
    [5]  = { name = "Priest",        token = "PRIEST",       color = "ffffffff",
             specs = { "Discipline", "Holy", "Shadow" } },
    [6]  = { name = "Death Knight",  token = "DEATHKNIGHT",  color = "ffc41f3b",
             specs = { "Blood", "Frost", "Unholy" } },
    [7]  = { name = "Shaman",        token = "SHAMAN",       color = "ff0070de",
             specs = { "Elemental", "Enhancement", "Restoration" } },
    [8]  = { name = "Mage",          token = "MAGE",         color = "ff69ccf0",
             specs = { "Arcane", "Fire", "Frost" } },
    [9]  = { name = "Warlock",       token = "WARLOCK",      color = "ff9482c9",
             specs = { "Affliction", "Demonology", "Destruction" } },
    [10] = { name = "Monk",          token = "MONK",         color = "ff00ff96",
             specs = { "Brewmaster", "Mistweaver", "Windwalker" } },
    [11] = { name = "Druid",         token = "DRUID",        color = "ffff7d0a",
             specs = { "Balance", "Feral", "Guardian", "Restoration" } },
    [12] = { name = "Demon Hunter",  token = "DEMONHUNTER",  color = "ffa330c9",
             specs = { "Havoc", "Vengeance" } },
    [13] = { name = "Evoker",        token = "EVOKER",       color = "ff33937f",
             specs = { "Devastation", "Preservation", "Augmentation" } },
}

-- Get spec name from hardcoded table (works for ALL classes, not just current)
local function GetSpecName(classID, specIndex)
    local classInfo = CLASS_INFO[classID]
    if classInfo and classInfo.specs and classInfo.specs[specIndex] then
        return classInfo.specs[specIndex]
    end
    return "Spec " .. (specIndex or "?")
end

-- Parse "class_7_spec_2" → classID=7, specIndex=2
local function ParseSpecKey(specKey)
    if not specKey then return nil, nil end
    local classID, specIndex = specKey:match("^class_(%d+)_spec_(%d+)$")
    return tonumber(classID), tonumber(specIndex)
end

-- Colored display name: "|cff0070deShaman|r - Enhancement"
local function GetSpecDisplayName(specKey, fallbackSpecName)
    local classID, specIndex = ParseSpecKey(specKey)
    if not classID then return specKey end
    
    local classInfo = CLASS_INFO[classID]
    local className = classInfo and classInfo.name or ("Class " .. classID)
    local classColor = classInfo and classInfo.color or "ffffffff"
    -- Always prefer hardcoded spec name, fallback to provided name
    local specName = GetSpecName(classID, specIndex)
    if specName:find("^Spec ") and fallbackSpecName then
        specName = fallbackSpecName  -- Only use fallback if hardcoded wasn't found
    end
    
    return string.format("|c%s%s|r - %s", classColor, className, specName)
end

-- Get short character name (strip realm)
local function GetCharName(charKey)
    return charKey:match("^(.-)%s*%-") or charKey
end

local function GetRealmFromKey(charKey)
    return charKey:match("%-+%s*(.+)$") or ""
end

-- Get bar data for any character. Current char uses AceDB (has defaults).
-- Other chars read raw SV (missing defaults OK — import writes through AceDB).
local function GetBarDataForChar(charKey)
    if not charKey or charKey == "" then return nil end
    
    local myCharKey = nil
    if ns.db and ns.db.keys and ns.db.keys.char then
        myCharKey = ns.db.keys.char
    end
    
    -- Current character: read through AceDB
    if charKey == myCharKey and ns.db and ns.db.char then
        local charDB = ns.db.char
        local data = {}
        if charDB.bars then data.bars = charDB.bars end
        if charDB.activeCooldowns then data.activeCooldowns = charDB.activeCooldowns end
        if charDB.activeCharges then data.activeCharges = charDB.activeCharges end
        if charDB.cooldownBarConfigs then data.cooldownBarConfigs = charDB.cooldownBarConfigs end
        if charDB.resourceBars then data.resourceBars = charDB.resourceBars end
        if charDB.timerBars then data.timerBars = charDB.timerBars end
        return next(data) and data or nil
    end
    
    -- Other character: read raw SV
    local svChar = ns.db and ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
    if not svChar or not svChar[charKey] then return nil end
    local cd = svChar[charKey]
    local data = {}
    if cd.bars then data.bars = cd.bars end
    if cd.activeCooldowns then data.activeCooldowns = cd.activeCooldowns end
    if cd.activeCharges then data.activeCharges = cd.activeCharges end
    if cd.cooldownBarConfigs then data.cooldownBarConfigs = cd.cooldownBarConfigs end
    if cd.resourceBars then data.resourceBars = cd.resourceBars end
    if cd.timerBars then data.timerBars = cd.timerBars end
    return next(data) and data or nil
end

local function CountBarsLabel(barData)
    if not barData then return "" end
    local parts = {}
    if barData.bars then
        local c = 0
        for _, bar in pairs(barData.bars) do
            if type(bar) == "table" and bar.tracking and bar.tracking.enabled then c = c + 1 end
        end
        if c > 0 then table.insert(parts, c .. " aura") end
    end
    local cd = barData.activeCooldowns and #barData.activeCooldowns or 0
    local ch = barData.activeCharges and #barData.activeCharges or 0
    if cd > 0 then table.insert(parts, cd .. " cooldown") end
    if ch > 0 then table.insert(parts, ch .. " charge") end
    if barData.resourceBars then
        local c = 0
        for _, bar in pairs(barData.resourceBars) do
            if type(bar) == "table" and bar.tracking and bar.tracking.enabled then c = c + 1 end
        end
        if c > 0 then table.insert(parts, c .. " resource") end
    end
    return #parts > 0 and table.concat(parts, ", ") or "no active bars"
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY
-- ═══════════════════════════════════════════════════════════════════════════

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SCAN ALL CHARACTERS' PROFILES
-- ═══════════════════════════════════════════════════════════════════════════

-- Scan all characters' bars from SavedVariables
function ME.ScanAllBars()
    local svChar = ns.db and ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
    if not svChar then return {} end
    
    local results = {}  -- { charKey, charName, aura={}, cooldown={}, resource={} }
    
    for charKey, charData in pairs(svChar) do
      if type(charData) == "table" then
        local entry = { charKey = charKey, charName = GetCharName(charKey), aura = {}, cooldown = {}, resource = {} }
        local hasAny = false
        
        -- Aura bars
        if charData.bars then
            for i, bar in pairs(charData.bars) do
                if type(bar) == "table" and bar.tracking and bar.tracking.enabled then
                    hasAny = true
                    table.insert(entry.aura, {
                        slot = i,
                        name = bar.tracking.buffName or "Unknown",
                        trackType = bar.tracking.trackType or "buff",
                        key = charKey .. "|aura|" .. i,
                    })
                end
            end
        end
        
        -- Cooldown bars (from char-level active lists)
        if charData.activeCooldowns then
            for _, e in ipairs(charData.activeCooldowns) do
                local spellID = type(e) == "table" and e.spellID or e
                if spellID and spellID > 0 then
                    hasAny = true
                    local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
                    table.insert(entry.cooldown, {
                        spellID = spellID, barType = "duration",
                        name = spellName, key = charKey .. "|cd|" .. spellID .. "_duration",
                    })
                end
            end
        end
        if charData.activeCharges then
            for _, e in ipairs(charData.activeCharges) do
                local spellID = type(e) == "table" and e.spellID or e
                if spellID and spellID > 0 then
                    hasAny = true
                    local spellName = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID) or ("Spell " .. spellID)
                    table.insert(entry.cooldown, {
                        spellID = spellID, barType = "charge",
                        name = spellName, key = charKey .. "|cd|" .. spellID .. "_charge",
                    })
                end
            end
        end
        
        -- Resource bars
        if charData.resourceBars then
            for i, bar in pairs(charData.resourceBars) do
                if type(bar) == "table" and bar.tracking and bar.tracking.enabled then
                    hasAny = true
                    local rname = bar.tracking.powerName or bar.tracking.secondaryType or "Resource"
                    table.insert(entry.resource, {
                        slot = i, name = rname,
                        key = charKey .. "|res|" .. i,
                    })
                end
            end
        end
        
        if hasAny then
            table.insert(results, entry)
        end
      end
    end
    
    table.sort(results, function(a, b) return a.charName < b.charName end)
    return results
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SCAN ALL CHARACTERS' CDM PROFILES
-- Reads ArcUIDB.char directly to find every Arc Manager profile
-- across all characters and specs on this account
-- ═══════════════════════════════════════════════════════════════════════════

function ME.ScanAllProfiles(opts)
    -- Use ns.db.sv.char (AceDB's internal reference to raw SavedVariables)
    -- This is the same data source the working Arc Manager Profiles dropdown uses
    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if not svChar then
        -- Fallback to global if AceDB not initialized yet
        svChar = ArcUIDB and ArcUIDB.char
    end
    if not svChar then return {} end
    
    local results = {}
    
    -- opts.allChars = true: skip shared-sync dedup so every character is listed
    local allChars = opts and opts.allChars
    
    -- Track which shared specs we've already collected (deduplicate)
    local sharedSpecCollected = {}
    
    for charKey, charData in pairs(svChar) do
        if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
            for specKey, specData in pairs(charData.cdmGroups.specData) do
                if type(specData) == "table" and specData.layoutProfiles then
                    -- When shared sync exists for this spec (global ref), only include ONE
                    -- character's profiles (unless allChars is set).
                    local skipShared = false
                    if not allChars then
                        local sharedRef = ns.db and ns.db.global and ns.db.global.sharedProfiles and ns.db.global.sharedProfiles[specKey]
                        if sharedRef then
                            if sharedSpecCollected[specKey] then
                                skipShared = true
                            else
                                sharedSpecCollected[specKey] = charKey
                            end
                        end
                    end
                    
                    if not skipShared then
                    local classID, specIndex = ParseSpecKey(specKey)
                    
                    -- Get spec name: prefer WoW API (works for all classes), fallback to hardcoded
                    local specName = GetSpecName(classID, specIndex)
                    if GetSpecializationInfoForClassID and classID and specIndex then
                        local _, apiName = GetSpecializationInfoForClassID(classID, specIndex)
                        if apiName then specName = apiName end
                    end
                    
                    for profileName, profileData in pairs(specData.layoutProfiles) do
                        if type(profileData) == "table" then
                            local uniqueKey = charKey .. "|" .. specKey .. "|" .. profileName
                            
                            -- Count data in this profile for display
                            local posCount = 0
                            local iconSettingsCount = 0
                            if profileData.savedPositions then
                                for _ in pairs(profileData.savedPositions) do posCount = posCount + 1 end
                            end
                            if profileData.iconSettings then
                                for _ in pairs(profileData.iconSettings) do iconSettingsCount = iconSettingsCount + 1 end
                            end
                            
                            table.insert(results, {
                                charKey = charKey,
                                specKey = specKey,
                                classID = classID or 0,
                                specIndex = specIndex or 0,
                                specName = specName,
                                profileName = profileName,
                                profileData = profileData,
                                uniqueKey = uniqueKey,
                                posCount = posCount,
                                iconSettingsCount = iconSettingsCount,
                                groupSettings = specData.groupSettings,
                                keepCDMStyle = specData.keepCDMStyle or nil,
                                globalIconSettings = {
                                    disableTooltips = charData.cdmGroups.disableTooltips,
                                    clickThrough = charData.cdmGroups.clickThrough,
                                },
                                charArcAuras = charData.arcAuras or nil,
                                sourceActiveProfile = specData.activeProfile,
                            })
                        end
                    end
                    end -- not skipShared
                end
            end
        end
    end
    
    -- Sort: charKey → specIndex → profileName (group by character)
    table.sort(results, function(a, b)
        if a.charKey ~= b.charKey then return a.charKey < b.charKey end
        if a.specIndex ~= b.specIndex then return a.specIndex < b.specIndex end
        return a.profileName < b.profileName
    end)
    
    return results
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EXPORT
-- ═══════════════════════════════════════════════════════════════════════════

function ME.Export(selectedKeys)
    local Serialize, Deflate = GetLibs()
    if not Serialize then return nil, "LibSerialize not available" end
    if not Deflate then return nil, "LibDeflate not available" end
    
    local allProfiles = ME.ScanAllProfiles()
    
    local exportPayload = {
        version = EXPORT_VERSION,
        prefix = EXPORT_PREFIX,
        timestamp = time(),
        exportedBy = UnitName("player") or "Unknown",
        realm = GetRealmName() or "Unknown",
        specs = {},
    }
    
    local totalProfiles = 0
    
    for _, entry in ipairs(allProfiles) do
        if selectedKeys[entry.uniqueKey] then
            local specKey = entry.specKey
            
            if not exportPayload.specs[specKey] then
                exportPayload.specs[specKey] = {
                    specName = entry.specName,
                    classID = entry.classID,
                    specIndex = entry.specIndex,
                    sourceChar = entry.charKey,
                    profiles = {},
                    groupSettings = entry.groupSettings and DeepCopy(entry.groupSettings) or nil,
                    keepCDMStyle = entry.keepCDMStyle or nil,
                    globalIconSettings = entry.globalIconSettings and DeepCopy(entry.globalIconSettings) or nil,
                    activeProfile = entry.sourceActiveProfile,
                    arcAuras = nil,  -- Built below by merging unique spells across characters
                }
            end
            
            -- Deduplicate: if same profile name already exists for this spec
            -- (e.g. two chars both have "Default" for Enhancement), rename the duplicate
            local finalName = entry.profileName
            if exportPayload.specs[specKey].profiles[finalName] then
                local charName = GetCharName(entry.charKey)
                finalName = entry.profileName .. " (" .. charName .. ")"
                local counter = 2
                while exportPayload.specs[specKey].profiles[finalName] do
                    finalName = entry.profileName .. " (" .. charName .. " " .. counter .. ")"
                    counter = counter + 1
                end
            end
            
            exportPayload.specs[specKey].profiles[finalName] = DeepCopy(entry.profileData)
            totalProfiles = totalProfiles + 1
        end
    end
    
    if totalProfiles == 0 then
        return nil, "No profiles selected for export"
    end
    
    -- Arc Auras: always export the CURRENT CHARACTER's data only.
    -- Merging across all characters caused stale data from alts to bleed into
    -- exports even after the current character deleted all their icons.
    -- If the current character deleted everything, importers get an empty set.
    do
        local myCharKey = (UnitName("player") or "") .. " - " .. (GetRealmName() or "")
        local svCharRef = (ns.db and ns.db.sv and ns.db.sv.char) or (ArcUIDB and ArcUIDB.char)
        local myArcAuras = svCharRef and svCharRef[myCharKey] and svCharRef[myCharKey].arcAuras
        for specKey in pairs(exportPayload.specs) do
            local aa = {
                trackedSpells = {},
                trackedItems = {},
                enabled = myArcAuras and myArcAuras.enabled or false,
                autoTrackEquippedTrinkets = myArcAuras and myArcAuras.autoTrackEquippedTrinkets or false,
                onlyOnUseTrinkets = myArcAuras and myArcAuras.onlyOnUseTrinkets or false,
                autoTrackSlots = (myArcAuras and myArcAuras.autoTrackSlots) and DeepCopy(myArcAuras.autoTrackSlots) or {[13] = false, [14] = false},
            }
            if myArcAuras then
                if myArcAuras.trackedSpells then
                    for arcID, config in pairs(myArcAuras.trackedSpells) do
                        aa.trackedSpells[arcID] = DeepCopy(config)
                    end
                end
                if myArcAuras.trackedItems then
                    for arcID, config in pairs(myArcAuras.trackedItems) do
                        -- Skip equipment-slot-based auto-track trinkets (discovered at runtime)
                        if not config.isAutoTrackSlot then
                            aa.trackedItems[arcID] = DeepCopy(config)
                        end
                    end
                end
            end
            exportPayload.specs[specKey].arcAuras = aa
        end
    end
    
    -- Include cdmEnhance global defaults
    if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
        local enhance = ns.db.profile.cdmEnhance
        exportPayload.cdmEnhance = {
            globalAuraSettings = enhance.globalAuraSettings and DeepCopy(enhance.globalAuraSettings) or nil,
            globalCooldownSettings = enhance.globalCooldownSettings and DeepCopy(enhance.globalCooldownSettings) or nil,
            globalApplyScale = enhance.globalApplyScale,
            globalApplyHideShadow = enhance.globalApplyHideShadow,
            disableRightClickSelect = enhance.disableRightClickSelect,
            lockGridSize = enhance.lockGridSize,
            enableAuraCustomization = enhance.enableAuraCustomization,
            enableCooldownCustomization = enhance.enableCooldownCustomization,
        }
    end
    
    exportPayload.profileCount = totalProfiles
    local specCount = 0
    for _ in pairs(exportPayload.specs) do specCount = specCount + 1 end
    exportPayload.specCount = specCount

    -- Cooldown Reminder bundle: include the current character's CR
    -- settings (globals + per-spell triggers + tracked spells/items)
    -- if the CR module is loaded. The user can opt out at import time
    -- via the Master importer's CR toggle.
    if ns.CRImportExport and ns.CRImportExport.GetExportPayloadForMaster then
        local crPayload = ns.CRImportExport.GetExportPayloadForMaster({
            includeGlobals  = true,
            includePerSpell = true,
        })
        if crPayload then
            exportPayload.cooldownReminder = crPayload
        end
    end

    -- Bar export: Coming Soon (disabled for this release)

    -- CDM native layout — export active layout for current character
    do
        local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
        local mgr = dp and dp:GetLayoutManager()
        if mgr then
            local activeID = mgr:GetActiveLayoutID()
            if activeID then
                local str = mgr:GetSerializer():SerializeLayouts(activeID)
                if str then
                    local activeLayout = mgr:GetLayout(activeID)
                    local layoutName = activeLayout and CooldownManagerLayout_GetName and CooldownManagerLayout_GetName(activeLayout) or nil
                    exportPayload.cdmNativeLayout = str
                    exportPayload.cdmNativeLayoutName = layoutName
                end
            end
        end
    end

    -- Serialize → Compress (level 9) → Encode
    local serialized = Serialize:SerializeEx(configForLS, exportPayload)
    if not serialized then return nil, "Serialization failed" end
    
    local compressed = Deflate:CompressDeflate(serialized, configForDeflate)
    if not compressed then return nil, "Compression failed" end
    
    local encoded = Deflate:EncodeForPrint(compressed)
    if not encoded then return nil, "Encoding failed" end
    
    return encoded, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMPORT
-- ═══════════════════════════════════════════════════════════════════════════

function ME.ParseImportString(importString)
    if not importString or importString == "" then
        return nil, "Empty import string"
    end
    
    local Serialize, Deflate = GetLibs()
    if not Serialize then return nil, "LibSerialize not available" end
    if not Deflate then return nil, "LibDeflate not available" end
    
    importString = importString:gsub("%s+", "")
    
    local decoded = Deflate:DecodeForPrint(importString)
    if not decoded then return nil, "Invalid string (decode failed)" end
    
    local decompressed = Deflate:DecompressDeflate(decoded)
    if not decompressed then return nil, "Invalid string (decompress failed)" end
    
    local success, data = Serialize:Deserialize(decompressed)
    if not success or type(data) ~= "table" then
        return nil, "Invalid string (deserialize failed)"
    end
    
    if data.prefix ~= EXPORT_PREFIX then
        return nil, "Wrong format — this is not an ArcUI Master Export string"
    end
    if not data.version then return nil, "Missing version" end
    if data.version > EXPORT_VERSION then
        return nil, "Export version " .. data.version .. " is newer than supported (" .. EXPORT_VERSION .. ")"
    end
    if not data.specs or not next(data.specs) then
        return nil, "No spec data or bars found in import"
    end
    
    return data, nil
end

function ME.GenerateImportPreview(data)
    if not data then return "|cff888888No data|r" end
    
    local lines = {}
    local _, _, myClassID = UnitClass("player")
    
    table.insert(lines, string.format(
        "|cff00ff00Master Export|r from |cff00ccff%s|r @ %s",
        data.exportedBy or "Unknown", data.realm or "Unknown"
    ))
    if data.timestamp then
        table.insert(lines, "|cff888888Exported: " .. date("%Y-%m-%d %H:%M", data.timestamp) .. "|r")
    end
    table.insert(lines, "")
    
    local sorted = {}
    for specKey, specEntry in pairs(data.specs or {}) do
        table.insert(sorted, { key = specKey, entry = specEntry })
    end
    table.sort(sorted, function(a, b)
        local ac = a.entry.classID or 99
        local bc = b.entry.classID or 99
        if ac ~= bc then return ac < bc end
        return (a.entry.specIndex or 99) < (b.entry.specIndex or 99)
    end)
    
    local totalProfiles = 0
    local myClassCount = 0
    local otherClassCount = 0
    
    for _, s in ipairs(sorted) do
        local specEntry = s.entry
        local displayName = GetSpecDisplayName(s.key, specEntry.specName)
        local isMyClass = specEntry.classID == myClassID
        
        local profileNames = {}
        if specEntry.profiles then
            for pName, pData in pairs(specEntry.profiles) do
                local posCount = 0
                if pData.savedPositions then
                    for _ in pairs(pData.savedPositions) do posCount = posCount + 1 end
                end
                table.insert(profileNames, string.format("'%s' (%d icons)", pName, posCount))
                totalProfiles = totalProfiles + 1
            end
        end
        table.sort(profileNames)
        
        local routeTag = isMyClass
            and "|cff00ff00→ Will merge into this character|r"
            or "|cff888888→ Stored for future (different class)|r"
        
        if isMyClass then myClassCount = myClassCount + 1
        else otherClassCount = otherClassCount + 1 end
        
        table.insert(lines, displayName .. "  " .. routeTag)
        for _, pStr in ipairs(profileNames) do
            table.insert(lines, "    • " .. pStr)
        end
        if specEntry.sourceChar then
            table.insert(lines, "    |cff666666from " .. specEntry.sourceChar .. "|r")
        end
        if specEntry.activeProfile then
            table.insert(lines, "    |cffffd100Active: '" .. specEntry.activeProfile .. "'|r")
        end
        if specEntry.arcAuras and specEntry.arcAuras.trackedSpells then
            local spellCount = 0
            for _ in pairs(specEntry.arcAuras.trackedSpells) do spellCount = spellCount + 1 end
            if spellCount > 0 then
                table.insert(lines, "    |cff00ccff+ " .. spellCount .. " Arc Aura spell(s)|r")
            end
        end
        if specEntry.arcAuras and specEntry.arcAuras.trackedItems then
            local itemCount = 0
            for _ in pairs(specEntry.arcAuras.trackedItems) do itemCount = itemCount + 1 end
            if itemCount > 0 then
                table.insert(lines, "    |cff00ccff+ " .. itemCount .. " Arc Aura item(s)|r")
            end
        end
    end
    
    table.insert(lines, "")
    table.insert(lines, string.format(
        "|cffffd100Total: %d profile(s) across %d spec(s)|r  |cff00ff00(%d for this class|r, |cff888888%d other)|r",
        totalProfiles, #sorted, myClassCount, otherClassCount
    ))
    
    if data.cdmEnhance then
        local extras = {}
        if data.cdmEnhance.globalAuraSettings then table.insert(extras, "Aura Defaults") end
        if data.cdmEnhance.globalCooldownSettings then table.insert(extras, "Cooldown Defaults") end
        if #extras > 0 then
            table.insert(lines, "|cffffd100Includes:|r " .. table.concat(extras, ", "))
        end
    end

    -- Cooldown Reminder bundle present?
    if data.cooldownReminder then
        local crP = data.cooldownReminder
        local wlCount = 0
        if crP.perSpell and crP.perSpell.whitelist then
            for _ in pairs(crP.perSpell.whitelist) do wlCount = wlCount + 1 end
        end
        local globalsLabel = (crP.globals and "globals") or nil
        local spellsLabel  = (wlCount > 0) and (wlCount .. " reminders") or nil
        local bits = {}
        if globalsLabel then table.insert(bits, globalsLabel) end
        if spellsLabel  then table.insert(bits, spellsLabel)  end
        if #bits > 0 then
            table.insert(lines, "|cffff7777Cooldown Reminder:|r " .. table.concat(bits, ", "))
        end
    end
    
    if data.barData then
        local barParts = {}
        if data.barData.bars then
            local count = 0
            for _, bar in pairs(data.barData.bars) do
                if type(bar) == "table" and bar.tracking and bar.tracking.enabled then
                    count = count + 1
                end
            end
            if count > 0 then table.insert(barParts, count .. " aura") end
        end
        if data.barData.activeCooldowns or data.barData.activeCharges then
            local cdCount = data.barData.activeCooldowns and #data.barData.activeCooldowns or 0
            local chgCount = data.barData.activeCharges and #data.barData.activeCharges or 0
            if cdCount > 0 then table.insert(barParts, cdCount .. " cooldown") end
            if chgCount > 0 then table.insert(barParts, chgCount .. " charge") end
        end
        if data.barData.resourceBars then
            local count = 0
            for _, bar in pairs(data.barData.resourceBars) do
                if type(bar) == "table" and bar.tracking and bar.tracking.enabled then
                    count = count + 1
                end
            end
            if count > 0 then table.insert(barParts, count .. " resource") end
        end
        if #barParts > 0 then
            table.insert(lines, "|cffffd100Bars:|r " .. table.concat(barParts, ", "))
        end
    end
    
    return table.concat(lines, "\n")
end

-- Merge profiles into specData with rename-on-conflict
-- This is the core merge logic shared by Import() and AutoApplyPendingProfiles()
-- Returns mergedCount, firstImportedProfileName
local function MergeProfilesIntoSpec(cdmGroupsDB, specKey, specEntry, sourceLabel)
    if not cdmGroupsDB.specData then cdmGroupsDB.specData = {} end
    
    -- Ensure specData entry exists
    if not cdmGroupsDB.specData[specKey] then
        cdmGroupsDB.specData[specKey] = {
            layoutProfiles = {},
            activeProfile = "Default",
            groupSettings = {},
        }
    end
    
    local targetSpec = cdmGroupsDB.specData[specKey]
    if not targetSpec.layoutProfiles then
        targetSpec.layoutProfiles = {}
    end
    
    local mergedCount = 0
    local firstImportedName = nil
    
    if specEntry.profiles then
        for profileName, profileData in pairs(specEntry.profiles) do
            if type(profileData) ~= "table" then
                -- Skip corrupted/non-table entries
            else
            local finalName = profileName
            
            if targetSpec.layoutProfiles[profileName] then
                local baseName = profileName .. " (" .. sourceLabel .. ")"
                finalName = baseName
                local counter = 2
                while targetSpec.layoutProfiles[finalName] do
                    finalName = baseName .. " " .. counter
                    counter = counter + 1
                end
                print(MSG_PREFIX .. "|cffFFFF00'" .. profileName .. "' exists|r → imported as '" .. finalName .. "'")
            end
            
            targetSpec.layoutProfiles[finalName] = DeepCopy(profileData)
            mergedCount = mergedCount + 1
            firstImportedName = firstImportedName or finalName
            print(MSG_PREFIX .. "Added profile: " .. finalName)
            end
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- REPAIR: Ensure all imported profiles have valid groupLayouts
    -- Matches the same repair logic as the normal per-spec import
    -- ═══════════════════════════════════════════════════════════════════════════
    local DEFAULT_GROUPS = ns.CDMGroups and ns.CDMGroups.DEFAULT_GROUPS
    
    for profileName, profileData in pairs(targetSpec.layoutProfiles) do
        -- Ensure required tables exist
        if not profileData.savedPositions then profileData.savedPositions = {} end
        if not profileData.freeIcons then profileData.freeIcons = {} end
        if not profileData.iconSettings then profileData.iconSettings = {} end
        
        -- If groupLayouts is empty AND not linked, populate from DEFAULT_GROUPS
        if (not profileData.groupLayouts or not next(profileData.groupLayouts)) and not profileData.groupLayoutName then
            print(MSG_PREFIX .. "|cffff8800[Repair]|r Profile '" .. profileName .. "' has no groups — adding defaults")
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
                -- Fallback if DEFAULT_GROUPS not available
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
    -- SET ACTIVE PROFILE: prefer source's active, fall back to first imported
    -- Mirrors normal CDM import behavior (uses source's activeProfile)
    -- ═══════════════════════════════════════════════════════════════════════════
    local preferredActive = specEntry.activeProfile
    if preferredActive and targetSpec.layoutProfiles[preferredActive] then
        targetSpec.activeProfile = preferredActive
        print(MSG_PREFIX .. "Set active profile to: " .. preferredActive)
    elseif firstImportedName then
        targetSpec.activeProfile = firstImportedName
        print(MSG_PREFIX .. "Set active profile to: " .. firstImportedName)
    end
    
    -- Merge groupSettings (fill missing only)
    if specEntry.groupSettings then
        if not targetSpec.groupSettings then
            targetSpec.groupSettings = DeepCopy(specEntry.groupSettings)
        else
            for vtype, settings in pairs(specEntry.groupSettings) do
                if not targetSpec.groupSettings[vtype] or not next(targetSpec.groupSettings[vtype]) then
                    targetSpec.groupSettings[vtype] = DeepCopy(settings)
                end
            end
        end
    end

    -- keepCDMStyle: only set if not already configured locally
    if specEntry.keepCDMStyle ~= nil and targetSpec.keepCDMStyle == nil then
        targetSpec.keepCDMStyle = specEntry.keepCDMStyle
    end
    
    -- Apply global icon settings
    if specEntry.globalIconSettings then
        if specEntry.globalIconSettings.disableTooltips ~= nil then
            cdmGroupsDB.disableTooltips = specEntry.globalIconSettings.disableTooltips
        end
        if specEntry.globalIconSettings.clickThrough ~= nil then
            cdmGroupsDB.clickThrough = specEntry.globalIconSettings.clickThrough
        end
    end
    
    return mergedCount, firstImportedName
end

function ME.Import(data, importMode, activeOverrides, selectedProfiles)
    if not data or not data.specs then
        return false, "No data to import"
    end
    
    importMode = importMode or "merge"
    activeOverrides = activeOverrides or {}
    
    local Shared = ns.CDMShared
    if not Shared then return false, "CDMShared not available" end
    
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    if not cdmGroupsDB then return false, "CDMGroups database not available" end
    if not cdmGroupsDB.specData then cdmGroupsDB.specData = {} end
    
    local _, _, myClassID = UnitClass("player")
    local importedProfiles = 0
    local storedForLater = 0
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    local currentSpecProfileName = nil  -- Track which profile to load for current spec
    
    -- Replace mode: wipe specData for matching class specs first
    -- Backup wiped data in case merge fails
    local replaceBackup = {}
    if importMode == "replace" then
        for specKey, specEntry in pairs(data.specs or {}) do
            local classID = ParseSpecKey(specKey)
            if classID == myClassID and cdmGroupsDB.specData[specKey] then
                replaceBackup[specKey] = cdmGroupsDB.specData[specKey]
                cdmGroupsDB.specData[specKey] = nil
            end
        end
    end
    
    for specKey, specEntry in pairs(data.specs or {}) do
        local classID = ParseSpecKey(specKey)
        
        if not classID then
            -- Skip malformed keys
        elseif classID == myClassID then
            local sourceLabel = specEntry.sourceChar or data.exportedBy or "Imported"
            -- Apply user's active profile override if they picked one
            if activeOverrides[specKey] then
                specEntry.activeProfile = activeOverrides[specKey]
            end
            -- Filter profiles by user selection (if provided)
            if selectedProfiles and next(selectedProfiles) then
                local filteredEntry = DeepCopy(specEntry)
                filteredEntry.profiles = {}
                for profileName, profileData in pairs(specEntry.profiles or {}) do
                    local fKey = specKey .. "|" .. profileName
                    if selectedProfiles[fKey] ~= false then
                        filteredEntry.profiles[profileName] = profileData
                    end
                end
                specEntry = filteredEntry
            end
            local merged, firstProfileName = MergeProfilesIntoSpec(cdmGroupsDB, specKey, specEntry, sourceLabel)
            importedProfiles = importedProfiles + merged
            
            -- If this is the current spec, load the user's chosen active profile
            if specKey == currentSpec and merged > 0 then
                local targetSpec = cdmGroupsDB.specData[specKey]
                if targetSpec then
                    currentSpecProfileName = targetSpec.activeProfile or firstProfileName
                end
            end
            
            -- Apply character-level Arc Auras (export is source of truth — replace wholesale)
            if specEntry.arcAuras then
                -- Ensure char arcAuras DB exists
                if not ArcUIDB then ArcUIDB = {} end
                if not ArcUIDB.char then ArcUIDB.char = {} end
                local charKey = UnitName("player") .. " - " .. GetRealmName()
                if not ArcUIDB.char[charKey] then ArcUIDB.char[charKey] = {} end
                if not ArcUIDB.char[charKey].arcAuras then
                    ArcUIDB.char[charKey].arcAuras = {
                        enabled = true,
                        trackedItems = {},
                        trackedSpells = {},
                        positions = {},
                        globalSettings = {},
                    }
                end
                local arcAuras = ArcUIDB.char[charKey].arcAuras
                
                -- Replace tracked spells wholesale (wipe existing so deleted icons don't persist)
                local spellCount = 0
                arcAuras.trackedSpells = {}
                if specEntry.arcAuras.trackedSpells then
                    for arcID, config in pairs(specEntry.arcAuras.trackedSpells) do
                        arcAuras.trackedSpells[arcID] = DeepCopy(config)
                        spellCount = spellCount + 1
                    end
                end
                
                -- Replace tracked items wholesale (wipe existing so deleted icons don't persist)
                local itemCount = 0
                arcAuras.trackedItems = {}
                if specEntry.arcAuras.trackedItems then
                    for arcID, config in pairs(specEntry.arcAuras.trackedItems) do
                        arcAuras.trackedItems[arcID] = DeepCopy(config)
                        itemCount = itemCount + 1
                    end
                end
                
                -- Apply enabled state unconditionally (export is source of truth)
                if specEntry.arcAuras.enabled ~= nil then
                    arcAuras.enabled = specEntry.arcAuras.enabled
                end
                if specEntry.arcAuras.autoTrackEquippedTrinkets ~= nil then
                    arcAuras.autoTrackEquippedTrinkets = specEntry.arcAuras.autoTrackEquippedTrinkets
                end
                -- ALWAYS overwrite autoTrackSlots — exporter's disabled slots must propagate
                if specEntry.arcAuras.autoTrackSlots ~= nil then
                    arcAuras.autoTrackSlots = DeepCopy(specEntry.arcAuras.autoTrackSlots)
                end
                if specEntry.arcAuras.onlyOnUseTrinkets ~= nil then
                    arcAuras.onlyOnUseTrinkets = specEntry.arcAuras.onlyOnUseTrinkets
                end
                
                -- Invalidate ArcAuras DB cache so next GetDB() reads fresh data
                if ns.ArcAuras and ns.ArcAuras.ClearDBCache then
                    ns.ArcAuras.ClearDBCache()
                end
                
                if spellCount + itemCount > 0 then
                    print(MSG_PREFIX .. "|cff00ccffImported " .. spellCount .. " spell(s), " .. itemCount .. " item(s) for Arc Auras|r")
                end
            else
                -- Export has no arcAuras section (legacy format or exporter has none).
                -- Clear the importer's existing Arc Auras to prevent stale items persisting.
                local charKey = UnitName("player") .. " - " .. GetRealmName()
                if ArcUIDB and ArcUIDB.char and ArcUIDB.char[charKey] and ArcUIDB.char[charKey].arcAuras then
                    local arcAuras = ArcUIDB.char[charKey].arcAuras
                    arcAuras.trackedItems = {}
                    arcAuras.trackedSpells = {}
                    arcAuras.enabled = false
                    arcAuras.autoTrackEquippedTrinkets = false
                    arcAuras.autoTrackSlots = {[13] = false, [14] = false}
                    arcAuras.onlyOnUseTrinkets = false
                    if ns.ArcAuras and ns.ArcAuras.ClearDBCache then
                        ns.ArcAuras.ClearDBCache()
                    end
                end
            end
            
            print(MSG_PREFIX .. "|cff00ff00Merged " .. merged .. " profile(s) into " ..
                GetSpecDisplayName(specKey, specEntry.specName) .. "|r")
        else
            -- Different class — store in global.masterCDMPending
            if ns.db and ns.db.global then
                if not ns.db.global.masterCDMPending then
                    ns.db.global.masterCDMPending = {}
                end
                ns.db.global.masterCDMPending[specKey] = DeepCopy(specEntry)
                storedForLater = storedForLater + 1
                print(MSG_PREFIX .. "|cff888888Stored " .. GetSpecDisplayName(specKey, specEntry.specName) .. " for future use|r")
            end
        end
    end
    
    -- Apply cdmEnhance global defaults
    if data.cdmEnhance and ns.db and ns.db.profile then
        if not ns.db.profile.cdmEnhance then ns.db.profile.cdmEnhance = {} end
        local enhance = ns.db.profile.cdmEnhance
        if data.cdmEnhance.globalAuraSettings then
            enhance.globalAuraSettings = DeepCopy(data.cdmEnhance.globalAuraSettings)
        end
        if data.cdmEnhance.globalCooldownSettings then
            enhance.globalCooldownSettings = DeepCopy(data.cdmEnhance.globalCooldownSettings)
        end
        if data.cdmEnhance.globalApplyScale ~= nil then
            enhance.globalApplyScale = data.cdmEnhance.globalApplyScale
        end
        if data.cdmEnhance.globalApplyHideShadow ~= nil then
            enhance.globalApplyHideShadow = data.cdmEnhance.globalApplyHideShadow
        end
        if data.cdmEnhance.disableRightClickSelect ~= nil then
            enhance.disableRightClickSelect = data.cdmEnhance.disableRightClickSelect
        end
        if data.cdmEnhance.lockGridSize ~= nil then
            enhance.lockGridSize = data.cdmEnhance.lockGridSize
        end
        if data.cdmEnhance.enableAuraCustomization ~= nil then
            enhance.enableAuraCustomization = data.cdmEnhance.enableAuraCustomization
        end
        if data.cdmEnhance.enableCooldownCustomization ~= nil then
            enhance.enableCooldownCustomization = data.cdmEnhance.enableCooldownCustomization
        end
    end
    
    -- Apply Cooldown Reminder bundle: route through CRImportExport.Import
    -- so all the engine wiring (RebuildTrackedSpells, ApplySettings,
    -- AceConfig refresh) runs the same way as a direct CR import.
    -- The Master importer's checkbox can pre-set crBundleEnabled in opts;
    -- if not provided we default to applying the bundle when present.
    if data.cooldownReminder and ns.CRImportExport and ns.CRImportExport.Import then
        local crOpts = (importMode == "replace") and { importMode = "replace" }
                                                  or  { importMode = "merge" }
        ns.CRImportExport.Import({ payload = data.cooldownReminder }, crOpts)
    end

    -- Bar import: Coming Soon (disabled for this release)
    local barImportCount = 0
    
    -- Replace mode: if nothing was imported, restore the backup
    if importMode == "replace" and importedProfiles == 0 and next(replaceBackup) then
        for specKey, backup in pairs(replaceBackup) do
            cdmGroupsDB.specData[specKey] = backup
        end
        print(MSG_PREFIX .. "|cffff8800No profiles imported — restored original data.|r")
    end
    replaceBackup = nil  -- Release reference
    
    if Shared.ClearDBCache then Shared.ClearDBCache() end
    
    -- Invalidate CDMEnhance settings cache
    if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
        ns.CDMEnhance.InvalidateCache()
    end
    
    -- Refresh cached layout settings (tooltips, click-through)
    if ns.CDMGroups and ns.CDMGroups.RefreshCachedLayoutSettings then
        ns.CDMGroups.RefreshCachedLayoutSettings()
    end
    
    -- CDM native layout
    local importedCDMLayoutID = nil
    if data.cdmNativeLayout and data.cdmNativeLayout ~= "" then
        local dp = CooldownViewerSettings and CooldownViewerSettings:GetDataProvider()
        local mgr = dp and dp:GetLayoutManager()
        if mgr then
            local ok, err = pcall(function()
                local newLayoutIDs = mgr:CreateLayoutsFromSerializedData(data.cdmNativeLayout)
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
                if newLayoutIDs and newLayoutIDs[1] then
                    importedCDMLayoutID = newLayoutIDs[1]
                    dp:SetActiveLayoutByID(newLayoutIDs[1])
                end
            end)
            if not ok then
                print(MSG_PREFIX .. "|cffff8800CDM layout could not be applied: " .. tostring(err) .. "|r")
            end
        end
    end

    -- If the current spec received profiles, switch to and load the imported profile
    if currentSpecProfileName then
        if ns.CDMGroups and ns.CDMGroups.LoadProfile then
            local capturedCDMLayoutID = importedCDMLayoutID
            C_Timer.After(0.2, function()
                print(MSG_PREFIX .. "Loading imported profile '" .. currentSpecProfileName .. "'...")
                ns.CDMGroups.LoadProfile(currentSpecProfileName)
                -- Deferred SV write: ensure new CDM layout ID survives the post-import chain
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
    end
    
    -- Push imported profiles to shared so all synced alts receive them
    local SP = ns.CDMSharedProfiles
    if SP and SP.IsEnabled and SP.Push then
        for specKey in pairs(data.specs or {}) do
            if ParseSpecKey(specKey) == myClassID and SP.IsEnabled(specKey) then
                SP.Push(specKey)
            end
        end
    end
    
    -- Notify FrameController that layout changed
    if ns.FrameController and ns.FrameController.OnLayoutChange then
        ns.FrameController.OnLayoutChange()
    end
    
    local result = string.format("Imported %d profile(s) to this character", importedProfiles)
    if barImportCount > 0 then
        result = result .. string.format(", %d bar(s)", barImportCount)
    end
    if storedForLater > 0 then
        result = result .. string.format(", %d spec(s) stored for other classes", storedForLater)
    end
    
    return true, result
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO-APPLY PENDING PROFILES ON LOGIN
-- ═══════════════════════════════════════════════════════════════════════════

function ME.AutoApplyPendingProfiles()
    if not ns.db or not ns.db.global or not ns.db.global.masterCDMPending then return end
    
    local pending = ns.db.global.masterCDMPending
    if not next(pending) then return end
    
    local Shared = ns.CDMShared
    if not Shared then return end
    
    local cdmGroupsDB = Shared.GetCDMGroupsDB()
    if not cdmGroupsDB then return end
    
    local _, _, myClassID = UnitClass("player")
    local applied = 0
    local keysToRemove = {}
    local currentSpec = ns.CDMGroups and ns.CDMGroups.currentSpec
    local currentSpecProfileName = nil
    
    for specKey, specEntry in pairs(pending) do
        local classID = ParseSpecKey(specKey)
        
        if classID == myClassID then
            local sourceLabel = specEntry.sourceChar or "Master Import"
            local merged, firstProfileName = MergeProfilesIntoSpec(cdmGroupsDB, specKey, specEntry, sourceLabel)
            
            if merged > 0 then
                applied = applied + 1
                print(MSG_PREFIX .. "|cff00ff00Auto-merged " .. merged .. " pending profile(s) into " ..
                    GetSpecDisplayName(specKey, specEntry.specName) .. "|r")
                
                -- Track which profile to load for current spec
                if specKey == currentSpec and merged > 0 then
                    local targetSpec = cdmGroupsDB.specData[specKey]
                    if targetSpec then
                        currentSpecProfileName = targetSpec.activeProfile or firstProfileName
                    end
                end
            end
            
            -- Apply character-level Arc Auras (export is source of truth — replace wholesale)
            if specEntry.arcAuras then
                local charKey = UnitName("player") .. " - " .. GetRealmName()
                if ArcUIDB and ArcUIDB.char and ArcUIDB.char[charKey] then
                    local charDB = ArcUIDB.char[charKey]
                    if not charDB.arcAuras then
                        charDB.arcAuras = { enabled = true, trackedItems = {}, trackedSpells = {}, positions = {}, globalSettings = {} }
                    end
                    local spellCount, itemCount = 0, 0
                    -- Replace tracked spells wholesale (wipe so deleted icons don't persist)
                    charDB.arcAuras.trackedSpells = {}
                    if specEntry.arcAuras.trackedSpells then
                        for arcID, config in pairs(specEntry.arcAuras.trackedSpells) do
                            charDB.arcAuras.trackedSpells[arcID] = DeepCopy(config)
                            spellCount = spellCount + 1
                        end
                    end
                    -- Replace tracked items wholesale
                    charDB.arcAuras.trackedItems = {}
                    if specEntry.arcAuras.trackedItems then
                        for arcID, config in pairs(specEntry.arcAuras.trackedItems) do
                            charDB.arcAuras.trackedItems[arcID] = DeepCopy(config)
                            itemCount = itemCount + 1
                        end
                    end
                    if specEntry.arcAuras.enabled ~= nil then
                        charDB.arcAuras.enabled = specEntry.arcAuras.enabled
                    end
                    if specEntry.arcAuras.autoTrackEquippedTrinkets ~= nil then
                        charDB.arcAuras.autoTrackEquippedTrinkets = specEntry.arcAuras.autoTrackEquippedTrinkets
                    end
                    -- ALWAYS overwrite autoTrackSlots — exporter's disabled slots must propagate
                    if specEntry.arcAuras.autoTrackSlots ~= nil then
                        charDB.arcAuras.autoTrackSlots = DeepCopy(specEntry.arcAuras.autoTrackSlots)
                    end
                    if specEntry.arcAuras.onlyOnUseTrinkets ~= nil then
                        charDB.arcAuras.onlyOnUseTrinkets = specEntry.arcAuras.onlyOnUseTrinkets
                    end
                    -- Invalidate ArcAuras DB cache so next GetDB() reads fresh data
                    if ns.ArcAuras and ns.ArcAuras.ClearDBCache then
                        ns.ArcAuras.ClearDBCache()
                    end
                    if spellCount + itemCount > 0 then
                        print(MSG_PREFIX .. "|cff00ccffAuto-imported " .. spellCount .. " spell(s), " .. itemCount .. " item(s) for Arc Auras|r")
                    end
                end
            else
                -- Export has no arcAuras section — clear to prevent stale items persisting
                local charKey = UnitName("player") .. " - " .. GetRealmName()
                if ArcUIDB and ArcUIDB.char and ArcUIDB.char[charKey] and ArcUIDB.char[charKey].arcAuras then
                    local arcAuras = ArcUIDB.char[charKey].arcAuras
                    arcAuras.trackedItems = {}
                    arcAuras.trackedSpells = {}
                    arcAuras.enabled = false
                    arcAuras.autoTrackEquippedTrinkets = false
                    arcAuras.autoTrackSlots = {[13] = false, [14] = false}
                    arcAuras.onlyOnUseTrinkets = false
                    if ns.ArcAuras and ns.ArcAuras.ClearDBCache then
                        ns.ArcAuras.ClearDBCache()
                    end
                end
            end
            
            table.insert(keysToRemove, specKey)
        end
    end
    
    for _, key in ipairs(keysToRemove) do
        pending[key] = nil
    end
    
    if not next(pending) then
        ns.db.global.masterCDMPending = nil
    end
    
    if applied > 0 and Shared.ClearDBCache then
        Shared.ClearDBCache()
        
        -- Invalidate CDMEnhance settings cache
        if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
            ns.CDMEnhance.InvalidateCache()
        end
        
        -- Refresh cached layout settings
        if ns.CDMGroups and ns.CDMGroups.RefreshCachedLayoutSettings then
            ns.CDMGroups.RefreshCachedLayoutSettings()
        end
        
        -- Load the imported profile for current spec
        if currentSpecProfileName and ns.CDMGroups and ns.CDMGroups.LoadProfile then
            C_Timer.After(0.5, function()
                print(MSG_PREFIX .. "Loading imported profile '" .. currentSpecProfileName .. "'...")
                ns.CDMGroups.LoadProfile(currentSpecProfileName)
            end)
        end
        
        -- Notify FrameController
        if ns.FrameController and ns.FrameController.OnLayoutChange then
            ns.FrameController.OnLayoutChange()
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS TABLE (AceConfig)
-- ═══════════════════════════════════════════════════════════════════════════

uiState = {
    selectedForExport = {},
    exportString = "",
    importString = "",
    importPreview = nil,
    importError = nil,
    importMode = "merge",
    importActiveOverrides = {},
    collapsedChars = {},
    cdmProfilesCollapsed = true,
    barsCollapsed = true,
    collapsedBarChars = {},
    selectedBarsForExport = {},
    -- Import profile filter: keyed by specKey.."|"..profileName → bool (true=include)
    importSelectedProfiles = {},
    -- Profile browser
    browserCollapsedChars = {},
    browserRenameValues = {},
}

-- Shared args table for per-spec active profile dropdowns (rebuilt on preview)
local activeProfileSelectorArgs = {}
local importProfileFilterArgs = {}

-- Rebuild import profile filter checkboxes from preview data
local function RebuildImportProfileFilter()
    wipe(importProfileFilterArgs)
    wipe(uiState.importSelectedProfiles)
    if not uiState.importPreview then return end
    local data = uiState.importPreview
    local order = 1
    for specKey, specEntry in pairs(data.specs or {}) do
        local specDisplayName = GetSpecDisplayName(specKey, specEntry.specName)
        for profileName, _ in pairs(specEntry.profiles or {}) do
            local fKey = specKey .. "|" .. profileName
            uiState.importSelectedProfiles[fKey] = true  -- default all selected
            local argKey = "impf_" .. fKey:gsub("[^%w]", "_")
            importProfileFilterArgs[argKey] = {
                type = "toggle",
                name = specDisplayName .. "  |cff888888" .. profileName .. "|r",
                order = order,
                width = "full",
                get = function() return uiState.importSelectedProfiles[fKey] ~= false end,
                set = function(_, v) uiState.importSelectedProfiles[fKey] = v end,
            }
            order = order + 1
        end
    end
end

-- Rebuild per-spec active profile dropdowns from preview data
local function RebuildActiveProfileSelectors()
    RebuildImportProfileFilter()
    wipe(activeProfileSelectorArgs)
    if not uiState.importPreview then return end
    
    local _, _, myClassID = UnitClass("player")
    local data = uiState.importPreview
    
    -- Sort specs for consistent display order
    local sorted = {}
    for specKey, specEntry in pairs(data.specs or {}) do
        table.insert(sorted, { key = specKey, entry = specEntry })
    end
    table.sort(sorted, function(a, b)
        local ac = a.entry.classID or 99
        local bc = b.entry.classID or 99
        if ac ~= bc then return ac < bc end
        return (a.entry.specIndex or 99) < (b.entry.specIndex or 99)
    end)
    
    local order = 1
    for _, s in ipairs(sorted) do
        local specKey = s.key
        local specEntry = s.entry
        local isMyClass = specEntry.classID == myClassID
        
        -- Only show selectors for specs that will merge into this character
        if isMyClass then
            -- Build profile name list for dropdown
            local profileValues = {}
            if specEntry.profiles then
                for pName in pairs(specEntry.profiles) do
                    profileValues[pName] = pName
                end
            end
            
            -- Count profiles — skip dropdown if only 1 profile
            local count = 0
            for _ in pairs(profileValues) do count = count + 1 end
            
            if count > 1 then
                local displayName = GetSpecDisplayName(specKey, specEntry.specName)
                local sKey = specKey  -- capture for closure
                
                activeProfileSelectorArgs["active_" .. order] = {
                    type = "select",
                    name = displayName .. "  |cff888888Active Profile|r",
                    order = order,
                    width = 1.5,
                    values = profileValues,
                    get = function()
                        return uiState.importActiveOverrides[sKey]
                    end,
                    set = function(_, val)
                        uiState.importActiveOverrides[sKey] = val
                    end,
                }
                order = order + 1
            end
        end
    end
end

local function GetOptionsTable()
    local options = {
        type = "group",
        name = "Export",
        order = 6,
        args = {
            description = {
                type = "description",
                name = "Bundle profiles from any character into a single export string. "
                    .. "Import on any alt — matching specs merge automatically, other classes queue for next login.\n\n"
                    .. "|cffff9900First Pass — this feature is new and may have rough edges. "
                    .. "If you run into any issues please report them in the Discord.|r\n",
                fontSize = "medium",
                order = 1,
            },
            
            -- ═══════════════════════════════════════════════════════════════
            -- CDM PROFILES SECTION (collapsible)
            -- ═══════════════════════════════════════════════════════════════
            cdmProfilesToggle = {
                type = "toggle",
                name = function()
                    local count = 0
                    for _ in pairs(uiState.selectedForExport) do count = count + 1 end
                    local label = "|cffffd100CDM Profiles|r"
                    if count > 0 then
                        label = label .. "  |cff00ff00[" .. count .. " selected]|r"
                    end
                    if uiState.cdmProfilesCollapsed then
                        local allProfiles = ME.ScanAllProfiles()
                        label = label .. "  |cff666666(" .. #allProfiles .. " available)|r"
                    end
                    return label
                end,
                desc = "Click to expand/collapse the CDM profile list",
                dialogControl = "CollapsibleHeader",
                order = 10,
                width = "full",
                get = function() return not uiState.cdmProfilesCollapsed end,
                set = function(_, v) uiState.cdmProfilesCollapsed = not v end,
            },
            
            cdmSelectAll = {
                type = "execute",
                name = "Select All",
                order = 11,
                width = 0.6,
                hidden = function() return uiState.cdmProfilesCollapsed end,
                func = function()
                    local allProfiles = ME.ScanAllProfiles()
                    for _, entry in ipairs(allProfiles) do
                        uiState.selectedForExport[entry.uniqueKey] = true
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            cdmSelectNone = {
                type = "execute",
                name = "Select None",
                order = 12,
                width = 0.6,
                hidden = function() return uiState.cdmProfilesCollapsed end,
                func = function()
                    wipe(uiState.selectedForExport)
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            -- Character profile sections injected below (order 13+)
            
            -- ═══════════════════════════════════════════════════════════════
            -- BARS SECTION (collapsible, per-character with per-bar toggles)
            -- ═══════════════════════════════════════════════════════════════
            barsComingSoon = {
                type = "description",
                name = "|cffffd100Bars|r  |cff888888(Coming Soon)|r",
                order = 100,
                fontSize = "medium",
            },
            
            -- Per-character bar sections injected below (order 103+)
            
            -- ═══════════════════════════════════════════════════════════════
            -- EXPORT ACTIONS
            -- ═══════════════════════════════════════════════════════════════
            exportHeader = {
                type = "header",
                name = "",
                order = 200,
            },
            
            exportBtn = {
                type = "execute",
                name = "Export Selected",
                order = 201,
                width = 1,
                func = function()
                    local result, err = ME.Export(uiState.selectedForExport)
                    if err then
                        print(MSG_PREFIX .. "|cffff0000Export failed:|r " .. err)
                        uiState.exportString = ""
                    else
                        uiState.exportString = result
                        print(MSG_PREFIX .. "|cff00ff00Master export successful!|r Copy the string below.")
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            exportString = {
                type = "input",
                name = "Export String",
                order = 202,
                multiline = 6,
                width = "full",
                get = function() return uiState.exportString end,
                set = function() end,
            },
            
            -- ═══════════════════════════════════════════════════════════════
            -- IMPORT SECTION
            -- ═══════════════════════════════════════════════════════════════
            importHeader = {
                type = "header",
                name = "Import",
                order = 210,
            },
            
            importString = {
                type = "input",
                name = "Paste Export String",
                order = 212,
                multiline = 6,
                width = "full",
                get = function() return uiState.importString end,
                set = function(_, val)
                    uiState.importString = val
                    local data, err = ME.ParseImportString(val)
                    if data then
                        uiState.importPreview = data
                        uiState.importError = nil
                        wipe(uiState.importActiveOverrides)
                        for specKey, specEntry in pairs(data.specs or {}) do
                            uiState.importActiveOverrides[specKey] = specEntry.activeProfile or nil
                        end
                        RebuildActiveProfileSelectors()
                    else
                        uiState.importPreview = nil
                        uiState.importError = err
                        wipe(uiState.importActiveOverrides)
                        RebuildActiveProfileSelectors()
                    end
                end,
            },
            
            previewBtn = {
                type = "execute",
                name = "Preview",
                order = 213,
                width = 0.5,
                func = function()
                    local data, err = ME.ParseImportString(uiState.importString)
                    if err then
                        uiState.importPreview = nil
                        uiState.importError = err
                        wipe(uiState.importActiveOverrides)
                        RebuildActiveProfileSelectors()
                        print(MSG_PREFIX .. "|cffff0000" .. err .. "|r")
                    else
                        uiState.importPreview = data
                        uiState.importError = nil
                        wipe(uiState.importActiveOverrides)
                        for specKey, specEntry in pairs(data.specs or {}) do
                            uiState.importActiveOverrides[specKey] = specEntry.activeProfile or nil
                        end
                        RebuildActiveProfileSelectors()
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            importPreviewText = {
                type = "description",
                name = function()
                    if uiState.importError then
                        return "|cffff0000Error:|r " .. uiState.importError
                    elseif uiState.importPreview then
                        return ME.GenerateImportPreview(uiState.importPreview)
                    else
                        return "|cff888888Paste a string and click Preview to see contents.|r"
                    end
                end,
                order = 214,
                fontSize = "medium",
            },
            
            activeProfileHeader = {
                type = "header",
                name = "Active Profile Per Spec",
                order = 214.1,
                hidden = function() return not uiState.importPreview end,
            },
            
            activeProfileDesc = {
                type = "description",
                name = "|cff888888Choose which profile becomes active for each spec after import.|r",
                order = 214.2,
                fontSize = "medium",
                hidden = function() return not uiState.importPreview end,
            },
            
            activeProfileSelectors = {
                type = "group",
                name = "",
                order = 214.3,
                inline = true,
                hidden = function() return not uiState.importPreview or not next(activeProfileSelectorArgs) end,
                args = activeProfileSelectorArgs,
            },
            
            importFilterHeader = {
                type = "description",
                name = "\n|cffffd700Choose which profiles to import:|r",
                order = 214.5,
                fontSize = "medium",
                hidden = function() return not uiState.importPreview or not next(importProfileFilterArgs) end,
            },
            importProfileFilter = {
                type = "group",
                name = "",
                order = 214.6,
                inline = true,
                hidden = function() return not uiState.importPreview or not next(importProfileFilterArgs) end,
                args = importProfileFilterArgs,
            },
            
            importModeSelect = {
                type = "select",
                name = "Import Mode",
                order = 215,
                width = 1.2,
                values = {
                    merge = "Merge (add alongside existing)",
                    replace = "Replace (wipe matching specs first)",
                },
                get = function() return uiState.importMode end,
                set = function(_, val) uiState.importMode = val end,
            },
            
            importModeDesc = {
                type = "description",
                name = function()
                    if uiState.importMode == "merge" then
                        return "|cff888888Conflicting names are auto-renamed.|r"
                    else
                        return "|cffff6600WARNING: Existing profiles for matching specs will be wiped!|r"
                    end
                end,
                order = 216,
            },
            
            importBtn = {
                type = "execute",
                name = "Import",
                order = 217,
                width = 0.5,
                disabled = function() return uiState.importPreview == nil end,
                func = function()
                    if not uiState.importPreview then
                        print(MSG_PREFIX .. "|cffff0000No valid import data.|r Paste a string and Preview first.")
                        return
                    end
                    local success, result = ME.Import(uiState.importPreview, uiState.importMode, uiState.importActiveOverrides, uiState.importSelectedProfiles)
                    if success then
                        print(MSG_PREFIX .. "|cff00ff00" .. result .. "|r")
                        uiState.importString = ""
                        uiState.importPreview = nil
                        uiState.importError = nil
                        wipe(uiState.importActiveOverrides)
                        wipe(activeProfileSelectorArgs)
                        StaticPopup_Show("ARCUI_MASTER_IMPORT_RELOAD")
                    else
                        print(MSG_PREFIX .. "|cffff0000Import failed:|r " .. (result or "Unknown error"))
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            clearImportBtn = {
                type = "execute",
                name = "Clear",
                order = 218,
                width = 0.5,
                func = function()
                    uiState.importString = ""
                    uiState.importPreview = nil
                    uiState.importError = nil
                    wipe(uiState.importActiveOverrides)
                    wipe(activeProfileSelectorArgs)
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            
            -- ═══════════════════════════════════════════════════════════════
            -- PENDING PROFILES
            -- ═══════════════════════════════════════════════════════════════
            pendingHeader = {
                type = "header",
                name = "Pending Profiles (Other Classes)",
                order = 230,
                hidden = function()
                    return not ns.db or not ns.db.global or not ns.db.global.masterCDMPending
                        or not next(ns.db.global.masterCDMPending or {})
                end,
            },
            
            pendingDesc = {
                type = "description",
                name = function()
                    if not ns.db or not ns.db.global or not ns.db.global.masterCDMPending then return "" end
                    local pending = ns.db.global.masterCDMPending
                    if not next(pending) then return "" end
                    
                    local lines = { "Auto-merge when you log the matching class:\n" }
                    for specKey, specEntry in pairs(pending) do
                        local displayName = GetSpecDisplayName(specKey, specEntry.specName)
                        local profileCount = 0
                        if specEntry.profiles then
                            for _ in pairs(specEntry.profiles) do profileCount = profileCount + 1 end
                        end
                        table.insert(lines, "  " .. displayName .. " |cff888888(" .. profileCount .. " profiles)|r")
                    end
                    return table.concat(lines, "\n")
                end,
                order = 231,
                fontSize = "medium",
                hidden = function()
                    return not ns.db or not ns.db.global or not ns.db.global.masterCDMPending
                        or not next(ns.db.global.masterCDMPending or {})
                end,
            },
            
            clearPendingBtn = {
                type = "execute",
                name = "Clear Pending",
                order = 232,
                width = 0.7,
                confirm = true,
                confirmText = "Delete all pending profiles for other classes?",
                hidden = function()
                    return not ns.db or not ns.db.global or not ns.db.global.masterCDMPending
                        or not next(ns.db.global.masterCDMPending or {})
                end,
                func = function()
                    if ns.db and ns.db.global then
                        ns.db.global.masterCDMPending = nil
                    end
                    print(MSG_PREFIX .. "|cffff8800Pending profiles cleared.|r")
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
        },
    }
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- BUILD PER-CHARACTER COLLAPSIBLE SECTIONS
    -- Uses CollapsibleHeader widget (same as CDMGroupsOptions)
    -- All collapsed by default
    -- ═══════════════════════════════════════════════════════════════════════════
    local allProfiles = ME.ScanAllProfiles()
    
    if #allProfiles == 0 then
        options.args["noProfiles"] = {
            type = "description",
            name = "|cff888888No Arc Manager profiles found across any character.|r",
            order = 13,
            hidden = function() return uiState.cdmProfilesCollapsed end,
        }
    else
        -- Group profiles by charKey
        local charOrder = {}
        local charProfiles = {}
        
        for _, entry in ipairs(allProfiles) do
            if not charProfiles[entry.charKey] then
                charProfiles[entry.charKey] = {}
                table.insert(charOrder, entry.charKey)
            end
            table.insert(charProfiles[entry.charKey], entry)
        end
        
        -- Default all characters to collapsed
        for _, charKey in ipairs(charOrder) do
            if uiState.collapsedChars[charKey] == nil then
                uiState.collapsedChars[charKey] = true
            end
        end
        
        -- Build a lookup: for shared specs, which characters are part of the sync?
        -- This lets us show "Shared: Arc, Testlov, Yeatest" in the header.
        local sharedCharsForSpec = {}  -- [specKey] = { "Arc", "Testlov", ... }
        if ns.db and ns.db.global and ns.db.global.sharedProfiles then
            local svChar = ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
            if svChar then
                for sk in pairs(ns.db.global.sharedProfiles) do
                    local names = {}
                    for ck, cd in pairs(svChar) do
                        if type(cd) == "table" and cd.cdmGroups and cd.cdmGroups.specData and cd.cdmGroups.specData[sk] then
                            table.insert(names, GetCharName(ck))
                        end
                    end
                    table.sort(names)
                    if #names > 0 then
                        sharedCharsForSpec[sk] = names
                    end
                end
            end
        end
        
        -- Create collapsible section per character
        local baseOrder = 13
        
        for charIdx, charKey in ipairs(charOrder) do
            local entries = charProfiles[charKey]
            local firstEntry = entries[1]
            local classInfo = CLASS_INFO[firstEntry.classID]
            local className = classInfo and classInfo.name or ("Class " .. firstEntry.classID)
            local classColor = classInfo and classInfo.color or "ffffffff"
            local charName = GetCharName(charKey)
            local cKey = charKey  -- capture for closures
            
            -- Count profiles and specs for collapsed summary
            local profileCount = #entries
            local specSet = {}
            for _, e in ipairs(entries) do specSet[e.specKey] = true end
            local specCount = 0
            for _ in pairs(specSet) do specCount = specCount + 1 end
            
            local charArgs = {}
            
            -- ── CollapsibleHeader toggle ──
            charArgs["_header"] = {
                type = "toggle",
                name = function()
                    local selCount = 0
                    for _, e in ipairs(entries) do
                        if uiState.selectedForExport[e.uniqueKey] then selCount = selCount + 1 end
                    end
                    local realm = GetRealmFromKey(cKey)
                    local realmSuffix = realm ~= "" and " |cff666666" .. realm .. "|r" or ""
                    local label = "|cffffd100" .. charName .. "|r" .. realmSuffix .. "  |c" .. classColor .. className .. "|r"
                    -- Check if any of this character's specs are shared
                    local sharedNames = nil
                    for _, e in ipairs(entries) do
                        if sharedCharsForSpec[e.specKey] then
                            sharedNames = sharedCharsForSpec[e.specKey]
                            break
                        end
                    end
                    if sharedNames and #sharedNames > 1 then
                        label = "|cffffd100" .. className .. "|r  |c" .. classColor .. "Shared|r |cff888888(" .. table.concat(sharedNames, ", ") .. ")|r"
                    end
                    if uiState.collapsedChars[cKey] then
                        label = label .. "  |cff666666(" .. profileCount .. " profiles, " .. specCount .. " specs)|r"
                    end
                    if selCount > 0 then
                        label = label .. "  |cff00ff00[" .. selCount .. " selected]|r"
                    end
                    return label
                end,
                desc = "Click to expand/collapse",
                dialogControl = "CollapsibleHeader",
                order = 0,
                width = "full",
                get = function() return not uiState.collapsedChars[cKey] end,
                set = function(_, v) uiState.collapsedChars[cKey] = not v end,
            }
            
            -- ── Spec headers and profile toggles (hidden when collapsed) ──
            local capturedEntries = entries  -- capture for closure
            charArgs["_selectAll"] = {
                type = "execute",
                name = "Select All",
                order = 0.1,
                width = 0.6,
                hidden = function() return uiState.collapsedChars[cKey] end,
                func = function()
                    for _, e in ipairs(capturedEntries) do
                        uiState.selectedForExport[e.uniqueKey] = true
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            }
            charArgs["_selectNone"] = {
                type = "execute",
                name = "Select None",
                order = 0.2,
                width = 0.6,
                hidden = function() return uiState.collapsedChars[cKey] end,
                func = function()
                    for _, e in ipairs(capturedEntries) do
                        uiState.selectedForExport[e.uniqueKey] = false
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            }
            
            local innerOrder = 1
            local lastSpecKey = nil
            
            for _, entry in ipairs(entries) do
                -- Spec sub-header
                if entry.specKey ~= lastSpecKey then
                    lastSpecKey = entry.specKey
                    charArgs["specHeader_" .. innerOrder] = {
                        type = "description",
                        name = "  |cff888888" .. entry.specName .. "|r",
                        order = innerOrder,
                        fontSize = "medium",
                        hidden = function() return uiState.collapsedChars[cKey] end,
                    }
                    innerOrder = innerOrder + 1
                end
                
                -- Profile toggle
                local detailStr = ""
                if entry.posCount > 0 or entry.iconSettingsCount > 0 then
                    local parts = {}
                    if entry.posCount > 0 then table.insert(parts, entry.posCount .. " icons") end
                    if entry.iconSettingsCount > 0 then table.insert(parts, entry.iconSettingsCount .. " styled") end
                    detailStr = " |cff666666[" .. table.concat(parts, ", ") .. "]|r"
                end
                
                -- Mark active profile for this spec/character
                local activeTag = ""
                if entry.sourceActiveProfile and entry.profileName == entry.sourceActiveProfile then
                    activeTag = " |cffffd100(Active)|r"
                end
                
                local uKey = entry.uniqueKey
                charArgs["profile_" .. innerOrder] = {
                    type = "toggle",
                    name = "    " .. entry.profileName .. activeTag .. detailStr,
                    order = innerOrder,
                    width = "full",
                    hidden = function() return uiState.collapsedChars[cKey] end,
                    get = function() return uiState.selectedForExport[uKey] or false end,
                    set = function(_, val) uiState.selectedForExport[uKey] = val end,
                }
                innerOrder = innerOrder + 1
            end
            
            options.args["char_" .. charIdx] = {
                type = "group",
                name = "",
                order = baseOrder + charIdx,
                inline = true,
                hidden = function() return uiState.cdmProfilesCollapsed end,
                args = charArgs,
            }
        end
    end

    -- Bar sections: Coming Soon (disabled for this release)

    return options
end

-- ═══════════════════════════════════════════════════════════════════
-- PROFILE BROWSER OPTIONS TABLE (own tab)
-- ═══════════════════════════════════════════════════════════════════
local function GetProfileBrowserOptionsTable()
    local args = {}

    args.browserDesc = {
        type = "description",
        name = "Browse, rename, or delete profiles across all characters and specs on this account.\n",
        order = 1,
        fontSize = "medium",
    }
    args.browserRefresh = {
        type = "execute",
        name = "Refresh",
        order = 2,
        width = 0.6,
        func = function()
            wipe(uiState.browserCollapsedChars)
            wipe(uiState.browserRenameValues)
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.browserExpandAll = {
        type = "execute",
        name = "Expand All",
        order = 3,
        width = 0.7,
        func = function()
            wipe(uiState.browserCollapsedChars)
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.browserCollapseAll = {
        type = "execute",
        name = "Collapse All",
        order = 4,
        width = 0.8,
        func = function()
            local allProfiles = ME.ScanAllProfiles()
            for _, e in ipairs(allProfiles) do
                uiState.browserCollapsedChars[e.charKey] = true
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }

    -- Group by character — use allChars so synced duplicates all show up
    local allProfiles = ME.ScanAllProfiles({ allChars = true })
    local charOrder = {}
    local charProfiles = {}
    for _, entry in ipairs(allProfiles) do
        if not charProfiles[entry.charKey] then
            charProfiles[entry.charKey] = {}
            table.insert(charOrder, entry.charKey)
        end
        table.insert(charProfiles[entry.charKey], entry)
    end

    -- Default collapsed
    for _, charKey in ipairs(charOrder) do
        if uiState.browserCollapsedChars[charKey] == nil then
            uiState.browserCollapsedChars[charKey] = true
        end
    end

    local baseOrder = 10
    for charIdx, charKey in ipairs(charOrder) do
        local entries = charProfiles[charKey]
        local firstEntry = entries[1]
        local classInfo = CLASS_INFO[firstEntry.classID]
        local className = classInfo and classInfo.name or ("Class " .. firstEntry.classID)
        local classColor = classInfo and classInfo.color or "ffffffff"
        local charName = GetCharName(charKey)
        local cKey = charKey

        local profileCount = #entries
        local specSet = {}
        for _, e in ipairs(entries) do specSet[e.specKey] = true end
        local specCount = 0
        for _ in pairs(specSet) do specCount = specCount + 1 end

        local charArgs = {}
        local cCharKey = charKey  -- capture for closures

        -- Purge character data button (for deleted/retired chars)
        charArgs["_purge"] = {
            type = "execute",
            name = "|cffff4444Delete Character|r",
            desc = "Delete ALL ArcUI data for this character. Use for deleted or retired characters.",
            order = -1,
            width = 0.9,
            hidden = function()
                -- Hide for the currently logged-in character
                local myKey = (UnitName("player") or "Unknown") .. " - " .. (GetRealmName() or "Unknown")
                return cCharKey == myKey or uiState.browserCollapsedChars[cCharKey] ~= false
            end,
            confirm = true,
            confirmText = "|cffff4444Delete ALL ArcUI data for " .. charName .. "?|r This cannot be undone.",
            func = function()
                local svChar = ns.db and ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
                if svChar and svChar[cCharKey] then svChar[cCharKey].cdmGroups = nil; svChar[cCharKey].arcAuras = nil end
                -- Clear from global sharedProfiles if they were source
                if ns.db and ns.db.global and ns.db.global.sharedProfiles then
                    for sk, ref in pairs(ns.db.global.sharedProfiles) do
                        if ref.sourceChar == cCharKey then ns.db.global.sharedProfiles[sk] = nil end
                    end
                end
                local db = ns.db and ns.db.char and ns.db.char.cdmGroups
                if db and db.initializedCharacters then db.initializedCharacters[cCharKey] = nil end
                print(MSG_PREFIX .. "|cffff4444Deleted|r all data for " .. charName)
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end,
        }

        -- Collapsible header (same style as Master Export)
        charArgs["_header"] = {
            type = "toggle",
            name = function()
                local realm = GetRealmFromKey(cKey)
                local realmSuffix = realm ~= "" and " |cff666666" .. realm .. "|r" or ""
                local label = "|cffffd100" .. charName .. "|r" .. realmSuffix .. "  |c" .. classColor .. className .. "|r"
                if uiState.browserCollapsedChars[cKey] then
                    label = label .. "  |cff666666(" .. profileCount .. " profiles, " .. specCount .. " specs)|r"
                end
                return label
            end,
            desc = "Click to expand/collapse",
            dialogControl = "CollapsibleHeader",
            order = 0,
            width = "full",
            get = function() return not uiState.browserCollapsedChars[cKey] end,
            set = function(_, v) uiState.browserCollapsedChars[cKey] = not v end,
        }

        local innerOrder = 1
        local lastSpecKey = nil

        for _, entry in ipairs(entries) do
            local eSpecKey = entry.specKey
            local eCharKey = entry.charKey
            local eProfileName = entry.profileName
            local renameStateKey = eCharKey .. "|" .. eSpecKey .. "|" .. eProfileName
            local argBase = "bp_" .. renameStateKey:gsub("[^%w]", "_")

            -- Spec sub-header (same style as Master Export)
            if eSpecKey ~= lastSpecKey then
                lastSpecKey = eSpecKey
                local specDisplayName = GetSpecDisplayName(eSpecKey, entry.specName)
                charArgs[argBase .. "_specHeader"] = {
                    type = "description",
                    name = "|cffaaaaaa" .. specDisplayName .. "|r",
                    order = innerOrder,
                    width = "full",
                    hidden = function() return uiState.browserCollapsedChars[cKey] end,
                }
                innerOrder = innerOrder + 1
            end

            -- Profile name inline with input + buttons (single row)
            charArgs[argBase .. "_label"] = {
                type = "description",
                name = "|cffffffff" .. eProfileName .. "|r  |cff555555(" .. entry.posCount .. " icons)|r",
                order = innerOrder,
                width = 1.4,
                hidden = function() return uiState.browserCollapsedChars[cKey] end,
            }
            charArgs[argBase .. "_rename"] = {
                type = "input",
                name = "",
                order = innerOrder + 0.1,
                width = 1.0,
                hidden = function() return uiState.browserCollapsedChars[cKey] end,
                get = function() return uiState.browserRenameValues[renameStateKey] or "" end,
                set = function(_, v) uiState.browserRenameValues[renameStateKey] = v end,
            }
            charArgs[argBase .. "_renameBtn"] = {
                type = "execute",
                name = "Rename",
                order = innerOrder + 0.2,
                width = 0.55,
                hidden = function() return uiState.browserCollapsedChars[cKey] end,
                func = function()
                    local newName = uiState.browserRenameValues[renameStateKey]
                    if not newName or newName == "" or newName == eProfileName then return end
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
                    if not svChar then return end
                    local charData = svChar[eCharKey]
                    if not charData then return end
                    local specData = charData.cdmGroups and charData.cdmGroups.specData and charData.cdmGroups.specData[eSpecKey]
                    if not specData or not specData.layoutProfiles then return end
                    if specData.layoutProfiles[newName] then
                        print(MSG_PREFIX .. "|cffff6600'" .. newName .. "' already exists.|r")
                        return
                    end
                    specData.layoutProfiles[newName] = specData.layoutProfiles[eProfileName]
                    specData.layoutProfiles[eProfileName] = nil
                    if specData.activeProfile == eProfileName then specData.activeProfile = newName end
                    uiState.browserRenameValues[renameStateKey] = nil
                    print(MSG_PREFIX .. "Renamed '" .. eProfileName .. "' → '" .. newName .. "'")
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            }
            charArgs[argBase .. "_delete"] = {
                type = "execute",
                name = "|cffff4444Delete|r",
                order = innerOrder + 0.3,
                width = 0.45,
                hidden = function() return uiState.browserCollapsedChars[cKey] end,
                confirm = true,
                confirmText = "Delete '" .. eProfileName .. "'? This cannot be undone.",
                func = function()
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char or (ArcUIDB and ArcUIDB.char)
                    if not svChar then return end
                    local charData = svChar[eCharKey]
                    if not charData then return end
                    local specData = charData.cdmGroups and charData.cdmGroups.specData and charData.cdmGroups.specData[eSpecKey]
                    if not specData or not specData.layoutProfiles then return end
                    specData.layoutProfiles[eProfileName] = nil
                    if specData.activeProfile == eProfileName then
                        specData.activeProfile = nil
                        for name in pairs(specData.layoutProfiles) do specData.activeProfile = name; break end
                    end
                    print(MSG_PREFIX .. "|cffff4444Deleted|r '" .. eProfileName .. "'")
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            }
            innerOrder = innerOrder + 1
            innerOrder = innerOrder + 1
        end

        args["char_" .. charIdx] = {
            type = "group",
            name = "",
            order = baseOrder + charIdx,
            inline = true,
            args = charArgs,
        }
    end

    return { type = "group", name = "Profile Browser", args = args }
end


function ns.GetCDMMasterExportOptionsTable()
    return GetOptionsTable()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UNIFIED IMPORT HELPER
-- Populates caller-owned args tables so the unified import window can show
-- the same per-spec active profile dropdowns and profile filter checkboxes
-- without sharing Master's module-level state tables.
--
-- outSelectorArgs   : table to wipe+fill with active-profile select widgets
-- outFilterArgs     : table to wipe+fill with profile filter toggle widgets
-- activeOverrides   : caller's table { [specKey] = chosenProfileName }
-- selectedProfiles  : caller's table { [specKey.."|"..profileName] = bool }
-- ═══════════════════════════════════════════════════════════════════════════
function ME.BuildImportSelectorArgs(data, activeOverrides, selectedProfiles, outSelectorArgs, outFilterArgs)
    wipe(outSelectorArgs)
    wipe(outFilterArgs)
    wipe(selectedProfiles)
    if not data or not data.specs then return end

    local _, _, myClassID = UnitClass("player")

    -- Sort specs
    local sorted = {}
    for specKey, specEntry in pairs(data.specs) do
        table.insert(sorted, { key = specKey, entry = specEntry })
    end
    table.sort(sorted, function(a, b)
        local ac = a.entry.classID or 99
        local bc = b.entry.classID or 99
        if ac ~= bc then return ac < bc end
        return (a.entry.specIndex or 99) < (b.entry.specIndex or 99)
    end)

    local filterOrder = 1
    local selectorOrder = 1

    for _, s in ipairs(sorted) do
        local specKey   = s.key
        local specEntry = s.entry
        local isMyClass = specEntry.classID == myClassID
        local specDisplayName = GetSpecDisplayName(specKey, specEntry.specName)

        -- Profile filter toggles (all specs)
        for profileName in pairs(specEntry.profiles or {}) do
            local fKey   = specKey .. "|" .. profileName
            selectedProfiles[fKey] = true
            local argKey = "impf_" .. fKey:gsub("[^%w]", "_")
            local cap_fKey = fKey
            outFilterArgs[argKey] = {
                type  = "toggle",
                name  = specDisplayName .. "  |cff888888" .. profileName .. "|r",
                order = filterOrder,
                width = "full",
                get = function() return selectedProfiles[cap_fKey] ~= false end,
                set = function(_, v) selectedProfiles[cap_fKey] = v end,
            }
            filterOrder = filterOrder + 1
        end

        -- Active profile dropdowns (my class only, only if >1 profile)
        if isMyClass then
            local profileValues = {}
            for pName in pairs(specEntry.profiles or {}) do
                profileValues[pName] = pName
            end
            local count = 0
            for _ in pairs(profileValues) do count = count + 1 end

            if count > 1 then
                local cap_specKey = specKey
                outSelectorArgs["active_" .. selectorOrder] = {
                    type   = "select",
                    name   = specDisplayName .. "  |cff888888Active Profile|r",
                    order  = selectorOrder,
                    width  = 1.5,
                    values = profileValues,
                    get = function() return activeOverrides[cap_specKey] end,
                    set = function(_, val) activeOverrides[cap_specKey] = val end,
                }
                selectorOrder = selectorOrder + 1
            end
        end
    end
end

function ns.GetCDMProfileBrowserOptionsTable()
    return GetProfileBrowserOptionsTable()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RELOAD POPUP
-- ═══════════════════════════════════════════════════════════════════════════

StaticPopupDialogs["ARCUI_MASTER_IMPORT_RELOAD"] = {
    text = "|cff00ccffArcUI|r Master import complete.\n\nReload UI to apply all changes?",
    button1 = "Reload Now",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT: Auto-apply pending on login
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(2, function()
            ME.AutoApplyPendingProfiles()
        end)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMAND
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCUIMASTEREXPORT1 = "/arcmaster"
SlashCmdList["ARCUIMASTEREXPORT"] = function()
    if ns.API and ns.API.OpenOptions then
        ns.API.OpenOptions()
        C_Timer.After(0.1, function()
            local ACD = LibStub("AceConfigDialog-3.0", true)
            if ACD then
                ACD:SelectGroup("ArcUI", "importExport", "masterExport")
            end
        end)
    else
        print(MSG_PREFIX .. "Options not available yet.")
    end
end