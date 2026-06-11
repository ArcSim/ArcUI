-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Shared Profiles (Reference-Based)
-- ═══════════════════════════════════════════════════════════════════════════
-- Syncs a profile across all characters of the same class+spec.
-- Enable once on any character, and every alt with sync enabled will
-- automatically receive the latest profile on login.
--
-- ZERO DUPLICATION: Only stores a reference (sourceChar + profileName +
-- timestamp) in global DB. On pull, reads directly from the source
-- character's SavedVariables data. ~100 bytes per spec.
--
-- Storage:
--   ns.db.global.sharedProfiles[specKey] = {
--       sourceChar  = "Arcmon - Xal'atath's Endgame",
--       profileName = "Rogue",
--       timestamp   = 1772588136,
--   }
--   ns.db.char.cdmGroups.sharedSync[specKey] = true/nil
--   ns.db.char.cdmGroups.sharedSyncTimestamp[specKey] = number
-- ═══════════════════════════════════════════════════════════════════════════

local _, ns = ...

local SP = {}
ns.CDMSharedProfiles = SP

local MSG_PREFIX = "|cff00CCFF[Arc Shared]|r "

-- ───────────────────────────────────────────────────────────────────────────
-- Utilities
-- ───────────────────────────────────────────────────────────────────────────

local function DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = DeepCopy(v)
    end
    return copy
end

local function GetCurrentSpecKey()
    return ns.CDMGroups and ns.CDMGroups.currentSpec
end

local function GetCDMGroupsDB()
    local Shared = ns.CDMShared
    if Shared and Shared.GetCDMGroupsDB then
        return Shared.GetCDMGroupsDB()
    end
    return ns.db and ns.db.char and ns.db.char.cdmGroups
end

local function GetCharKey()
    return (UnitName("player") or "Unknown") .. " - " .. (GetRealmName() or "Unknown")
end

--- Access raw SavedVariables for ALL characters (same as MasterExport).
local function GetAllCharData()
    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if not svChar then
        svChar = ArcUIDB and ArcUIDB.char
    end
    return svChar
end

--- Parse classID from a specKey like "class_7_spec_2"
local function ParseClassID(specKey)
    if not specKey then return nil end
    local classID = specKey:match("class_(%d+)_spec_")
    return tonumber(classID)
end

--- Get all specKeys for a given classID that exist in the current character's specData
local function GetAllSpecKeysForClass(classID)
    if not classID then return {} end
    local keys = {}
    -- Check current character's specData
    local db = GetCDMGroupsDB()
    if db and db.specData then
        for specKey in pairs(db.specData) do
            if ParseClassID(specKey) == classID then
                keys[#keys + 1] = specKey
            end
        end
    end
    -- Also check global sharedProfiles for specs we might not have locally yet
    if ns.db and ns.db.global and ns.db.global.sharedProfiles then
        for specKey in pairs(ns.db.global.sharedProfiles) do
            if ParseClassID(specKey) == classID then
                local found = false
                for _, k in ipairs(keys) do
                    if k == specKey then found = true; break end
                end
                if not found then keys[#keys + 1] = specKey end
            end
        end
    end
    -- Also generate known spec indices (1-4) for this class
    -- in case neither local nor global has all specs yet
    for specIdx = 1, 4 do
        local testKey = "class_" .. classID .. "_spec_" .. specIdx
        -- Validate it's a real spec
        if GetSpecializationInfoForClassID then
            local id = GetSpecializationInfoForClassID(classID, specIdx)
            if id then
                local found = false
                for _, k in ipairs(keys) do
                    if k == testKey then found = true; break end
                end
                if not found then keys[#keys + 1] = testKey end
            end
        end
    end
    table.sort(keys)
    return keys
end

--- Sync is always per-class: all chars of the same class share profiles per spec automatically.
local function GetSyncMode() return "per_class" end
local function SetSyncMode(_) end -- no-op, kept for compatibility

--- Read the source character's data for a shared reference.
local function ReadSourceData(ref)
    if not ref or not ref.sourceChar or not ref.profileName then return nil end
    
    local svChar = GetAllCharData()
    if not svChar then return nil end
    
    local charData = svChar[ref.sourceChar]
    if not charData then return nil end
    
    local specKey = ref.specKey
    if not specKey then return nil end
    
    local cdmGroups = charData.cdmGroups
    if not cdmGroups or not cdmGroups.specData then return nil end
    
    local specData = cdmGroups.specData[specKey]
    if not specData or not specData.layoutProfiles then return nil end
    
    local profile = specData.layoutProfiles[ref.profileName]
    if not profile then return nil end
    
    return {
        profile = profile,
        layoutProfiles = specData.layoutProfiles,
        groupSettings = specData.groupSettings,
        keepCDMStyle = specData.keepCDMStyle,
        disableTooltips = cdmGroups.disableTooltips,
        clickThrough = cdmGroups.clickThrough,
        arcAuras = charData.arcAuras,
        -- Bar data (all at char level, not per-spec)
        bars = charData.bars,
        cooldownBars = charData.cooldownBars,
        resourceBars = charData.resourceBars,
        timerBars = charData.timerBars,
        cooldownBarSetup = charData.cooldownBarSetup,
    }
end

local function PrintMsg(msg)
    print(MSG_PREFIX .. msg)
end

--- Rename the active profile to spec-only name (e.g. "Enhancement (Arc)" → "Enhancement")
--- so all alts converge on the same name when shared sync is on.
local function RenameActiveToSpecName(specKey)
    if not specKey then return end
    
    -- Build the spec-only name
    local specName = nil
    local classID, specIndex = specKey:match("class_(%d+)_spec_(%d+)")
    classID = tonumber(classID)
    specIndex = tonumber(specIndex)
    if GetSpecializationInfoForClassID and classID and specIndex then
        local _, apiName = GetSpecializationInfoForClassID(classID, specIndex)
        if apiName then specName = apiName end
    end
    if not specName then return end
    
    -- Rename in current character's specData
    local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(specKey)
    if specData and specData.layoutProfiles then
        local activeName = specData.activeProfile
        if activeName and activeName ~= specName and specData.layoutProfiles[activeName] and not specData.layoutProfiles[specName] then
            specData.layoutProfiles[specName] = specData.layoutProfiles[activeName]
            specData.layoutProfiles[activeName] = nil
            specData.activeProfile = specName
            if ns.CDMGroups then ns.CDMGroups.activeProfile = specName end
        end
    end
    
    -- Also rename in ALL characters' SavedVariables for this shared spec
    -- so master export / load layout see consistent names immediately
    local svChar = GetAllCharData()
    if not svChar then return end
    for _, charData in pairs(svChar) do
        if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
            local sd = charData.cdmGroups.specData[specKey]
            if sd and sd.layoutProfiles then
                local active = sd.activeProfile
                if active and active ~= specName and sd.layoutProfiles[active] and not sd.layoutProfiles[specName] then
                    sd.layoutProfiles[specName] = sd.layoutProfiles[active]
                    sd.layoutProfiles[active] = nil
                    sd.activeProfile = specName
                end
            end
        end
    end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Query Functions
-- ───────────────────────────────────────────────────────────────────────────

function SP.IsEnabled(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return false end
    local db = GetCDMGroupsDB()
    return db and db.sharedSync and db.sharedSync[specKey] or false
end

-- Returns true if global sync is on for this class but this char is explicitly detached
function SP.IsDetached(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return false end
    local classID = ParseClassID(specKey)
    -- Check if ANY spec of this class has a global ref (sync is active for the class)
    local classHasRef = false
    if ns.db and ns.db.global and ns.db.global.sharedProfiles then
        local allSpecs = classID and GetAllSpecKeysForClass(classID) or { specKey }
        for _, sk in ipairs(allSpecs) do
            if ns.db.global.sharedProfiles[sk] then
                classHasRef = true
                break
            end
        end
    end
    if not classHasRef then return false end
    -- Check if this char is explicitly disabled
    local db = GetCDMGroupsDB()
    local allSpecs = classID and GetAllSpecKeysForClass(classID) or { specKey }
    for _, sk in ipairs(allSpecs) do
        if db and db.sharedSyncDisabled and db.sharedSyncDisabled[sk] then
            return true
        end
    end
    return false
end

-- Re-attach this character to the class sync group
function SP.ReattachSelf(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return end
    local db = GetCDMGroupsDB()
    if not db then return end
    local classID = ParseClassID(specKey)
    local specsToReattach = classID and GetAllSpecKeysForClass(classID) or { specKey }
    if not db.sharedSync then db.sharedSync = {} end
    for _, sk in ipairs(specsToReattach) do
        if db.sharedSyncDisabled then db.sharedSyncDisabled[sk] = nil end
        db.sharedSync[sk] = true
    end
    -- Pull latest from source
    SP.CheckAndSync()
    PrintMsg("Re-attached to class sync group")
end

function SP.GetSharedRef(specKey)
    if not ns.db or not ns.db.global then return nil end
    if not ns.db.global.sharedProfiles then return nil end
    return ns.db.global.sharedProfiles[specKey]
end

function SP.GetSharedInfo(specKey)
    specKey = specKey or GetCurrentSpecKey()
    local ref = SP.GetSharedRef(specKey)
    if not ref then return nil end
    
    local refWithSpec = { sourceChar = ref.sourceChar, profileName = ref.profileName, specKey = specKey }
    local source = ReadSourceData(refWithSpec)
    
    local info = {
        sourceChar = ref.sourceChar,
        profileName = ref.profileName,
        timestamp = ref.timestamp,
        timeAgo = ref.timestamp and (time() - ref.timestamp) or nil,
        sourceValid = source ~= nil,
    }
    
    if source and source.profile then
        if source.profile.savedPositions then
            local count = 0
            for _ in pairs(source.profile.savedPositions) do count = count + 1 end
            info.iconCount = count
        end
        if source.profile.groupLayouts then
            local count = 0
            for _ in pairs(source.profile.groupLayouts) do count = count + 1 end
            info.groupCount = count
        end
    end
    
    -- Count all profiles from source
    if source and source.layoutProfiles then
        local names = {}
        for pName in pairs(source.layoutProfiles) do
            table.insert(names, pName)
        end
        table.sort(names)
        info.profileCount = #names
        info.profileNames = names
    end
    
    return info
end

-- ───────────────────────────────────────────────────────────────────────────
-- Enable / Disable
-- ───────────────────────────────────────────────────────────────────────────

function SP.SetEnabled(specKey, enabled)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return end
    
    local db = GetCDMGroupsDB()
    if not db then return end
    if not db.sharedSync then db.sharedSync = {} end
    
    -- Determine which specs to toggle
    local specsToToggle = { specKey }
    local classID = ParseClassID(specKey)
    if classID then specsToToggle = GetAllSpecKeysForClass(classID) end
    
    if enabled then
        local charKey = GetCharKey()
        for _, sk in ipairs(specsToToggle) do
            db.sharedSync[sk] = true
            if db.sharedSyncDisabled then db.sharedSyncDisabled[sk] = nil end
            -- Clear global disabled flag so new chars of this class can auto-enable again
            if ns.db and ns.db.global and ns.db.global.sharedSyncDisabled then
                ns.db.global.sharedSyncDisabled[sk] = nil
            end
            
            -- Rename active profile to spec-only name (drop character name)
            -- so all alts converge on the same profile name
            RenameActiveToSpecName(sk)
            
            local ref = SP.GetSharedRef(sk)
            if ref and ref.sourceChar and ref.sourceChar ~= charKey then
                -- Pull from existing source
                SP.Pull(sk)
            else
                -- We're the source (or first to enable) — push
                SP.Push(sk)
            end
        end
        PrintMsg("Enabled shared sync for all specs of this class (" .. #specsToToggle .. " specs)")
    else
        if not db.sharedSyncDisabled then db.sharedSyncDisabled = {} end
        if ns.db and ns.db.global then
            if not ns.db.global.sharedSyncDisabled then ns.db.global.sharedSyncDisabled = {} end
        end
        for _, sk in ipairs(specsToToggle) do
            db.sharedSync[sk] = nil
            db.sharedSyncDisabled[sk] = true
            -- Delete global ref so new chars won't see it and auto-enable
            if ns.db and ns.db.global and ns.db.global.sharedProfiles then
                ns.db.global.sharedProfiles[sk] = nil
            end
            -- Set global disabled flag so new chars of this class don't auto-enable
            if ns.db and ns.db.global and ns.db.global.sharedSyncDisabled then
                ns.db.global.sharedSyncDisabled[sk] = true
            end
        end
        -- Clear sharedSync on ALL existing characters for these specs
        -- so no lingering auto-pulls happen on other warriors
        local svChar = GetAllCharData()
        if svChar then
            for _, charData in pairs(svChar) do
                local cd = charData and charData.cdmGroups
                if cd and cd.sharedSync then
                    for _, sk in ipairs(specsToToggle) do
                        cd.sharedSync[sk] = nil
                        if not cd.sharedSyncDisabled then cd.sharedSyncDisabled = {} end
                        cd.sharedSyncDisabled[sk] = true
                    end
                end
            end
        end
        PrintMsg("Disabled shared sync for all specs of this class — all characters updated")
    end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Push (store reference only — ~100 bytes)
-- ───────────────────────────────────────────────────────────────────────────

function SP.Push(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return end
    if not ns.db then return end
    
    -- Determine which specs to push
    local specsToPush = { specKey }
    local classID = ParseClassID(specKey)
    if classID then specsToPush = GetAllSpecKeysForClass(classID) end
    
    if not ns.db.global then ns.db.global = {} end
    if not ns.db.global.sharedProfiles then ns.db.global.sharedProfiles = {} end
    
    local now = time()
    local db = GetCDMGroupsDB()
    local pushed = 0
    
    for _, sk in ipairs(specsToPush) do
        -- Ensure active profile uses spec-only name for shared consistency
        RenameActiveToSpecName(sk)
        
        local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(sk)
        if specData then
            local activeProfileName = specData.activeProfile or "Default"
            local profile = specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
            if profile then
                ns.db.global.sharedProfiles[sk] = {
                    sourceChar = GetCharKey(),
                    profileName = activeProfileName,
                    timestamp = now,
                }
                if db then
                    if not db.sharedSyncTimestamp then db.sharedSyncTimestamp = {} end
                    db.sharedSyncTimestamp[sk] = now
                end
                pushed = pushed + 1
            end
        end
    end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Pull (read from source character's SavedVariables, copy into local)
-- ───────────────────────────────────────────────────────────────────────────

function SP.Pull(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return false end
    
    local ref = SP.GetSharedRef(specKey)
    if not ref then return false end
    
    local db = GetCDMGroupsDB()
    if not db then return false end
    
    if not db.sharedSyncTimestamp then db.sharedSyncTimestamp = {} end
    local localTS = db.sharedSyncTimestamp[specKey] or 0
    if ref.timestamp and ref.timestamp <= localTS then
        return false
    end
    
    local refWithSpec = { sourceChar = ref.sourceChar, profileName = ref.profileName, specKey = specKey }
    local source = ReadSourceData(refWithSpec)
    if not source or not source.profile then
        PrintMsg("|cffff8800Source data not found for " .. (ref.sourceChar or "?") .. " / " .. (ref.profileName or "?") .. "|r")
        return false
    end
    
    local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(specKey)
    if not specData then return false end
    if not specData.layoutProfiles then specData.layoutProfiles = {} end
    
    local profileName = ref.profileName or "Default"
    
    -- Sync ALL profiles from source character, not just the active one.
    -- This means if the source has "Enhancement", "PvP", "Mythic+", the alt gets all three.
    local sourceProfileNames = {}
    if source.layoutProfiles then
        for pName, pData in pairs(source.layoutProfiles) do
            specData.layoutProfiles[pName] = DeepCopy(pData)
            sourceProfileNames[pName] = true
        end
    end
    
    -- Clean up orphan profiles: remove any alt-created profiles that
    -- don't exist in the source's set. Shared sync = source is authoritative.
    for pName in pairs(specData.layoutProfiles) do
        if not sourceProfileNames[pName] then
            specData.layoutProfiles[pName] = nil
        end
    end
    
    -- Don't auto-switch activeProfile — each character may have different
    -- talent conditions or states. Sync the profile DATA but let the user
    -- keep whatever profile they had active. Only set if alt has no valid active.
    local currentActive = specData.activeProfile
    if not currentActive or not specData.layoutProfiles[currentActive] then
        specData.activeProfile = profileName
    end
    
    if source.groupSettings then
        specData.groupSettings = DeepCopy(source.groupSettings)
    end

    if source.keepCDMStyle ~= nil then
        specData.keepCDMStyle = source.keepCDMStyle or nil
    end
    
    if source.disableTooltips ~= nil then
        db.disableTooltips = source.disableTooltips
    end
    if source.clickThrough ~= nil then
        db.clickThrough = source.clickThrough
    end
    
    -- ─── Sync Arc Auras tracked spells (source is authoritative) ────────────────
    -- When shared sync is on, the source's spell config (forceShow, showOnSpecs,
    -- talentConditions, etc.) overwrites the alt's. New spells added, existing
    -- updated, removed spells cleaned.
    if source.arcAuras and source.arcAuras.trackedSpells then
        local arcDB = ns.db.char and ns.db.char.arcAuras
        if arcDB then
            if not arcDB.trackedSpells then arcDB.trackedSpells = {} end
            -- Replace all spell configs from source
            for arcID, config in pairs(source.arcAuras.trackedSpells) do
                arcDB.trackedSpells[arcID] = DeepCopy(config)
            end
            -- Remove spells that source no longer has
            local toRemove = {}
            for arcID in pairs(arcDB.trackedSpells) do
                if not source.arcAuras.trackedSpells[arcID] then
                    toRemove[#toRemove + 1] = arcID
                end
            end
            for _, arcID in ipairs(toRemove) do
                arcDB.trackedSpells[arcID] = nil
            end
        end
    end
    
    -- ─── Merge Arc Auras tracked items (only if placed in source profiles) ─
    -- Build a set of item arcIDs that appear in any of the source's
    -- profile savedPositions. Skip items the source hasn't placed yet.
    if source.arcAuras and source.arcAuras.trackedItems and source.layoutProfiles then
        local placedItems = {}
        for _, pData in pairs(source.layoutProfiles) do
            if pData.savedPositions then
                for arcID in pairs(pData.savedPositions) do
                    if type(arcID) == "string" and arcID:find("^arc_item_") then
                        placedItems[arcID] = true
                    end
                end
            end
        end
        
        local arcDB = ns.db.char and ns.db.char.arcAuras
        if arcDB then
            if not arcDB.trackedItems then arcDB.trackedItems = {} end
            for arcID, config in pairs(source.arcAuras.trackedItems) do
                if placedItems[arcID] and not config.isAutoTrackSlot then
                    arcDB.trackedItems[arcID] = DeepCopy(config)
                end
            end
        end
    end
    
    -- ─── Apply auto-track SETTINGS ───────────────────────────────────
    if source.arcAuras then
        local arcDB = ns.db.char and ns.db.char.arcAuras
        if arcDB then
            if source.arcAuras.autoTrackEquippedTrinkets ~= nil then
                arcDB.autoTrackEquippedTrinkets = source.arcAuras.autoTrackEquippedTrinkets
            end
            if source.arcAuras.autoTrackSlots then
                arcDB.autoTrackSlots = DeepCopy(source.arcAuras.autoTrackSlots)
            end
            if source.arcAuras.onlyOnUseTrinkets ~= nil then
                arcDB.onlyOnUseTrinkets = source.arcAuras.onlyOnUseTrinkets
            end
        end
    end
    
    -- ─── Sync bars (if bar sync toggle is on) ─────────────────────────
    -- Copies buff/debuff bars, cooldown bars, resource bars, timer bars,
    -- and active spell lists from the source character.
    -- ─── Bar sync DISABLED for now ─────────────────────────────────
    -- Bar syncing works but needs schema migration for legacy configs
    -- (e.g. resource bars missing 'height' field). Re-enable in a future version.
    -- if SP.IsBarSyncEnabled() and ns.db and ns.db.char then
    --     ...
    -- end
    
    db.sharedSyncTimestamp[specKey] = ref.timestamp
    
    local CDMShared = ns.CDMShared
    if CDMShared and CDMShared.ClearDBCache then
        CDMShared.ClearDBCache()
    end
    if ns.CDMEnhance and ns.CDMEnhance.InvalidateCache then
        ns.CDMEnhance.InvalidateCache()
    end
    if ns.CDMGroups and ns.CDMGroups.RefreshCachedLayoutSettings then
        ns.CDMGroups.RefreshCachedLayoutSettings()
    end
    
    local syncedCount = 0
    if source.layoutProfiles then
        for _ in pairs(source.layoutProfiles) do syncedCount = syncedCount + 1 end
    end

    
    -- Only LoadProfile + RestorePositions for the currently active spec
    -- (per-class mode pulls all specs, but we only want to reload the one we're on)
    -- NOTE: Do NOT call RefreshAllFrames here — it destroys frames and wipes
    -- savedPositions, causing items to lose their synced positions. Items are
    -- already created during Enable() with correct positions from the synced profile.
    local currentSpec = GetCurrentSpecKey()
    if specKey == currentSpec and ns.CDMGroups and ns.CDMGroups.LoadProfile then
        C_Timer.After(0.3, function()
            -- Use the alt's own activeProfile (not the source's)
            local activeToLoad = specData.activeProfile or profileName
            ns.CDMGroups.LoadProfile(activeToLoad)
            
            -- Reposition arc aura frames using the freshly synced savedPositions
            C_Timer.After(0.5, function()
                if ns.CDMGroups.RestoreArcAurasPositions then
                    ns.CDMGroups.RestoreArcAurasPositions("[SharedPull]")
                end
                -- Sync spell+item frames: create new, destroy removed, update configs
                if ns.ArcAuras and ns.ArcAuras.SyncAfterSharedPull then
                    ns.ArcAuras.SyncAfterSharedPull()
                end
                -- Bar rebuild DISABLED for now
                -- if SP.IsBarSyncEnabled() and ns.CooldownBars then
                --     ...
                -- end
            end)
        end)
    end
    
    return true
end

-- ───────────────────────────────────────────────────────────────────────────
-- Auto-Sync on Login
-- ───────────────────────────────────────────────────────────────────────────

function SP.CheckAndSync()
    local specKey = GetCurrentSpecKey()
    if not specKey then return end
    
    -- Determine which specs to sync
    local specsToSync = { specKey }
    local classID = ParseClassID(specKey)
    if classID then specsToSync = GetAllSpecKeysForClass(classID) end
    
    local pulled = false
    for _, sk in ipairs(specsToSync) do
        -- Rename to spec-only name if shared sync is on (keeps names consistent)
        if SP.IsEnabled(sk) then
            RenameActiveToSpecName(sk)
        end
        
        -- ─── Auto-enable: if a shared ref exists, enable sync ──
        if not SP.IsEnabled(sk) then
            local db = GetCDMGroupsDB()
            local explicitlyDisabled = (db and db.sharedSyncDisabled and db.sharedSyncDisabled[sk])
                or (ns.db and ns.db.global and ns.db.global.sharedSyncDisabled and ns.db.global.sharedSyncDisabled[sk])
            if not explicitlyDisabled then
                local ref = SP.GetSharedRef(sk)
                if ref and ref.sourceChar then
                    local charKey = GetCharKey()
                    if ref.sourceChar ~= charKey then
                        if db then
                            if not db.sharedSync then db.sharedSync = {} end
                            db.sharedSync[sk] = true
                            -- Auto-enable: notify options panel so toggle shows as checked
                            C_Timer.After(0, function()
                                local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
                                if reg then reg:NotifyChange("ArcUI") end
                            end)
                        end
                    end
                end
            end
        end
        
        -- ─── Pull if newer OR if this char has no profile data yet ──
        if SP.IsEnabled(sk) then
            local ref = SP.GetSharedRef(sk)
            if ref then
                local db = GetCDMGroupsDB()
                if db then
                    if not db.sharedSyncTimestamp then db.sharedSyncTimestamp = {} end
                    local localTS = db.sharedSyncTimestamp[sk] or 0
                    -- Force pull if no local profile data exists (new char, never synced)
                    local hasLocalData = false
                    if db.specData and db.specData[sk] and db.specData[sk].layoutProfiles then
                        hasLocalData = next(db.specData[sk].layoutProfiles) ~= nil
                    end
                    if (ref.timestamp and ref.timestamp > localTS) or not hasLocalData then
                        SP.Pull(sk)
                        if sk == specKey then pulled = true end
                    end
                end
            end
        end
    end
    
    -- ─── Default group template: disabled for this patch ─────────────────
    -- if not pulled then
    --     SP.ApplyDefaultTemplate(specKey)
    -- end
end

-- ───────────────────────────────────────────────────────────────────────────
-- Default Group Template
-- ───────────────────────────────────────────────────────────────────────────
-- Stores a reference (~100 bytes) to a source profile whose groupLayouts
-- (positions, sizes, grid config, visibility, borders) are copied into
-- brand-new characters on first login. Spells are NOT copied — CDM fills
-- them in automatically.
-- ───────────────────────────────────────────────────────────────────────────

--- Set a profile as the default group template for all new characters.
function SP.SetDefaultTemplate(sourceChar, specKey, profileName)
    if not ns.db or not ns.db.global then return end
    ns.db.global.defaultGroupTemplate = {
        sourceChar = sourceChar or GetCharKey(),
        specKey = specKey or GetCurrentSpecKey(),
        profileName = profileName,
    }
    PrintMsg("Set default group template: '" .. (profileName or "?") .. "' from " .. (sourceChar or GetCharKey()))
end

--- Clear the default group template.
function SP.ClearDefaultTemplate()
    if ns.db and ns.db.global then
        ns.db.global.defaultGroupTemplate = nil
    end
    PrintMsg("Cleared default group template")
end

--- Get current default template info.
function SP.GetDefaultTemplateInfo()
    if not ns.db or not ns.db.global then return nil end
    local tmpl = ns.db.global.defaultGroupTemplate
    if not tmpl then return nil end
    
    -- Validate source exists
    local svChar = GetAllCharData()
    local valid = false
    if svChar and tmpl.sourceChar then
        local charData = svChar[tmpl.sourceChar]
        if charData and charData.cdmGroups and charData.cdmGroups.specData then
            local specData = charData.cdmGroups.specData[tmpl.specKey]
            if specData and specData.layoutProfiles and specData.layoutProfiles[tmpl.profileName] then
                local profile = specData.layoutProfiles[tmpl.profileName]
                if profile.groupLayoutName or (profile.groupLayouts and next(profile.groupLayouts)) then
                    valid = true
                end
            end
        end
    end
    
    return {
        sourceChar = tmpl.sourceChar,
        specKey = tmpl.specKey,
        profileName = tmpl.profileName,
        valid = valid,
    }
end

--- Apply default group template to a spec if its active profile has no groupLayouts.
function SP.ApplyDefaultTemplate(specKey)
    -- DISABLED: Not shipping in this patch
    return
end
--[[ DISABLED BODY:
function SP.ApplyDefaultTemplate(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return end
    if not ns.db or not ns.db.global then return end
    
    local tmpl = ns.db.global.defaultGroupTemplate
    if not tmpl then return end
    
    -- Only apply if current profile has NO groupLayouts (brand-new or empty)
    local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(specKey)
    if not specData then return end
    if not specData.layoutProfiles then return end
    
    local activeProfileName = specData.activeProfile or "Default"
    local profile = specData.layoutProfiles[activeProfileName]
    if not profile then return end
    
    -- Skip if profile already has groups OR is linked to a Group Layout
    if profile.groupLayoutName then return end
    if profile.groupLayouts and next(profile.groupLayouts) then return end
    
    -- Read template source
    local svChar = GetAllCharData()
    if not svChar or not tmpl.sourceChar then return end
    local charData = svChar[tmpl.sourceChar]
    if not charData or not charData.cdmGroups or not charData.cdmGroups.specData then return end
    
    local sourceSpecData = charData.cdmGroups.specData[tmpl.specKey]
    if not sourceSpecData or not sourceSpecData.layoutProfiles then return end
    local sourceProfile = sourceSpecData.layoutProfiles[tmpl.profileName]
    if not sourceProfile or not sourceProfile.groupLayouts or not next(sourceProfile.groupLayouts) then return end
    
    -- Copy ONLY groupLayouts (positions, sizes, grid config). NOT savedPositions/freeIcons/iconSettings.
    profile.groupLayouts = DeepCopy(sourceProfile.groupLayouts)
    
    local groupCount = 0
    for _ in pairs(profile.groupLayouts) do groupCount = groupCount + 1 end
    PrintMsg("Applied default group template (" .. groupCount .. " groups) from '" .. tmpl.profileName .. "'")
end
--]] -- END DISABLED BODY

-- ───────────────────────────────────────────────────────────────────────────
-- Push Hooks (debounced)
-- ───────────────────────────────────────────────────────────────────────────

local pushTimer = nil
local PUSH_DEBOUNCE = 3.0

function SP.DebouncedPush()
    local specKey = GetCurrentSpecKey()
    if not specKey then return end
    if not SP.IsEnabled(specKey) then return end
    
    if pushTimer then pushTimer:Cancel() end
    pushTimer = C_Timer.NewTimer(PUSH_DEBOUNCE, function()
        pushTimer = nil
        SP.Push(specKey)
    end)
end

function SP.OnProfileSaved()
    SP.DebouncedPush()
end

-- ───────────────────────────────────────────────────────────────────────────
-- Hook Setup
-- ───────────────────────────────────────────────────────────────────────────

local hooksInstalled = false

local function InstallHooks()
    if hooksInstalled then return end
    if not ns.CDMGroups then return end
    
    if ns.CDMGroups.SaveCurrentToProfile then
        hooksecurefunc(ns.CDMGroups, "SaveCurrentToProfile", function()
            SP.OnProfileSaved()
        end)
    end
    
    if ns.CDMGroups.TriggerTemplateAutoSave then
        hooksecurefunc(ns.CDMGroups, "TriggerTemplateAutoSave", function()
            SP.OnProfileSaved()
        end)
    end
    
    hooksInstalled = true
end

-- ───────────────────────────────────────────────────────────────────────────
-- Delete Shared Data
-- ───────────────────────────────────────────────────────────────────────────

function SP.DeleteSharedData(specKey)
    specKey = specKey or GetCurrentSpecKey()
    if not specKey then return end

    local specsToDelete = { specKey }
    local classID = ParseClassID(specKey)
    if classID then specsToDelete = GetAllSpecKeysForClass(classID) end

    -- Delete global refs and set global disabled so new chars don't auto-enable
    if ns.db and ns.db.global then
        if not ns.db.global.sharedSyncDisabled then ns.db.global.sharedSyncDisabled = {} end
        for _, sk in ipairs(specsToDelete) do
            if ns.db.global.sharedProfiles then
                ns.db.global.sharedProfiles[sk] = nil
            end
            ns.db.global.sharedSyncDisabled[sk] = true
        end
    end

    -- Clear sharedSync and sharedSyncTimestamp on ALL characters for these specs
    local svChar = GetAllCharData()
    if svChar then
        for _, charData in pairs(svChar) do
            local cd = charData and charData.cdmGroups
            if cd then
                if not cd.sharedSyncDisabled then cd.sharedSyncDisabled = {} end
                for _, sk in ipairs(specsToDelete) do
                    if cd.sharedSync then cd.sharedSync[sk] = nil end
                    cd.sharedSyncDisabled[sk] = true
                    if cd.sharedSyncTimestamp then cd.sharedSyncTimestamp[sk] = nil end
                end
            end
        end
    end

    PrintMsg("Deleted shared references — sync disabled for all characters of this class")
end

--- Detach a specific character from the shared group.
--- Their profiles are untouched; they just stop pushing/receiving updates.
--- charKey: the full "Name - Realm" key of the character to detach.
function SP.DetachCharacter(charKey)
    if not charKey then return end
    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if not svChar then svChar = ArcUIDB and ArcUIDB.char end
    if not svChar or not svChar[charKey] then
        PrintMsg("|cffff8800Character data not found: " .. charKey .. "|r")
        return
    end
    local cd = svChar[charKey].cdmGroups
    if not cd then return end
    -- Clear sharedSync and mark explicitly disabled for this character only
    -- Global ref and all other characters are untouched — class sync continues for them
    if not cd.sharedSyncDisabled then cd.sharedSyncDisabled = {} end
    if cd.sharedSync then
        for sk, v in pairs(cd.sharedSync) do
            if v then cd.sharedSyncDisabled[sk] = true end
        end
        cd.sharedSync = {}
    end
    local charName = charKey:match("^([^%-]+)") or charKey
    PrintMsg(charName .. " detached from shared sync.")
end

--- Fully purge all ArcUI data for a character from SavedVariables.
--- Use for deleted characters or characters you want a clean slate for.
function SP.PurgeCharacterData(charKey)
    if not charKey then return end
    local myCharKey = GetCharKey()
    if charKey == myCharKey then
        PrintMsg("|cffff0000Cannot purge your own character.|r")
        return
    end
    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if not svChar then svChar = ArcUIDB and ArcUIDB.char end
    if svChar and svChar[charKey] then svChar[charKey].cdmGroups = nil; svChar[charKey].arcAuras = nil end
    -- Remove from global sharedProfiles if they were the source
    if ns.db and ns.db.global and ns.db.global.sharedProfiles then
        for sk, ref in pairs(ns.db.global.sharedProfiles) do
            if ref.sourceChar == charKey then
                ns.db.global.sharedProfiles[sk] = nil
            end
        end
    end
    -- Remove from initializedCharacters
    local db = GetCDMGroupsDB()
    if db and db.initializedCharacters then
        db.initializedCharacters[charKey] = nil
    end
    local charName = charKey:match("^([^%-]+)") or charKey
    PrintMsg("|cffff4444Deleted|r all data for " .. charName)
end


function SP.GetSyncedChars()
    local sk = GetCurrentSpecKey()
    if not sk then return {} end
    local classID = ParseClassID(sk)
    if not classID then return {} end

    local svChar = ns.db and ns.db.sv and ns.db.sv.char
    if not svChar then svChar = ArcUIDB and ArcUIDB.char end
    if not svChar then return {} end

    local sharedRef = ns.db and ns.db.global and ns.db.global.sharedProfiles and ns.db.global.sharedProfiles[sk]
    local sourceChar = sharedRef and sharedRef.sourceChar
    local myCharKey = GetCharKey()

    local results = {}
    for charKey, charData in pairs(svChar) do
        if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
            -- Only include chars that have spec data for this class
            local hasClassData = false
            for specIdx = 1, 4 do
                if charData.cdmGroups.specData["class_" .. classID .. "_spec_" .. specIdx] then
                    hasClassData = true; break
                end
            end
            if hasClassData then
                local cd = charData.cdmGroups
                local syncedSpecCount = 0
                for specIdx = 1, 4 do
                    local testKey = "class_" .. classID .. "_spec_" .. specIdx
                    local on = cd.sharedSync and cd.sharedSync[testKey]
                    local off = cd.sharedSyncDisabled and cd.sharedSyncDisabled[testKey]
                    if on and not off then syncedSpecCount = syncedSpecCount + 1 end
                end
                local isSource = (charKey == sourceChar)
                local isDetachedChar = false
                for specIdx = 1, 4 do
                    local testKey = "class_" .. classID .. "_spec_" .. specIdx
                    if cd.sharedSyncDisabled and cd.sharedSyncDisabled[testKey] then
                        isDetachedChar = true; break
                    end
                end
                results[#results + 1] = {
                    charKey = charKey,
                    charName = charKey:match("^([^%-]+)") or charKey,
                    isSource = isSource,
                    isSelf = (charKey == myCharKey),
                    isSynced = syncedSpecCount > 0 or isSource,
                    isDetached = isDetachedChar,
                }
            end
        end
    end
    table.sort(results, function(a, b) return a.charName < b.charName end)
    return results
end


-- ───────────────────────────────────────────────────────────────────────────
-- Public Sync Mode Accessors
-- ───────────────────────────────────────────────────────────────────────────

-- Bar sync toggle - DISABLED for now (needs schema migration)
function SP.IsBarSyncEnabled()
    return false  -- disabled pending schema migration work
end

function SP.SetBarSyncEnabled(enabled)
    local db = GetCDMGroupsDB()
    if not db then return end
    db.sharedSyncBars = enabled or false
end

-- ───────────────────────────────────────────────────────────────────────────
-- Options Table
-- ───────────────────────────────────────────────────────────────────────────

function SP.GetOptionsTable()
    return {
        type = "group",
        name = "Sharing",
        order = 900,
        args = {
            description = {
                type = "description",
                name = "Sync profiles and Arc Auras across all same-class characters. "
                    .. "Profiles are shared per spec automatically — enable once and all alts stay in sync.\n\n"
                    .. "|cffff9900First Pass — this feature is new and may have rough edges. "
                    .. "If you run into any issues please report them in the Discord.|r\n",
                order = 1,
                fontSize = "medium",
            },
            barSync = {
                type = "toggle",
                name = "Sync Bars",
                desc = "Also sync buff/debuff, cooldown, resource, and timer bars.",
                order = 2.5,
                width = 0.7,
                hidden = true,  -- DISABLED: needs schema migration work
                get = function() return SP.IsBarSyncEnabled() end,
                set = function(_, val)
                    SP.SetBarSyncEnabled(val)
                end,
            },
            enableToggle = {
                type = "toggle",
                name = function()
                    local sk = GetCurrentSpecKey()
                    if sk then
                        local classID = ParseClassID(sk)
                        if classID then
                            local className = C_CreatureInfo and C_CreatureInfo.GetClassInfo and C_CreatureInfo.GetClassInfo(classID)
                            if className then
                                return "Enable for all " .. className.className .. " specs"
                            end
                        end
                    end
                    return "Enable for all specs"
                end,
                desc = "Sync all specs for this class across same-class characters automatically.",
                order = 3,
                width = "full",
                get = function()
                    -- Show as enabled if sync is on OR if this char is detached
                    -- (class sync is active globally even if this char opted out)
                    return SP.IsEnabled() or SP.IsDetached()
                end,
                set = function(_, val)
                    SP.SetEnabled(nil, val)
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            detachToggle = {
                type = "toggle",
                name = "Detached (this character)",
                desc = "When checked, this character is excluded from class sync. Other characters are unaffected.",
                order = 3.5,
                width = "full",
                hidden = function()
                    local sk = GetCurrentSpecKey()
                    if not sk then return true end
                    -- Only show when global sync is active for this class (ref exists)
                    local classID = ParseClassID(sk)
                    local allSpecs = classID and GetAllSpecKeysForClass(classID) or { sk }
                    if ns.db and ns.db.global and ns.db.global.sharedProfiles then
                        for _, s in ipairs(allSpecs) do
                            if ns.db.global.sharedProfiles[s] then return false end
                        end
                    end
                    return true
                end,
                get = function()
                    return SP.IsDetached()
                end,
                set = function(_, val)
                    if val then
                        -- Detach just this character
                        local charKey = GetCharKey()
                        SP.DetachCharacter(charKey)
                    else
                        -- Re-attach this character
                        SP.ReattachSelf()
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            statusInfo = {
                type = "description",
                name = function()
                    local sk = GetCurrentSpecKey()
                    if not sk then return "" end
                    
                    local specsToShow = { sk }
                    local classID = ParseClassID(sk)
                    if classID then specsToShow = GetAllSpecKeysForClass(classID) end
                    
                    local lines = { "" }
                    for _, specKeyToShow in ipairs(specsToShow) do
                        local info = SP.GetSharedInfo(specKeyToShow)
                        local specLabel = specKeyToShow
                        local cID, sIdx = specKeyToShow:match("class_(%d+)_spec_(%d+)")
                        cID = tonumber(cID)
                        sIdx = tonumber(sIdx)
                        if GetSpecializationInfoForClassID and cID and sIdx then
                            local _, apiName = GetSpecializationInfoForClassID(cID, sIdx)
                            if apiName then specLabel = apiName end
                        end
                        
                        if info then
                            local timeStr = info.timestamp and date("%b %d %I:%M%p", info.timestamp) or "?"
                            local src = info.sourceChar and info.sourceChar:match("^([^%-]+)") or "?"
                            table.insert(lines, "|cffffd100" .. specLabel .. ":|r " .. (info.profileName or "?") .. "  from " .. src .. "  (" .. timeStr .. ")")
                            if not info.sourceValid then
                                table.insert(lines, "  |cffff8800Source not found.|r")
                            end
                        else
                            if SP.IsEnabled(specKeyToShow) then
                                table.insert(lines, "|cffffd100" .. specLabel .. ":|r |cff888888Waiting for first sync...|r")
                            end
                        end
                    end
                    return table.concat(lines, "\n")
                end,
                order = 4,
                fontSize = "medium",
                hidden = function()
                    local sk = GetCurrentSpecKey()
                    return not sk or not SP.IsEnabled(sk)
                end,
            },
            forcePush = {
                type = "execute",
                name = "Push",
                desc = "Push your current data to the shared reference.",
                order = 10,
                width = 0.5,
                func = function()
                    SP.Push()
                    PrintMsg("Pushed shared reference(s)")
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
            },
            forcePull = {
                type = "execute",
                name = "Pull",
                desc = "Pull the latest shared data, overwriting your local copy.",
                order = 11,
                width = 0.5,
                func = function()
                    local db = GetCDMGroupsDB()
                    local sk = GetCurrentSpecKey()
                    if not db or not sk then return end
                    
                    local specsToPull = { sk }
                    local pullClassID = ParseClassID(sk)
                    if pullClassID then specsToPull = GetAllSpecKeysForClass(pullClassID) end
                    
                    if not db.sharedSyncTimestamp then db.sharedSyncTimestamp = {} end
                    local pulledAny = false
                    for _, pullSk in ipairs(specsToPull) do
                        db.sharedSyncTimestamp[pullSk] = 0
                        if SP.Pull(pullSk) then pulledAny = true end
                    end
                    if not pulledAny then
                        PrintMsg("No shared data found to pull")
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
            },
            deleteShared = {
                type = "execute",
                name = "Delete",
                desc = "Remove shared references. Local profiles are not affected.",
                order = 12,
                width = 0.5,
                func = function()
                    SP.DeleteSharedData()
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    -- Force toggle to reflect disabled state
                    C_Timer.After(0, function()
                        local reg = LibStub and LibStub("AceConfigRegistry-3.0", true)
                        if reg then reg:NotifyChange("ArcUI") end
                    end)
                end,
                hidden = function()
                    local sk = GetCurrentSpecKey()
                    return not sk or not SP.GetSharedRef(sk)
                end,
                confirm = true,
                confirmText = "Delete shared references? Local profiles are not affected.",
            },
            
            -- ═══════════════════════════════════════════════════════════
            -- SYNCED CHARACTERS
            -- ═══════════════════════════════════════════════════════════
            syncedCharsHeader = {
                type = "header",
                name = "Synced Characters",
                order = 13,
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
            },
            syncedCharsList = {
                type = "description",
                order = 13.1,
                fontSize = "medium",
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
                name = function()
                    local chars = SP.GetSyncedChars()
                    if #chars == 0 then return "|cff888888No characters found for this class.|r\n" end
                    local lines = { "" }
                    for _, c in ipairs(chars) do
                        local label
                        if c.isSelf and c.isDetached then
                            label = "|cffff8800" .. c.charName .. " (you — detached)|r"
                        elseif c.isSelf then
                            label = "|cff00ff00" .. c.charName .. " (you)|r"
                        elseif c.isDetached then
                            label = "|cffff8800" .. c.charName .. " (detached)|r"
                        elseif c.isSynced and c.isSource then
                            label = "|cffffd100" .. c.charName .. " [source]|r"
                        elseif c.isSynced then
                            label = "|cffcccccc" .. c.charName .. "|r"
                        else
                            label = "|cff666666" .. c.charName .. " (not synced)|r"
                        end
                        table.insert(lines, label)
                    end
                    table.insert(lines, "")
                    return table.concat(lines, "\n")
                end,
            },
            syncedCharSelect = {
                type = "select",
                name = "Character",
                desc = "Select a character to detach or purge.",
                order = 13.2,
                width = 1.6,
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
                values = function()
                    local vals = { [""] = "|cff666666Select...|r" }
                    local chars = SP.GetSyncedChars()
                    for _, c in ipairs(chars) do
                        local label = c.charName
                        if c.isSelf then label = label .. " (you)" end
                        if c.isSource then label = label .. " [source]" end
                        if not c.isSynced then label = "|cff666666" .. label .. " (not synced)|r" end
                        vals[c.charKey] = label
                    end
                    return vals
                end,
                get = function() return ns._detachCharSelected or "" end,
                set = function(_, val) ns._detachCharSelected = val ~= "" and val or nil end,
            },
            syncedCharDetach = {
                type = "execute",
                name = "Detach",
                desc = "Stop this character receiving or pushing sync updates. Profiles are kept.",
                order = 13.3,
                width = 0.55,
                hidden = function() return not SP.IsEnabled() and not SP.IsDetached() end,
                disabled = function()
                    if not ns._detachCharSelected then return true end
                    local chars = SP.GetSyncedChars()
                    for _, c in ipairs(chars) do
                        if c.charKey == ns._detachCharSelected then return not c.isSynced end
                    end
                    return true
                end,
                func = function()
                    local sel = ns._detachCharSelected
                    if not sel then return end
                    SP.DetachCharacter(sel)
                    ns._detachCharSelected = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
                confirm = function()
                    local sel = ns._detachCharSelected
                    if not sel then return false end
                    local name = sel:match("^([^%-]+)") or sel
                    return "Detach " .. name .. " from shared sync? Their profiles will not be changed."
                end,
            },


            -- ═══════════════════════════════════════════════════════════
            -- QUICK COPY FROM ALT
            -- ═══════════════════════════════════════════════════════════
            copyHeader = {
                type = "header",
                name = "Copy Profile from Character",
                order = 15,
            },
            copyDesc = {
                type = "description",
                name = "Grab a same-spec profile from any character.\n",
                order = 15.1,
                fontSize = "medium",
            },
            copySelect = {
                type = "select",
                name = "Profile",
                order = 16,
                width = 2.2,
                values = function()
                    local vals = { [""] = "|cff666666Select...|r" }
                    local ME = ns.CDMMasterExport
                    if not ME or not ME.ScanAllProfiles then return vals end

                    local sk = GetCurrentSpecKey()
                    if not sk then return vals end
                    local myCharKey = GetCharKey()

                    -- Build spec display name
                    local specLabel = sk
                    local cID, sIdx = sk:match("class_(%d+)_spec_(%d+)")
                    if GetSpecializationInfoForClassID and tonumber(cID) and tonumber(sIdx) then
                        local _, apiName = GetSpecializationInfoForClassID(tonumber(cID), tonumber(sIdx))
                        if apiName then specLabel = apiName end
                    end

                    local allProfiles = ME.ScanAllProfiles({ allChars = true })
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char

                    -- Build the set of charKeys that are part of the shared group for this spec.
                    -- A char is shared if: sharedSync[sk]=true OR it is the sourceChar in the global ref.
                    local sharedRef = ns.db and ns.db.global and ns.db.global.sharedProfiles and ns.db.global.sharedProfiles[sk]
                    local sharedCharSet = {}
                    if svChar then
                        for charKey, charData in pairs(svChar) do
                            if type(charData) == "table" and charData.cdmGroups then
                                local cd = charData.cdmGroups
                                local syncOn = cd.sharedSync and cd.sharedSync[sk]
                                local disabled = cd.sharedSyncDisabled and cd.sharedSyncDisabled[sk]
                                if syncOn and not disabled then
                                    sharedCharSet[charKey] = true
                                end
                            end
                        end
                    end
                    -- Also include sourceChar regardless of flag (they pushed the ref)
                    if sharedRef and sharedRef.sourceChar then
                        sharedCharSet[sharedRef.sourceChar] = true
                    end

                    -- Separate shared vs non-shared chars for this spec
                    local sharedChars = {}     -- charKey -> true
                    local sharedProfileMap = {} -- profileName -> srcChar (deduplicated)
                    local nonSharedEntries = {}

                    for _, entry in ipairs(allProfiles) do
                        local _, entrySpecKey = entry.uniqueKey:match("^(.-)%|(.-)%|(.+)$")
                        if entrySpecKey == sk and entry.charKey ~= myCharKey then
                            local isShared = sharedCharSet[entry.charKey] or false

                            if isShared then
                                sharedChars[entry.charKey] = true
                                if not sharedProfileMap[entry.profileName] then
                                    local srcChar = (sharedRef and sharedRef.sourceChar) or entry.charKey
                                    sharedProfileMap[entry.profileName] = srcChar
                                end
                            else
                                nonSharedEntries[#nonSharedEntries + 1] = entry
                            end
                        end
                    end

                    -- Count shared chars and add deduplicated entries
                    local sharedCount = 0
                    for _ in pairs(sharedChars) do sharedCount = sharedCount + 1 end

                    if sharedCount > 0 then
                        local groupLabel = specLabel .. " (" .. sharedCount .. " Shared)"
                        for profName, srcChar in pairs(sharedProfileMap) do
                            local key = srcChar .. "|" .. sk .. "|" .. profName
                            vals[key] = groupLabel .. "  ·  " .. profName
                        end
                    end

                    -- Non-shared chars listed individually
                    for _, entry in ipairs(nonSharedEntries) do
                        local charName = entry.charKey:match("^([^%-]+)") or entry.charKey
                        local label = charName .. "  ·  " .. entry.specName .. "  ·  " .. entry.profileName
                        vals[entry.uniqueKey] = label
                    end

                    return vals
                end,
                get = function() return ns._quickCopySelected or "" end,
                set = function(_, val) ns._quickCopySelected = val ~= "" and val or nil end,
            },
            copyBtn = {
                type = "execute",
                name = "Copy",
                desc = "Copy this profile into your current spec. Existing profiles are not affected.",
                order = 17,
                width = 0.5,
                disabled = function() return not ns._quickCopySelected or ns._quickCopySelected == "" end,
                func = function()
                    local sel = ns._quickCopySelected
                    if not sel or sel == "" then return end
                    
                    -- Parse key: "charKey|specKey|profileName"
                    local srcCharKey, srcSpecKey, srcProfileName = sel:match("^(.-)%|(.-)%|(.+)$")
                    if not srcCharKey or not srcSpecKey or not srcProfileName then
                        PrintMsg("|cffff0000Invalid selection.|r")
                        return
                    end
                    
                    -- Read source data
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char
                    if not svChar then svChar = ArcUIDB and ArcUIDB.char end
                    if not svChar then
                        PrintMsg("|cffff0000SavedVariables not available.|r")
                        return
                    end
                    
                    local srcData = svChar[srcCharKey]
                    if not srcData or not srcData.cdmGroups or not srcData.cdmGroups.specData then
                        PrintMsg("|cffff0000Source character data not found.|r")
                        return
                    end
                    
                    local srcSpecData = srcData.cdmGroups.specData[srcSpecKey]
                    if not srcSpecData or not srcSpecData.layoutProfiles or not srcSpecData.layoutProfiles[srcProfileName] then
                        PrintMsg("|cffff0000Source profile not found.|r")
                        return
                    end
                    
                    -- Write to the SOURCE's spec (not necessarily current spec)
                    -- e.g. copying a Demo profile goes into Demo spec data even if you're on Affliction
                    local targetSpecKey = srcSpecKey
                    
                    local db = GetCDMGroupsDB()
                    if not db or not db.specData then
                        PrintMsg("|cffff0000No local spec data.|r")
                        return
                    end
                    
                    if not db.specData[targetSpecKey] then
                        db.specData[targetSpecKey] = { layoutProfiles = {}, groupSettings = {} }
                    end
                    local mySpecData = db.specData[targetSpecKey]
                    if not mySpecData.layoutProfiles then mySpecData.layoutProfiles = {} end
                    
                    -- Pick a name (rename on conflict)
                    local targetName = srcProfileName
                    if mySpecData.layoutProfiles[targetName] then
                        local srcChar = srcCharKey:match("^([^%-]+)") or srcCharKey
                        targetName = srcProfileName .. " (" .. srcChar .. ")"
                        local i = 2
                        while mySpecData.layoutProfiles[targetName] do
                            targetName = srcProfileName .. " (" .. srcChar .. " " .. i .. ")"
                            i = i + 1
                        end
                    end
                    
                    -- Copy the profile
                    mySpecData.layoutProfiles[targetName] = DeepCopy(srcSpecData.layoutProfiles[srcProfileName])
                    
                    -- Copy group settings if target spec doesn't have any
                    if srcSpecData.groupSettings and (not mySpecData.groupSettings or not next(mySpecData.groupSettings)) then
                        mySpecData.groupSettings = DeepCopy(srcSpecData.groupSettings)
                    end
                    
                    -- Copy Arc Auras (merge — add missing spells/items from source)
                    local arcDB = ns.db and ns.db.char and ns.db.char.arcAuras
                    if arcDB and srcData.arcAuras then
                        local srcArc = srcData.arcAuras
                        local spellCount, itemCount = 0, 0
                        
                        if srcArc.trackedSpells then
                            if not arcDB.trackedSpells then arcDB.trackedSpells = {} end
                            for arcID, config in pairs(srcArc.trackedSpells) do
                                if not arcDB.trackedSpells[arcID] then
                                    arcDB.trackedSpells[arcID] = DeepCopy(config)
                                    spellCount = spellCount + 1
                                end
                            end
                        end
                        
                        if srcArc.trackedItems then
                            if not arcDB.trackedItems then arcDB.trackedItems = {} end
                            for arcID, config in pairs(srcArc.trackedItems) do
                                -- Skip auto-track trinkets (equipment-based, not profile data)
                                if not config.isAutoTrackSlot and not arcDB.trackedItems[arcID] then
                                    arcDB.trackedItems[arcID] = DeepCopy(config)
                                    itemCount = itemCount + 1
                                end
                            end
                        end
                        
                        if spellCount + itemCount > 0 then
                            PrintMsg("Added " .. spellCount .. " spell(s), " .. itemCount .. " item(s) from Arc Auras")
                        end
                    end
                    
                    -- Only load immediately if the copied profile matches current spec
                    local currentSk = GetCurrentSpecKey()
                    if targetSpecKey == currentSk and ns.CDMGroups and ns.CDMGroups.LoadProfile then
                        mySpecData.activeProfile = targetName
                        ns.CDMGroups.LoadProfile(targetName)
                        
                        -- Sync Arc Auras frames (create new spells/items from copied data)
                        if ns.ArcAuras and ns.ArcAuras.SyncAfterSharedPull then
                            C_Timer.After(0.3, function()
                                ns.ArcAuras.SyncAfterSharedPull()
                                if ns.CDMGroups and ns.CDMGroups.RestoreArcAurasPositions then
                                    ns.CDMGroups.RestoreArcAurasPositions("[QuickCopy]")
                                end
                            end)
                        end
                    end
                    
                    -- Get spec display name for message
                    local specLabel = srcSpecKey
                    local cID, sIdx = srcSpecKey:match("class_(%d+)_spec_(%d+)")
                    if GetSpecializationInfoForClassID and tonumber(cID) and tonumber(sIdx) then
                        local _, apiName = GetSpecializationInfoForClassID(tonumber(cID), tonumber(sIdx))
                        if apiName then specLabel = apiName end
                    end
                    
                    ns._quickCopySelected = nil
                    if targetSpecKey == currentSk then
                        PrintMsg("Copied |cff00ff00" .. srcProfileName .. "|r as |cff00ff00" .. targetName .. "|r (now active)")
                    else
                        PrintMsg("Copied |cff00ff00" .. srcProfileName .. "|r as |cff00ff00" .. targetName .. "|r into " .. specLabel .. " (switch spec to use it)")
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    StaticPopup_Show("ARCUI_MASTER_IMPORT_RELOAD")
                end,
                confirm = function()
                    local sel = ns._quickCopySelected
                    if not sel then return false end
                    local _, _, name = sel:match("^(.-)%|(.-)%|(.+)$")
                    return "Copy '" .. (name or "?") .. "' into your current spec and make it active?"
                end,
            },
            
            -- ═══════════════════════════════════════════════════════════
            -- GROUP LAYOUTS MANAGER
            -- ═══════════════════════════════════════════════════════════
            groupLayoutsHeader = {
                type = "header",
                name = "Group Layouts",
                order = 30,
            },
            groupLayoutsDesc = {
                type = "description",
                name = "Account-wide group layouts shared across all characters and specs. "
                    .. "Profiles can live-link to a layout — saves go straight to the shared layout, no copies needed.\n",
                order = 30.1,
                fontSize = "medium",
            },
            groupLayoutsDefaultStatus = {
                type = "description",
                name = function()
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if not db or not next(db) then
                        return "|cff666666No Group Layouts created yet.|r"
                    end
                    local count = 0
                    for _ in pairs(db) do count = count + 1 end
                    return count .. " layout" .. (count == 1 and "" or "s")
                end,
                order = 30.2,
                width = "full",
                fontSize = "small",
            },
            -- Create new layout
            groupLayoutsNewName = {
                type = "input",
                name = "New Layout Name",
                desc = "Name for the new Group Layout. Will be seeded from your current active profile's groups.",
                order = 31,
                width = 1.2,
                get = function() return ns._glNewLayoutName or "" end,
                set = function(_, val) ns._glNewLayoutName = val ~= "" and val or nil end,
            },
            groupLayoutsCreateBtn = {
                type = "execute",
                name = "Create Layout",
                desc = "Create a new layout seeded from your current profile's groups.",
                order = 31.1,
                width = 0.75,
                disabled = function()
                    local name = ns._glNewLayoutName
                    if not name or name == "" then return true end
                    -- Don't allow duplicate names
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return db and db[name] ~= nil
                end,
                func = function()
                    local name = ns._glNewLayoutName
                    if not name or name == "" then return end
                    -- Save current groups first so snapshot is fresh
                    if ns.CDMGroups and ns.CDMGroups.SaveGroupLayoutsToActiveProfile then
                        ns.CDMGroups.SaveGroupLayoutsToActiveProfile()
                    end
                    -- Get current profile's groupLayouts as seed
                    local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData()
                    local activeProfileName = (specData and specData.activeProfile) or "Default"
                    local profile = specData and specData.layoutProfiles and specData.layoutProfiles[activeProfileName]
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        -- Seed from linked global layout if linked, else own groupLayouts
                        local _seedSrc = nil
                        if profile and profile.groupLayoutName and db[profile.groupLayoutName] then
                            _seedSrc = db[profile.groupLayoutName]
                        elseif profile and profile.groupLayouts and next(profile.groupLayouts) then
                            _seedSrc = profile.groupLayouts
                        end
                        if _seedSrc then
                            local copy = {}
                            for k, v in pairs(_seedSrc) do
                                copy[k] = v
                            end
                            db[name] = copy
                        else
                            db[name] = {}
                        end
                    end
                    ns._glNewLayoutName = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    print("|cff00ccffArcUI|r: Group Layout '" .. name .. "' created.")
                end,
                confirm = function()
                    local name = ns._glNewLayoutName
                    if not name or name == "" then return false end
                    return "Create Group Layout '" .. name .. "' from your current active profile's groups?"
                end,
            },
            groupLayoutsNewDupeNote = {
                type = "description",
                name = "|cffff8800A layout with that name already exists.|r",
                order = 31.2,
                width = "full",
                fontSize = "small",
                hidden = function()
                    local name = ns._glNewLayoutName
                    if not name or name == "" then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not (db and db[name])
                end,
            },
            -- Manage existing layouts
            groupLayoutsManageHeader = {
                type = "description",
                name = "|cffd4af37Manage Existing Layouts|r",
                order = 32,
                width = "full",
                fontSize = "medium",
                hidden = function()
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not db or not next(db)
                end,
            },
            groupLayoutsSelect = {
                type = "select",
                name = "Layout",
                desc = "Select a Group Layout to manage.",
                order = 32.1,
                width = 1.4,
                hidden = function()
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not db or not next(db)
                end,
                values = function()
                    local vals = { [""] = "|cff666666Select...|r" }
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        local svChar = ns.db and ns.db.sv and ns.db.sv.char
                        for layoutName in pairs(db) do
                            -- Count how many profiles are linked to this layout
                            local linkedCount = 0
                            if svChar then
                                for _, charData in pairs(svChar) do
                                    local cd = charData and charData.cdmGroups
                                    if cd and cd.specData then
                                        for _, specData in pairs(cd.specData) do
                                            if type(specData) == "table" and specData.layoutProfiles then
                                                for _, prof in pairs(specData.layoutProfiles) do
                                                    if type(prof) == "table" and prof.groupLayoutName == layoutName then
                                                        linkedCount = linkedCount + 1
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            if linkedCount > 0 then
                                vals[layoutName] = layoutName .. " |cff888888(" .. linkedCount .. " linked)|r"
                            else
                                vals[layoutName] = layoutName .. " |cff666666(none linked)|r"
                            end
                        end
                    end
                    return vals
                end,
                sorting = function()
                    local order = { "" }
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if db then
                        for name in pairs(db) do
                            order[#order + 1] = name
                        end
                    end
                    return order
                end,
                get = function()
                    if ns._glManageSelected then return ns._glManageSelected end
                    local linked = ns.CDMGroups and ns.CDMGroups.GetActiveProfileGroupLayoutName and ns.CDMGroups.GetActiveProfileGroupLayoutName()
                    return linked or ""
                end,
                set = function(_, val) ns._glManageSelected = val ~= "" and val or nil end,
            },
            groupLayoutsLinkedChars = {
                type = "description",
                name = function()
                    local sel = ns._glManageSelected
                    if not sel or sel == "" then return "" end
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char
                    if not svChar then return "|cff666666No characters found.|r" end
                    local lines = {}
                    for charKey, charData in pairs(svChar) do
                        local cd = charData and charData.cdmGroups
                        if cd and cd.specData then
                            for specKey, specData in pairs(cd.specData) do
                                if type(specData) == "table" and specData.layoutProfiles then
                                    for profName, prof in pairs(specData.layoutProfiles) do
                                        if type(prof) == "table" and prof.groupLayoutName == sel then
                                            local charName = charKey:match("^([^%-]+)") or charKey
                                            local cID, sIdx = specKey:match("class_(%d+)_spec_(%d+)")
                                            local specLabel = specKey
                                            if GetSpecializationInfoForClassID and tonumber(cID) and tonumber(sIdx) then
                                                local _, apiName = GetSpecializationInfoForClassID(tonumber(cID), tonumber(sIdx))
                                                if apiName then specLabel = apiName end
                                            end
                                            lines[#lines + 1] = "|cffcccccc" .. charName .. "|r |cff888888" .. specLabel .. " — " .. profName .. "|r"
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if #lines == 0 then return "|cff666666No profiles linked to this layout.|r" end
                    return table.concat(lines, "\n")
                end,
                order = 32.2,
                width = "full",
                fontSize = "small",
                hidden = function()
                    return not ns._glManageSelected or ns._glManageSelected == ""
                end,
            },
            groupLayoutsRenameInput = {
                type = "input",
                name = "Rename To",
                order = 32.3,
                width = 1.2,
                hidden = function() return not ns._glManageSelected or ns._glManageSelected == "" end,
                get = function() return ns._glRenameLayoutName or "" end,
                set = function(_, val) ns._glRenameLayoutName = val ~= "" and val or nil end,
            },
            groupLayoutsRenameBtn = {
                type = "execute",
                name = "Rename",
                desc = "Rename this layout and update all linked profiles.",
                order = 32.31,
                width = 0.5,
                hidden = function() return not ns._glManageSelected or ns._glManageSelected == "" end,
                disabled = function()
                    local newName = ns._glRenameLayoutName
                    if not newName or newName == "" then return true end
                    if newName == ns._glManageSelected then return true end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return db and db[newName] ~= nil
                end,
                func = function()
                    local sel = ns._glManageSelected
                    local newName = ns._glRenameLayoutName
                    if not sel or not newName or newName == "" or newName == sel then return end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    if not db or not db[sel] then return end
                    -- Move layout data to new name
                    db[newName] = db[sel]
                    db[sel] = nil
                    -- Update all linked profiles across all characters
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char
                    if svChar then
                        for _, charData in pairs(svChar) do
                            local cd = charData and charData.cdmGroups
                            if cd and cd.specData then
                                for _, specData in pairs(cd.specData) do
                                    if type(specData) == "table" and specData.layoutProfiles then
                                        for _, prof in pairs(specData.layoutProfiles) do
                                            if type(prof) == "table" and prof.groupLayoutName == sel then
                                                prof.groupLayoutName = newName
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    ns._glManageSelected = newName
                    ns._glRenameLayoutName = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    print("|cff00ccffArcUI|r: Layout renamed to '" .. newName .. "'.")
                end,
                confirm = function()
                    local sel = ns._glManageSelected
                    local newName = ns._glRenameLayoutName
                    if not sel or not newName then return false end
                    return "Rename '" .. sel .. "' to '" .. newName .. "'?"
                end,
            },
            groupLayoutsDeleteBtn = {
                type = "execute",
                name = "Delete Layout",
                desc = "Delete this layout — all linked profiles will take an independent snapshot.",
                order = 32.4,
                width = 0.8,
                hidden = function()
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    return not db or not next(db)
                end,
                disabled = function() return not ns._glManageSelected or ns._glManageSelected == "" end,
                func = function()
                    local sel = ns._glManageSelected
                    if not sel or sel == "" then return end
                    local db = ns.CDMShared and ns.CDMShared.GetGroupLayoutsDB and ns.CDMShared.GetGroupLayoutsDB()
                    local globalLayout = db and db[sel]

                    -- Snapshot layout into every linked profile across all characters in SV
                    local svChar = ns.db and ns.db.sv and ns.db.sv.char
                    if svChar and globalLayout then
                        for charKey, charData in pairs(svChar) do
                            if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
                                for specKey, specData in pairs(charData.cdmGroups.specData) do
                                    if type(specData) == "table" and specData.layoutProfiles then
                                        for profName, prof in pairs(specData.layoutProfiles) do
                                            if type(prof) == "table" and prof.groupLayoutName == sel then
                                                -- Snapshot global layout into own storage
                                                local snapshot = {}
                                                for gName, gData in pairs(globalLayout) do
                                                    snapshot[gName] = DeepCopy(gData)
                                                end
                                                -- Preserve own positions on top of snapshot
                                                if prof.groupLayouts then
                                                    for gName, ownData in pairs(prof.groupLayouts) do
                                                        if snapshot[gName] and ownData.position then
                                                            snapshot[gName].position = ownData.position
                                                        end
                                                    end
                                                end
                                                prof.groupLayouts = snapshot
                                                prof.groupLayoutName = nil
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end

                    -- Delete the layout from global
                    if db then db[sel] = nil end

                    ns._glManageSelected = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                    print("|cff00ccffArcUI|r: Group Layout '" .. sel .. "' deleted. All linked profiles snapshotted.")
                end,
                confirm = function()
                    local sel = ns._glManageSelected
                    if not sel then return false end
                    return "Delete Group Layout '" .. sel .. "'?\n\nAll linked profiles across all characters will receive a snapshot and become independent."
                end,
            },

            -- ═══════════════════════════════════════════════════════════
            -- DEFAULT GROUP TEMPLATE
            -- ═══════════════════════════════════════════════════════════
            templateHeader = {
                type = "header",
                name = "Default Group Template",
                order = 20,
                hidden = true,  -- DISABLED: needs more testing
            },
            templateDesc = {
                type = "description",
                name = "Set a profile's group layout as the default for new characters. "
                    .. "Only the layout is copied — spells fill in automatically.\n",
                order = 21,
                fontSize = "medium",
                hidden = true,
            },
            templateStatus = {
                type = "description",
                name = function()
                    local info = SP.GetDefaultTemplateInfo()
                    if not info then
                        return "|cff888888No default template set.|r"
                    end
                    local status = info.valid and "|cff00ff00Valid|r" or "|cffff8800Source not found|r"
                    return "|cffffd100Template:|r " .. (info.profileName or "?")
                        .. "  |  |cffffd100Source:|r " .. (info.sourceChar or "?")
                        .. "  |  " .. status
                end,
                order = 22,
                fontSize = "medium",
                hidden = true,
            },
            templateSelectProfile = {
                type = "select",
                name = "Profile",
                desc = "Select a profile to use as the default group layout for new characters.",
                order = 23,
                width = 2.2,
                hidden = true,
                values = function()
                    local vals = { [""] = "|cff666666Select a profile...|r" }
                    local IE = ns.CDMImportExport
                    if IE and IE.GetAvailableProfiles then
                        local profiles = IE.GetAvailableProfiles()
                        for _, p in ipairs(profiles) do
                            vals[p.key] = p.displayName
                        end
                    end
                    local sk = GetCurrentSpecKey()
                    if sk then
                        local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(sk)
                        if specData then
                            local activeName = specData.activeProfile or "Default"
                            local selfKey = GetCharKey() .. "||" .. sk .. "||" .. activeName
                            if not vals[selfKey] then
                                vals[selfKey] = "|cff00ff00" .. activeName .. " (current)|r"
                            end
                        end
                    end
                    return vals
                end,
                sorting = function()
                    local order = { "" }
                    local sk = GetCurrentSpecKey()
                    if sk then
                        local specData = ns.CDMGroups and ns.CDMGroups.GetSpecData and ns.CDMGroups.GetSpecData(sk)
                        if specData then
                            local activeName = specData.activeProfile or "Default"
                            local selfKey = GetCharKey() .. "||" .. sk .. "||" .. activeName
                            order[#order + 1] = selfKey
                        end
                    end
                    local IE = ns.CDMImportExport
                    if IE and IE.GetAvailableProfiles then
                        local profiles = IE.GetAvailableProfiles()
                        for _, p in ipairs(profiles) do
                            order[#order + 1] = p.key
                        end
                    end
                    return order
                end,
                get = function() return ns._sharedTemplateSelected or "" end,
                set = function(_, val) ns._sharedTemplateSelected = val ~= "" and val or nil end,
            },
            templateSetBtn = {
                type = "execute",
                name = "|cff00ff00Set as Default|r",
                desc = "Use the selected profile as the default layout for new characters.",
                order = 24,
                width = 0.7,
                hidden = true,
                disabled = function() return not ns._sharedTemplateSelected or ns._sharedTemplateSelected == "" end,
                func = function()
                    local sel = ns._sharedTemplateSelected
                    if not sel or sel == "" then return end
                    local charKey, specKey, profName = sel:match("^(.-)%|%|(.-)%|%|(.+)$")
                    if charKey and specKey and profName then
                        SP.SetDefaultTemplate(charKey, specKey, profName)
                    end
                    ns._sharedTemplateSelected = nil
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
            },
            templateClearBtn = {
                type = "execute",
                name = "Clear",
                desc = "Remove the default template.",
                order = 25,
                width = 0.5,
                hidden = true,
                func = function()
                    SP.ClearDefaultTemplate()
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end,
                hidden = function() return not SP.GetDefaultTemplateInfo() end,
                confirm = true,
                confirmText = "Clear the default group template?",
            },
        },
    }
end

-- ───────────────────────────────────────────────────────────────────────────
-- Event Handler
-- ───────────────────────────────────────────────────────────────────────────

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")

-- Poll IsRestoring() until restoration completes, then sync immediately.
-- Much faster than a blind timer — triggers within 0.5s of restore finishing.
local syncPollTimer = nil
local SYNC_POLL_INTERVAL = 0.5
local SYNC_POLL_MAX = 15.0  -- Safety timeout (seconds)

local function StartSyncPoll()
    if syncPollTimer then syncPollTimer:Cancel() end
    local elapsed = 0
    syncPollTimer = C_Timer.NewTicker(SYNC_POLL_INTERVAL, function(ticker)
        elapsed = elapsed + SYNC_POLL_INTERVAL
        
        -- Safety timeout
        if elapsed >= SYNC_POLL_MAX then
            ticker:Cancel()
            syncPollTimer = nil
            SP.CheckAndSync()
            return
        end
        
        -- Wait for CDMGroups to exist and finish restoring
        if not ns.CDMGroups then return end
        if ns.CDMGroups.IsRestoring and ns.CDMGroups.IsRestoring() then return end
        if ns.CDMGroups._profileNotLoaded then return end
        if ns.CDMGroups.initialLoadInProgress then return end
        
        -- Restoration complete — sync now
        ticker:Cancel()
        syncPollTimer = nil
        SP.CheckAndSync()
    end)
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin, isReloadingUI = ...
        
        C_Timer.After(0, function()
            InstallHooks()
        end)
        
        -- One-time cleanup: strip old bloated data from v1 shared profiles.
        C_Timer.After(1.0, function()
            if not ns.db or not ns.db.global or not ns.db.global.sharedProfiles then return end
            for specKey, ref in pairs(ns.db.global.sharedProfiles) do
                if ref.profileData or ref.cdmEnhance or ref.arcAurasTrackedSpells or ref.arcAurasAutoTrack or ref.globalIconSettings then
                    ns.db.global.sharedProfiles[specKey] = {
                        sourceChar = ref.sourceChar,
                        profileName = ref.profileName,
                        timestamp = ref.timestamp,
                    }

                end
            end
        end)
        
        -- One-time migration: rename "Default" profiles to spec names
        -- across ALL characters in SavedVariables
        C_Timer.After(1.5, function()
            if not ns.db or not ns.db.global then return end
            if ns.db.global.migratedDefaultNames then return end
            
            local svChar = GetAllCharData()
            if not svChar then return end
            
            local renamed = 0
            for charKey, charData in pairs(svChar) do
                if type(charData) == "table" and charData.cdmGroups and charData.cdmGroups.specData then
                    for specKey, specData in pairs(charData.cdmGroups.specData) do
                        if type(specData) == "table" and specData.layoutProfiles and specData.layoutProfiles["Default"] then
                            -- Build spec name
                            local cID, sIdx = specKey:match("class_(%d+)_spec_(%d+)")
                            cID = tonumber(cID)
                            sIdx = tonumber(sIdx)
                            local specName = nil
                            if GetSpecializationInfoForClassID and cID and sIdx then
                                local _, apiName = GetSpecializationInfoForClassID(cID, sIdx)
                                if apiName then specName = apiName end
                            end
                            
                            if specName and not specData.layoutProfiles[specName] then
                                specData.layoutProfiles[specName] = specData.layoutProfiles["Default"]
                                specData.layoutProfiles["Default"] = nil
                                if specData.activeProfile == "Default" then
                                    specData.activeProfile = specName
                                end
                                renamed = renamed + 1
                            end
                        end
                    end
                end
            end
            
            -- Also update shared profile refs that point to "Default"
            if ns.db.global.sharedProfiles then
                for specKey, ref in pairs(ns.db.global.sharedProfiles) do
                    if ref.profileName == "Default" then
                        local cID, sIdx = specKey:match("class_(%d+)_spec_(%d+)")
                        cID = tonumber(cID)
                        sIdx = tonumber(sIdx)
                        if GetSpecializationInfoForClassID and cID and sIdx then
                            local _, apiName = GetSpecializationInfoForClassID(cID, sIdx)
                            if apiName then ref.profileName = apiName end
                        end
                    end
                end
            end
            
            -- Also update current character's runtime reference
            if ns.CDMGroups and ns.CDMGroups.activeProfile == "Default" then
                local sk = GetCurrentSpecKey()
                if sk then
                    local cID, sIdx = sk:match("class_(%d+)_spec_(%d+)")
                    cID = tonumber(cID)
                    sIdx = tonumber(sIdx)
                    if GetSpecializationInfoForClassID and cID and sIdx then
                        local _, apiName = GetSpecializationInfoForClassID(cID, sIdx)
                        if apiName then ns.CDMGroups.activeProfile = apiName end
                    end
                end
            end
            
            ns.db.global.migratedDefaultNames = true
            if renamed > 0 then

            end
        end)
        
        -- Auto-sync: poll until restoration is done, then sync immediately
        if isInitialLogin then
            StartSyncPoll()
        end
        
    elseif event == "PLAYER_LOGOUT" then
        local specKey = GetCurrentSpecKey()
        if specKey and SP.IsEnabled(specKey) then
            if pushTimer then
                pushTimer:Cancel()
                pushTimer = nil
            end
            SP.Push(specKey)
        end
    end
end)