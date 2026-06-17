-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras - Custom Tracking System
-- Track items (trinkets, potions) and spells not covered by CDM
-- v1.5 - Refactor: Unified item-cooldown path. Removed pcall (4 sites), removed
--        IsMatchingGCD/IsLikelyGCD/GetItemBaseCooldown in favor of a single
--        duration-threshold filter (< 2.5s = GCD/windup noise) used by both
--        the full-rebuild path (ApplyItemCooldownToFrame) and the delta path
--        (BAG_UPDATE_COOLDOWN handler). Matches ArcUI_CooldownReminder.
-- v1.4 - Refactor: Removed continuity protection cache (_startTime/_lastDuration
--        used as stale-value fallback). GCD suppression was sufficient;
--        continuity protection was the root cause of potions not resetting
--        after ENCOUNTER_END. ENCOUNTER_END handler simplified.
-- v1.3 - Fix: Ready glow stuck on during cooldown. _arcReadyGlowActive was
--        cleared BEFORE calling HideReadyGlow(), causing its early-exit guard
--        to skip the actual glow stop. Now call HideReadyGlow first, then clear flags.
-- v1.2 - Fix: Potion ready-glow during active CD (C_Container returns nil when consumed)
--        Added C_Item.GetItemCooldown fallback, GCD suppression, glow debounce
-- 
-- NOTE: Item cooldowns are NON-SECRET in WoW 12.0!
-- This means direct numeric comparisons work in combat.
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

ns.ArcAuras = ns.ArcAuras or {}
local ArcAuras = ns.ArcAuras
local Track = _G.ArcUIProfiler_Track

-- Dependencies
local Shared = ns.CDMShared

-- ═══════════════════════════════════════════════════════════════════════════
-- CLICK-THROUGH REFRESH (debounced)
-- Frames created AFTER the post-enable sweep — custom timers / custom icons
-- added live, or spell frames (re)created on talent changes — would otherwise
-- keep the default clickable state until the user opens and closes the options
-- panel. Coalesce a single RefreshIconSettings sweep (the same one the panel
-- triggers) so these frames inherit the saved click-through / tooltip state.
-- Debounced so bulk creation collapses into one sweep.
-- ═══════════════════════════════════════════════════════════════════════════
local clickThroughRefreshPending = false
local function RequestClickThroughRefresh()
    if clickThroughRefreshPending then return end
    if not (ns.CDMGroups and ns.CDMGroups.RefreshIconSettings) then return end
    clickThroughRefreshPending = true
    C_Timer.After(0.2, function()
        clickThroughRefreshPending = false
        if ns.CDMGroups and ns.CDMGroups.RefreshIconSettings then
            ns.CDMGroups.RefreshIconSettings()
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local TRINKET_SLOTS = {
    { slotID = 13, name = "Trinket 1" },
    { slotID = 14, name = "Trinket 2" },
}

local DEFAULT_ICON_SIZE = 40
-- (item/trinket frames are event-driven via BAG_UPDATE_COOLDOWN, no polling rate needed)

-- Arc Aura ID prefixes
local ID_PREFIX = {
    TRINKET = "arc_trinket_",
    ITEM = "arc_item_",
    SPELL = "arc_spell_",
    TIMER = "arc_timer_",
    TOTEM = "arc_totem_",
}

-- Frame Strata/Level Constants - Standardized to match CDM icons
-- CDM viewers use MEDIUM strata; we match for consistent z-ordering
local FRAME_STRATA = "MEDIUM"
local BASE_FRAME_LEVEL = 10
local FRAME_LEVEL_BORDER = 5     -- Offset for border overlay above base
local FRAME_LEVEL_GLOW = 3       -- Offset for glow anchor above base
local FRAME_LEVEL_COUNT = 10     -- Offset for count/stack text (above cooldown swipe)

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

ArcAuras.frames = {}           -- arcID -> frame
-- (no updateTicker - item frames are event-driven)
ArcAuras.isEnabled = false
ArcAuras.initialized = false
-- Masque registration handled by unified ns.Masque system (ArcUI_Masque.lua)

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE: CACHED REFERENCES (avoid repeated lookups)
-- ═══════════════════════════════════════════════════════════════════════════

local cachedLCG = nil  -- LibCustomGlow reference, cached once
local function GetLCG()
    if cachedLCG == nil then
        cachedLCG = LibStub and LibStub("LibCustomGlow-1.0", true) or false
    end
    return cachedLCG or nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MASQUE INTEGRATION
-- Registration handled by unified ns.Masque system (ArcUI_Masque.lua)
-- No local Masque group needed - prevents dual registration conflicts
-- ═══════════════════════════════════════════════════════════════════════════

-- Settings cache per frame - invalidated only when settings change
local settingsCache = {}  -- arcID -> { settings = {}, timestamp = time }
local SETTINGS_CACHE_TTL = 5  -- Re-validate cache every 5 seconds max
local settingsCacheGeneration = 0  -- Bumped on explicit invalidation (not TTL expiry)

-- Apply swipe/edge colors from settings, skipping when Masque controls cooldowns
-- Masque's skin owns swipe/edge colors when useMasqueCooldowns is enabled.
local function ApplySwipeColors(frame, settings)
    if ns.Masque and ns.Masque.ShouldMasqueControlCooldowns
       and ns.Masque.ShouldMasqueControlCooldowns() then return end
    if not frame.Cooldown or not settings or not settings.cooldownSwipe then return end
    local sc = settings.cooldownSwipe.swipeColor
    if sc then
        frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
    end
    local ec = settings.cooldownSwipe.edgeColor
    if ec and frame.Cooldown.SetEdgeColor then
        frame.Cooldown:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
    end
end

local function InvalidateSettingsCache(arcID)
    if arcID then
        settingsCache[arcID] = nil
    else
        wipe(settingsCache)
    end
    settingsCacheGeneration = settingsCacheGeneration + 1
end

-- Stack/charge cache per frame - updated on events, not polling
local stackCache = {}  -- arcID -> { value = x, isCharges = bool, itemID = id }

local function InvalidateStackCache(arcID)
    if arcID then
        stackCache[arcID] = nil
    else
        wipe(stackCache)
    end
end

-- Export cache invalidation for external use
ArcAuras.InvalidateSettingsCache = InvalidateSettingsCache
ArcAuras.InvalidateStackCache = InvalidateStackCache
ArcAuras.GetSettingsCacheGeneration = function() return settingsCacheGeneration end

-- Helper: return 0.35 preview alpha when options panel is open, 0 otherwise.
-- Used by all item hide paths so hidden items are visible during editing.
local PREVIEW_ALPHA = 0.35
local function GetHiddenAlpha()
    if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
        return PREVIEW_ALPHA
    end
    return 0
end

-- Helper: return true if frame should remain visible for options preview
local function IsOptionsPreviewActive()
    return ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen()
end

-- Helper: hide frame or show at preview alpha when options panel is open
local function HideOrPreview(frame)
    if IsOptionsPreviewActive() then
        -- Bypass any Show hooks by using original if available
        if frame._arcOriginalShow then
            frame._arcOriginalShow(frame)
        else
            frame:Show()
        end
        frame:SetAlpha(PREVIEW_ALPHA)
    else
        frame:Hide()
        frame:SetAlpha(0)
    end
end

-- Global bridge for GlowDebugger (debug only)
_G.ArcUI_ArcAuras = ArcAuras

-- ═══════════════════════════════════════════════════════════════════════════
-- DATABASE
-- BYPASS ACEDB: Access ArcUIDB directly to avoid removeDefaults stripping data
-- This follows the same pattern as CDMShared.GetCDMGroupsDB()
-- ═══════════════════════════════════════════════════════════════════════════

-- Cache for GetDB to avoid repeated string concatenation and table lookups
local cachedArcAurasDB = nil
local cachedCharKey = nil
local arcAurasDBCacheEnabled = false  -- Only enable after PLAYER_LOGIN

-- Forward declaration (needed because EnableDBCache references GetDB)
local GetDB

-- Define GetDB first
GetDB = function()
    -- Return cached result if available AND caching is enabled
    if arcAurasDBCacheEnabled and cachedArcAurasDB then
        return cachedArcAurasDB
    end
    
    -- CRITICAL: Access the raw SavedVariables table directly, not through AceDB
    -- AceDB's removeDefaults strips tables that "match defaults" on logout,
    -- which can cause data loss for complex nested structures like trackedItems.
    
    -- Ensure base structure exists
    if not ArcUIDB then 
        -- SavedVariables not loaded yet - return nil and caller should retry
        return nil 
    end
    if not ArcUIDB.char then ArcUIDB.char = {} end
    
    -- Get character key the same way AceDB does
    local playerName = UnitName("player")
    local realmName = GetRealmName()
    
    -- Guard against early calls before player info is available
    if not playerName or playerName == "" or not realmName or realmName == "" then
        return nil
    end
    
    local charKey = playerName .. " - " .. realmName
    
    if not ArcUIDB.char[charKey] then ArcUIDB.char[charKey] = {} end
    
    local charDB = ArcUIDB.char[charKey]
    
    -- Initialize arcAuras if missing (first time setup for this character)
    if not charDB.arcAuras then
        charDB.arcAuras = {
            enabled = true,
            autoTrackEquippedTrinkets = false,
            autoTrackSlots = {
                [13] = true,
                [14] = true,
            },
            onlyOnUseTrinkets = false,
            trackedItems = {},
            positions = {},
            globalSettings = {},
        }
    end
    
    local db = charDB.arcAuras
    
    -- Ensure sub-tables exist (defensive - for existing data that may be missing keys)
    if not db.trackedItems then db.trackedItems = {} end
    if not db.trackedSpells then db.trackedSpells = {} end
    if not db.positions then db.positions = {} end
    if not db.globalSettings then db.globalSettings = {} end
    if not db.autoTrackSlots then
        db.autoTrackSlots = { [13] = true, [14] = true }
    end
    if db.enabled == nil then db.enabled = true end
    if db.autoTrackEquippedTrinkets == nil then db.autoTrackEquippedTrinkets = false end
    if db.onlyOnUseTrinkets == nil then db.onlyOnUseTrinkets = false end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- ═══════════════════════════════════════════════════════════════════════════
    -- MIGRATION: Move Arc Auras from old ns.db.profile location (one-time)
    -- ═══════════════════════════════════════════════════════════════════════════
    if ns.db and ns.db.profile and ns.db.profile.arcAuras then
        local profileData = ns.db.profile.arcAuras
        
        -- Only migrate if profile has tracked items AND our trackedItems is empty AND not done before
        if profileData.trackedItems and next(profileData.trackedItems) then
            if not next(db.trackedItems) and not db.migrationDone then
                -- Copy tracked items
                for arcID, config in pairs(profileData.trackedItems) do
                    db.trackedItems[arcID] = CopyTable(config)
                end
                
                -- Copy positions
                if profileData.positions then
                    for arcID, pos in pairs(profileData.positions) do
                        db.positions[arcID] = CopyTable(pos)
                    end
                end
                
                -- Copy enabled state
                if profileData.enabled then
                    db.enabled = true
                end
                
                -- Copy global settings
                if profileData.globalSettings and next(profileData.globalSettings) then
                    db.globalSettings = CopyTable(profileData.globalSettings)
                end
                
                db.migrationDone = true
                print("|cff00ccffArcUI|r: Migrated Arc Auras to character-specific storage")
            end
            
            -- ALWAYS wipe profile data regardless of whether we copied.
            -- Prevents re-population if AceDB profile changes and trackedItems
            -- becomes empty again (which would re-trigger the copy condition).
            wipe(profileData.trackedItems)
            if profileData.positions then wipe(profileData.positions) end
            profileData.enabled = false
            print("|cff00ccffArcUI|r: Cleared profile Arc Auras data (now per-character)")
        end
    end
    
    -- Cache the result if caching is enabled (after PLAYER_LOGIN)
    if arcAurasDBCacheEnabled then
        cachedArcAurasDB = db
        cachedCharKey = charKey
    end
    
    return db
end

-- NOW define EnableDBCache (after GetDB is defined)
function ArcAuras.EnableDBCache()
    arcAurasDBCacheEnabled = true
    -- Force a DB fetch to populate the cache
    cachedArcAurasDB = nil  -- Clear first to force refresh
    GetDB()
end

-- Clear cache - call when DB needs to be re-fetched
function ArcAuras.ClearDBCache()
    cachedArcAurasDB = nil
    cachedCharKey = nil
end

-- Public DB accessor for sibling modules (e.g. ArcAurasTimer).
function ArcAuras.GetDB() return GetDB() end

-- ═══════════════════════════════════════════════════════════════════════════
-- ID HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.MakeTrinketID(slotID)
    return ID_PREFIX.TRINKET .. tostring(slotID)
end

function ArcAuras.MakeItemID(itemID)
    return ID_PREFIX.ITEM .. tostring(itemID)
end

function ArcAuras.MakeSpellID(spellID)
    return ID_PREFIX.SPELL .. tostring(spellID)
end

function ArcAuras.ParseArcID(arcID)
    if not arcID or type(arcID) ~= "string" then return nil end
    
    if arcID:find("^" .. ID_PREFIX.TRINKET) then
        local slotID = tonumber(arcID:sub(#ID_PREFIX.TRINKET + 1))
        return "trinket", slotID
    elseif arcID:find("^" .. ID_PREFIX.ITEM) then
        local itemID = tonumber(arcID:sub(#ID_PREFIX.ITEM + 1))
        return "item", itemID
    elseif arcID:find("^" .. ID_PREFIX.SPELL) then
        local spellID = tonumber(arcID:sub(#ID_PREFIX.SPELL + 1))
        return "spell", spellID
    elseif arcID:find("^" .. ID_PREFIX.TIMER) then
        -- Timer IDs can have a "_N" dedup suffix. Extract the leading digits only.
        local tail = arcID:sub(#ID_PREFIX.TIMER + 1)
        local spellID = tonumber(tail:match("^(%d+)"))
        return "timer", spellID
    elseif arcID:find("^" .. ID_PREFIX.TOTEM) then
        -- Totem IDs are "arc_totem_<slot>" — the trailing number is the totem slot.
        local slot = tonumber(arcID:sub(#ID_PREFIX.TOTEM + 1))
        return "totem", slot
    end

    return nil
end

function ArcAuras.IsArcAuraID(id)
    if not id or type(id) ~= "string" then return false end
    return id:find("^arc_") ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM INFO HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function GetItemNameAndIcon(itemID)
    if not itemID then return nil, nil end
    
    -- First try GetItemInfo (returns full data if cached)
    local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    
    -- If not cached, use GetItemInfoInstant for basic info (always available from local DB)
    if not name or not icon then
        local itemName, _, _, _, itemIcon = GetItemInfoInstant(itemID)
        name = name or itemName
        icon = icon or itemIcon
    end
    
    return name, icon
end

local function GetSlotItemInfo(slotID)
    local itemID = GetInventoryItemID("player", slotID)
    if not itemID then return nil, nil, nil end
    local name, icon = GetItemNameAndIcon(itemID)
    return itemID, name, icon or GetInventoryItemTexture("player", slotID)
end

local function GetItemOnUseSpell(itemID)
    if not itemID then return nil, nil end
    local spellName, spellID = GetItemSpell(itemID)
    return spellName, spellID
end

local function IsItemOnUse(itemID)
    if not itemID then return false end
    local spellName = GetItemSpell(itemID)
    -- Secret-safe: use truthiness check, not ~= nil comparison
    -- In WoW 12.0, GetItemSpell may return a secret for the spell name
    if spellName then return true end
    return false
end

-- Check if an item is passive (no on-use spell)
local function IsItemPassive(itemID)
    if not itemID then return true end  -- No item = treat as passive
    local spellName = GetItemSpell(itemID)
    -- Secret-safe: a secret value is truthy even if "empty"
    -- For passive items, GetItemSpell returns nil (non-secret)
    if spellName then return false end
    return true
end

-- Check if a specific item is currently equipped in any trinket slot
local function IsItemEquipped(itemID)
    if not itemID then return false end
    -- Check all equipment slots (1-19: head through ranged)
    for slot = 1, 19 do
        local equippedID = GetInventoryItemID("player", slot)
        if equippedID == itemID then
            return true
        end
    end
    return false
end

-- Expose for options
ArcAuras.IsItemEquipped = IsItemEquipped

-- ═══════════════════════════════════════════════════════════════════════════
-- BASE COOLDOWN CACHE (for GCD filtering)
-- ═══════════════════════════════════════════════════════════════════════════

-- Cache: itemID -> base cooldown in seconds (nil = not yet cached, false = no cooldown)
local baseCooldownCache = {}  -- retained; may be useful for future features; currently unused

-- ═══════════════════════════════════════════════════════════════════════════
-- STACK COUNT HELPERS (EVENT-DRIVEN, NOT POLLED)
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if an item should show inventory count (consumables, reagents)
local function ShouldShowInventoryCount(itemID)
    if not itemID then return false end
    
    -- GetItemInfo returns classID as 12th value, subclassID as 13th
    local _, _, _, _, _, _, _, _, _, _, _, classID, subclassID = GetItemInfo(itemID)
    if not classID then return false end  -- Item info not loaded yet
    
    -- Consumables (potions, food, flasks, etc.) - always show count
    -- Enum.ItemClass.Consumable = 0
    if classID == 0 then
        return true
    end
    
    -- Tradeskill items (reagents) - could be useful for profession items
    -- Enum.ItemClass.Tradegoods = 7
    if classID == 7 then
        return true
    end
    
    -- Everything else (armor, weapons, trinkets) - don't show inventory count
    return false
end

-- Helper: Find item location in bags
local function FindItemInBags(itemID)
    for bag = 0, 4 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID then
                return bag, slot
            end
        end
    end
    return nil, nil
end

-- Helper: Get item charges from tooltip (for items like Healthstone)
-- Returns charges number or nil if not found
local function GetItemChargesFromTooltip(itemID)
    local bag, slot = FindItemInBags(itemID)
    if not bag then return nil end
    
    local tooltipData = C_TooltipInfo.GetBagItem(bag, slot)
    if not tooltipData or not tooltipData.lines then return nil end
    
    for _, line in ipairs(tooltipData.lines) do
        if line.leftText then
            local text = line.leftText
            
            -- WoW uses |4 for plural handling: "2 |4Charge:Charges;"
            -- Pattern 1: Match WoW's localization format "X |4Charge:Charges;"
            local charges = text:match("^(%d+) |4Charge:Charges;$")
            if charges then
                return tonumber(charges)
            end
            
            -- Pattern 2: Simple "X Charges" or "X Charge" 
            charges = text:match("^(%d+) Charges?$")
            if charges then
                return tonumber(charges)
            end
            
            -- Pattern 3: More lenient - find number before "Charge" anywhere
            charges = text:match("(%d+) |4Charge")
            if charges then
                return tonumber(charges)
            end
        end
    end
    
    return nil
end

-- Get the stack count to display for an Arc Aura config
-- Returns: displayValue, isCharges (boolean)
-- NOTE: This is fully event-driven, not polled!
local function ComputeStackDisplay(config)
    if not config then return nil, false end
    
    if config.type == "item" and config.itemID then
        -- First check if item has spell charges via C_Spell API
        local spellName, spellID = GetItemSpell(config.itemID)
        if spellID then
            local chargeInfo = C_Spell.GetSpellCharges(spellID)
            -- currentCharges is SECRET in 12.0 — comparing to nil returns false for secret numbers.
            -- If chargeInfo table exists, GetSpellCharges confirmed a charge system exists.
            -- SetText accepts secrets so we can pass currentCharges directly.
            if chargeInfo then
                return chargeInfo.currentCharges, true
            end
        end
        
        -- Check for item-based charges (like Healthstone) via GetItemCount includeCharges=true
        -- This is what CooldownPanels uses — no tooltip parsing needed
        local withCharges = GetItemCount(config.itemID, false, true)
        local withoutCharges = GetItemCount(config.itemID, false, false)
        if withCharges and withoutCharges and withCharges > withoutCharges then
            return withCharges, true
        end
        
        -- No charges - fall back to inventory count for consumables
        if ShouldShowInventoryCount(config.itemID) then
            return withoutCharges, false
        end
        
    elseif config.type == "trinket" and config.slotID then
        -- Trinkets: check for spell charges
        local itemID = GetInventoryItemID("player", config.slotID)
        if itemID then
            local spellName, spellID = GetItemSpell(itemID)
            if spellID then
                local chargeInfo = C_Spell.GetSpellCharges(spellID)
                -- currentCharges is SECRET in 12.0 — if chargeInfo table exists, charge system confirmed
                if chargeInfo then
                    return chargeInfo.currentCharges, true
                end
            end
        end
    end
    
    return nil, false  -- Don't show any stack text
end

-- Cached version - updated on events, read during update loop
-- Cache invalidated by:
--   1. BAG_UPDATE_DELAYED (new items, bag changes)
--   2. Cooldown starting (item used - charges changed)
--   3. Trinket swap (detected in UpdateTrinketCooldown)
local function GetStackDisplay(config, arcID)
    -- Custom Icons (Arc Auras timers): read live stack count from the
    -- timer engine. Timer stacks change frequently (every proc event)
    -- and the count is stored in RAM per-timer, so there's nothing to
    -- cache and no cache to miss — just ask the engine.
    if ns.ArcAurasTimer and ns.ArcAurasTimer.GetStackCount then
        local db = ns.db and ns.db.char and ns.db.char.arcAuras
        if db and db.customTimers and db.customTimers[arcID] then
            local stacks = ns.ArcAurasTimer.GetStackCount(arcID)
            if stacks and stacks > 0 then
                return stacks, true   -- isCharges=true so chargeText styling applies
            end
            -- Idle (no stacks accumulated). If Track Stacks is enabled on
            -- this timer, return 0 as a persistent placeholder so the
            -- count is always visible — same way normal spell-charge text
            -- always displays its current count. This makes the stack
            -- text easy to find and style even before the first proc.
            local cfg = db.customTimers[arcID]
            local trackStacks = cfg and cfg.startTrigger
                and cfg.startTrigger.trackStacks == true
            if trackStacks then
                return 0, true
            end
            return nil, false
        end
    end

    -- Check cache first
    local cached = stackCache[arcID]
    if cached then
        -- Verify itemID hasn't changed (trinket swap)
        local currentItemID = config.itemID
        if config.type == "trinket" and config.slotID then
            currentItemID = GetInventoryItemID("player", config.slotID)
        end
        if cached.itemID == currentItemID then
            return cached.value, cached.isCharges
        end
    end
    
    -- Cache miss - compute and cache
    local value, isCharges = ComputeStackDisplay(config)
    local currentItemID = config.itemID
    if config.type == "trinket" and config.slotID then
        currentItemID = GetInventoryItemID("player", config.slotID)
    end
    
    stackCache[arcID] = {
        value = value,
        isCharges = isCharges,
        itemID = currentItemID,
    }
    
    return value, isCharges
end

-- Forward declaration: ApplyStackText is defined later in the file (around
-- line 1580) but is referenced earlier in RefreshStackTextStyle. Declaring
-- the local up here makes the upvalue resolve correctly at definition time
-- of RefreshStackTextStyle. The actual function body is assigned below.
local ApplyStackText

-- Apply CDMEnhance chargeText styling to a fontstring
local function ApplyStackTextStyle(frame, fontString)
    if not frame or not fontString then return end
    
    -- Get settings from CDMEnhance cascade
    local arcID = frame._arcAuraID or frame.cooldownID
    local settings = nil
    
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
        settings = ns.CDMEnhance.GetEffectiveIconSettings(arcID)
    end
    
    local chargeCfg = settings and settings.chargeText
    if not chargeCfg then
        -- Use defaults
        chargeCfg = {
            enabled = true,
            size = 16,
            color = {r = 1, g = 1, b = 0, a = 1},
            font = "Friz Quadrata TT",
            outline = "OUTLINE",
            shadow = false,
            shadowOffsetX = 1,
            shadowOffsetY = -1,
            anchor = "BOTTOMRIGHT",
            offsetX = -2,
            offsetY = 2,
        }
    end
    
    -- Check if enabled
    if chargeCfg.enabled == false then
        fontString:Hide()
        return
    end
    
    -- Get font path using CDMEnhance's helper
    local fontPath = "Fonts\\FRIZQT__.TTF"
    if ns.CDMEnhance and ns.CDMEnhance.GetFontPath then
        fontPath = ns.CDMEnhance.GetFontPath(chargeCfg.font)
    end
    
    local fontSize = chargeCfg.size or 16
    local outline = chargeCfg.outline or "OUTLINE"
    
    -- Apply font using CDMEnhance's safe setter if available
    if ns.CDMEnhance and ns.CDMEnhance.SafeSetFont then
        ns.CDMEnhance.SafeSetFont(fontString, fontPath, fontSize, outline)
    else
        fontString:SetFont(fontPath, fontSize, outline)
    end
    
    -- Color
    local c = chargeCfg.color or {r = 1, g = 1, b = 0, a = 1}
    fontString:SetTextColor(c.r or 1, c.g or 1, c.b or 0, c.a or 1)
    
    -- Shadow
    if chargeCfg.shadow then
        fontString:SetShadowOffset(chargeCfg.shadowOffsetX or 1, chargeCfg.shadowOffsetY or -1)
        fontString:SetShadowColor(0, 0, 0, 0.8)
    else
        fontString:SetShadowOffset(0, 0)
    end
    
    -- Set draw layer to appear above glows
    fontString:SetDrawLayer("OVERLAY", 7)
    
    -- Position based on mode setting (anchor or free)
    fontString:ClearAllPoints()
    if chargeCfg.mode == "free" then
        -- Free position mode - use freeX/freeY relative to center
        local freeX = chargeCfg.freeX or 0
        local freeY = chargeCfg.freeY or 0
        fontString:SetPoint("CENTER", frame, "CENTER", freeX, freeY)
    else
        -- Anchor position mode (default)
        local anchor = chargeCfg.anchor or "BOTTOMRIGHT"
        local offsetX = chargeCfg.offsetX or -2
        local offsetY = chargeCfg.offsetY or 2
        fontString:SetPoint(anchor, frame, anchor, offsetX, offsetY)
    end
end

-- Export stack helpers
ArcAuras.ShouldShowInventoryCount = ShouldShowInventoryCount
ArcAuras.GetStackDisplay = GetStackDisplay
ArcAuras.ApplyStackTextStyle = ApplyStackTextStyle

-- Refresh stack text styling for all Arc Aura frames
-- Called when chargeText settings change in options
function ArcAuras.RefreshStackTextStyle()
    for arcID, frame in pairs(ArcAuras.frames) do
        if frame and frame._arcStackText then
            -- Clear flag to force re-application
            frame._arcStackStyleApplied = false
            -- Immediately apply the style (don't wait for OnUpdate)
            ApplyStackTextStyle(frame, frame._arcStackText)
            frame._arcStackStyleApplied = true
            -- Also push the current displayed value. Without this, timer
            -- frames (which have no periodic stack-update loop like items
            -- do in UpdateArcItemFrame) lose their text whenever
            -- ApplyStackTextStyle runs without a corresponding value
            -- refresh. ApplyStackText is forward-declared above so this
            -- reference resolves correctly at parse time.
            if ApplyStackText then
                ApplyStackText(frame, arcID)
            end
        end
    end
    -- 3.6.6: spell frames render their charge text via ArcAurasCooldown's
    -- UpdateChargeText (separate path from ApplyStackText above which handles
    -- item / timer frames). Re-push the current charge value for spell frames
    -- so changing a chargeText option in the panel doesn't blank the number
    -- until the next cooldown event.
    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshAllChargeText then
        ns.ArcAurasCooldown.RefreshAllChargeText()
    end
end

-- Export helpers
ArcAuras.GetItemNameAndIcon = GetItemNameAndIcon
ArcAuras.GetSlotItemInfo = GetSlotItemInfo
ArcAuras.GetItemOnUseSpell = GetItemOnUseSpell
ArcAuras.IsItemOnUse = IsItemOnUse
ArcAuras.IsItemPassive = IsItemPassive

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME CREATION
-- ═══════════════════════════════════════════════════════════════════════════

local function CreateArcAuraFrame(arcID, config)
    local frameName = "ArcAura_" .. arcID:gsub("[^%w]", "_")
    
    -- Reuse the existing named frame if it was orphaned by DestroyFrame.
    -- WoW never truly destroys named frames — calling CreateFrame again with
    -- the same name creates a duplicate. Reuse + reset instead.
    local frame = _G[frameName]
    if frame then
        frame:SetParent(UIParent)
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
        frame:SetFrameStrata(FRAME_STRATA)
        frame:SetFrameLevel(BASE_FRAME_LEVEL)
        frame:Show()
    else
        frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
        frame:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:SetFrameStrata(FRAME_STRATA)
        frame:SetFrameLevel(BASE_FRAME_LEVEL)
    end
    
    -- Arc Aura identification
    -- cooldownID is REQUIRED for CDMGroups drag handlers (they read self.cooldownID)
    -- String IDs are safe - CDM API guards (type checks) prevent them from being passed to C_CooldownViewer
    frame._arcAuraID = arcID
    frame.cooldownID = arcID  -- CRITICAL: Enables drag, group membership, free icon tracking
    frame._arcIconType = config.type
    frame._arcConfig = config
    
    -- Background (transparent by default - borders handle visual framing)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0, 0, 0, 0)  -- Transparent - padding won't show black gap
    frame:SetBackdropBorderColor(0, 0, 0, 0)  -- Border handled by CDMEnhance
    
    -- Icon texture (matches CDM structure for CDMEnhance compatibility)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    frame.Icon = icon
    
    -- Cooldown frame
    local cooldown = CreateFrame("Cooldown", frameName .. "_Cooldown", frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    cooldown:SetDrawSwipe(true)
    cooldown:SetDrawEdge(true)
    cooldown:SetHideCountdownNumbers(false)
    
    -- CRITICAL: Initialize swipe texture - CDM defines this in XML, we must set it manually
    -- Without this, SetSwipeColor has nothing to colorize!
    -- Using same texture as CDM: "Interface\HUD\UI-HUD-CoolDownManager-Icon-Swipe"
    cooldown:SetSwipeTexture("Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe", 1, 1, 1, 1)
    cooldown:SetEdgeTexture("Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown", 1, 1, 1, 1)
    
    frame.Cooldown = cooldown
    -- Assign .Text so preserve duration text logic can find it (matches CDM frame structure)
    if cooldown.GetCountdownFontString then
        cooldown.Text = cooldown:GetCountdownFontString()
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SPELL-SPECIFIC: Hidden Desaturation Cooldown + Hooks
    -- Only created for spell frames (type == "spell")
    -- Drives icon desaturation entirely through hooks — zero secret comparisons.
    --   SetCooldown(0,0) → frame not shown → hooks read IsShown()=false → desat OFF
    --   SetCooldownFromDurationObject(durObj) → frame shown → IsShown()=true → desat ON
    --   OnCooldownDone fires → CD expired → desat OFF instantly
    -- ═══════════════════════════════════════════════════════════════════════════
    if config.type == "spell" or config.type == "timer" or config.type == "totem" then
        frame._arcIsSpellCooldown = true  -- Flag: OnUpdate loop skips this frame
        frame._arcSpellID = config.spellID
        
        -- State detection uses GetSpellCooldown().isActive and GetSpellCharges().isActive
        -- (both non-secret). No shadow frame needed.
        -- Visible cooldown: OnCooldownDone → re-feed for instant visual update
        local _cooldownOnDone = Track and Track("ArcAuras.Cooldown.OnCooldownDone", function(self)
            local fd = self._arcFrameData
            if not fd then return end
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.FeedCooldown then
                ns.ArcAurasCooldown.FeedCooldown(fd)
            end
        end) or function(self)
            local fd = self._arcFrameData
            if not fd then return end
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.FeedCooldown then
                ns.ArcAurasCooldown.FeedCooldown(fd)
            end
        end
        cooldown:SetScript("OnCooldownDone", _cooldownOnDone)
        
        -- CooldownFlash (matches CDM structure for CDMEnhance bling control)
        local cooldownFlash = CreateFrame("Frame", nil, frame)
        cooldownFlash:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 1)
        cooldownFlash:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 1)
        cooldownFlash:Hide()
        
        local flipbook = cooldownFlash:CreateTexture(nil, "ARTWORK")
        flipbook:SetAllPoints()
        flipbook:SetAlpha(0)
        flipbook:SetAtlas("UI-HUD-ActionBar-GCD-Flipbook")
        cooldownFlash.Flipbook = flipbook
        
        local flashAnim = cooldownFlash:CreateAnimationGroup()
        cooldownFlash.FlashAnim = flashAnim
        
        local hideAnim = flashAnim:CreateAnimation("Alpha")
        hideAnim:SetDuration(0)
        hideAnim:SetOrder(1)
        hideAnim:SetFromAlpha(0)
        hideAnim:SetToAlpha(0)
        flashAnim.HideAnim = hideAnim
        
        local showAnim = flashAnim:CreateAnimation("Alpha")
        showAnim:SetDuration(0)
        showAnim:SetOrder(1)
        showAnim:SetFromAlpha(1)
        showAnim:SetToAlpha(1)
        flashAnim.ShowAnim = showAnim
        
        -- FlipBook animation if supported, else Alpha fallback. Feature-detect
        -- the FlipBook-specific setters rather than pcall the whole creation —
        -- CreateAnimation("FlipBook") may succeed silently on older clients
        -- but lack the FlipBook setters.
        local playAnim = flashAnim:CreateAnimation("FlipBook")
        if playAnim and type(playAnim.SetFlipBookRows) == "function" then
            playAnim:SetDuration(0.75)
            playAnim:SetOrder(1)
            playAnim:SetFlipBookRows(11)
            playAnim:SetFlipBookColumns(2)
            playAnim:SetFlipBookFrames(22)
        else
            playAnim = flashAnim:CreateAnimation("Alpha")
            playAnim:SetDuration(0.75)
            playAnim:SetOrder(1)
        end
        flashAnim.PlayAnim = playAnim
        
        frame.CooldownFlash = cooldownFlash
    end
    
    -- Duration object for cooldown updates (items only - spells use C_Spell DurationObjects)
    if config.type ~= "spell" and C_DurationUtil and C_DurationUtil.CreateDuration then
        frame._durationObj = C_DurationUtil.CreateDuration()
    end
    
    -- IconOverlay: CDMEnhance controls visibility via keepCDMStyle toggle.
    -- Created hidden by default; CDMEnhance will show/position it when keepCDMStyle is on.
    local iconOverlay = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    iconOverlay:SetAllPoints(icon)
    iconOverlay:SetAlpha(0)
    iconOverlay:Hide()
    frame.IconOverlay = iconOverlay
    
    -- Border overlay frame (for custom borders)
    local borderOverlay = CreateFrame("Frame", nil, frame)
    borderOverlay:SetAllPoints()
    borderOverlay:SetFrameLevel(frame:GetFrameLevel() + FRAME_LEVEL_BORDER)
    frame._arcBorderOverlay = borderOverlay
    
    -- Glow anchor frame (for LibCustomGlow)
    local glowAnchor = CreateFrame("Frame", nil, frame)
    glowAnchor:SetAllPoints()
    glowAnchor:SetFrameLevel(frame:GetFrameLevel() + FRAME_LEVEL_GLOW)
    frame._arcGlowAnchor = glowAnchor
    
    -- Count container frame (sits ABOVE cooldown swipe for proper layering)
    -- Cooldown frame inherits frame level, so we need count on a higher level frame
    local countContainer = CreateFrame("Frame", nil, frame)
    countContainer:SetAllPoints()
    countContainer:SetFrameLevel(frame:GetFrameLevel() + FRAME_LEVEL_COUNT)
    frame._arcCountContainer = countContainer
    
    -- Stack/charge text - parented to container for proper strata
    -- IMPORTANT: We use _arcStackText instead of "Count" because Masque auto-detects
    -- frame.Count and tries to manage its position even when we don't pass it in regions.
    -- By using a different name, Masque can't find it and ArcUI maintains full control.
    local countText = countContainer:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    countText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    countText:SetText("")
    frame._arcStackText = countText
    
    -- Cooldown state tracking
    frame._lastCooldownState = nil
    frame._lastStartTime = nil
    frame._lastDuration = nil
    
    -- Make draggable (controlled by options)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if self._isDraggable then
            self:StartMoving()
        end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local arcID = self._arcAuraID
        
        -- ═══════════════════════════════════════════════════════════════════════════
        -- SAVE TO ARC MANAGER PROFILE - EXACTLY like CDM OnDragStop (lines 1019-1030)
        -- This is what makes positions persist across reloads/profile switches
        -- ═══════════════════════════════════════════════════════════════════════════
        if ns.CDMGroups and ns.CDMGroups.savedPositions then
            -- Check if in a group - if so, group manages position, don't save as free
            local saved = ns.CDMGroups.savedPositions[arcID]
            if saved and saved.type == "group" then
                return  -- Group manages this, don't overwrite
            end
            
            -- Calculate CENTER-based coordinates (same as CDM line 977-979)
            local cx, cy = self:GetCenter()
            local ux, uy = UIParent:GetCenter()
            local newX, newY = cx - ux, cy - uy
            
            -- Update freeIcons if tracked (same as CDM line 1019-1022)
            if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
                ns.CDMGroups.freeIcons[arcID].x = newX
                ns.CDMGroups.freeIcons[arcID].y = newY
            end
            
            -- Update savedPositions (same as CDM line 1023-1028)
            local iconSize = (ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] and ns.CDMGroups.freeIcons[arcID].iconSize) or 36
            ns.CDMGroups.savedPositions[arcID] = {
                type = "free",
                x = newX,
                y = newY,
                iconSize = iconSize,
            }
            
            -- Call SavePositionToSpec (same as CDM line 1029)
            if ns.CDMGroups.SavePositionToSpec then
                ns.CDMGroups.SavePositionToSpec(arcID, ns.CDMGroups.savedPositions[arcID])
            end
            
            -- Call SaveFreeIconToSpec (same as CDM line 1030)
            if ns.CDMGroups.SaveFreeIconToSpec then
                ns.CDMGroups.SaveFreeIconToSpec(arcID, { x = newX, y = newY, iconSize = iconSize })
            end
            
            -- CLEANUP: Remove legacy db.positions since CDMGroups now manages this
            local db = GetDB()
            if db and db.positions and db.positions[arcID] then
                db.positions[arcID] = nil
            end
        else
            -- FALLBACK: CDMGroups not available, use legacy ArcAuras storage
            local point, _, relPoint, x, y = self:GetPoint()
            ArcAuras.SaveFramePosition(arcID, point, relPoint, x, y)
        end
    end)
    
    -- Tooltip
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        ArcAuras.ShowTooltip(self)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- Right-click for options
    frame:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ArcAuras.ShowContextMenu(self)
        end
    end)
    frame:RegisterForClicks("RightButtonUp")
    
    return frame
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.CreateFrame(arcID, config)
    if ArcAuras.frames[arcID] then
        return ArcAuras.frames[arcID]
    end
    
    local frame = CreateArcAuraFrame(arcID, config)
    ArcAuras.frames[arcID] = frame
    
    -- Set initial icon
    ArcAuras.UpdateFrameIcon(frame, config)
    
    -- For item-type frames, request full item data loading
    -- This ensures icon/name are available even if player doesn't have the item
    if config.type == "item" and config.itemID then
        C_Item.RequestLoadItemDataByID(config.itemID)
    end
    
    -- Check if trinket slot is empty (items and trinkets only)
    local skipCDMGroups = false
    if config.type == "trinket" and config.slotID then
        local itemID = GetInventoryItemID("player", config.slotID)
        if not itemID then
            frame._arcSlotEmpty = true
            -- Still register with CDMGroups if there's a saved position (imported profiles)
            -- so the frame holds its group slot while hidden
            if not (ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]) then
                skipCDMGroups = true
            end
        end
    end
    
    -- Register with CDMGroups for positioning, dragging, groups
    -- CDMGroups handles: saved positions, group membership, drag handlers, free icon tracking
    if not skipCDMGroups then
        -- ─────────────────────────────────────────────────────────────────
        -- DEFAULT SPAWN POSITION
        --
        -- If this frame has NO existing saved position (i.e. it's brand new
        -- — first time being created, never moved by the user), seed a
        -- free-icon entry at screen-center, slightly above the middle. This
        -- prevents new icons from auto-stacking off to the right side of
        -- the screen as additional members of the Essential viewer's icon
        -- row, which is what happens when RegisterExternalFrame falls
        -- through to its default placement.
        --
        -- Existing icons (returning from /reload, profile copy, etc.) hit
        -- the savedPositions[arcID] check and skip the seed entirely so we
        -- don't stomp their placements.
        -- ─────────────────────────────────────────────────────────────────
        if ns.CDMGroups and ns.CDMGroups.savedPositions
           and not ns.CDMGroups.savedPositions[arcID] then
            local DEFAULT_X = 0       -- horizontal center
            local DEFAULT_Y = 50      -- slightly above vertical center
            local iconSize  = 36      -- matches CDMGroups default
            ns.CDMGroups.savedPositions[arcID] = {
                type     = "free",
                x        = DEFAULT_X,
                y        = DEFAULT_Y,
                iconSize = iconSize,
            }
            -- Also register in freeIcons so the drag handler can find it.
            if ns.CDMGroups.freeIcons then
                ns.CDMGroups.freeIcons[arcID] = ns.CDMGroups.freeIcons[arcID] or {}
                ns.CDMGroups.freeIcons[arcID].x        = DEFAULT_X
                ns.CDMGroups.freeIcons[arcID].y        = DEFAULT_Y
                ns.CDMGroups.freeIcons[arcID].iconSize = iconSize
            end
            -- Persist to spec profile so the centered position survives a
            -- /reload immediately, even before the user drags the icon.
            if ns.CDMGroups.SavePositionToSpec then
                ns.CDMGroups.SavePositionToSpec(arcID, ns.CDMGroups.savedPositions[arcID])
            end
            if ns.CDMGroups.SaveFreeIconToSpec then
                ns.CDMGroups.SaveFreeIconToSpec(arcID,
                    { x = DEFAULT_X, y = DEFAULT_Y, iconSize = iconSize })
            end
        end

        if ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
            ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", "Essential")
        else
            -- CDMGroups Integration not loaded yet, defer
            C_Timer.After(1.0, function()
                if ArcAuras.frames[arcID] then
                    if ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
                        ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", "Essential")
                    end
                end
            end)
        end
    end
    
    -- Register with CDMEnhance for visual style integration
    ArcAuras.RegisterWithCDMEnhance(arcID, frame)
    
    -- Register with Masque for skinning via unified system (if available)
    if ns.Masque and ns.Masque.AddFrame then
        ns.Masque.AddFrame(frame, "ArcAuras", arcID)
        -- Store the size Masque was registered at for stale-skin detection
        frame._arcMasqueSkinW = frame:GetWidth()
        frame._arcMasqueSkinH = frame:GetHeight()
    end
    
    -- Initialize stack cache for this frame
    InvalidateStackCache(arcID)
    
    -- Apply current click-through / tooltip state to this frame. Covers frames
    -- created outside the post-enable sweep (live-added custom timers/icons,
    -- talent-change spell frames). Debounced — Enable's bulk creation collapses
    -- to one sweep and is also covered explicitly by the post-enable sweep.
    RequestClickThroughRefresh()
    
    return frame
end

function ArcAuras.DestroyFrame(arcID)
    local frame = ArcAuras.frames[arcID]
    if not frame then return end
    
    -- Clear caches
    InvalidateSettingsCache(arcID)
    InvalidateStackCache(arcID)
    
    -- Unregister from Masque via unified system
    if ns.Masque and ns.Masque.RemoveFrame then
        ns.Masque.RemoveFrame(frame)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SPELL CLEANUP: Clear ArcAurasCooldown state tables
    -- ═══════════════════════════════════════════════════════════════════════════
    if frame._arcIsSpellCooldown and ns.ArcAurasCooldown then
        local fd = ns.ArcAurasCooldown.spellData and ns.ArcAurasCooldown.spellData[arcID]
        if fd then
            -- Stop proc glows
            if ns.Glows then
                ns.Glows.StopAll(frame)
            end
            if ActionButtonSpellAlertManager and ActionButtonSpellAlertManager.HideAlert then
                ActionButtonSpellAlertManager:HideAlert(frame)
            end
        end
        
        -- Clear reverse lookup
        if fd and fd.spellID and ns.ArcAurasCooldown.spellsByID then
            if ns.ArcAurasCooldown.spellsByID[fd.spellID] == arcID then
                ns.ArcAurasCooldown.spellsByID[fd.spellID] = nil
            end
        end
        
        -- Clear spell state tables
        if ns.ArcAurasCooldown.spellFrames then
            ns.ArcAurasCooldown.spellFrames[arcID] = nil
        end
        if ns.ArcAurasCooldown.spellData then
            ns.ArcAurasCooldown.spellData[arcID] = nil
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 1: Unregister from CDMGroups (removes from groups/freeIcons)
    -- This must happen FIRST before we clear frame properties
    -- ═══════════════════════════════════════════════════════════════════════════
    if ns.CDMGroups and ns.CDMGroups.UnregisterExternalFrame then
        ns.CDMGroups.UnregisterExternalFrame(arcID)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 2: Stop any visual effects (glows, animations)
    -- ═══════════════════════════════════════════════════════════════════════════
    if ns.Glows then
        ns.Glows.StopAll(frame)
        if frame._arcGlowAnchor and frame._arcGlowAnchor ~= frame then
            ns.Glows.StopAll(frame._arcGlowAnchor)
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 3: Clear ALL CDMGroups hooks and properties
    -- This prevents "ghost frames" from fighting to restore position
    -- ═══════════════════════════════════════════════════════════════════════════
    
    -- Clear hook flags (hooks can't be removed, but clearing flags disables them)
    frame._cdmgClearPointsHooked = nil
    frame._cdmgClearPointsFreeHooked = nil
    frame._cdmgScaleHooked = nil
    frame._cdmgSizeHooked = nil
    frame._cdmgStrataHooked = nil
    frame._cdmgParentHooked = nil
    
    -- Clear CDMGroups control properties (prevents hooks from triggering)
    frame._cdmgIsFreeIcon = nil
    frame._cdmgFreeTargetSize = nil
    frame._cdmgTargetPoint = nil
    frame._cdmgTargetRelPoint = nil
    frame._cdmgTargetX = nil
    frame._cdmgTargetY = nil
    frame._cdmgTargetSize = nil
    frame._cdmgSlotW = nil
    frame._cdmgSlotH = nil
    frame._cdmgSettingPosition = nil
    frame._cdmgSettingScale = nil
    frame._cdmgSettingSize = nil
    frame._cdmgSettingStrata = nil
    frame._cdmgSettingParent = nil
    
    -- Clear drag state
    frame._groupDragging = nil
    frame._freeDragging = nil
    frame._sourceGroup = nil
    frame._sourceCdID = nil
    frame._isDraggable = nil
    
    -- Clear recovery/timing flags
    frame._arcRecoveryProtection = nil
    frame.frameLostAt = nil
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 4: Clear drag handlers and scripts
    -- ═══════════════════════════════════════════════════════════════════════════
    if frame and frame.SetMovable then
        frame:SetMovable(false)
        frame:EnableMouse(false)
        frame:RegisterForDrag()  -- Unregister all drag buttons
        frame:SetScript("OnDragStart", nil)
        frame:SetScript("OnDragStop", nil)
        frame:SetScript("OnUpdate", nil)
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 5: Hide visual elements
    -- ═══════════════════════════════════════════════════════════════════════════
    if frame._arcBorderEdges then
        if frame._arcBorderEdges.top then frame._arcBorderEdges.top:Hide() end
        if frame._arcBorderEdges.bottom then frame._arcBorderEdges.bottom:Hide() end
        if frame._arcBorderEdges.left then frame._arcBorderEdges.left:Hide() end
        if frame._arcBorderEdges.right then frame._arcBorderEdges.right:Hide() end
    end
    if frame._arcTextOverlay then frame._arcTextOverlay:Hide() end
    if frame._arcOverlay then frame._arcOverlay:Hide() end
    if frame._arcGlowAnchor then frame._arcGlowAnchor:Hide() end
    if frame._arcBorderOverlay then frame._arcBorderOverlay:Hide() end
    if frame._arcCountContainer then frame._arcCountContainer:Hide() end
    if frame._arcStackText then frame._arcStackText:Hide() end
    if frame.Cooldown then frame.Cooldown:Hide() end
    if frame.Icon then frame.Icon:Hide() end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- STEP 6: Final cleanup - hide and orphan the frame
    -- ═══════════════════════════════════════════════════════════════════════════
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetParent(nil)  -- Orphan the frame (allows GC if no other refs)
    
    -- Remove from our frames table
    ArcAuras.frames[arcID] = nil
end

function ArcAuras.GetFrame(arcID)
    return ArcAuras.frames[arcID]
end

function ArcAuras.UpdateFrameIcon(frame, config)
    if not frame or not config then return end
    
    local icon = nil
    
    if config.type == "trinket" and config.slotID then
        -- Check for icon override on trinket/item frames
        local db2 = GetDB()
        local trackedItemConfig = db2 and db2.trackedItems and db2.trackedItems[frame._arcAuraID]
        if trackedItemConfig and trackedItemConfig.iconOverride then
            icon = trackedItemConfig.iconOverride
        else
            local itemID, itemName, itemIcon = GetSlotItemInfo(config.slotID)
            icon = itemIcon
        end
        local itemID, itemName = GetSlotItemInfo(config.slotID)
        frame._currentItemID = itemID
        frame._currentItemName = itemName
    elseif config.type == "item" and config.itemID then
        local db2 = GetDB()
        local trackedItemConfig = db2 and db2.trackedItems and db2.trackedItems[frame._arcAuraID]
        if trackedItemConfig and trackedItemConfig.iconOverride then
            icon = trackedItemConfig.iconOverride
        else
            local itemName, itemIcon = GetItemNameAndIcon(config.itemID)
            icon = itemIcon
        end
        frame._currentItemID = config.itemID
        local itemName = GetItemNameAndIcon(config.itemID)
        frame._currentItemName = itemName
    elseif config.type == "spell" and config.spellID then
        -- Check for user icon override first (stored in trackedSpells config)
        local db = GetDB()
        local trackedConfig = db and db.trackedSpells and db.trackedSpells[frame._arcAuraID]
        if trackedConfig and trackedConfig.iconOverride then
            icon = trackedConfig.iconOverride
        else
            local spellInfo = C_Spell.GetSpellInfo(config.spellID)
            if spellInfo then
                icon = spellInfo.iconID or spellInfo.originalIconID
            end
        end
        frame._currentItemName = config.name or (C_Spell.GetSpellInfo(config.spellID) or {}).name
        frame._currentItemID = nil
    elseif config.type == "timer" and config.spellID then
        -- Custom timer icon: user override from customTimers config, else spell icon.
        local db = GetDB()
        local timerConfig = db and db.customTimers and db.customTimers[frame._arcAuraID]
        if timerConfig and timerConfig.icon then
            icon = timerConfig.icon
        else
            local spellInfo = C_Spell.GetSpellInfo(config.spellID)
            if spellInfo then
                icon = spellInfo.iconID or spellInfo.originalIconID
            end
        end
        frame._currentItemName = config.name or (C_Spell.GetSpellInfo(config.spellID) or {}).name
        frame._currentItemID = nil
    end
    
    if icon then
        frame.Icon:SetTexture(icon)
        -- NOTE: Don't set desaturation here - the update loop / spell engine handles cooldown state
    else
        frame.Icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        frame._currentItemID = nil
        frame._currentItemName = nil
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- POSITION MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.SaveFramePosition(arcID, point, relPoint, x, y)
    local db = GetDB()
    if not db then return end
    
    if not db.positions then db.positions = {} end
    db.positions[arcID] = {
        point = point or "CENTER",
        relPoint = relPoint or "CENTER",
        x = x or 0,
        y = y or 0,
    }
end

function ArcAuras.LoadFramePosition(arcID, frame)
    -- If CDMGroups is managing this frame, don't override its position
    -- CDMGroups uses savedPositions to track what it controls
    if ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID] then
        -- CLEANUP: Remove legacy db.positions since CDMGroups now manages this
        local db = GetDB()
        if db and db.positions and db.positions[arcID] then
            db.positions[arcID] = nil
        end
        return  -- CDMGroups has control, skip ArcAuras positioning
    end
    
    local db = GetDB()
    if not db or not db.positions or not db.positions[arcID] then
        -- Default position based on type
        local arcType, id = ArcAuras.ParseArcID(arcID)
        if arcType == "trinket" then
            local offset = (id == 13) and -30 or 30
            frame:SetPoint("CENTER", UIParent, "CENTER", offset, -200)
        else
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        end
        return
    end
    
    local pos = db.positions[arcID]
    frame:ClearAllPoints()
    frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- COOLDOWN UPDATE LOGIC
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM COOLDOWN RESOLUTION (unified, no pcall, GCD threshold filter)
-- ═══════════════════════════════════════════════════════════════════════════
-- Item-cooldown APIs (GetInventoryItemCooldown, C_Container.GetItemCooldown,
-- C_Item.GetItemCooldown) have NO ignoreGCD parameter — they return the raw
-- (startTime, duration) tuple. When the user uses an item and a GCD fires,
-- these APIs report the ~1-1.5s GCD as the item's cooldown. There is also
-- NO secret-safe DurationObject variant for items.
--
-- Filter rule: any reported duration below ITEM_GCD_THRESHOLD seconds is
-- treated as GCD/windup noise → return zero. GCD caps at 1.5s (unhasted);
-- real item cooldowns are always much longer (trinkets ≥20s, potions ≥60s,
-- shared trinket-slot CD = 20-30s). This matches the approach used in
-- ArcUI_CooldownReminder and is the simplest robust filter that works
-- without any pcall or secret-value comparison.
local ITEM_GCD_THRESHOLD = 1.5

-- Get the use-spell ID for an item (cached). Non-secret — GetItemSpell returns
-- the use-spell name+ID, or nil for passive items.
local itemUseSpellCache = {}
local function GetItemUseSpellID(itemID)
    if not itemID then return nil end
    local cached = itemUseSpellCache[itemID]
    if cached ~= nil then return cached or nil end
    local _, spellID = GetItemSpell(itemID)
    spellID = tonumber(spellID)
    itemUseSpellCache[itemID] = spellID or false
    return spellID
end

-- Resolve item cooldown to (startTime, duration, isGCD).
-- Returns 0,0,true when the reported duration is GCD-length noise.
-- All APIs are non-secret and return raw numbers — no pcall needed.
local function ResolveItemCooldown(itemID, slotID)
    local startTime, duration
    if slotID then
        startTime, duration = GetInventoryItemCooldown("player", slotID)
    end
    if not startTime then
        if C_Container and C_Container.GetItemCooldown then
            startTime, duration = C_Container.GetItemCooldown(itemID)
        elseif C_Item and C_Item.GetItemCooldown then
            startTime, duration = C_Item.GetItemCooldown(itemID)
        end
    end
    startTime = startTime or 0
    duration  = duration  or 0

    -- GCD/windup filter — anything below the threshold is noise, treat as ready.
    if duration > 0 and duration <= ITEM_GCD_THRESHOLD then
        return 0, 0, true
    end

    return startTime, duration, false
end

local function ApplyItemCooldownToFrame(frame, itemID, slotID)
    if frame._arcSwipePreviewActive then
        return frame._isOnCooldown, frame._remaining or 0
    end

    local arcID    = frame._arcAuraID
    local settings = ArcAuras.GetCachedSettings(arcID)
    local noGCDSwipe = settings and settings.cooldownSwipe and settings.cooldownSwipe.noGCDSwipe

    local startTime, duration, isGCD = ResolveItemCooldown(itemID, slotID)

    if isGCD then
        if noGCDSwipe and frame._lastDuration ~= 0 then
            frame.Cooldown:Clear()
            frame._lastStartTime = 0
            frame._lastDuration  = 0
        end
        frame._isOnCooldown = false
        frame._remaining    = 0
        frame._duration     = 0
        return false, 0
    end

    local cooldownChanged = (startTime ~= frame._lastStartTime) or (duration ~= frame._lastDuration)
    if cooldownChanged then
        if frame._durationObj and C_DurationUtil then
            frame._durationObj:SetTimeFromStart(startTime, duration)
            frame.Cooldown:SetCooldownFromDurationObject(frame._durationObj, true)
        else
            frame.Cooldown:SetCooldown(startTime, duration)
        end
        ApplySwipeColors(frame, settings)
        frame._lastStartTime = startTime
        frame._lastDuration  = duration
    end

    local isOnCooldown = duration and duration > 0
    local remaining    = 0
    if isOnCooldown then
        remaining = (startTime + duration) - GetTime()
        if remaining < 0 then remaining = 0; isOnCooldown = false end
    end

    frame._isOnCooldown = isOnCooldown
    frame._remaining    = remaining
    frame._duration     = duration

    if frame.Cooldown and frame.Cooldown.SetScript then
        if isOnCooldown then
            local aid = frame._arcAuraID
            frame.Cooldown:SetScript("OnCooldownDone", function()
                frame.Cooldown:SetScript("OnCooldownDone", nil)
                ArcAuras.UpdateArcItemFrame(frame, aid)
            end)
        else
            frame.Cooldown:SetScript("OnCooldownDone", nil)
        end
    end

    return isOnCooldown, remaining
end

local function UpdateTrinketCooldown(frame, slotID)
    -- Update icon if item changed
    local currentItemID = GetInventoryItemID("player", slotID)
    if currentItemID ~= frame._currentItemID then
        local config = frame._arcConfig
        ArcAuras.UpdateFrameIcon(frame, config)
        InvalidateStackCache(frame._arcAuraID)
        if currentItemID then itemUseSpellCache[currentItemID] = nil end
    end
    return ApplyItemCooldownToFrame(frame, currentItemID, slotID)
end

local function UpdateItemCooldown(frame, itemID)
    return ApplyItemCooldownToFrame(frame, itemID, nil)
end

-- Apply visual states based on settings
-- ═══════════════════════════════════════════════════════════════════════════
-- CDM ENHANCE INTEGRATION - Arc Auras provides cooldown STATE
-- CDM Enhance handles ALL visual effects (glow, alpha, desaturation)
-- ═══════════════════════════════════════════════════════════════════════════

--- Get the cooldown state for an Arc Aura
-- @param arcID The Arc Aura ID (e.g., "arc_trinket_13" or "arc_item_12345")
-- @return state ("ready" or "cooldown"), remaining (seconds), duration (seconds)
function ArcAuras.GetCooldownState(arcID)
    if not arcID then return "ready", 0, 0 end
    
    local frame = ArcAuras.frames and ArcAuras.frames[arcID]
    if not frame then return "ready", 0, 0 end
    
    -- Check frame's cached state
    if frame._isOnCooldown then
        return "cooldown", frame._remaining or 0, frame._duration or 0
    end
    
    return "ready", 0, 0
end

--- Check if an Arc Aura is ready (off cooldown)
-- @param arcID The Arc Aura ID
-- @return boolean true if ready
function ArcAuras.IsReady(arcID)
    local state = ArcAuras.GetCooldownState(arcID)
    return state == "ready"
end

--- Get all active Arc Aura frames
-- @return table of arcID -> frame
function ArcAuras.GetActiveFrames()
    return ArcAuras.frames or {}
end

--- Notify that cooldown state changed (called by update loop)
-- CDM Enhance can hook this to update visuals
function ArcAuras.NotifyStateChanged(arcID, isOnCooldown, remaining, duration)
    -- Fire a message that CDM Enhance can listen for
    if ns.CDMEnhance and ns.CDMEnhance.OnArcAuraStateChanged then
        ns.CDMEnhance.OnArcAuraStateChanged(arcID, isOnCooldown, remaining, duration)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PERFORMANCE: CACHED SETTINGS ACCESS
-- ═══════════════════════════════════════════════════════════════════════════

-- Get cached settings - avoids expensive GetEffectiveSettings() every tick
function ArcAuras.GetCachedSettings(arcID)
    local cached = settingsCache[arcID]
    local now = GetTime()
    
    -- Use cached if still valid
    if cached and (now - cached.timestamp) < SETTINGS_CACHE_TTL then
        return cached.settings
    end
    
    -- Cache miss or expired - fetch and cache
    local settings = ArcAuras.GetEffectiveSettings(arcID)
    settingsCache[arcID] = {
        settings = settings,
        timestamp = now,
    }
    
    return settings
end

-- Main update function - Updates cooldown display AND visual state
-- OPTIMIZED: Uses cached settings, cached LCG reference, state-change detection
-- Called when BAG_UPDATE_COOLDOWN fires or on initial state apply.
-- Handles a single non-spell arc frame (trinket/item).

-- ═══════════════════════════════════════════════════════════════════════════
-- TARGETED VISUAL APPLIERS (item/trinket frames only)
-- Each function handles ONE concern. Called only when that concern changes.
-- Never called for spell frames (_arcIsSpellCooldown = true).
-- ═══════════════════════════════════════════════════════════════════════════

-- Updates stack/count text only. Called from BAG_UPDATE_COOLDOWN for count-based items.
-- Definition of the function forward-declared above. Assigning to the
-- existing upvalue rather than creating a new local so RefreshStackTextStyle
-- (defined earlier) gets a working reference.
ApplyStackText = function(frame, arcID)
    if not frame._arcStackText then return end
    local config = frame._arcConfig
    if not config then return end
    -- Cache is invalidated by the event that triggered this call (BAG_UPDATE_COOLDOWN,
    -- SPELL_UPDATE_CHARGES, etc.) via InvalidateStackCache before ApplyStackText is
    -- reached. Pre-invalidating here caused ComputeStackDisplay to run on every call
    -- defeating the cache entirely.
    local displayValue, isCharges = GetStackDisplay(config, arcID)
    local settings = ArcAuras.GetCachedSettings(arcID)
    local chargeTextEnabled = not (settings and settings.chargeText and settings.chargeText.enabled == false)
    if displayValue ~= nil and chargeTextEnabled then
        frame._arcStackText:SetText(displayValue)
        frame._arcStackText:Show()
    else
        frame._arcStackText:SetText("")
        frame._arcStackText:Hide()
    end
end

-- Public: ArcUI_ArcAurasTimer needs to push stack text updates into the
-- shared ApplyStackText pipeline whenever a custom timer's stack count
-- changes (every proc / per-stack expiry).
ArcAuras.ApplyStackText = ApplyStackText

-- Returns cached stateVisuals, refreshing only when settings generation changed.
local function GetCachedStateVisuals(frame, arcID)
    if frame._settingsGeneration ~= settingsCacheGeneration or not frame._cachedStateVisuals_init then
        local settings = ArcAuras.GetCachedSettings(arcID)
        local sv = nil
        if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
            sv = ns.CDMEnhance.GetEffectiveStateVisuals(settings)
        end
        frame._cachedStateVisuals = sv
        frame._settingsGeneration = settingsCacheGeneration
        frame._cachedStateVisuals_init = true
        frame._cachedSettings = settings
    end
    return frame._cachedStateVisuals, frame._cachedSettings
end

-- Called only when isOnCooldown flips. Updates desat/alpha/tint/glow for cooldown state.
local function ApplyCooldownStateVisuals(frame, arcID, isOnCooldown)
    -- DURATION OVERRIDE: while active on this Arc item/trinket frame, the override
    -- owns the whole visual (treated as an aura override). Delegate and stop.
    if frame._arcDurOvActive and ns.DurationOverride and ns.DurationOverride.ApplyVisuals then
        ns.DurationOverride.ApplyVisuals(frame)
        return
    end
    local sv, settings = GetCachedStateVisuals(frame, arcID)
    local csv = settings and settings.cooldownStateVisuals or {}
    local rs = csv.readyState or {}
    local cs = csv.cooldownState or {}
    local iconTex = frame.Icon

    if isOnCooldown then
        -- Alpha
        local cooldownAlpha = cs.alpha ~= nil and cs.alpha or (sv and sv.cooldownAlpha) or 1.0
        if cooldownAlpha <= 0 and ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
            cooldownAlpha = 0.35
        end
        if frame._lastAppliedAlpha ~= cooldownAlpha then
            frame._arcTargetAlpha = cooldownAlpha
            frame._arcEnforceReadyAlpha = false
            frame._arcReadyAlphaValue = nil
            frame._arcBypassFrameAlphaHook = true
            frame:SetAlpha(cooldownAlpha)
            frame._arcBypassFrameAlphaHook = false
            frame._lastAppliedAlpha = cooldownAlpha
        end
        -- Preserve duration text
        local preserveText = (sv and sv.preserveDurationText) or (cs.preserveDurationText == true)
        local parentContainer = frame:GetParent()
        local groupHidden = frame._arcGroupHidden or (parentContainer and parentContainer._arcGroupHidden)
        if preserveText and not groupHidden then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(true)
                frame.Cooldown.Text:SetAlpha(1)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(true)
                frame._arcCooldownText:SetAlpha(1)
            end
            frame._arcPreserveDurationText = true
        elseif frame._arcPreserveDurationText then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(false)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(false)
            end
            frame._arcPreserveDurationText = false
        end
        -- Desaturation
        local noDesaturate = (sv and sv.noDesaturate) or (cs.noDesaturate == true)
        local shouldDesat = not noDesaturate
        local desatKey = shouldDesat and "desat" or "normal"
        if frame._lastDesatState ~= desatKey then
            frame._lastDesatState = desatKey
            if iconTex then
                if shouldDesat then
                    if iconTex.SetDesaturation then iconTex:SetDesaturation(1)
                    elseif iconTex.SetDesaturated then iconTex:SetDesaturated(true) end
                else
                    if iconTex.SetDesaturation then iconTex:SetDesaturation(0)
                    elseif iconTex.SetDesaturated then iconTex:SetDesaturated(false) end
                end
            end
        end
        -- Tint
        local cooldownTint = (sv and sv.cooldownTint) or (cs.tint == true)
        local tintColor = (sv and sv.cooldownTintColor) or cs.tintColor
        local tintKey = cooldownTint and tintColor or false
        if frame._lastTintRef ~= tintKey then
            frame._lastTintRef = tintKey
            if iconTex then
                if cooldownTint and tintColor then
                    local c = tintColor
                    iconTex:SetVertexColor(c.r or 0.5, c.g or 0.5, c.b or 0.5, 1)
                else
                    iconTex:SetVertexColor(1, 1, 1, 1)
                end
            end
        end
        -- Stop ready glow on cooldown start
        if frame._lastVisualState ~= "cooldown" then
            frame._lastVisualState = "cooldown"
            if ns.Glows and (frame._arcReadyGlowActive or ns.Glows.IsActive(frame, "ArcUI_ReadyGlow")) then
                ns.Glows.Stop(frame, "ArcUI_ReadyGlow")
            end
            frame._arcReadyGlowActive = false
            frame._arcPreviewGlowActive = false
            frame._arcCurrentGlowSig = nil
            if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
                ns.CustomLabel.UpdateVisibility(frame)
            end
        end
    else
        -- READY STATE
        local readyAlpha = rs.alpha ~= nil and rs.alpha or (sv and sv.readyAlpha) or 1.0
        local hideEverything = readyAlpha <= 0   -- frame is supposed to be invisible
        if hideEverything and ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
            readyAlpha = 0.35   -- panel preview override; flash still suppressed below
        end
        -- Tell ArcAurasCooldown not to play the CD→ready flash bling on
        -- frames whose ready-state alpha is 0. Without this, the flash
        -- animation is its own frame with its own alpha and plays for
        -- ~0.8s independent of the parent's alpha — visible "ghost flash"
        -- on icons the user has hidden via readyAlpha=0.
        frame._arcHideCooldownFlash = hideEverything
        frame._arcTargetAlpha = nil
        frame._arcEnforceReadyAlpha = true
        frame._arcReadyAlphaValue = readyAlpha
        if frame._lastAppliedAlpha ~= readyAlpha then
            frame._arcBypassFrameAlphaHook = true
            frame:SetAlpha(readyAlpha)
            frame._arcBypassFrameAlphaHook = false
            frame._lastAppliedAlpha = readyAlpha
        end
        -- Clear desat
        local desatKey = "normal"
        if frame._lastDesatState ~= desatKey then
            frame._lastDesatState = desatKey
            if iconTex then
                if iconTex.SetDesaturation then iconTex:SetDesaturation(0)
                elseif iconTex.SetDesaturated then iconTex:SetDesaturated(false) end
                iconTex:SetVertexColor(1, 1, 1, 1)
            end
        end
        -- Start ready glow on ready state
        if frame._lastVisualState ~= "ready" then
            frame._lastVisualState = "ready"
            if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
                ns.CustomLabel.UpdateVisibility(frame)
            end
            -- Glow evaluation only on state change
            local shouldGlow = sv and sv.readyGlow
            local combatOnly = sv and sv.readyGlowCombatOnly
            if shouldGlow and (not combatOnly or InCombatLockdown()) then
                if not frame._arcReadyGlowActive then
                    frame._arcReadyGlowActive = true
                    if ns.Glows then
                        ns.Glows.Start(frame, "ArcUI_ReadyGlow",
                            sv.readyGlowType or "button", {
                                color = sv.readyGlowColor or {1,1,1,1},
                                lines = sv.readyGlowLines or 8,
                                frequency = sv.readyGlowSpeed or 0.25,
                                thickness = sv.readyGlowThickness or 2,
                            })
                    end
                end
            else
                if frame._arcReadyGlowActive then
                    if ns.Glows then ns.Glows.Stop(frame, "ArcUI_ReadyGlow") end
                    frame._arcReadyGlowActive = false
                end
            end
        end
    end
end

-- Called only when isUsable/notEnoughMana flips. Only touches alpha + desat.
local function ApplyUsabilityVisuals(frame, arcID, isUsable)
    if frame._isOnCooldown then return end  -- cooldown state takes priority
    local sv, settings = GetCachedStateVisuals(frame, arcID)
    local csv = settings and settings.cooldownStateVisuals or {}
    local cs = csv.readyState or {}
    local iconTex = frame.Icon

    local isUnusable = not isUsable
    local desatKey = isUnusable and "desat_unusable" or "normal"
    if frame._lastDesatState ~= desatKey then
        frame._lastDesatState = desatKey
        if iconTex then
            if isUnusable then
                if iconTex.SetDesaturation then iconTex:SetDesaturation(1)
                elseif iconTex.SetDesaturated then iconTex:SetDesaturated(true) end
            else
                if iconTex.SetDesaturation then iconTex:SetDesaturation(0)
                elseif iconTex.SetDesaturated then iconTex:SetDesaturated(false) end
                iconTex:SetVertexColor(1, 1, 1, 1)
            end
        end
    end
    local csvReady = csv.readyState or {}
    local readyAlpha = csvReady.alpha ~= nil and csvReady.alpha or (sv and sv.readyAlpha) or 1.0
    local cooldownAlpha = (csv.cooldownState or {}).alpha
    local targetAlpha = isUnusable and (cooldownAlpha or 1.0) or readyAlpha
    if targetAlpha <= 0 and ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
        targetAlpha = 0.35
    end
    if isUnusable then
        frame._arcTargetAlpha = targetAlpha
        frame._arcEnforceReadyAlpha = false
        frame._arcReadyAlphaValue = nil
    else
        frame._arcTargetAlpha = nil
        frame._arcEnforceReadyAlpha = true
        frame._arcReadyAlphaValue = targetAlpha
    end
    if frame._lastAppliedAlpha ~= targetAlpha then
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(targetAlpha)
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = targetAlpha
    end
end

local function UpdateArcItemFrame(frame, arcID)
    if not (frame and frame:IsShown()) then return end
    if frame._arcIsSpellCooldown then return end
    do
            local config = frame._arcConfig
            if config then
                -- Step 1: Update the cooldown frame (sets the swipe animation)
                if config.type == "trinket" and config.slotID then
                    UpdateTrinketCooldown(frame, config.slotID)
                elseif config.type == "item" and config.itemID then
                    UpdateItemCooldown(frame, config.itemID)
                end
                
                -- Step 2: Use the internal cooldown state set by UpdateItemCooldown/UpdateTrinketCooldown
                -- frame._isOnCooldown is set by the actual cooldown API query and is authoritative
                -- Do NOT use frame.Cooldown:IsVisible() - it can return stale/incorrect values!
                local isOnCooldown = frame._isOnCooldown
                local remaining = frame._remaining or 0
                local iconTex = frame.Icon
                
                -- Step 3: Get visual settings from CACHE (not fresh every tick!)
                local settings = ArcAuras.GetCachedSettings(arcID)
                
                -- Get properly formatted state visuals from CDMEnhance if available
                -- OPTIMIZED: Refresh stateVisuals on state change OR when settings invalidated
                local stateVisuals = frame._cachedStateVisuals
                local stateChanged = (frame._lastVisualState == "ready") ~= (not isOnCooldown)
                local settingsChanged = (frame._settingsGeneration ~= settingsCacheGeneration)
                
                if stateChanged or settingsChanged or not stateVisuals then
                    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
                        stateVisuals = ns.CDMEnhance.GetEffectiveStateVisuals(settings)
                    end
                    frame._cachedStateVisuals = stateVisuals
                    frame._settingsGeneration = settingsCacheGeneration
                    -- Settings explicitly changed — kill any active glow, let this tick re-evaluate
                    if settingsChanged then
                        local hasActiveGlow = ns.Glows and ns.Glows.IsActive(frame, "ArcUI_ReadyGlow")
                        if hasActiveGlow then
                            ns.Glows.Stop(frame, "ArcUI_ReadyGlow")
                        end
                        frame._arcReadyGlowActive = false
                        frame._arcCurrentGlowSig = nil
                    end
                end
                
                -- Check if glow preview is active for this icon
                local isGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive and
                                      ns.CDMEnhanceOptions.IsGlowPreviewActive(arcID)
                
                -- Fallback to raw settings if CDMEnhance not available
                local csv = settings and settings.cooldownStateVisuals or {}
                local rs = csv.readyState or {}
                local cs = csv.cooldownState or {}
                
                -- Step 4: Apply visuals based on state
                -- NOTE: Preview mode forces ready-state visuals (glow) even when on cooldown
                if isOnCooldown and not isGlowPreview then
                    --===============================================
                    -- ON COOLDOWN: Desaturate, dim, stop ready glow
                    --===============================================
                    
                    -- Alpha: Check raw settings FIRST since that's where it's stored
                    -- stateVisuals.cooldownAlpha may not be populated correctly
                    local cooldownAlpha = cs.alpha ~= nil and cs.alpha or (stateVisuals and stateVisuals.cooldownAlpha) or 1.0
                    
                    -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
                    if cooldownAlpha <= 0 then
                        if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                            cooldownAlpha = 0.35
                        end
                    end
                    
                    -- OPTIMIZED: Only call SetAlpha when value changes
                    if frame._lastAppliedAlpha ~= cooldownAlpha then
                        frame._arcTargetAlpha = cooldownAlpha
                        frame._arcEnforceReadyAlpha = false
                        frame._arcReadyAlphaValue = nil
                        frame._arcBypassFrameAlphaHook = true
                        frame:SetAlpha(cooldownAlpha)
                        frame._arcBypassFrameAlphaHook = false
                        frame._lastAppliedAlpha = cooldownAlpha
                    end
                    
                    -- Desaturation - DEFAULT ON unless user disabled via noDesaturate
                    local noDesaturate = (stateVisuals and stateVisuals.noDesaturate) or (cs.noDesaturate == true)
                    local shouldDesaturate = not noDesaturate
                    -- OPTIMIZED: Only call SetDesaturation when value changes
                    local desatKey = shouldDesaturate and "desat" or "normal"
                    if frame._lastDesatState ~= desatKey then
                        frame._lastDesatState = desatKey
                        if iconTex then
                            if shouldDesaturate then
                                if iconTex.SetDesaturation then
                                    iconTex:SetDesaturation(1)
                                elseif iconTex.SetDesaturated then
                                    iconTex:SetDesaturated(true)
                                end
                            else
                                if iconTex.SetDesaturation then
                                    iconTex:SetDesaturation(0)
                                elseif iconTex.SetDesaturated then
                                    iconTex:SetDesaturated(false)
                                end
                            end
                        end
                    end
                    
                    -- Tint
                    local cooldownTint = (stateVisuals and stateVisuals.cooldownTint) or (cs.tint == true)
                    local tintColor = (stateVisuals and stateVisuals.cooldownTintColor) or cs.tintColor
                    -- OPTIMIZED: Only call SetVertexColor when tint state changes
                    local tintRef = cooldownTint and tintColor or false
                    if frame._lastTintRef ~= tintRef then
                        frame._lastTintRef = tintRef
                        if iconTex then
                            if cooldownTint and tintColor then
                                local c = tintColor
                                iconTex:SetVertexColor(c.r or 0.5, c.g or 0.5, c.b or 0.5, 1)
                            else
                                iconTex:SetVertexColor(1, 1, 1, 1)
                            end
                        end
                    end
                    
                    local preserveText = (stateVisuals and stateVisuals.preserveDurationText) or (cs.preserveDurationText == true)
                    local parentContainer = frame:GetParent()
                    local groupHidden = frame._arcGroupHidden or (parentContainer and parentContainer._arcGroupHidden)
                    if preserveText and not groupHidden then
                        if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                            frame.Cooldown.Text:SetIgnoreParentAlpha(true)
                            frame.Cooldown.Text:SetAlpha(1)
                        end
                        if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                            frame._arcCooldownText:SetIgnoreParentAlpha(true)
                            frame._arcCooldownText:SetAlpha(1)
                        end
                        frame._arcPreserveDurationText = true
                    elseif frame._arcPreserveDurationText then
                        if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                            frame.Cooldown.Text:SetIgnoreParentAlpha(false)
                        end
                        if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                            frame._arcCooldownText:SetIgnoreParentAlpha(false)
                        end
                        frame._arcPreserveDurationText = false
                    end

                    -- Stop ready glows (only on state change)
                    if frame._lastVisualState ~= "cooldown" then
                        frame._lastVisualState = "cooldown"
                        frame._arcReadyConfirmTicks = 0  -- Reset debounce counter
                        if ns.Glows and (frame._arcReadyGlowActive or ns.Glows.IsActive(frame, "ArcUI_ReadyGlow")) then
                            ns.Glows.Stop(frame, "ArcUI_ReadyGlow")
                        end
                        frame._arcReadyGlowActive = false
                        frame._arcPreviewGlowActive = false
                        frame._arcCurrentGlowSig = nil
                        -- Update custom label visibility on state change
                        if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
                            ns.CustomLabel.UpdateVisibility(frame)
                        end
                    end
                    
                    -- Threshold glow (when almost ready)
                    local tg = settings and settings.thresholdGlow
                    if tg and tg.enabled and remaining > 0 and ns.Glows then
                        if remaining <= (tg.seconds or 5) then
                            if not frame._thresholdGlowActive then
                                ns.Glows.Start(frame, "ArcAura_ThresholdGlow", "pixel", {
                                    color = tg.color or {1, 0.5, 0, 1},
                                    lines = 8, frequency = 0.25, thickness = 2,
                                })
                                frame._thresholdGlowActive = true
                            end
                        elseif frame._thresholdGlowActive then
                            ns.Glows.Stop(frame, "ArcAura_ThresholdGlow")
                            frame._thresholdGlowActive = false
                        end
                    end
                else
                    --===============================================
                    -- READY: Full color, full alpha, optional glow
                    --===============================================

                    -- Determine usability FIRST so alpha logic is consistent
                    local isLockedOut = frame._arcLockedOut
                    local isUnusableDim = false   -- controls alpha dimming
                    local isUnusableDesat = false -- controls desaturation
                    if config.type == "item" and config.itemID then
                        local count = GetItemCount(config.itemID, false, false)
                        local dimWhenEmpty = settings and settings.cooldownStateVisuals
                            and settings.cooldownStateVisuals.cooldownState
                            and settings.cooldownStateVisuals.cooldownState.dimWhenEmpty
                        local emptyDimAllowed = dimWhenEmpty == true  -- default OFF: nil means disabled
                        if count == 0 then
                            -- Item not in bags — always desat, only dim if dimWhenEmpty is on
                            isUnusableDesat = true
                            isUnusableDim = emptyDimAllowed
                        else
                            -- Item exists — respect actual usability/lockout (e.g. CC/fear)
                            local unusable = (frame._lastUsableResult == false) or isLockedOut
                            isUnusableDim = unusable
                            isUnusableDesat = unusable
                        end
                    elseif isLockedOut then
                        isUnusableDim = true
                        isUnusableDesat = true
                    end
                    local isUnusable = isUnusableDim  -- alias for glow suppression checks below

                    -- Alpha: unusable mirrors cooldown alpha; ready uses ready alpha
                    local readyAlpha = rs.alpha ~= nil and rs.alpha or (stateVisuals and stateVisuals.readyAlpha) or 1.0
                    local targetAlpha
                    if isUnusableDim then
                        targetAlpha = cs.alpha ~= nil and cs.alpha or (stateVisuals and stateVisuals.cooldownAlpha) or 1.0
                    else
                        targetAlpha = readyAlpha
                    end
                    -- OPTIONS PANEL PREVIEW: clamp to 0.35 so icon is visible while editing
                    if targetAlpha <= 0 then
                        if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                            targetAlpha = 0.35
                        end
                    end
                    -- ALWAYS update enforcement mode so the hook knows the current state,
                    -- even if the alpha value hasn't changed. Without this, untoggling
                    -- dimWhenEmpty leaves _arcTargetAlpha set (dim mode) when both alphas
                    -- happen to be equal, and the hook keeps enforcing the wrong state.
                    if isUnusableDim then
                        frame._arcTargetAlpha = targetAlpha
                        frame._arcEnforceReadyAlpha = false
                        frame._arcReadyAlphaValue = nil
                    else
                        frame._arcTargetAlpha = nil
                        frame._arcEnforceReadyAlpha = true
                        frame._arcReadyAlphaValue = targetAlpha
                    end
                    if frame._lastAppliedAlpha ~= targetAlpha then
                        frame._arcBypassFrameAlphaHook = true
                        frame:SetAlpha(targetAlpha)
                        frame._arcBypassFrameAlphaHook = false
                        frame._lastAppliedAlpha = targetAlpha
                    end
                    local desatKey = isUnusableDesat and "desat_unusable" or "normal"
                    if frame._lastDesatState ~= desatKey then
                        frame._lastDesatState = desatKey
                        if iconTex then
                            if isUnusableDesat then
                                if iconTex.SetDesaturation then
                                    iconTex:SetDesaturation(1)
                                elseif iconTex.SetDesaturated then
                                    iconTex:SetDesaturated(true)
                                end
                                iconTex:SetVertexColor(1, 1, 1, 1)
                            else
                                -- Normal ready state - no desaturation
                                if iconTex.SetDesaturation then
                                    iconTex:SetDesaturation(0)
                                elseif iconTex.SetDesaturated then
                                    iconTex:SetDesaturated(false)
                                end
                                iconTex:SetVertexColor(1, 1, 1, 1)
                            end
                        end
                    end
                    -- Reset preserve text on ready (matches ArcAurasCooldown pattern)
                    if frame._arcPreserveDurationText then
                        if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                            frame.Cooldown.Text:SetIgnoreParentAlpha(false)
                        end
                        if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                            frame._arcCooldownText:SetIgnoreParentAlpha(false)
                        end
                        frame._arcPreserveDurationText = false
                    end
                    
                    -- Stop threshold glow when ready
                    if ns.Glows and frame._thresholdGlowActive then
                        ns.Glows.Stop(frame, "ArcAura_ThresholdGlow")
                        frame._thresholdGlowActive = false
                    end
                    
                    -- Track state change for other purposes
                    local stateJustChanged = (frame._lastVisualState ~= "ready")
                    frame._lastVisualState = "ready"
                    
                    -- Update custom label visibility on state change
                    if stateJustChanged and ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
                        ns.CustomLabel.UpdateVisibility(frame)
                    end
                    
                    -- READY GLOW: Event-driven path has no data gaps, confirm immediately
                    local readyConfirmed = true
                    
                    -- GLOW HANDLING: Only update on state change or preview toggle
                    local shouldShowGlow = isGlowPreview or (stateVisuals and stateVisuals.readyGlow) or (rs.glow == true)
                    
                    -- Check combat-only restriction (but preview overrides this)
                    local glowCombatOnly = (stateVisuals and stateVisuals.readyGlowCombatOnly) or (rs.glowCombatOnly == true)
                    if glowCombatOnly and not InCombatLockdown() and not isGlowPreview then
                        shouldShowGlow = false
                    end
                    
                    -- Disable glow for unusable/locked out items (no glow when you can't use it)
                    -- Preview mode overrides this so you can still see what the glow looks like
                    if isUnusable and not isGlowPreview then
                        shouldShowGlow = false
                    end
                    
                    -- Suppress glow for consumed items (count = 0) — can't use what you don't have
                    if shouldShowGlow and not isGlowPreview and config.type == "item" and config.itemID then
                        local count = GetItemCount(config.itemID, false, false)
                        if count == 0 then
                            shouldShowGlow = false
                        end
                    end
                    
                    -- Block glow until debounce confirms ready state
                    if not readyConfirmed then
                        shouldShowGlow = false
                    end
                    
                    -- Track current glow state (ns.Glows is the authority, not the flag)
                    local glowCurrentlyShowing = ns.Glows and ns.Glows.IsActive(frame, "ArcUI_ReadyGlow") and true or false
                    -- Sync flag if it drifted
                    if frame._arcReadyGlowActive ~= glowCurrentlyShowing then
                        frame._arcReadyGlowActive = glowCurrentlyShowing
                    end
                    -- Detect if glow needs restart (sig cleared by resize in ApplySettingsToFrame)
                    local glowNeedsRestart = glowCurrentlyShowing and not frame._arcCurrentGlowSig
                    
                    -- Only start/stop glow on state change (not every tick!)
                    if shouldShowGlow and (stateJustChanged or not glowCurrentlyShowing or glowNeedsRestart) then
                        -- START glow
                        frame._arcReadyGlowActive = true
                        frame._arcPreviewGlowActive = isGlowPreview
                        
                        -- Build glow settings - prefer stateVisuals, fallback to raw readyState
                        local glowSettings = stateVisuals
                        if not glowSettings then
                            -- Create glow settings from raw readyState
                            glowSettings = {
                                readyGlow = true,
                                readyGlowType = rs.glowType or "button",
                                readyGlowColor = rs.glowColor,
                                readyGlowIntensity = rs.glowIntensity or 1.0,
                                readyGlowScale = rs.glowScale or 1.0,
                                readyGlowSpeed = rs.glowSpeed or 0.25,
                                readyGlowLines = rs.glowLines or 8,
                                readyGlowThickness = rs.glowThickness or 2,
                                readyGlowParticles = rs.glowParticles or 4,
                                readyGlowXOffset = rs.glowXOffset or 0,
                                readyGlowYOffset = rs.glowYOffset or 0,
                            }
                        end
                        
                        -- Start glow via unified Glows module
                        if ns.Glows then
                            local gc = glowSettings.readyGlowColor
                            local r, g, b = 1, 0.85, 0
                            if gc then
                                r = gc.r or gc[1] or 1
                                g = gc.g or gc[2] or 0.85
                                b = gc.b or gc[3] or 0
                            end
                            local intensity = glowSettings.readyGlowIntensity or 1.0
                            ns.Glows.Start(frame, "ArcUI_ReadyGlow", glowSettings.readyGlowType or "button", {
                                color = {r, g, b, intensity},
                                intensity = intensity,
                                scale = glowSettings.readyGlowScale or 1.0,
                                frequency = glowSettings.readyGlowSpeed or 0.25,
                                lines = glowSettings.readyGlowLines or 8,
                                thickness = glowSettings.readyGlowThickness or 2,
                                particles = glowSettings.readyGlowParticles or 4,
                                xOffset = glowSettings.readyGlowXOffset or 0,
                                yOffset = glowSettings.readyGlowYOffset or 0,
                                strata = glowSettings.readyGlowFrameStrata,
                                frameLevel = glowSettings.readyGlowFrameLevel,
                            })
                            -- Set signature to prevent restart-every-tick
                            frame._arcCurrentGlowSig = glowSettings.readyGlowType or "button"
                        end
                        
                    elseif not shouldShowGlow and glowCurrentlyShowing then
                        -- STOP glow
                        if ns.Glows then
                            ns.Glows.Stop(frame, "ArcUI_ReadyGlow")
                        end
                        frame._arcReadyGlowActive = false
                        frame._arcPreviewGlowActive = false
                        frame._arcCurrentGlowSig = nil
                    end
                end
                
                -- ═══════════════════════════════════════════════════════════════
                -- STACK/CHARGE COUNT UPDATE (uses cached values)
                -- ═══════════════════════════════════════════════════════════════
                local displayValue, isCharges = GetStackDisplay(config, arcID)
                
                -- frame._arcStackText is created in CreateArcAuraFrame, should always exist
                if frame._arcStackText then
                    -- Check if charge text is enabled in settings
                    local chargeTextEnabled = true
                    if settings and settings.chargeText and settings.chargeText.enabled == false then
                        chargeTextEnabled = false
                    end
                    
                    if displayValue ~= nil and chargeTextEnabled then
                        -- Apply styling from CDMEnhance chargeText settings
                        -- Only re-apply styling if not done recently (performance)
                        if not frame._arcStackStyleApplied then
                            ApplyStackTextStyle(frame, frame._arcStackText)
                            frame._arcStackStyleApplied = true
                        end
                        
                        -- Pass displayValue directly to SetText - it may be SECRET during combat!
                        -- Do NOT compare or manipulate the value, just display it
                        frame._arcStackText:SetText(displayValue)
                        frame._arcStackText:Show()
                    else
                        -- No stack/charges to show, or charge text disabled
                        frame._arcStackText:SetText("")
                        frame._arcStackText:Hide()
                    end
                end
                
                -- Notify CDM Enhance for border sync
                if frame._lastCooldownState ~= isOnCooldown then
                    frame._lastCooldownState = isOnCooldown
                    ArcAuras.NotifyStateChanged(arcID, isOnCooldown, remaining, frame._duration or 0)
                end
            end
    end -- close do
end -- UpdateArcItemFrame

-- ═══════════════════════════════════════════════════════════════════════════
-- SETTINGS INTEGRATION
-- ═══════════════════════════════════════════════════════════════════════════

local DEFAULT_ARCAURA_SETTINGS = {
    scale = 1.0,
    alpha = 1.0,
    zoom = 0.08,
    
    cooldownStateVisuals = {
        readyState = {
            alpha = 1.0,
            glow = false,
        },
        cooldownState = {
            alpha = 1.0,
            desaturate = true,  -- Match CDM behavior: desaturate when on cooldown
        },
    },
    
    cooldownSwipe = {
        showSwipe = true,
        showEdge = true,
        showBling = true,
    },
    
    thresholdGlow = {
        enabled = false,
        seconds = 5,
        color = {1, 0.5, 0, 1},
    },
    
    border = {
        enabled = false,
    },
}

-- Deep merge helper for nested tables
local function DeepMerge(base, override)
    if not override then return base end
    if not base then return override end
    
    local result = CopyTable(base)
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = DeepMerge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

function ArcAuras.GetEffectiveSettings(arcID)
    -- Start with Arc Aura defaults
    local result = CopyTable(DEFAULT_ARCAURA_SETTINGS)
    
    -- Use CDMEnhance's proper cascading merge if available
    -- This handles: defaults → globalCooldownSettings → per-icon settings
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveIconSettings then
        local cdmSettings = ns.CDMEnhance.GetEffectiveIconSettings(arcID)
        if cdmSettings then
            -- Merge CDMEnhance settings over Arc Aura defaults
            result = DeepMerge(result, cdmSettings)
        end
    else
        -- Fallback: direct DB access (legacy behavior)
        if ns.db and ns.db.profile and ns.db.profile.cdmEnhance and ns.db.profile.cdmEnhance.iconSettings then
            local perIcon = ns.db.profile.cdmEnhance.iconSettings[arcID]
            if perIcon then
                result = DeepMerge(result, perIcon)
            end
        end
    end
    
    -- Also merge Arc Auras-specific global settings (if any)
    local db = GetDB()
    if db and db.globalSettings and next(db.globalSettings) then
        result = DeepMerge(result, db.globalSettings)
    end
    
    return result
end

-- Apply CDMEnhance settings to an Arc Aura frame
-- Called by CDMEnhance.UpdateIcon via Integration patch
function ArcAuras.ApplySettingsToFrame(arcID, frame)
    if not frame then
        frame = ArcAuras.frames[arcID]
    end
    if not frame then return end
    
    -- Invalidate settings cache when applying new settings
    InvalidateSettingsCache(arcID)
    
    local cfg = ArcAuras.GetEffectiveSettings(arcID)
    if not cfg then return end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SIZE: Check if frame is in a group - if so, use group size
    -- ═══════════════════════════════════════════════════════════════════════════
    local width, height
    local inGroup = false
    
    -- Check if frame is in a CDMGroup
    if ns.CDMGroups and ns.CDMGroups.groups then
        for groupName, group in pairs(ns.CDMGroups.groups) do
            if group.members and group.members[arcID] then
                inGroup = true
                -- Use group's slot dimensions (respects group iconSize/width/height)
                if ns.CDMGroups.GetSlotDimensions then
                    width, height = ns.CDMGroups.GetSlotDimensions(group.layout)
                else
                    -- Fallback: calculate manually
                    local baseScale = 36
                    local iconSize = group.layout.iconSize or 36
                    local iconWidth = group.layout.iconWidth or 36
                    local iconHeight = group.layout.iconHeight or 36
                    local scale = iconSize / baseScale
                    width = iconWidth * scale
                    height = iconHeight * scale
                end
                break
            end
        end
    end
    
    -- If not in a group, use ArcAura's own size settings
    if not inGroup then
        local scale = cfg.scale or 1
        -- Use freeIcons stored iconSize as the fallback base so this path and
        -- RefreshAllGroupLayouts/RefreshIconLayout (which use data.iconSize as
        -- their fallback) agree when cfg.width is nil. ArcAura frames use
        -- _arcAuraID as their key into freeIcons — NOT _arcCooldownID.
        local freeIconKey = frame._arcAuraID or frame._arcCooldownID
        local storedBase = (frame._cdmgIsFreeIcon
            and ns.CDMGroups and ns.CDMGroups.freeIcons
            and freeIconKey
            and ns.CDMGroups.freeIcons[freeIconKey]
            and ns.CDMGroups.freeIcons[freeIconKey].iconSize) or 40
        local baseWidth = cfg.width or storedBase
        local baseHeight = cfg.height or storedBase
        width = baseWidth * scale
        height = baseHeight * scale
    end
    
    frame:SetSize(width, height)

    -- Sync freeIcons stored iconSize so TrackFreeIcon re-runs read the correct
    -- base. Uses _arcAuraID (the correct key for ArcAura frames in freeIcons).
    if frame._cdmgIsFreeIcon and ns.CDMGroups and ns.CDMGroups.freeIcons then
        local syncKey = frame._arcAuraID or frame._arcCooldownID
        if syncKey and ns.CDMGroups.freeIcons[syncKey] then
            local syncBase = (not inGroup) and (cfg.width or ns.CDMGroups.freeIcons[syncKey].iconSize or 40) or width
            ns.CDMGroups.freeIcons[syncKey].iconSize = syncBase
            frame._cdmgFreeTargetSize = syncBase
        end
    end

    -- CRITICAL: Invalidate glow signature when size changes. LCG glow textures
    -- are sized at creation time — if the frame was resized after glow started
    -- (common during loading when CDMGroups enforces group sizes), the glow
    -- stays at the old size. Clearing the sig causes the next glow evaluation
    -- to detect a mismatch and restart with correct dimensions.
    frame._arcCurrentGlowSig = nil
    
    -- Ensure scale is 1 (size is handled above)
    frame:SetScale(1)
    
    -- Check if Masque is globally enabled - skip ArcUI visuals even if frame not yet registered
    -- This prevents visual conflicts during zone load when frames are updated before Masque registration
    local masqueActive = ns.Masque and ns.Masque.IsEnabled and ns.Masque.IsEnabled()
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- MASQUE RE-SKIN: When Masque is active, it calculates Icon insets based on
    -- the frame size at registration time. If frame:SetSize() above changed the
    -- size (e.g. group layout assigns 36x36 but frame was registered at 40x40),
    -- Masque's insets go stale — Icon bleeds past the Masque border artwork.
    -- Fix: Detect size change and force Masque to re-register at the new size.
    -- ═══════════════════════════════════════════════════════════════════════════
    if masqueActive and frame._arcMasqueAdded and ns.Masque then
        local oldW = frame._arcMasqueSkinW or 0
        local oldH = frame._arcMasqueSkinH or 0
        if math.abs(oldW - width) > 0.1 or math.abs(oldH - height) > 0.1 then
            frame._arcMasqueSkinW = width
            frame._arcMasqueSkinH = height
            -- Force re-registration: clear guard flag so AddFrame doesn't skip
            frame._arcMasqueAdded = nil
            ns.Masque.AddFrame(frame, "ArcAuras", arcID)
        end
    end
    
    -- Get zoom and padding from config (needed for cooldown positioning even when Masque is active)
    local zoom = cfg.zoom or 0.08
    local padding = cfg.padding or 0
    
    -- Apply zoom/texcoords (skip if Masque is active)
    if frame.Icon then
        if masqueActive then
            -- Masque controls icon completely - don't touch it at all
            -- Just override padding/zoom values so any later code doesn't try to use them
            zoom = 0
            padding = 0
        else
            -- ArcUI controls icon - apply zoom and padding
            frame.Icon:SetTexCoord(zoom, 1 - zoom, zoom, 1 - zoom)
            
            -- Apply icon padding (insets the icon from the frame edges)
            if padding > 0 then
                frame.Icon:ClearAllPoints()
                frame.Icon:SetPoint("TOPLEFT", frame, "TOPLEFT", padding, -padding)
                frame.Icon:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -padding, padding)
            else
                frame.Icon:ClearAllPoints()
                frame.Icon:SetAllPoints()
            end
        end
    end
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- COOLDOWN ANIMATION SETTINGS (full CDMEnhance parity)
    -- ═══════════════════════════════════════════════════════════════════════════
    if frame.Cooldown then
        local swipe = cfg.cooldownSwipe or {}
        
        -- Basic swipe settings (apply regardless of Masque - these are user preferences)
        frame.Cooldown:SetDrawSwipe(swipe.showSwipe ~= false)
        frame.Cooldown:SetDrawEdge(swipe.showEdge ~= false)
        frame.Cooldown:SetDrawBling(swipe.showBling ~= false)
        frame.Cooldown:SetReverse(swipe.reverse == true)
        
        -- Swipe color (skip when Masque controls cooldowns — skin owns colors)
        local masqueControlsCooldowns = ns.Masque and ns.Masque.ShouldMasqueControlCooldowns
            and ns.Masque.ShouldMasqueControlCooldowns()
        if not masqueControlsCooldowns then
            if swipe.swipeColor then
                local sc = swipe.swipeColor
                frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
            else
                -- Default black swipe
                frame.Cooldown:SetSwipeColor(0, 0, 0, 0.7)
            end
        end
        
        -- Edge scale
        if swipe.edgeScale and frame.Cooldown.SetEdgeScale then
            frame.Cooldown:SetEdgeScale(swipe.edgeScale)
        end
        
        -- Edge color (skip when Masque controls cooldowns)
        if not masqueControlsCooldowns then
            if swipe.edgeColor and frame.Cooldown.SetEdgeColor then
                local ec = swipe.edgeColor
                frame.Cooldown:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
            end
        end
        
        -- Swipe insets (adjust cooldown frame positioning)
        -- Skip positioning when Masque is active - Masque controls size and position
        if masqueActive then
            if not masqueControlsCooldowns then
                -- MASQUE ACTIVE but not controlling cooldowns: Anchor cooldown to the Icon texture.
                -- Masque skins inset the Icon within the button frame. Anchoring to Icon ensures
                -- the cooldown swipe perfectly matches the visible icon area, not the full button.
                frame.Cooldown:ClearAllPoints()
                frame.Cooldown:SetAllPoints(frame.Icon or frame)
                frame.Cooldown._arcPaddingX = 0
                frame.Cooldown._arcPaddingY = 0
            end
            -- When masqueControlsCooldowns: Masque owns cooldown completely, don't touch
        else
            local swipeInsetX, swipeInsetY
            
            if swipe.separateInsets then
                swipeInsetX = swipe.swipeInsetX or 0
                swipeInsetY = swipe.swipeInsetY or 0
            else
                local inset = swipe.swipeInset or 0
                swipeInsetX = inset
                swipeInsetY = inset
            end
            
            local totalPaddingX = padding + swipeInsetX
            local totalPaddingY = padding + swipeInsetY
            
            -- Apply insets to cooldown frame
            frame.Cooldown:ClearAllPoints()
            frame.Cooldown:SetPoint("TOPLEFT", frame, "TOPLEFT", totalPaddingX, -totalPaddingY)
            frame.Cooldown:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -totalPaddingX, totalPaddingY)
            
            -- Store padding for hooks
            frame.Cooldown._arcPaddingX = totalPaddingX
            frame.Cooldown._arcPaddingY = totalPaddingY
            
            -- Apply texcoord range to cooldown swipe to match icon crop
            if swipe.showSwipe ~= false then
                local left, right, top, bottom = zoom, 1 - zoom, zoom, 1 - zoom
                if frame.Cooldown.SetSwipeTexCoords then
                    frame.Cooldown:SetSwipeTexCoords(left, right, top, bottom)
                end
            end
        end
        
        -- Store settings for hooks to reference
        frame._arcShowSwipe = swipe.showSwipe ~= false
        frame._arcShowEdge = swipe.showEdge ~= false
        frame._arcReverse = swipe.reverse == true
        frame._arcSwipeColor = swipe.swipeColor
        frame._arcSwipeWaitForNoCharges = swipe.swipeWaitForNoCharges
        frame._arcEdgeWaitForNoCharges = swipe.edgeWaitForNoCharges
    end
    
    -- Apply border if CDMEnhance has border functions
    if ns.CDMEnhance and ns.CDMEnhance.ApplyBorder then
        ns.CDMEnhance.ApplyBorder(frame, arcID)
        
        -- Track the size at which border was applied
        frame._arcBorderAppliedW = frame:GetWidth()
        frame._arcBorderAppliedH = frame:GetHeight()
        
        -- Hook SetSize (once) so that when external systems (FrameController, CDMGroups)
        -- resize the frame AFTER ApplySettingsToFrame, the border gets re-applied.
        -- Without this, borders draw at the old size until the options panel triggers a refresh.
        if not frame._arcBorderSizeHooked then
            frame._arcBorderSizeHooked = true
            hooksecurefunc(frame, "SetSize", function(self, w, h)
                -- Only re-apply if size actually changed from what border was drawn at
                local bw = self._arcBorderAppliedW or 0
                local bh = self._arcBorderAppliedH or 0
                if math.abs(bw - w) > 0.5 or math.abs(bh - h) > 0.5 then
                    self._arcBorderAppliedW = w
                    self._arcBorderAppliedH = h
                    -- Defer to next frame to avoid re-entrance during layout passes
                    if not self._arcBorderResizePending then
                        self._arcBorderResizePending = true
                        C_Timer.After(0, function()
                            self._arcBorderResizePending = nil
                            if self:IsShown() and ns.CDMEnhance and ns.CDMEnhance.ApplyBorder then
                                local aid = self._arcAuraID
                                if aid then
                                    ns.CDMEnhance.ApplyBorder(self, aid)
                                end
                            end
                        end)
                    end
                end
            end)
        end
    end
end

--- Refresh just the swipe/edge colors for a frame (called when settings change)
-- This forces immediate update without waiting for cooldown state change
function ArcAuras.RefreshSwipeColors(arcID)
    local frame = ArcAuras.frames[arcID]
    if not frame or not frame.Cooldown then return end
    
    -- Skip when Masque controls cooldowns — skin owns swipe/edge colors
    if ns.Masque and ns.Masque.ShouldMasqueControlCooldowns
       and ns.Masque.ShouldMasqueControlCooldowns() then return end
    
    -- Invalidate cache to get fresh settings
    InvalidateSettingsCache(arcID)
    
    local settings = ArcAuras.GetEffectiveSettings(arcID)
    if not settings or not settings.cooldownSwipe then return end
    
    local swipe = settings.cooldownSwipe
    
    -- Apply swipe color
    if swipe.swipeColor then
        local sc = swipe.swipeColor
        frame.Cooldown:SetSwipeColor(sc.r or 0, sc.g or 0, sc.b or 0, sc.a or 0.8)
    else
        frame.Cooldown:SetSwipeColor(0, 0, 0, 0.7)
    end
    
    -- Apply edge color
    if swipe.edgeColor and frame.Cooldown.SetEdgeColor then
        local ec = swipe.edgeColor
        frame.Cooldown:SetEdgeColor(ec.r or 1, ec.g or 1, ec.b or 1, ec.a or 1)
    end
    
    -- Update cached color
    frame._arcSwipeColor = swipe.swipeColor
end

--- Refresh swipe colors for all Arc Aura frames
function ArcAuras.RefreshAllSwipeColors()
    for arcID, frame in pairs(ArcAuras.frames) do
        ArcAuras.RefreshSwipeColors(arcID)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TOOLTIP & CONTEXT MENU
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.ShowTooltip(frame)
    local config = frame._arcConfig
    
    if config.type == "trinket" then
        local itemID = GetInventoryItemID("player", config.slotID)
        if itemID then
            GameTooltip:SetInventoryItem("player", config.slotID)
        else
            GameTooltip:AddLine(config.name or "Empty Trinket Slot", 1, 1, 1)
            GameTooltip:AddLine("No trinket equipped", 0.7, 0.7, 0.7)
        end
    elseif config.type == "item" then
        GameTooltip:SetItemByID(config.itemID)
    elseif config.type == "spell" then
        if config.spellID then
            GameTooltip:SetSpellByID(config.spellID)
        else
            GameTooltip:AddLine(config.name or "Unknown Spell", 1, 1, 1)
        end
    elseif config.type == "timer" then
        if config.spellID then
            GameTooltip:SetSpellByID(config.spellID)
        else
            GameTooltip:AddLine(config.name or "Custom Timer", 1, 1, 1)
        end
        GameTooltip:AddLine("|cffFFCC00Custom Timer|r", 1, 0.8, 0)
    end
    
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cff00CCFFArc Auras|r", 0, 0.8, 1)
    
    -- Show auto-track indicator
    if config.isAutoTrackSlot then
        GameTooltip:AddLine("|cff88ff88Auto-Tracked Slot|r", 0.5, 1, 0.5)
    end
    
    -- Show forceShow and iconOverride indicators for spell frames
    if config.type == "spell" and frame._arcAuraID then
        local db = GetDB()
        local trackedConfig = db and db.trackedSpells and db.trackedSpells[frame._arcAuraID]
        if trackedConfig then
            if trackedConfig.forceShow then
                GameTooltip:AddLine("|cff00FF00Always Show|r (spec check bypassed)", 0, 1, 0)
            end
            if trackedConfig.iconOverride then
                GameTooltip:AddLine("|cffFFCC00Custom Icon|r (ID: " .. (trackedConfig.iconOverrideID or "?") .. ")", 1, 0.8, 0)
            end
        end
    end
    
    -- Show iconOverride indicator for item/trinket frames
    if (config.type == "item" or config.type == "trinket") and frame._arcAuraID then
        local db = GetDB()
        local trackedConfig = db and db.trackedItems and db.trackedItems[frame._arcAuraID]
        if trackedConfig and trackedConfig.iconOverride then
            GameTooltip:AddLine("|cffFFCC00Custom Icon|r (ID: " .. (trackedConfig.iconOverrideID or "?") .. ")", 1, 0.8, 0)
        end
    end
    
    GameTooltip:AddLine("Right-click for options", 0.7, 0.7, 0.7)
    
    if frame._isOnCooldown and frame._remaining then
        GameTooltip:AddLine(string.format("Cooldown: %.1fs", frame._remaining), 1, 0.8, 0)
    end
end

function ArcAuras.ShowContextMenu(frame)
    -- Dispatch spell frames to ArcAurasCooldown context menu
    if frame._arcIsSpellCooldown and ns.ArcAurasCooldown and ns.ArcAurasCooldown.ShowContextMenu then
        ns.ArcAurasCooldown.ShowContextMenu(frame)
        return
    end
    
    MenuUtil.CreateContextMenu(frame, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle("Arc Auras: " .. (frame._currentItemName or frame._arcAuraID))
        rootDescription:CreateButton("Configure Icon", function()
            ArcAuras.OpenIconConfig(frame._arcAuraID)
        end)
        rootDescription:CreateButton("Change Icon...", function()
            ArcAuras.ShowIconOverridePicker(frame._arcAuraID, frame)
        end)
        rootDescription:CreateButton("Reset Position", function()
            ArcAuras.ResetFramePosition(frame._arcAuraID)
        end)
        rootDescription:CreateButton("Hide This Frame", function()
            ArcAuras.SetTrackedItemEnabled(frame._arcAuraID, false)
        end)
    end)
end

function ArcAuras.OpenIconConfig(arcID)
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.OpenIconConfig then
        ns.CDMEnhanceOptions.OpenIconConfig(arcID)
    else
        print("|cff00CCFF[Arc Auras]|r Icon configuration panel not available")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ICON OVERRIDE (for item frames)
-- Spell frames use ArcAurasCooldown.ShowIconOverridePicker instead.
-- Accepts a Spell ID or Item ID to source the icon texture from.
-- ═══════════════════════════════════════════════════════════════════════════

StaticPopupDialogs["ARCAURAS_ICON_OVERRIDE"] = {
    text = "Enter a Spell ID or Item ID for the new icon:\n(Enter 0 or leave blank to reset to default)",
    button1 = "Apply", button2 = "Cancel",
    hasEditBox = true,
    OnShow = function(self)
        self.editBox:SetNumeric(true)
        self.editBox:SetFocus()
        local data = self.data
        if data and data.currentOverrideID then
            self.editBox:SetText(tostring(data.currentOverrideID))
            self.editBox:HighlightText()
        end
    end,
    OnAccept = function(self, data)
        local inputID = tonumber(self.editBox:GetText())
        if data and data.arcID then
            ArcAuras.ApplyIconOverride(data.arcID, inputID)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        local inputID = tonumber(self:GetText())
        local data = dialog.data
        if data and data.arcID then
            ArcAuras.ApplyIconOverride(data.arcID, inputID)
        end
        dialog:Hide()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

function ArcAuras.ShowIconOverridePicker(arcID, frame)
    local db = GetDB()
    if not db then return end
    
    -- Find config in either trackedItems or trackedTrinkets
    local config = db.trackedItems and db.trackedItems[arcID]
    local currentOverrideID = config and config.iconOverrideID or nil
    
    local dialog = StaticPopup_Show("ARCAURAS_ICON_OVERRIDE")
    if dialog then
        dialog.data = { arcID = arcID, currentOverrideID = currentOverrideID }
        if currentOverrideID and dialog.editBox then
            dialog.editBox:SetText(tostring(currentOverrideID))
            dialog.editBox:HighlightText()
        end
    end
end

function ArcAuras.ApplyIconOverride(arcID, overrideID)
    local db = GetDB()
    if not db then return end
    
    local config = db.trackedItems and db.trackedItems[arcID]
    if not config then return end
    
    -- Reset if 0 or nil
    if not overrideID or overrideID <= 0 then
        config.iconOverride = nil
        config.iconOverrideID = nil
        -- Restore original icon
        local frame = ArcAuras.frames and ArcAuras.frames[arcID]
        if frame then
            ArcAuras.SetFrameIcon(frame, config)
        end
        print("|cff00CCFF[Arc Auras]|r Icon reset to default for " .. (config.name or arcID))
        return
    end
    
    -- Try as spell ID first, then item ID
    local newIcon, sourceName = nil, nil
    
    local spellInfo = C_Spell.GetSpellInfo(overrideID)
    if spellInfo and (spellInfo.iconID or spellInfo.originalIconID) then
        newIcon = spellInfo.iconID or spellInfo.originalIconID
        sourceName = spellInfo.name
    end
    
    if not newIcon then
        local itemIcon = C_Item.GetItemIconByID(overrideID)
        if itemIcon then
            newIcon = itemIcon
            sourceName = C_Item.GetItemNameByID(overrideID) or ("Item " .. overrideID)
        end
    end
    
    if not newIcon then
        print("|cff00CCFF[Arc Auras]|r Could not find icon for ID " .. overrideID)
        return
    end
    
    config.iconOverride = newIcon
    config.iconOverrideID = overrideID
    
    local frame = ArcAuras.frames and ArcAuras.frames[arcID]
    if frame and frame.Icon then
        frame.Icon:SetTexture(newIcon)
    end
    
    print(string.format("|cff00CCFF[Arc Auras]|r Icon changed to %s (%d) for %s",
        sourceName or "?", overrideID, config.name or arcID))
end

function ArcAuras.ResetFramePosition(arcID)
    -- Clear from legacy db.positions
    local db = GetDB()
    if db and db.positions then
        db.positions[arcID] = nil
    end
    
    -- Also clear from CDMGroups savedPositions (profile system)
    if ns.CDMGroups then
        if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID] then
            ns.CDMGroups.savedPositions[arcID] = nil
        end
        if ns.CDMGroups.ClearPositionFromSpec then
            ns.CDMGroups.ClearPositionFromSpec(arcID)
        end
        -- Also remove from freeIcons if tracked there
        if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
            ns.CDMGroups.ReleaseFreeIcon(arcID)
        end
    end
    
    local frame = ArcAuras.frames[arcID]
    if frame then
        frame:ClearAllPoints()
        ArcAuras.LoadFramePosition(arcID, frame)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TRACKED ITEMS MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.GetTrackedItems()
    local db = GetDB()
    if not db then return {} end
    return db.trackedItems or {}
end

function ArcAuras.AddTrackedItem(config)
    local db = GetDB()
    if not db then 
        print("|cffFF4444[Arc Auras]|r ERROR: Database not ready, cannot add item")
        return false 
    end
    
    -- CRITICAL: Ensure trackedItems exists
    if not db.trackedItems then 
        db.trackedItems = {} 
    end
    
    local arcID
    local itemID  -- For passive detection
    
    if config.type == "trinket" then
        arcID = ArcAuras.MakeTrinketID(config.slotID)
        -- Get itemID from slot for passive detection
        itemID = GetInventoryItemID("player", config.slotID)
    elseif config.type == "item" then
        arcID = ArcAuras.MakeItemID(config.itemID)
        itemID = config.itemID
    else
        print("|cffFF4444[Arc Auras]|r ERROR: Invalid item type:", config.type)
        return false
    end
    
    -- Check if already tracked
    if db.trackedItems[arcID] then
        -- Already exists - just return true without creating duplicate
        return true
    end
    
    -- Detect if item is passive (no on-use spell)
    local isPassive = IsItemPassive(itemID)
    
    -- Create the entry
    local entry = {
        type = config.type,
        slotID = config.slotID,
        itemID = config.itemID,
        enabled = true,
        isPassive = isPassive,
        isAutoTrackSlot = config.isAutoTrackSlot or false,
        hideWhenUnequipped = config.hideWhenUnequipped or false,
    }
    
    -- Save to database
    db.trackedItems[arcID] = entry
    
    -- VALIDATION: Verify it was actually saved
    if not db.trackedItems[arcID] then
        print("|cffFF4444[Arc Auras]|r ERROR: Failed to save item to database!")
        return false
    end
    
    -- Invalidate caches
    InvalidateSettingsCache(arcID)
    InvalidateStackCache(arcID)
    
    if ArcAuras.isEnabled then
        -- Skip frame creation for items with hideWhenUnequipped that aren't equipped
        if config.type == "item" and config.hideWhenUnequipped and config.itemID then
            if not ArcAuras.IsItemEquipped(config.itemID) then
                -- Don't create frame — UpdateItemFrameVisibility will create when equipped
                return true
            end
        end
        
        local frame = ArcAuras.CreateFrame(arcID, db.trackedItems[arcID])
        if frame then
            ArcAuras.LoadFramePosition(arcID, frame)
            frame:Show()
            ArcAuras.ApplyInitialStateVisuals(arcID, frame)
            
            -- For items with on-use spells, schedule a delayed stack refresh
            -- This handles the case where tooltip data isn't ready immediately
            if config.type == "item" and config.itemID then
                local spellName, spellID = GetItemSpell(config.itemID)
                if spellID then
                    C_Timer.After(0.5, function()
                        if ArcAuras.frames[arcID] then
                            stackCache[arcID] = nil  -- Force recompute
                        end
                    end)
                end
            end
        end
    end
    
    return true
end

function ArcAuras.RemoveTrackedItem(arcID)
    local db = GetDB()
    if not db or not db.trackedItems then return end
    
    if db.trackedItems[arcID] then
        db.trackedItems[arcID] = nil
        ArcAuras.DestroyFrame(arcID)
        
        -- Also remove position from legacy storage
        if db.positions then
            db.positions[arcID] = nil
        end
        
        -- Also remove from CDMGroups savedPositions (profile system)
        if ns.CDMGroups then
            if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID] then
                ns.CDMGroups.savedPositions[arcID] = nil
            end
            if ns.CDMGroups.ClearPositionFromSpec then
                ns.CDMGroups.ClearPositionFromSpec(arcID)
            end
        end
    end
end

function ArcAuras.SetTrackedItemEnabled(arcID, enabled)
    local db = GetDB()
    if not db or not db.trackedItems or not db.trackedItems[arcID] then return end
    
    db.trackedItems[arcID].enabled = enabled
    
    if enabled and ArcAuras.isEnabled then
        -- Check hideWhenUnequipped — don't create if not equipped
        local config = db.trackedItems[arcID]
        if config.type == "item" and config.itemID and config.hideWhenUnequipped then
            if not IsItemEquipped(config.itemID) then
                return  -- stay destroyed, UpdateItemFrameVisibility will create when equipped
            end
        end
        
        ArcAuras.RecreateItemFrame(arcID)
    elseif not enabled and ArcAuras.frames[arcID] then
        ArcAuras.DestroyItemFramePreservePosition(arcID)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DESTROY / RECREATE HELPERS (shared by enable/disable + hideWhenUnequipped)
-- Destroy saves position, recreate restores it. No hiding — fully remove/add.
-- ═══════════════════════════════════════════════════════════════════════════

-- Destroy frame but preserve its savedPosition for later recreation
function ArcAuras.DestroyItemFramePreservePosition(arcID)
    local frame = ArcAuras.frames[arcID]
    if not frame then return end
    
    -- Save position BEFORE destroy (UnregisterExternalFrame wipes savedPositions)
    local savedPos = ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
    local savedPosCopy = nil
    if savedPos then
        savedPosCopy = {}
        for k, v in pairs(savedPos) do savedPosCopy[k] = v end
    end
    
    ArcAuras.DestroyFrame(arcID)
    
    -- Restore savedPosition so recreate reads the correct placement
    if savedPosCopy and ns.CDMGroups and ns.CDMGroups.savedPositions then
        ns.CDMGroups.savedPositions[arcID] = savedPosCopy
    end
end

-- Recreate a previously destroyed item frame, restoring its position
function ArcAuras.RecreateItemFrame(arcID)
    if ArcAuras.frames[arcID] then return end  -- already exists
    
    local db = GetDB()
    if not db or not db.trackedItems then return end
    local config = db.trackedItems[arcID]
    if not config then return end
    
    local frame = ArcAuras.CreateFrame(arcID, config)
    if not frame then return end
    
    frame:Show()
    ArcAuras.ApplyInitialStateVisuals(arcID, frame)
    
    -- Force position restore after a tick (CDMGroups registration is async sometimes)
    C_Timer.After(0.1, function()
        if not ArcAuras.frames[arcID] then return end
        if ns.CDMGroups then
            if ns.CDMGroups.RestoreArcAurasPositions then
                ns.CDMGroups.RestoreArcAurasPositions("[ItemRecreate]")
            end
            -- Layout all groups so newly registered members are positioned (not DETACHED)
            if ns.CDMGroups.groups then
                for _, group in pairs(ns.CDMGroups.groups) do
                    if group.Layout then group:Layout() end
                end
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TRINKET SLOT VISIBILITY (hide when empty, show when equipped)
-- When hidden, frames are removed from groups so they don't occupy space
-- ═══════════════════════════════════════════════════════════════════════════

-- Temporarily hide a trinket slot frame (when slot is empty)
-- Removes from group so it doesn't occupy space, preserves position for restoration
function ArcAuras.HideTrinketSlotFrame(arcID)
    local frame = ArcAuras.frames[arcID]
    if not frame then return end
    
    -- Destroy the frame (preserves savedPositions for later recreation)
    ArcAuras.DestroyItemFramePreservePosition(arcID)
end

-- Restore a trinket slot frame (when trinket is equipped or filter changed)
function ArcAuras.ShowTrinketSlotFrame(arcID)
    -- Guard: don't show if slot toggle is off
    local db = GetDB()
    if db and db.trackedItems and db.trackedItems[arcID] then
        local config = db.trackedItems[arcID]
        if config.isAutoTrackSlot and config.slotID then
            if not ArcAuras.IsAutoTrackSlotEnabled(config.slotID) then
                return
            end
        end
    end
    
    -- Recreate the frame (reads savedPositions for correct placement)
    ArcAuras.RecreateItemFrame(arcID)
end

function ArcAuras.ScanEquippedTrinkets()
    local result = {}
    for _, slot in ipairs(TRINKET_SLOTS) do
        local itemID, itemName, itemIcon = GetSlotItemInfo(slot.slotID)
        result[slot.slotID] = {
            slotID = slot.slotID,
            slotName = slot.name,
            itemID = itemID,
            itemName = itemName,
            itemIcon = itemIcon,
            isOnUse = itemID and IsItemOnUse(itemID),
        }
    end
    return result
end

-- Check if auto-track equipped trinkets is enabled
function ArcAuras.IsAutoTrackEquippedTrinketsEnabled()
    local db = GetDB()
    if not db then return false end
    -- db.autoTrackEquippedTrinkets defaults to false (line 168)
    -- Treat nil as false to match the DB default
    return db.autoTrackEquippedTrinkets == true
end

-- Set auto-track equipped trinkets
function ArcAuras.SetAutoTrackEquippedTrinkets(enabled)
    local db = GetDB()
    if not db then return end
    
    local wasEnabled = db.autoTrackEquippedTrinkets
    db.autoTrackEquippedTrinkets = enabled
    
    -- If disabling, HIDE auto-track slot frames (preserve position for re-enable)
    if wasEnabled ~= false and not enabled then
        if db.trackedItems then
            local hidCount = 0
            for arcID, config in pairs(db.trackedItems) do
                if config.isAutoTrackSlot then
                    local frame = ArcAuras.frames[arcID]
                    if frame then
                        ArcAuras.HideTrinketSlotFrame(arcID)
                        hidCount = hidCount + 1
                    end
                end
            end
            if hidCount > 0 then
                InvalidateSettingsCache()
                InvalidateStackCache()
            end
        end
    -- If enabling, show existing hidden frames or create new ones
    elseif enabled and wasEnabled == false then
        local needsAutoAdd = false
        for _, slot in ipairs(TRINKET_SLOTS) do
            local arcID = ArcAuras.MakeTrinketID(slot.slotID)
            local frame = ArcAuras.frames[arcID]
            local config = db.trackedItems and db.trackedItems[arcID]
            
            if config and config.isAutoTrackSlot then
                -- Frame may have been destroyed by HideTrinketSlotFrame — check slot visibility
                if ArcAuras.IsAutoTrackSlotEnabled(slot.slotID) then
                    local itemID = GetInventoryItemID("player", slot.slotID)
                    if itemID then
                        local onlyOnUse = db.onlyOnUseTrinkets
                        if not onlyOnUse or not IsItemPassive(itemID) then
                            ArcAuras.ShowTrinketSlotFrame(arcID)  -- recreates if destroyed, shows if hidden
                        end
                    end
                end
            elseif not frame and not config then
                -- No frame or config at all - need AutoAddTrinkets
                needsAutoAdd = true
            end
        end
        
        if needsAutoAdd then
            ArcAuras.AutoAddTrinkets(nil, true)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PER-SLOT AUTO-TRACK MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if a specific slot is enabled for auto-tracking
function ArcAuras.IsAutoTrackSlotEnabled(slotID)
    local db = GetDB()
    if not db then return true end  -- Default to enabled
    if not db.autoTrackSlots then return true end
    -- Handle nil as true (enabled by default)
    if db.autoTrackSlots[slotID] == nil then
        return true
    end
    return db.autoTrackSlots[slotID]
end

-- Enable/disable auto-tracking for a specific slot
function ArcAuras.SetAutoTrackSlotEnabled(slotID, enabled)
    local db = GetDB()
    if not db then return end
    
    if not db.autoTrackSlots then
        db.autoTrackSlots = {}
    end
    
    local wasEnabled = db.autoTrackSlots[slotID]
    db.autoTrackSlots[slotID] = enabled
    
    local arcID = ArcAuras.MakeTrinketID(slotID)
    
    if enabled and wasEnabled == false then
        -- Slot was disabled, now enabled
        if ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
            local itemID = GetInventoryItemID("player", slotID)
            if itemID then
                local onlyOnUse = db.onlyOnUseTrinkets
                local isPassive = onlyOnUse and IsItemPassive(itemID)
                
                -- Frame may have been destroyed by HideTrinketSlotFrame
                local frame = ArcAuras.frames[arcID]
                local slotConfig = db.trackedItems and db.trackedItems[arcID]
                if slotConfig then
                    -- Config exists (frame destroyed or hidden) - recreate/show
                    if not isPassive then
                        ArcAuras.ShowTrinketSlotFrame(arcID)  -- RecreateItemFrame if destroyed
                    end
                    -- If passive with on-use filter, keep destroyed/hidden
                elseif not frame and not slotConfig then
                    -- No frame and no tracked entry - create fresh
                    ArcAuras.AddTrackedItem({
                        type = "trinket",
                        slotID = slotID,
                        enabled = true,
                        isAutoTrackSlot = true,
                    })
                    -- If passive with on-use filter, hide immediately
                    if isPassive then
                        ArcAuras.HideTrinketSlotFrame(arcID)
                    end
                end
            end
        end
    elseif not enabled and wasEnabled ~= false then
        -- Slot was enabled, now disabled - HIDE the frame (preserve position)
        local frame = ArcAuras.frames[arcID]
        if frame then
            ArcAuras.HideTrinketSlotFrame(arcID)
        end
    end
    
    -- Invalidate caches
    InvalidateSettingsCache()
    InvalidateStackCache()
end

-- Get "only on-use trinkets" setting
function ArcAuras.IsOnlyOnUseTrinketsEnabled()
    local db = GetDB()
    if not db then return false end
    return db.onlyOnUseTrinkets or false
end

-- Set "only on-use trinkets" setting
function ArcAuras.SetOnlyOnUseTrinkets(enabled)
    local db = GetDB()
    if not db then return end
    
    local wasEnabled = db.onlyOnUseTrinkets
    db.onlyOnUseTrinkets = enabled
    
    -- If changed, refresh auto-track slots
    if enabled ~= wasEnabled and ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
        if enabled then
            -- Filter just got enabled - HIDE (not remove) passive trinkets
            for _, slot in ipairs(TRINKET_SLOTS) do
                local arcID = ArcAuras.MakeTrinketID(slot.slotID)
                local config = db.trackedItems and db.trackedItems[arcID]
                local frame = ArcAuras.frames[arcID]
                
                if config and config.isAutoTrackSlot and frame then
                    local itemID = GetInventoryItemID("player", slot.slotID)
                    if itemID and IsItemPassive(itemID) then
                        -- Hide the frame but keep trackedItem and position
                        ArcAuras.HideTrinketSlotFrame(arcID)
                    end
                end
            end
        else
            -- Filter disabled - SHOW hidden passive trinkets
            for _, slot in ipairs(TRINKET_SLOTS) do
                local arcID = ArcAuras.MakeTrinketID(slot.slotID)
                local config = db.trackedItems and db.trackedItems[arcID]
                local frame = ArcAuras.frames[arcID]
                
                if config and config.isAutoTrackSlot then
                    -- GUARD: Skip if per-slot toggle is OFF
                    if not ArcAuras.IsAutoTrackSlotEnabled(slot.slotID) then
                        -- Slot toggle is OFF - don't restore, keep hidden
                    elseif not frame then
                        -- Frame was destroyed (empty slot or filter) - recreate if trinket equipped
                        local itemID = GetInventoryItemID("player", slot.slotID)
                        if itemID then
                            ArcAuras.ShowTrinketSlotFrame(arcID)
                        end
                    end
                end
            end
        end
        
        -- Invalidate caches
        InvalidateSettingsCache()
        InvalidateStackCache()
    end
end

-- Get list of trinket slots for options display
function ArcAuras.GetTrinketSlots()
    return TRINKET_SLOTS
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HIDE WHEN UNEQUIPPED (for item-based frames)
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if hideWhenUnequipped is enabled for an item
function ArcAuras.IsHideWhenUnequippedEnabled(arcID)
    local db = GetDB()
    if not db or not db.trackedItems or not db.trackedItems[arcID] then
        return false
    end
    return db.trackedItems[arcID].hideWhenUnequipped or false
end

-- Set hideWhenUnequipped for an item (uses destroy/recreate)
function ArcAuras.SetHideWhenUnequipped(arcID, enabled)
    local db = GetDB()
    if not db or not db.trackedItems or not db.trackedItems[arcID] then
        return
    end
    
    local config = db.trackedItems[arcID]
    config.hideWhenUnequipped = enabled
    
    if config.type == "item" and config.itemID then
        if enabled and not IsItemEquipped(config.itemID) then
            -- Not equipped — destroy frame
            if ArcAuras.frames[arcID] then
                ArcAuras.DestroyItemFramePreservePosition(arcID)
            end
        elseif not enabled and not ArcAuras.frames[arcID] then
            -- Setting disabled, frame was destroyed — recreate
            if config.enabled and ArcAuras.isEnabled then
                ArcAuras.RecreateItemFrame(arcID)
            end
        end
    end
end

-- Check all item-based frames for equipped state and destroy/recreate accordingly
function ArcAuras.UpdateItemFrameVisibility()
    local db = GetDB()
    if not db or not db.trackedItems then return end
    
    for arcID, config in pairs(db.trackedItems) do
        if config.type == "item" and config.itemID and config.hideWhenUnequipped and config.enabled then
            local frame = ArcAuras.frames[arcID]
            local isEquipped = IsItemEquipped(config.itemID)
            
            if isEquipped and not frame and ArcAuras.isEnabled then
                -- Item equipped, no frame — recreate
                ArcAuras.RecreateItemFrame(arcID)
            elseif not isEquipped and frame then
                -- Item unequipped, frame exists — destroy
                ArcAuras.DestroyItemFramePreservePosition(arcID)
            end
        end
    end
end

-- Auto-add equipped on-use trinkets
-- @param onlyOnUse: boolean - if true, only add trinkets with on-use effects
--                            if nil, use the onlyOnUseTrinkets setting
-- @param asSlotTracker: boolean - if true, create slot-based frames (arc_trinket_13)
--                                 if false/nil, create item-based frames (arc_item_12345)
-- @return: number of trinkets added
function ArcAuras.AutoAddTrinkets(onlyOnUse, asSlotTracker)
    local db = GetDB()
    if not db then return 0 end
    
    -- If onlyOnUse is nil, use the setting
    local onlyOnUseSetting = db.onlyOnUseTrinkets
    if onlyOnUse == nil then
        onlyOnUse = onlyOnUseSetting
    end
    
    local trinkets = ArcAuras.ScanEquippedTrinkets()
    local added = 0
    
    for slotID, info in pairs(trinkets) do
        if info.itemID then
            -- Check if slot is enabled for auto-tracking (only for slot trackers)
            local slotEnabled = true
            if asSlotTracker then
                slotEnabled = ArcAuras.IsAutoTrackSlotEnabled(slotID)
            end
            
            if not slotEnabled then
                -- Skip this slot
            else
                -- For slot trackers, ALWAYS create the frame (for position preservation)
                -- but hide if on-use filter is on and trinket is passive
                if asSlotTracker then
                    local arcID = ArcAuras.MakeTrinketID(slotID)
                    if not db.trackedItems or not db.trackedItems[arcID] then
                        local success = ArcAuras.AddTrackedItem({
                            type = "trinket",
                            slotID = slotID,
                            enabled = true,
                            isAutoTrackSlot = true,
                        })
                        if success then
                            added = added + 1
                            
                            -- If on-use filter is on and trinket is passive, hide it
                            if onlyOnUseSetting and not info.isOnUse then
                                local frame = ArcAuras.frames[arcID]
                                if frame then
                                    ArcAuras.HideTrinketSlotFrame(arcID)
                                end
                            end
                        end
                    end
                else
                    -- ITEM-BASED: Only create if on-use (or filter not set)
                    if not onlyOnUse or info.isOnUse then
                        local arcID = ArcAuras.MakeItemID(info.itemID)
                        if not db.trackedItems or not db.trackedItems[arcID] then
                            local success = ArcAuras.AddTrackedItem({
                                type = "item",
                                itemID = info.itemID,
                                enabled = true,
                            })
                            if success then
                                added = added + 1
                            end
                        end
                    end
                end
            end
        end
    end
    
    return added
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UPDATE LOOP CONTROL (no-op: item/trinket frames are event-driven via BAG_UPDATE_COOLDOWN)
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.StartUpdateLoop() end
function ArcAuras.StopUpdateLoop() end

-- ═══════════════════════════════════════════════════════════════════════════
-- ENABLE/DISABLE
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAuras.Enable()
    if ArcAuras.isEnabled then return end
    ArcAuras.isEnabled = true
    
    local db = GetDB()
    if not db then return end
    
    db.enabled = true
    local onlyOnUse = db.onlyOnUseTrinkets
    
    for arcID, config in pairs(db.trackedItems or {}) do
        if config.enabled then
            -- Skip items filtered by spec/talent conditions
            -- (trinkets skip this — they don't have spec filters)
            if config.type == "item" and not ArcAuras.ShouldItemBeVisible(arcID, config) then
                -- Don't create frame — spec/talent filter excludes it
            elseif config.type == "item" and config.itemID and config.hideWhenUnequipped and not IsItemEquipped(config.itemID) then
                -- Don't create frame — hideWhenUnequipped and not equipped
                -- UpdateItemFrameVisibility will create when equipped
            else
            local frame = ArcAuras.CreateFrame(arcID, config)
            if frame then
                local shouldHide = false
                
                -- For trinket slot trackers, check visibility conditions
                if config.type == "trinket" and config.slotID then
                    -- If auto-track is globally disabled, hide auto-track slot frames
                    if config.isAutoTrackSlot and not ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
                        shouldHide = true
                    elseif config.isAutoTrackSlot and not ArcAuras.IsAutoTrackSlotEnabled(config.slotID) then
                        -- Individual slot disabled
                        shouldHide = true
                    else
                        local itemID = GetInventoryItemID("player", config.slotID)
                        
                        if not itemID then
                            -- Slot is empty
                            shouldHide = true
                        elseif config.isAutoTrackSlot and onlyOnUse and IsItemPassive(itemID) then
                            -- Passive trinket with on-use filter
                            shouldHide = true
                        end
                    end
                end
                
                if shouldHide then
                    -- Use HideTrinketSlotFrame for trinkets - properly hooks Show() to block re-showing
                    ArcAuras.HideTrinketSlotFrame(arcID)
                else
                    frame:Show()
                    -- Apply proper state visuals (respects saved alpha settings)
                    ArcAuras.ApplyInitialStateVisuals(arcID, frame)
                end
            end
            end -- else (not spec/talent filtered)
        end
    end
    
    ArcAuras.StartUpdateLoop()
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- SPELL COOLDOWN FRAMES: Create frames for tracked spells the player knows
    -- ArcAurasCooldown is initialized after ArcAuras, so we defer briefly
    -- ═══════════════════════════════════════════════════════════════════════════
    C_Timer.After(0.3, function()
        if not ArcAuras.isEnabled then return end
        local db2 = GetDB()
        if not db2 or not db2.trackedSpells then return end
        
        for arcID, config in pairs(db2.trackedSpells) do
            local existingFrame = ArcAuras.frames[arcID]
            local spellID = config.spellID
            
            -- Use full visibility check (spec filter + talent conditions),
            -- not just IsPlayerSpell. Without this, frames that should be
            -- hidden by spec/talent conditions get created on reload,
            -- registering with CDMGroups and corrupting saved positions.
            local shouldShow = false
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ShouldFrameBeVisible then
                shouldShow = ns.ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)
            else
                -- Fallback if cooldown module not loaded yet (shouldn't happen after 0.3s)
                shouldShow = config.forceShow or (IsPlayerSpell and IsPlayerSpell(spellID)) or (IsSpellKnown and IsSpellKnown(spellID))
            end
            
            if existingFrame then
                -- Frame already exists (hidden by Disable) - re-show if appropriate
                if shouldShow then
                    existingFrame:Show()
                    ArcAuras.ApplyInitialStateVisuals(arcID, existingFrame)
                    -- Re-initialize with cooldown engine so state tracking resumes
                    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InitializeSpellFrame then
                        local spellConfig = {
                            type = "spell",
                            spellID = spellID,
                            name = config.name,
                            icon = config.iconOverride or config.icon,
                            enabled = true,
                        }
                        ns.ArcAurasCooldown.InitializeSpellFrame(arcID, existingFrame, spellConfig)
                    end
                end
            elseif shouldShow then
                -- No frame yet - create it
                local spellConfig = {
                    type = "spell",
                    spellID = spellID,
                    name = config.name,
                    icon = config.iconOverride or config.icon,
                    enabled = true,
                }
                local frame = ArcAuras.CreateFrame(arcID, spellConfig)
                if frame then
                    frame:Show()
                    -- Let ArcAurasCooldown engine take over
                    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InitializeSpellFrame then
                        ns.ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
                    end
                end
            end
        end
    end)
    
    -- ═══════════════════════════════════════════════════════════════════════════
    -- POST-ENABLE VERIFICATION SWEEP
    -- After all frames (items + spells) are created and RegisterExternalFrame has
    -- run, verify each frame is in the correct group according to savedPositions.
    -- This catches cases where RegisterExternalFrame didn't check savedPositions
    -- (e.g., after import/reload when profile data has arc_ IDs in specific groups
    -- but RegisterExternalFrame defaulted them to "Essential" or left them free).
    -- Runs at +1.5s to ensure both item frames (immediate) and spell frames (+0.3s)
    -- have been created and CDMGroups has fully loaded the active profile.
    -- ═══════════════════════════════════════════════════════════════════════════
    C_Timer.After(1.5, function()
        if not ArcAuras.isEnabled then return end
        if not ns.CDMGroups then return end
        
        -- Ensure savedPositions reference is current
        if ns.CDMGroups.GetProfileSavedPositions then
            ns.CDMGroups.GetProfileSavedPositions()
        end
        
        if not ns.CDMGroups.savedPositions then return end
        
        local correctedCount = 0
        for arcID, frame in pairs(ArcAuras.frames) do
            if frame and frame:IsShown() then
                local saved = ns.CDMGroups.savedPositions[arcID]
                if saved then
                    if saved.type == "group" and saved.target then
                        -- Check if frame is already in the CORRECT group
                        local currentGroup = nil
                        if ns.CDMGroups.groups then
                            for gName, group in pairs(ns.CDMGroups.groups) do
                                if group.members and group.members[arcID] then
                                    currentGroup = gName
                                    break
                                end
                            end
                        end
                        
                        if currentGroup ~= saved.target then
                            -- Frame is in wrong group (or no group) - fix it
                            local targetGroup = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
                            if targetGroup then
                                -- Remove from current group if any
                                if currentGroup and ns.CDMGroups.groups[currentGroup] then
                                    local oldGroup = ns.CDMGroups.groups[currentGroup]
                                    if oldGroup.members then
                                        oldGroup.members[arcID] = nil
                                    end
                                end
                                
                                -- Also remove from freeIcons if tracked there
                                if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
                                    ns.CDMGroups.freeIcons[arcID] = nil
                                end
                                
                                -- Register into correct group
                                if targetGroup.AddMemberAtWithFrame then
                                    targetGroup:AddMemberAtWithFrame(arcID, saved.row or 0, saved.col or 0, frame, nil)
                                elseif ns.CDMGroups.RegisterExternalFrame then
                                    ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", saved.target)
                                end
                                correctedCount = correctedCount + 1
                            end
                        end
                    elseif saved.type == "free" then
                        -- Check if frame is tracked as free icon
                        local inGroup = false
                        if ns.CDMGroups.groups then
                            for _, group in pairs(ns.CDMGroups.groups) do
                                if group.members and group.members[arcID] then
                                    inGroup = true
                                    break
                                end
                            end
                        end
                        
                        if inGroup then
                            -- Frame is in a group but should be free - remove and make free
                            for _, group in pairs(ns.CDMGroups.groups) do
                                if group.members and group.members[arcID] then
                                    group.members[arcID] = nil
                                    break
                                end
                            end
                        end
                        
                        if not (ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID]) then
                            -- Track as free icon at saved position
                            if ns.CDMGroups.TrackFreeIcon then
                                ns.CDMGroups.TrackFreeIcon(arcID, saved.x or 0, saved.y or 0, saved.iconSize or 36, frame)
                                correctedCount = correctedCount + 1
                            end
                        end
                    end
                end
            end
        end
        
        -- If any frames were corrected, re-layout all groups
        if correctedCount > 0 then
            if ns.CDMGroups.groups then
                for _, group in pairs(ns.CDMGroups.groups) do
                    if group.Layout then group:Layout() end
                end
            end
        end
        
        -- ═══════════════════════════════════════════════════════════════════════
        -- APPLY CLICK-THROUGH / TOOLTIP STATE
        -- All Arc Aura frames (items, trinkets, spells, timers, custom icons) are
        -- now created and registered with CDMGroups. Run the same RefreshIconSettings
        -- sweep that opening the options panel triggers, so the saved click-through
        -- and tooltip settings actually apply at login/enable instead of only after
        -- the user opens and closes the panel.
        -- ═══════════════════════════════════════════════════════════════════════
        if ns.CDMGroups.RefreshIconSettings then
            ns.CDMGroups.RefreshIconSettings()
        end
    end)
end

function ArcAuras.Disable()
    if not ArcAuras.isEnabled then return end
    ArcAuras.isEnabled = false
    
    local db = GetDB()
    if db then db.enabled = false end
    
    ArcAuras.StopUpdateLoop()
    
    for arcID, frame in pairs(ArcAuras.frames) do
        frame:Hide()
    end
end

function ArcAuras.Toggle()
    if ArcAuras.isEnabled then
        ArcAuras.Disable()
    else
        ArcAuras.Enable()
    end
end

function ArcAuras.IsEnabled()
    return ArcAuras.isEnabled
end

-- Reload all frames from DB (used after import/profile load)
-- Destroys all existing frames and recreates them from current trackedItems
function ArcAuras.Reload()
    local db = GetDB()
    if not db then return end
    
    local wasEnabled = ArcAuras.isEnabled
    
    -- Destroy all existing frames
    if ArcAuras.isEnabled then
        ArcAuras.Disable()
    end
    
    -- Force clear all frame objects (Disable may leave some behind)
    for arcID, frame in pairs(ArcAuras.frames) do
        if frame then
            -- Clear Show hook so new frame gets a fresh one
            if frame._arcOriginalShow then
                frame.Show = frame._arcOriginalShow
                frame._arcOriginalShow = nil
            end
            frame:Hide()
        end
    end
    wipe(ArcAuras.frames)
    
    -- Clear spell engine state tables
    if ns.ArcAurasCooldown then
        if ns.ArcAurasCooldown.spellFrames then wipe(ns.ArcAurasCooldown.spellFrames) end
        if ns.ArcAurasCooldown.spellData then wipe(ns.ArcAurasCooldown.spellData) end
        if ns.ArcAurasCooldown.spellsByID then wipe(ns.ArcAurasCooldown.spellsByID) end
    end
    
    -- Re-enable if it was enabled or DB says enabled
    if wasEnabled or db.enabled then
        ArcAuras.Enable()
        
        -- Auto-add equipped trinkets if auto-track is enabled.
        -- Enable() only creates frames from trackedItems. During profile switch,
        -- the incoming profile may not have trinket entries in trackedItems even
        -- though auto-track is a character-wide setting. This mirrors the login
        -- path (line ~4401) but without delay since items are already loaded.
        if ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
            ArcAuras.AutoAddTrinkets(nil, true)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SYNC TO PROFILE (import-only)
-- ═══════════════════════════════════════════════════════════════════════════
-- Called when a cross-character imported profile has arcAuras data.
-- Diffs existing frames vs current char DB: creates missing, destroys removed.
-- Does NOT destroy-all/recreate-all. Frames that already exist survive.
-- ═══════════════════════════════════════════════════════════════════════════
function ArcAuras.SyncToProfile()
    if not ArcAuras.isEnabled then return end
    local db = GetDB()
    if not db then return end

    -- Build what SHOULD exist (items + auto-tracked trinkets)
    local shouldExist = {}
    for arcID, config in pairs(db.trackedItems or {}) do
        if config.enabled then shouldExist[arcID] = config end
    end
    -- NOTE: spells are discovered by ArcAurasCooldown timer, not synced here

    -- Destroy frames no longer tracked
    local toDestroy = {}
    for arcID, frame in pairs(ArcAuras.frames) do
        -- Only check item/trinket frames (spells managed by ArcAurasCooldown)
        if not frame._arcIsSpellCooldown and not shouldExist[arcID] then
            table.insert(toDestroy, arcID)
        end
    end
    for _, arcID in ipairs(toDestroy) do
        ArcAuras.DestroyFrame(arcID)
    end

    -- Create frames for newly tracked items (not yet existing)
    for arcID, config in pairs(shouldExist) do
        if not ArcAuras.frames[arcID] then
            local frame = ArcAuras.CreateFrame(arcID, config)
            if frame then
                ArcAuras.ApplyInitialStateVisuals(arcID, frame)
            end
        end
    end

    -- Refresh visibility on all surviving frames
    ArcAuras.RefreshVisibility()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SYNC SPELL FRAMES (lightweight — no position wipe)
-- Creates frames for newly tracked spells, destroys removed ones,
-- and refreshes existing frames' configs (forceShow, etc.)
-- ═══════════════════════════════════════════════════════════════════════════
function ArcAuras.SyncSpellFrames()
    if not ArcAuras.isEnabled then return end
    local db = GetDB()
    if not db or not db.trackedSpells then return end
    
    -- Build what SHOULD exist
    local shouldExist = {}
    for arcID, config in pairs(db.trackedSpells) do
        local spellID = config.spellID
        local shouldShow = false
        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ShouldFrameBeVisible then
            shouldShow = ns.ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)
        else
            shouldShow = config.forceShow or (IsPlayerSpell and IsPlayerSpell(spellID)) or (IsSpellKnown and IsSpellKnown(spellID))
        end
        if shouldShow then
            shouldExist[arcID] = config
        end
    end
    
    -- Destroy spell frames no longer tracked
    local toDestroy = {}
    for arcID, frame in pairs(ArcAuras.frames) do
        if frame._arcIsSpellCooldown and not shouldExist[arcID] then
            toDestroy[#toDestroy + 1] = arcID
        end
    end
    for _, arcID in ipairs(toDestroy) do
        ArcAuras.DestroyFrame(arcID)
    end
    
    -- Create frames for newly tracked spells
    for arcID, config in pairs(shouldExist) do
        if not ArcAuras.frames[arcID] then
            local spellConfig = {
                type = "spell",
                spellID = config.spellID,
                name = config.name,
                icon = config.iconOverride or config.icon,
                enabled = true,
            }
            local frame = ArcAuras.CreateFrame(arcID, spellConfig)
            if frame then
                frame:Show()
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InitializeSpellFrame then
                    ns.ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
                end
            end
        end
    end
end

-- Combined sync for SharedProfiles Pull — updates both items and spells
-- without destroying positions
function ArcAuras.SyncAfterSharedPull()
    if not ArcAuras.isEnabled then return end
    ArcAuras.SyncToProfile()    -- items
    ArcAuras.SyncSpellFrames()  -- spells
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM VISIBILITY CHECK
-- ═══════════════════════════════════════════════════════════════════════════
-- Checks whether an item/trinket frame should be visible based on:
-- 1. Spec filter (showOnSpecs) — only show on selected specs
-- 2. Talent conditions (talentConditions) — require specific talents
-- 3. Equipment state (hideWhenUnequipped, slot empty, passive filter)
-- ═══════════════════════════════════════════════════════════════════════════
function ArcAuras.ShouldItemBeVisible(arcID, config)
    if not config or not config.enabled then return false end

    -- 1) Per-item spec filter (showOnSpecs = { 1, 3 } etc.)
    if config.showOnSpecs and #config.showOnSpecs > 0 then
        local currentSpec = GetSpecialization and GetSpecialization() or 1
        local specAllowed = false
        for _, spec in ipairs(config.showOnSpecs) do
            if spec == currentSpec then specAllowed = true break end
        end
        if not specAllowed then return false end
    end

    -- 2) Talent conditions ({nodeID, required} objects)
    if config.talentConditions and #config.talentConditions > 0 then
        if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
            local pass = ns.TalentPicker.CheckTalentConditions(
                config.talentConditions, config.talentConditionMode or "all")
            if not pass then return false end
        end
    end

    -- 3) Equipment-based checks (not spec/talent — these are runtime state)
    -- NOTE: These return true to let the frame exist but be hidden,
    -- handled by the caller (RefreshVisibility sets _arcHiddenUnequipped)

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH VISIBILITY
-- ═══════════════════════════════════════════════════════════════════════════
-- Re-evaluates show/hide for ALL frames based on current runtime conditions:
-- talent checks, equip checks, auto-track settings, on-use filters.
-- Also creates item frames that should be visible but don't exist yet
-- (e.g., after spec change makes an item's spec filter pass).
-- Called on every profile switch, spec change, and after SyncToProfile.
-- ═══════════════════════════════════════════════════════════════════════════
function ArcAuras.RefreshVisibility()
    if not ArcAuras.isEnabled then return end
    local db = GetDB()
    if not db then return end
    local onlyOnUse = db.onlyOnUseTrinkets

    -- Collect frames to destroy (can't destroy during pairs() iteration)
    local toDestroy = {}

    for arcID, frame in pairs(ArcAuras.frames) do
        local config = nil

        -- Get config from appropriate source
        if frame._arcIsSpellCooldown then
            config = db.trackedSpells and db.trackedSpells[arcID]
        else
            config = db.trackedItems and db.trackedItems[arcID]
        end

        if not config then
            -- Frame exists but config missing — hide but don't destroy
            -- (SyncToProfile handles destruction, this is visibility-only)
            frame:Hide()
        else
            local shouldDestroy = false
            local shouldHide = false

            if frame._arcIsSpellCooldown then
                -- Spell visibility: talent + spec check → destroy if not visible
                local spellID = config.spellID
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ShouldFrameBeVisible then
                    shouldDestroy = not ns.ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)
                else
                    shouldDestroy = not (IsPlayerSpell and IsPlayerSpell(spellID))
                end
            elseif config.type == "trinket" and config.slotID then
                -- Trinket visibility: auto-track toggles + slot empty + passive filter
                -- Trinkets don't support spec/talent filters (they're slot-based)
                if config.isAutoTrackSlot and not ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
                    shouldHide = true
                elseif config.isAutoTrackSlot and not ArcAuras.IsAutoTrackSlotEnabled(config.slotID) then
                    shouldHide = true
                else
                    local itemID = GetInventoryItemID("player", config.slotID)
                    if not itemID then
                        shouldHide = true
                    elseif config.isAutoTrackSlot and onlyOnUse and IsItemPassive(itemID) then
                        shouldHide = true
                    end
                end
            elseif config.type == "item" then
                -- Item visibility: spec filter + talent conditions → destroy if filtered
                if not ArcAuras.ShouldItemBeVisible(arcID, config) then
                    shouldDestroy = true
                elseif config.hideWhenUnequipped and config.itemID and not IsItemEquipped(config.itemID) then
                    shouldDestroy = true  -- destroy/recreate pattern for hideWhenUnequipped
                end
            end

            if shouldDestroy then
                table.insert(toDestroy, arcID)
            elseif shouldHide then
                if config.type == "trinket" then
                    ArcAuras.HideTrinketSlotFrame(arcID)
                else
                    HideOrPreview(frame)
                end
            else
                frame:Show()
                -- Item frames: use full UpdateArcItemFrame so 0-stack desaturation
                -- is re-evaluated (ApplyInitialStateVisuals only checks _isOnCooldown
                -- and would stamp "ready/saturated" onto a 0-stack item frame).
                -- Trinket and spell frames still use ApplyInitialStateVisuals (which
                -- skips spell frames entirely and hands them to FeedCooldown).
                if config.type == "item" and not frame._arcIsSpellCooldown then
                    UpdateArcItemFrame(frame, arcID)
                else
                    ArcAuras.ApplyInitialStateVisuals(arcID, frame)
                end
            end
        end
    end

    -- Destroy collected frames (safe — outside iteration)
    -- Preserve savedPositions across destroy (UnregisterExternalFrame wipes them)
    -- so re-creation on spec switch reads correct placement
    for _, arcID in ipairs(toDestroy) do
        local savedPos = ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
        ArcAuras.DestroyFrame(arcID)
        if savedPos and ns.CDMGroups and ns.CDMGroups.savedPositions then
            ns.CDMGroups.savedPositions[arcID] = savedPos
        end
    end

    -- CREATE missing item frames that should now be visible
    -- (e.g., after spec change makes an item's spec filter pass)
    for arcID, config in pairs(db.trackedItems or {}) do
        if config.enabled and not ArcAuras.frames[arcID] then
            -- Skip auto-track trinkets (handled by AutoAddTrinkets)
            if not config.isAutoTrackSlot then
                if ArcAuras.ShouldItemBeVisible(arcID, config) then
                    -- Skip creation for hideWhenUnequipped items that aren't equipped
                    if config.hideWhenUnequipped and config.itemID and not IsItemEquipped(config.itemID) then
                        -- Don't create — UpdateItemFrameVisibility handles equip events
                    else
                        local frame = ArcAuras.CreateFrame(arcID, config)
                        if frame then
                            frame:Show()
                            ArcAuras.ApplyInitialStateVisuals(arcID, frame)
                        end
                    end
                end
            end
        end
    end
end

-- Refresh all frames (called after spec change)
function ArcAuras.RefreshAllFrames()
    if not ArcAuras.isEnabled then return end
    
    local db = GetDB()
    if not db then return end
    
    -- Clear all caches
    InvalidateSettingsCache()
    InvalidateStackCache()
    
    -- Destroy all existing frames
    for arcID, frame in pairs(ArcAuras.frames) do
        if ns.CDMGroups and ns.CDMGroups.UnregisterExternalFrame then
            ns.CDMGroups.UnregisterExternalFrame(arcID)
        end
        
        -- Stop glows
        if ns.Glows then
            ns.Glows.StopAll(frame)
            if frame._arcGlowAnchor and frame._arcGlowAnchor ~= frame then
                ns.Glows.StopAll(frame._arcGlowAnchor)
            end
        end
        
        frame:Hide()
        frame:SetParent(nil)
    end
    wipe(ArcAuras.frames)
    
    -- Clear spell engine state tables
    if ns.ArcAurasCooldown then
        if ns.ArcAurasCooldown.spellFrames then wipe(ns.ArcAurasCooldown.spellFrames) end
        if ns.ArcAurasCooldown.spellData then wipe(ns.ArcAurasCooldown.spellData) end
        if ns.ArcAurasCooldown.spellsByID then wipe(ns.ArcAurasCooldown.spellsByID) end
    end
    
    -- Get on-use filter setting
    local onlyOnUse = db.onlyOnUseTrinkets
    
    -- Recreate all enabled tracked items
    for arcID, config in pairs(db.trackedItems or {}) do
        if config.enabled then
            -- Skip items filtered by spec/talent conditions
            if config.type == "item" and not ArcAuras.ShouldItemBeVisible(arcID, config) then
                -- Don't create frame — spec/talent filter excludes it
            elseif config.type == "item" and config.itemID and config.hideWhenUnequipped and not IsItemEquipped(config.itemID) then
                -- Don't create frame — hideWhenUnequipped and not equipped
            else
            local frame = ArcAuras.CreateFrame(arcID, config)
            if frame then
                local shouldHide = false
                
                -- For trinket slot trackers, check visibility conditions
                if config.type == "trinket" and config.slotID then
                    local itemID = GetInventoryItemID("player", config.slotID)
                    
                    if not itemID then
                        -- Slot is empty
                        shouldHide = true
                        frame._arcSlotEmpty = true
                    elseif config.isAutoTrackSlot and onlyOnUse and IsItemPassive(itemID) then
                        -- Passive trinket with on-use filter
                        shouldHide = true
                        frame._arcSlotEmpty = true
                    end
                end
                
                if shouldHide then
                    HideOrPreview(frame)
                else
                    frame:Show()
                    -- Apply proper state visuals (respects saved alpha settings)
                    ArcAuras.ApplyInitialStateVisuals(arcID, frame)
                end
            end
            end -- else (not spec/talent filtered)
        end
    end
    
    -- Recreate tracked spell frames
    if db.trackedSpells then
        for arcID, config in pairs(db.trackedSpells) do
            local spellID = config.spellID
            -- Use full visibility check (spec filter + talent conditions)
            local shouldShow = false
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ShouldFrameBeVisible then
                shouldShow = ns.ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)
            else
                shouldShow = config.forceShow or (IsPlayerSpell and IsPlayerSpell(spellID)) or (IsSpellKnown and IsSpellKnown(spellID))
            end
            if shouldShow then
                local spellConfig = {
                    type = "spell",
                    spellID = spellID,
                    name = config.name,
                    icon = config.iconOverride or config.icon,
                    enabled = true,
                }
                local frame = ArcAuras.CreateFrame(arcID, spellConfig)
                if frame then
                    frame:Show()
                    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InitializeSpellFrame then
                        ns.ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
                    end
                end
            end
        end
    end
    
    -- Invalidate caches
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
        ns.CDMEnhanceOptions.InvalidateCache()
    end
    if ns.ArcAurasOptions and ns.ArcAurasOptions.InvalidateCache then
        ns.ArcAurasOptions.InvalidateCache()
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FORCE SHOW ALL FRAMES (without resetting positions)
-- Used by the Refresh button to just show frames at their saved positions
-- ═══════════════════════════════════════════════════════════════════════════
function ArcAuras.ForceShowAllFrames()
    if not ArcAuras.isEnabled then return end
    
    local showCount = 0
    
    for arcID, frame in pairs(ArcAuras.frames) do
        if frame then
            -- Show the frame with proper state visuals (respects saved alpha settings)
            frame:Show()
            ArcAuras.ApplyInitialStateVisuals(arcID, frame)
            showCount = showCount + 1
            
            -- If in CDMGroups, restore to saved position
            if ns.CDMGroups and ns.CDMGroups.savedPositions then
                local saved = ns.CDMGroups.savedPositions[arcID]
                if saved then
                    if saved.type == "free" then
                        -- Restore free position
                        frame:ClearAllPoints()
                        frame:SetPoint("CENTER", UIParent, "CENTER", saved.x or 0, saved.y or 0)
                        frame:SetParent(UIParent)
                        
                        -- Ensure tracked as free icon
                        if ns.CDMGroups.TrackFreeIcon then
                            ns.CDMGroups.TrackFreeIcon(arcID, saved.x or 0, saved.y or 0, saved.iconSize or 36, frame)
                        end
                    elseif saved.type == "group" and saved.target then
                        -- Ensure in group
                        local targetGroup = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
                        if targetGroup and not targetGroup.members[arcID] then
                            if ns.CDMGroups.RegisterExternalFrame then
                                ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", saved.target)
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Trigger layout updates
    if ns.CDMGroups and ns.CDMGroups.groups then
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.Layout then group:Layout() end
        end
    end
    
    return showCount
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDMENHANCE INTEGRATION
-- Register Arc Auras frames with the CDMEnhance catalog system
-- ═══════════════════════════════════════════════════════════════════════════

-- Get all Arc Auras icons for catalog display
function ArcAuras.GetIcons()
    local result = {}
    
    local db = GetDB()
    if not db or not db.trackedItems then return result end
    
    for arcID, config in pairs(db.trackedItems) do
        if config.enabled then
            local frame = ArcAuras.frames[arcID]
            local name, icon = nil, nil
            local arcType, id = ArcAuras.ParseArcID(arcID)
            
            if arcType == "trinket" then
                local itemID = GetInventoryItemID("player", id)
                if itemID then
                    name, icon = GetItemNameAndIcon(itemID)
                    icon = icon or GetInventoryItemTexture("player", id)
                end
                name = name or ("Trinket Slot " .. id)
            elseif arcType == "item" then
                name, icon = GetItemNameAndIcon(config.itemID)
                name = name or ("Item " .. config.itemID)
            end
            
            result[arcID] = {
                cooldownID = arcID,
                arcID = arcID,
                arcType = arcType,
                itemID = config.itemID or (arcType == "trinket" and GetInventoryItemID("player", id)),
                slotID = arcType == "trinket" and id or nil,
                name = name or "Unknown",
                icon = icon or 134400,
                isArcAura = true,
                viewerName = "ArcAurasViewer",
                hasCustomPos = true,
                frame = frame,
            }
        end
    end
    
    -- Also include tracked spells
    if db.trackedSpells then
        for arcID, config in pairs(db.trackedSpells) do
            local frame = ArcAuras.frames[arcID]
            local name, icon = nil, nil
            if config.spellID then
                local spellInfo = C_Spell.GetSpellInfo(config.spellID)
                if spellInfo then
                    name = spellInfo.name
                    icon = spellInfo.iconID or spellInfo.originalIconID
                end
            end
            
            result[arcID] = {
                cooldownID = arcID,
                arcID = arcID,
                arcType = "spell",
                spellID = config.spellID,
                name = name or config.name or "Unknown",
                icon = icon or config.icon or 134400,
                isArcAura = true,
                isSpellCooldown = true,
                viewerName = "ArcAurasViewer",
                hasCustomPos = true,
                frame = frame,
            }
        end
    end
    
    return result
end

-- Register a single frame with CDMEnhance (call when frame is created)
function ArcAuras.RegisterWithCDMEnhance(arcID, frame)
    if not ns.CDMEnhance then return end
    
    -- Mark frame as enhanced
    frame._arcEnhanced = true
    frame._arcIsArcAura = true
    
    -- For spell cooldown frames, ensure noGCDSwipe defaults to true
    -- (CDM defaults to false, but Arc Aura cooldown frames should filter GCD by default)
    -- Only set if cooldownSwipe section doesn't exist yet (truly new config)
    if frame._arcIsSpellCooldown and ns.CDMEnhance.GetOrCreateIconSettings then
        local cfg = ns.CDMEnhance.GetOrCreateIconSettings(arcID)
        if cfg and not cfg.cooldownSwipe then
            cfg.cooldownSwipe = { noGCDSwipe = true }
        end
    end
    
    -- Apply icon style if CDMEnhance supports it
    if ns.CDMEnhance.ApplyIconStyle then
        C_Timer.After(0.1, function()
            if ArcAuras.frames[arcID] then
                ns.CDMEnhance.ApplyIconStyle(frame, arcID)
                -- Also apply our cooldown settings after CDMEnhance styling
                ArcAuras.ApplySettingsToFrame(arcID, frame)
                
                -- Apply charge/stack text styling from cascaded settings
                -- Without this, first creation uses hardcoded NumberFontNormal (yellow)
                -- instead of the user's globalCooldownSettings chargeText config
                if frame._arcStackText then
                    ApplyStackTextStyle(frame, frame._arcStackText)
                    frame._arcStackStyleApplied = true
                end
                
                -- CRITICAL: Apply initial state visuals (alpha, desat, glow)
                -- Without this, frames show at default alpha until BAG_UPDATE_COOLDOWN fires
                ArcAuras.ApplyInitialStateVisuals(arcID, frame)
            end
        end)
    else
        -- CDMEnhance.ApplyIconStyle not available, just apply our settings
        C_Timer.After(0.1, function()
            if ArcAuras.frames[arcID] then
                ArcAuras.ApplySettingsToFrame(arcID, frame)
                
                -- Apply charge/stack text styling from cascaded settings
                if frame._arcStackText then
                    ApplyStackTextStyle(frame, frame._arcStackText)
                    frame._arcStackStyleApplied = true
                end
                
                -- CRITICAL: Apply initial state visuals (alpha, desat, glow)
                ArcAuras.ApplyInitialStateVisuals(arcID, frame)
            end
        end)
    end
end

-- Apply initial state visuals (alpha, desaturation) for a frame
-- Called after frame creation to ensure correct visuals before first BAG_UPDATE_COOLDOWN fires
function ArcAuras.ApplyInitialStateVisuals(arcID, frame)
    if not frame then
        frame = ArcAuras.frames[arcID]
    end
    if not frame then return end
    
    -- SKIP spell cooldown frames - their state is managed by ArcAurasCooldown engine
    -- via DesatCooldown hooks and FeedCooldown. CDMEnhance settings are applied there.
    if frame._arcIsSpellCooldown then
        -- Trigger a re-feed if the spell engine is available
        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData then
            local fd = ns.ArcAurasCooldown.spellData[arcID]
            if fd then
                if ns.ArcAurasCooldown.FeedCooldown then
                    ns.ArcAurasCooldown.FeedCooldown(fd)
                end
                if ns.ArcAurasCooldown.UpdateProcGlow then
                    ns.ArcAurasCooldown.UpdateProcGlow(fd)
                end
            end
        end
        return
    end
    
    local config = frame._arcConfig
    if not config then return end
    
    -- Clear optimization caches to ensure values are applied
    frame._lastAppliedAlpha = nil
    frame._lastVisualState = nil
    frame._cachedStateVisuals = nil
    frame._lastDesatState = nil
    frame._lastTintRef = nil
    
    -- Get settings
    local settings = ArcAuras.GetCachedSettings(arcID)
    if not settings then return end
    
    -- Get state visuals
    local stateVisuals
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
        stateVisuals = ns.CDMEnhance.GetEffectiveStateVisuals(settings)
    end
    
    -- Fallback to raw settings
    local csv = settings and settings.cooldownStateVisuals or {}
    local cs = csv.cooldownState or {}
    local rs = csv.readyState or {}
    
    -- Determine cooldown state using internal state set by UpdateItemCooldown/UpdateTrinketCooldown
    -- frame._isOnCooldown is authoritative - do NOT use frame.Cooldown:IsVisible() which can be stale
    local isOnCooldown = frame._isOnCooldown
    
    local iconTex = frame.Icon
    
    if isOnCooldown then
        -- ON COOLDOWN: Apply cooldown alpha and desaturation
        local cooldownAlpha = cs.alpha ~= nil and cs.alpha or (stateVisuals and stateVisuals.cooldownAlpha) or 1.0
        
        -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
        if cooldownAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                cooldownAlpha = 0.35
            end
        end
        
        frame._arcTargetAlpha = cooldownAlpha
        frame._arcEnforceReadyAlpha = false
        frame._arcReadyAlphaValue = nil
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(cooldownAlpha)
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = cooldownAlpha
        
        -- Preserve duration text (same pattern as UpdateArcItemFrame)
        local preserveText = (stateVisuals and stateVisuals.preserveDurationText) or (cs.preserveDurationText == true)
        local parentContainer = frame:GetParent()
        local groupHidden = frame._arcGroupHidden or (parentContainer and parentContainer._arcGroupHidden)
        if preserveText and not groupHidden then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(true)
                frame.Cooldown.Text:SetAlpha(1)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(true)
                frame._arcCooldownText:SetAlpha(1)
            end
            frame._arcPreserveDurationText = true
        end
        
        -- Desaturation
        local noDesaturate = (stateVisuals and stateVisuals.noDesaturate) or (cs.noDesaturate == true)
        if iconTex then
            if not noDesaturate then
                if iconTex.SetDesaturation then
                    iconTex:SetDesaturation(1)
                elseif iconTex.SetDesaturated then
                    iconTex:SetDesaturated(true)
                end
            else
                if iconTex.SetDesaturation then
                    iconTex:SetDesaturation(0)
                elseif iconTex.SetDesaturated then
                    iconTex:SetDesaturated(false)
                end
            end
        end
    else
        -- READY: Apply ready alpha
        local readyAlpha = rs.alpha ~= nil and rs.alpha or (stateVisuals and stateVisuals.readyAlpha) or 1.0
        
        -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
        if readyAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                readyAlpha = 0.35
            end
        end
        
        frame._arcTargetAlpha = nil
        frame._arcEnforceReadyAlpha = true
        frame._arcReadyAlphaValue = readyAlpha
        frame._arcBypassFrameAlphaHook = true
        frame:SetAlpha(readyAlpha)
        frame._arcBypassFrameAlphaHook = false
        frame._lastAppliedAlpha = readyAlpha
        
        -- Ready state: no desaturation
        if iconTex then
            if iconTex.SetDesaturation then
                iconTex:SetDesaturation(0)
            elseif iconTex.SetDesaturated then
                iconTex:SetDesaturated(false)
            end
        end
    end
    
    frame._lastVisualState = isOnCooldown and "cooldown" or "ready"
end

-- Refresh settings for a single Arc Aura frame
-- Called by CDMEnhance when settings change (via options panel)
function ArcAuras.RefreshFrameSettings(arcID)
    local frame = ArcAuras.frames[arcID]
    if not frame then return end
    
    -- Invalidate caches
    InvalidateSettingsCache(arcID)
    frame._cachedStateVisuals = nil  -- Force refresh of state visuals
    frame._arcStackStyleApplied = false  -- Re-apply stack text style
    
    -- CRITICAL: Clear visual state caches to force immediate re-application
    -- Without this, the optimization checks in UpdateArcItemFrame may skip applying new values
    frame._lastAppliedAlpha = nil  -- Force alpha re-application
    frame._lastVisualState = nil   -- Force visual state re-evaluation
    frame._lastDesatState = nil    -- Force desat re-application
    frame._lastTintRef = nil       -- Force tint re-application
    
    -- CRITICAL: Reset cached cooldown values so next BAG_UPDATE_COOLDOWN reapplies the cooldown swipe
    -- This fixes the issue where zone changes or Masque refresh clears the cooldown display
    -- but the cached values prevent SetCooldown from being called again
    frame._lastStartTime = nil
    frame._lastDuration = nil
    
    -- Apply settings from CDMEnhance cascade
    ArcAuras.ApplySettingsToFrame(arcID, frame)
    
    -- Also apply CDMEnhance icon style if available
    if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
        ns.CDMEnhance.ApplyIconStyle(frame, arcID)
    end
    
    -- Immediately apply stack text style (don't wait for OnUpdate)
    if frame._arcStackText then
        ApplyStackTextStyle(frame, frame._arcStackText)
        frame._arcStackStyleApplied = true
    end
    
    -- Drive a full visual re-evaluation via UpdateArcItemFrame.
    -- This is required so glow changes made in the options panel take effect
    -- immediately: UpdateArcItemFrame sees settingsChanged=true (caches cleared
    -- above), stops any stale glow, and restarts it with the new settings.
    -- ApplyInitialStateVisuals only handled alpha/desat and never touched glows,
    -- which is why glow changes were invisible until the panel was closed and a
    -- BAG_UPDATE event fired. UpdateArcItemFrame contains a strict superset of
    -- ApplyInitialStateVisuals so this is a safe drop-in replacement.
    -- NOTE: Spell frames are guarded by the _arcIsSpellCooldown early-return
    -- inside UpdateArcItemFrame, so they remain unaffected.
    ArcAuras.UpdateArcItemFrame(frame, arcID)
end

-- Refresh settings for all Arc Aura frames
function ArcAuras.RefreshAllSettings()
    -- Clear all caches
    InvalidateSettingsCache()
    
    for arcID, frame in pairs(ArcAuras.frames) do
        ArcAuras.RefreshFrameSettings(arcID)
    end
end

-- Refresh Masque registration state for all frames
-- Called when Masque enabled setting changes
function ArcAuras.RefreshMasqueState()
    local masqueEnabled = ns.Masque and ns.Masque.IsEnabled and ns.Masque.IsEnabled()
    
    for arcID, frame in pairs(ArcAuras.frames) do
        if masqueEnabled then
            -- Masque is now enabled - register via unified system if not already
            if not frame._arcMasqueAdded then
                if ns.Masque and ns.Masque.AddFrame then
                    ns.Masque.AddFrame(frame, "ArcAuras", arcID)
                    frame._arcMasqueSkinW = frame:GetWidth()
                    frame._arcMasqueSkinH = frame:GetHeight()
                end
            end
            -- Reset icon texture to default 1:1 for Masque to control
            if frame.Icon and frame.Icon.SetTexCoord then
                frame.Icon:SetTexCoord(0, 1, 0, 1)
            end
        else
            -- Masque is now disabled - unregister via unified system
            if frame._arcMasqueAdded then
                if ns.Masque and ns.Masque.RemoveFrame then
                    ns.Masque.RemoveFrame(frame)
                end
                frame._arcMasqueSkinW = nil
                frame._arcMasqueSkinH = nil
                -- Reset icon texture to default
                if frame.Icon and frame.Icon.SetTexCoord then
                    frame.Icon:SetTexCoord(0, 1, 0, 1)
                end
            end
        end
        
        -- Refresh settings regardless
        ArcAuras.RefreshFrameSettings(arcID)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Track initialization attempts for debugging
local initAttempts = 0

-- Expose for external callers (e.g. options panel forcing immediate visual refresh)
ArcAuras.UpdateArcItemFrame = UpdateArcItemFrame

function ArcAuras.Initialize()
    if ArcAuras.initialized then return end
    
    initAttempts = initAttempts + 1
    
    local db = GetDB()
    if not db then
        if initAttempts < 10 then
            -- Keep trying for up to 10 seconds
            C_Timer.After(1, ArcAuras.Initialize)
        else
            print("|cffFF4444[Arc Auras]|r ERROR: Database failed to initialize after 10 attempts")
        end
        return
    end
    
    ArcAuras.initialized = true
    
    -- Debug: Report tracked items found
    local itemCount = 0
    if db.trackedItems then
        for _ in pairs(db.trackedItems) do itemCount = itemCount + 1 end
    end
    if itemCount > 0 then
        -- Silent load - items found, everything is good
    end
    
    -- Enable if saved as enabled
    if db.enabled then
        ArcAuras.Enable()
        
        -- Auto-add equipped trinkets if auto-track is enabled
        -- NOTE: Enable() already loaded existing trackedItems, so AutoAddTrinkets
        -- will only add slots that don't already have frames
        if ArcAuras.IsAutoTrackEquippedTrinketsEnabled() then
            -- Delay slightly to ensure item data is loaded
            C_Timer.After(0.5, function()
                -- nil = use onlyOnUseTrinkets setting, true = create slot trackers (arc_trinket_13)
                ArcAuras.AutoAddTrinkets(nil, true)
            end)
            
            -- VISIBILITY FIX: Enable() creates frames and calls frame:Show(), but
            -- at login time GetInventoryItemID may return nil (items not loaded yet),
            -- causing frames to get _arcSlotEmpty=true incorrectly. Re-check actual
            -- slot state after items are loaded and call ShowTrinketSlotFrame.
            C_Timer.After(1.5, function()
                if not ArcAuras.isEnabled then return end
                local db2 = GetDB()
                if not db2 then return end
                local onlyOnUse2 = db2.onlyOnUseTrinkets
                for _, slot in ipairs(TRINKET_SLOTS) do
                    if ArcAuras.IsAutoTrackSlotEnabled(slot.slotID) then
                        local arcID = ArcAuras.MakeTrinketID(slot.slotID)
                        local frame = ArcAuras.frames[arcID]
                        local itemID = GetInventoryItemID("player", slot.slotID)
                        
                        if itemID and not frame then
                            -- Frame was destroyed but trinket is equipped — recreate
                            local isPassive = onlyOnUse2 and IsItemPassive(itemID)
                            if not isPassive then
                                ArcAuras.ShowTrinketSlotFrame(arcID)
                            end
                        elseif not itemID and frame then
                            -- Slot empty but frame exists — destroy
                            ArcAuras.HideTrinketSlotFrame(arcID)
                        end
                    end
                end
            end)
        end
        
        -- CRITICAL: Delayed refresh pass to apply state visuals (alpha, desat, glow)
        -- This ensures all settings are applied after frames are fully created and CDMEnhance is ready
        -- Same effect as opening options panel - forces a full visual refresh
        C_Timer.After(1.0, function()
            if ArcAuras.RefreshAllSettings then
                ArcAuras.RefreshAllSettings()
            end
        end)
        
        -- INITIAL STATE PASS: Apply charges/stack counts and cooldown state for all item frames.
        -- BAG_UPDATE_COOLDOWN only fires when a cooldown changes, so without this pass
        -- charge text stays blank until the first combat action.
        C_Timer.After(2.0, function()
            if not ArcAuras.isEnabled then return end
            for arcID, frame in pairs(ArcAuras.frames) do
                UpdateArcItemFrame(frame, arcID)
            end
        end)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")           -- Fires when bag contents settled (new items, tooltip ready)
eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")       -- For item data loading
eventFrame:RegisterEvent("PLAYER_EQUIPED_SPELLS_CHANGED") -- Fires when item charges change (Healthstone!)
eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")          -- Fires when item/trinket cooldown changes (event-driven replacement for polling)
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")          -- Fires when item usability changes (CC, fear, combat restrictions)
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")         -- Fires when charges change (Healthstone consumed/recharged)
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")         -- Fires when leaving combat (unlocks once-per-combat items)
eventFrame:RegisterEvent("ENCOUNTER_END")                -- Fires on boss kill/wipe (resets potion combat-use lockout)

-- ═══════════════════════════════════════════════════════════════════════════
-- USABILITY CHECK (dedicated, deferred)
-- Called after events that change item usability (e.g. Healthstone once-per-combat).
-- Deferred by 0.1s because C_Item.IsUsableItem lags ~50ms behind the event firing.
-- ═══════════════════════════════════════════════════════════════════════════
local usabilityCheckPending = false

local function CheckAllItemUsability()
    usabilityCheckPending = false
    for arcID, frame in pairs(ArcAuras.frames) do
        if not frame._arcIsSpellCooldown and frame:IsShown() then
            local config = frame._arcConfig
            local itemID = config and (config.itemID or (config.type == "trinket" and GetInventoryItemID("player", config.slotID)))
            if itemID then
                local usable = C_Item.IsUsableItem(itemID)
                -- State-change guard: only act if usability actually changed
                if frame._lastUsableResult ~= usable then
                    frame._lastUsableResult = usable
                    frame._lastUsableCheckTime = GetTime()
                    -- Only apply usability visuals — not a full rebuild
                    ApplyUsabilityVisuals(frame, arcID, usable)
                end
            end
        end
    end
end

local function ScheduleUsabilityCheck()
    if usabilityCheckPending then return end
    usabilityCheckPending = true
    C_Timer.After(0.1, CheckAllItemUsability)
end

eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")     -- Catches once-per-combat lockouts (e.g. Healthstone)

-- Debounce for PLAYER_EQUIPED_SPELLS_CHANGED (fires 12 times at once)
local lastEquipedSpellsTime = 0

local _arcAurasOnEvent = function(self, event, arg1)
    if event == "PLAYER_LOGIN" then
        -- Enable DB caching now that SavedVariables are loaded
        C_Timer.After(0.1, function()
            ArcAuras.EnableDBCache()
        end)
        -- Then initialize
        C_Timer.After(2, function()
            ArcAuras.Initialize()
        end)
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = arg1
        
        -- Always check hideWhenUnequipped items on any equipment change
        ArcAuras.UpdateItemFrameVisibility()
        
        if slot == 13 or slot == 14 then
            local arcID = ArcAuras.MakeTrinketID(slot)
            local frame = ArcAuras.frames[arcID]
            local itemID = GetInventoryItemID("player", slot)
            local db = GetDB()
            
            local savedConfig = db and db.trackedItems and db.trackedItems[arcID]
            
            if frame then
                local config = frame._arcConfig
                
                if itemID then
                    -- Trinket equipped - check on-use filter for auto-track slots
                    if savedConfig and savedConfig.isAutoTrackSlot then
                        -- GUARD: If the per-slot toggle is OFF, don't show or update
                        if not ArcAuras.IsAutoTrackSlotEnabled(slot) then
                            ArcAuras.UpdateItemFrameVisibility()
                            return
                        end
                        
                        local onlyOnUse = db and db.onlyOnUseTrinkets
                        if onlyOnUse and IsItemPassive(itemID) then
                            -- Passive trinket with on-use filter - destroy it
                            ArcAuras.HideTrinketSlotFrame(arcID)
                            ArcAuras.UpdateItemFrameVisibility()
                            return
                        end
                    end
                    
                    -- Trinket equipped and passes filters - just update icon
                    ArcAuras.UpdateFrameIcon(frame, config)
                    frame._arcStackStyleApplied = false
                    InvalidateStackCache(arcID)
                else
                    -- Slot is empty - destroy the frame
                    ArcAuras.HideTrinketSlotFrame(arcID)
                end
            elseif not frame and ArcAuras.IsAutoTrackEquippedTrinketsEnabled() and ArcAuras.isEnabled then
                -- No frame exists (destroyed or never created) - recreate if trinket equipped
                if itemID then
                    -- Check if slot is enabled for auto-tracking
                    if ArcAuras.IsAutoTrackSlotEnabled(slot) then
                        local onlyOnUse = db and db.onlyOnUseTrinkets
                        local isPassive = IsItemPassive(itemID)
                        
                        local success
                        if savedConfig then
                            -- trackedItems entry exists (frame was destroyed e.g. passive→active swap)
                            -- Use ShowTrinketSlotFrame which calls RecreateItemFrame, NOT AddTrackedItem
                            -- (AddTrackedItem returns early without creating a frame when entry exists)
                            ArcAuras.ShowTrinketSlotFrame(arcID)
                            success = ArcAuras.frames[arcID] ~= nil
                        else
                            -- Brand new slot — create entry and frame from scratch
                            success = ArcAuras.AddTrackedItem({
                                type = "trinket",
                                slotID = slot,
                                enabled = true,
                                isAutoTrackSlot = true,
                            })
                        end
                        
                        -- If passive and on-use filter is on, hide immediately
                        if success and onlyOnUse and isPassive then
                            local newFrame = ArcAuras.frames[arcID]
                            if newFrame then
                                ArcAuras.HideTrinketSlotFrame(arcID)
                            end
                        end
                    end
                end
            end
            
            -- Also check item-based frames that depend on equipped state
            ArcAuras.UpdateItemFrameVisibility()
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Item data loaded - update any item-type frames that match this itemID
        -- AND bust the use-spell cache so it re-resolves on next query (item
        -- spell info may not have been available when the cache was first hit).
        local itemID = arg1
        if itemID then
            itemUseSpellCache[itemID] = nil
            for arcID, frame in pairs(ArcAuras.frames) do
                local config = frame._arcConfig
                if config and config.type == "item" and config.itemID == itemID then
                    ArcAuras.UpdateFrameIcon(frame, config)
                    -- Drive a full visual refresh so cooldown swipe / desat
                    -- catch up to the now-loaded item data.
                    ArcAuras.UpdateArcItemFrame(frame, arcID)
                end
            end
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        -- Bag contents settled - invalidate caches and update all item frames
        InvalidateStackCache()
        for arcID, frame in pairs(ArcAuras.frames) do
            if not frame._arcIsSpellCooldown and frame:IsShown() then
                ArcAuras.UpdateArcItemFrame(frame, arcID)
            end
        end
    elseif event == "BAG_UPDATE_COOLDOWN" then
        -- Only update cooldown state — no full rebuild.
        -- Unified: delegates to ResolveItemCooldown for the SAME threshold
        -- GCD filter used by ApplyItemCooldownToFrame. Previously used a
        -- different IsLikelyGCD+GetItemBaseCooldown heuristic that could
        -- disagree with the full-rebuild path.
        -- State-change guard: each frame exits immediately if startTime/duration unchanged.
        for arcID, frame in pairs(ArcAuras.frames) do
            if frame:IsShown() and not frame._arcIsSpellCooldown then
                local config = frame._arcConfig
                if config then
                    local itemID, slotID
                    if config.type == "trinket" and config.slotID then
                        slotID = config.slotID
                        itemID = GetInventoryItemID("player", slotID)
                    elseif config.type == "item" and config.itemID then
                        itemID = config.itemID
                    end

                    if itemID then
                        local startTime, duration, isGCD = ResolveItemCooldown(itemID, slotID)

                        -- GCD/windup: skip entirely (same behavior as before)
                        if not isGCD then
                            local isOnCooldown = duration > 0 and ((startTime + duration) - GetTime()) > 0
                            -- Only act if something changed
                            if isOnCooldown ~= frame._isOnCooldown
                                or startTime ~= frame._lastStartTime
                                or duration ~= frame._lastDuration then
                                -- Feed cooldown animation
                                if frame._durationObj and C_DurationUtil then
                                    frame._durationObj:SetTimeFromStart(startTime, duration)
                                    frame.Cooldown:SetCooldownFromDurationObject(frame._durationObj, true)
                                else
                                    frame.Cooldown:SetCooldown(startTime, duration)
                                end
                                frame._lastStartTime = startTime
                                frame._lastDuration = duration
                                local prevOnCooldown = frame._isOnCooldown
                                frame._isOnCooldown = isOnCooldown
                                if isOnCooldown and not prevOnCooldown then
                                    -- Cooldown STARTED: apply cooldown visuals immediately
                                    ApplyCooldownStateVisuals(frame, arcID, true)
                                    -- Set OnCooldownDone to trigger full ready-state rebuild
                                    local _arcID = arcID
                                    frame.Cooldown:SetScript("OnCooldownDone", function()
                                        frame.Cooldown:SetScript("OnCooldownDone", nil)
                                        ArcAuras.UpdateArcItemFrame(frame, _arcID)
                                    end)
                                else
                                    -- Not on cooldown (includes lockout items like Healthstone where
                                    -- duration=0.001 expires instantly). Always run full UpdateArcItemFrame
                                    -- so isLockedOut + IsUsableItem checks fire and apply correct visuals.
                                    frame.Cooldown:SetScript("OnCooldownDone", nil)
                                    ArcAuras.UpdateArcItemFrame(frame, arcID)
                                end
                            end
                        end
                        -- Always refresh stack/count text — catches Healthstone create/consume
                        ApplyStackText(frame, arcID)
                    end
                end
            end
        end
    elseif event == "SPELL_UPDATE_USABLE" or event == "SPELL_UPDATE_CHARGES" or event == "PLAYER_REGEN_ENABLED" then
        -- Defer to CheckAllItemUsability (0.1s debounced, state-change guarded).
        -- No immediate full sweep — CheckAllItemUsability calls ApplyUsabilityVisuals
        -- only on frames where usability actually changed.
        InvalidateStackCache()
        ScheduleUsabilityCheck()

    elseif event == "ENCOUNTER_END" then
        -- Boss ended - item CDs (potions, trinkets) may have been reset by Blizzard.
        -- Threshold GCD filter in ResolveItemCooldown means no continuity cache
        -- to clear here — any short-duration bleed after the reset is filtered out.
        InvalidateStackCache()
        ScheduleUsabilityCheck()
        for arcID, frame in pairs(ArcAuras.frames) do
            if not frame._arcIsSpellCooldown then
                UpdateArcItemFrame(frame, arcID)
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- arg1 = unit token (non-secret for player). Schedule deferred usability check
        -- so C_Item.IsUsableItem has time to reflect the new state.
        if arg1 == "player" then
            ScheduleUsabilityCheck()
        end
    elseif event == "PLAYER_EQUIPED_SPELLS_CHANGED" then
        -- Fires 12 times at once - debounce to only process once
        local now = GetTime()
        if now - lastEquipedSpellsTime > 0.1 then
            lastEquipedSpellsTime = now
            -- Item spell charges changed (Healthstone!) - invalidate stack cache
            InvalidateStackCache()
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        -- Debounce: Both events can fire during spec change, only refresh once
        if not ArcAuras._specChangeRefreshPending then
            ArcAuras._specChangeRefreshPending = true
            -- Wait for CDMGroups to fully load the new spec
            -- CDMGroups does: Reconcile at ~1.0s, FOLLOWUP_SWEEP_2 at ~2.5s
            -- We must run AFTER ForceRepositionAllFrames completes (at ~2.5s)
            C_Timer.After(3.0, function()
                ArcAuras._specChangeRefreshPending = false
                ArcAuras.RefreshAllSettings()
                
                -- ═══════════════════════════════════════════════════════════════════════════
                -- APPLY ON-USE FILTER FIRST: Hide passive trinkets if filter is enabled
                -- Must run BEFORE CDMGroups registration to prevent showing hidden frames
                -- ═══════════════════════════════════════════════════════════════════════════
                local hiddenByFilter = {}
                local filterEnabled = ArcAuras.isEnabled and ArcAuras.IsOnlyOnUseTrinketsEnabled()
                
                if filterEnabled then
                    for _, slot in ipairs(TRINKET_SLOTS) do
                        local arcID = ArcAuras.MakeTrinketID(slot.slotID)
                        local frame = ArcAuras.frames[arcID]
                        local itemID = GetInventoryItemID("player", slot.slotID)
                        local isPassive = itemID and IsItemPassive(itemID)
                        
                        if frame then
                            if itemID and isPassive then
                                -- Hide passive trinket (removes from group, hides frame)
                                ArcAuras.HideTrinketSlotFrame(arcID)
                                hiddenByFilter[arcID] = true
                            end
                        end
                    end
                end
                
                -- ═══════════════════════════════════════════════════════════════════════════
                -- APPLY HIDE-WHEN-UNEQUIPPED: Show/hide item-based frames based on equipped state
                -- Must run BEFORE CDMGroups registration to prevent showing hidden frames
                -- ═══════════════════════════════════════════════════════════════════════════
                if ArcAuras.isEnabled then
                    -- Check visibility for all item-based frames with hideWhenUnequipped
                    local db = GetDB()
                    if db and db.trackedItems then
                        for arcID, config in pairs(db.trackedItems) do
                            if config.type == "item" and config.itemID and config.hideWhenUnequipped then
                                if not IsItemEquipped(config.itemID) and ArcAuras.frames[arcID] then
                                    -- Destroy frame — UpdateItemFrameVisibility handles equip events
                                    ArcAuras.DestroyItemFramePreservePosition(arcID)
                                    hiddenByFilter[arcID] = true
                                end
                            end
                        end
                    end
                end
                
                -- ═══════════════════════════════════════════════════════════════════════════
                -- Re-register Arc Auras frames with CDMGroups after spec change
                -- FORCE re-registration regardless of current state - CDMGroups may have
                -- stale member entries after spec change that prevent proper drag/positioning
                -- ═══════════════════════════════════════════════════════════════════════════
                if ns.CDMGroups and ArcAuras.isEnabled then
                    -- CRITICAL: Ensure savedPositions reference is correct for current spec
                    -- The ns.CDMGroups.savedPositions reference may be stale after spec change
                    -- GetProfileSavedPositions syncs it to the current spec's profile data
                    if ns.CDMGroups.GetProfileSavedPositions then
                        ns.CDMGroups.GetProfileSavedPositions()
                    end
                    
                    local registeredCount = 0
                    for arcID, frame in pairs(ArcAuras.frames) do
                        -- Skip frames hidden by filters (destroyed spell frames won't be in this table)
                        if not hiddenByFilter[arcID] and frame and frame:IsShown() then
                            -- Check if already in a group (restored by CDMGroups.RestoreArcAurasPositions)
                            local alreadyInGroup = false
                            if ns.CDMGroups.groups then
                                for _, group in pairs(ns.CDMGroups.groups) do
                                    if group.members and group.members[arcID] then
                                        alreadyInGroup = true
                                        break
                                    end
                                end
                            end
                            
                            if alreadyInGroup then
                                -- Already correctly positioned by RestoreArcAurasPositions, skip
                                registeredCount = registeredCount + 1
                            else
                            -- Check if CDMGroups has a saved position for this arc aura
                            local hasSavedPosition = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
                            
                            if hasSavedPosition then
                                local saved = ns.CDMGroups.savedPositions[arcID]
                                if saved.type == "group" and saved.target then
                                    local targetGroup = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
                                    if targetGroup then
                                        -- FORCE re-registration: Remove stale entry first, then register fresh
                                        -- This ensures hooks and member.frame are properly set up
                                        if targetGroup.members and targetGroup.members[arcID] then
                                            -- Clear stale member entry
                                            targetGroup.members[arcID] = nil
                                        end
                                        
                                        -- Register with fresh state
                                        if ns.CDMGroups.RegisterExternalFrame then
                                            ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", saved.target)
                                            registeredCount = registeredCount + 1
                                        end
                                    end
                                elseif saved.type == "free" then
                                    -- Free icon - re-track to ensure proper setup
                                    if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
                                        ns.CDMGroups.freeIcons[arcID] = nil
                                    end
                                    if ns.CDMGroups.TrackFreeIcon then
                                        ns.CDMGroups.TrackFreeIcon(arcID, saved.x or 0, saved.y or 0, saved.iconSize or 36, frame)
                                        registeredCount = registeredCount + 1
                                    end
                                end
                            else
                                -- No saved position for new spec - register as new (will go to default group)
                                if ns.CDMGroups.RegisterExternalFrame then
                                    ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", "Essential")
                                    registeredCount = registeredCount + 1
                                end
                            end
                            end -- alreadyInGroup
                        end
                    end
                    
                    -- Always layout all groups after spec change to ensure proper positioning
                    if ns.CDMGroups.groups then
                        for _, group in pairs(ns.CDMGroups.groups) do
                            if group.Layout then group:Layout() end
                        end
                    end
                end
            end)
        end
    end
end
eventFrame:SetScript("OnEvent", Track and Track("ArcAuras.OnEvent", _arcAurasOnEvent) or _arcAurasOnEvent)

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_ARCAURAS1 = "/arcauras"
SlashCmdList["ARCAURAS"] = function(msg)
    local cmd = strtrim(msg:lower())
    
    if cmd == "" then
        if ns.ArcAurasOptions and ns.ArcAurasOptions.OpenPanel then
            ns.ArcAurasOptions.OpenPanel()
        else
            print("|cff00CCFF[Arc Auras]|r Commands: enable, disable, toggle, scan, unlock, lock, help")
        end
    elseif cmd == "enable" or cmd == "on" then
        ArcAuras.Enable()
        print("|cff00CCFF[Arc Auras]|r Enabled")
    elseif cmd == "disable" or cmd == "off" then
        ArcAuras.Disable()
        print("|cff00CCFF[Arc Auras]|r Disabled")
    elseif cmd == "toggle" then
        ArcAuras.Toggle()
        print("|cff00CCFF[Arc Auras]|r " .. (ArcAuras.isEnabled and "Enabled" or "Disabled"))
    elseif cmd == "scan" then
        local trinkets = ArcAuras.ScanEquippedTrinkets()
        print("|cff00CCFF[Arc Auras]|r Equipped Trinkets:")
        for slotID, info in pairs(trinkets) do
            if info.itemID then
                local onUse = info.isOnUse and "|cff00FF00On-Use|r" or "|cff888888Passive|r"
                print(string.format("  %s: %s (%s)", info.slotName, info.itemName or "Unknown", onUse))
            else
                print(string.format("  %s: (empty)", info.slotName))
            end
        end
    elseif cmd == "unlock" then
        for _, frame in pairs(ArcAuras.frames) do
            frame._isDraggable = true
            frame:SetBackdropBorderColor(0, 1, 0, 1)
        end
        print("|cff00CCFF[Arc Auras]|r Frames unlocked")
    elseif cmd == "lock" then
        for _, frame in pairs(ArcAuras.frames) do
            frame._isDraggable = false
            frame:SetBackdropBorderColor(0, 0, 0, 1)
        end
        print("|cff00CCFF[Arc Auras]|r Frames locked")
    elseif cmd == "help" then
        print("|cff00CCFF[Arc Auras]|r Commands:")
        print("  /arcauras - Open options")
        print("  /arcauras enable - Enable")
        print("  /arcauras disable - Disable")
        print("  /arcauras scan - Show trinkets")
        print("  /arcauras unlock - Unlock frames")
        print("  /arcauras lock - Lock frames")
    else
        print("|cff00CCFF[Arc Auras]|r Unknown command. /arcauras help")
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INTEGRATION HELPERS (for CDMEnhance catalog and other modules)
-- ═══════════════════════════════════════════════════════════════════════════

-- Helper: Create catalog entry for Arc Aura (item-based cooldown)
-- Used by CDMEnhance.GetCooldownIcons() and any other catalog/list displays
function ArcAuras.CreateCatalogEntry(cdID, frame)
    local Shared = ns.CDMShared
    if not Shared or not Shared.IsArcAuraID or not Shared.IsArcAuraID(cdID) then
        return nil
    end
    
    -- Use the local ParseArcID (handles spell/item/trinket and tolerates suffixes).
    -- Shared.ParseArcAuraID is stricter and doesn't know about spell/timer prefixes.
    local arcType, id = ArcAuras.ParseArcID(cdID)
    if not arcType then return nil end
    
    local name, icon, itemID, spellID
    
    if arcType == "trinket" and id then
        -- Trinket slot
        itemID = GetInventoryItemID("player", id)
        if itemID then
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
            name = itemName or ("Trinket " .. id)
            icon = itemIcon or GetInventoryItemTexture("player", id) or 134400
        else
            name = "Trinket " .. id
            icon = GetInventoryItemTexture("player", id) or 134400
        end
    elseif arcType == "item" and id then
        -- Generic item
        itemID = id
        local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(id)
        name = itemName or "Item"
        icon = itemIcon or 134400
    elseif arcType == "spell" and id then
        -- Spell cooldown frame (Arc Auras spell tracking)
        spellID = id
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            name = info.name
            icon = info.iconID or info.originalIconID
        end
        -- Icon override from trackedSpells
        local db = GetDB()
        local trackedCfg = db and db.trackedSpells and db.trackedSpells[cdID]
        if trackedCfg and trackedCfg.iconOverride then
            icon = trackedCfg.iconOverride
        end
        name = name or ("Spell " .. spellID)
    elseif arcType == "timer" and id then
        -- Custom timer frame — icon and name come from the watched spell,
        -- or the user's icon override in customTimers.
        spellID = id
        local info = C_Spell.GetSpellInfo(spellID)
        if info then
            name = info.name
            icon = info.iconID or info.originalIconID
        end
        local db = GetDB()
        local timerCfg = db and db.customTimers and db.customTimers[cdID]
        if timerCfg and timerCfg.icon then
            icon = timerCfg.icon
        end
        name = (name or ("Spell " .. spellID)) .. " |cff888888(Timer)|r"
    elseif arcType == "totem" and id then
        -- Totem-slot frame. The live totem icon is a SECRET fileID (we SetTexture
        -- it from GetTotemInfo), so the catalog must NOT read the frame's texture
        -- — it always uses a stable placeholder + "Totem Slot N" label.
        name = "Totem Slot " .. id .. " |cff888888(Totem)|r"
        icon = 310731  -- totem glyph placeholder (matches ArcAurasTotems.PLACEHOLDER_ICON)
    end

    -- Fallback to frame data if available
    if frame then
        if frame._currentItemName and frame._currentItemName ~= "" then
            -- Don't clobber the timer/totem suffix
            if arcType ~= "timer" and arcType ~= "totem" then name = frame._currentItemName end
        end
        -- Skip the live frame icon for totems (secret) and guard every type
        -- against a secret texture value — comparing a secret number throws.
        if arcType ~= "totem" and frame.Icon and frame.Icon.GetTexture then
            local frameIcon = frame.Icon:GetTexture()
            if frameIcon and not (issecretvalue and issecretvalue(frameIcon))
               and frameIcon ~= 134400 then
                icon = icon or frameIcon
            end
        end
    end
    
    return {
        cooldownID = cdID,
        spellID = spellID,
        itemID = itemID,
        name = name or "Unknown",
        icon = icon or 134400,
        hasCustomPos = true,
        viewerName = "EssentialCooldownViewer",
        isArcAura = true,
        arcType = arcType,
        isCustomTimer = arcType == "timer" or nil,
    }
end

-- Helper: Get item cooldown info for Arc Aura
-- Returns: isOnCooldown, remaining, startTime, duration
-- Item cooldowns are NON-SECRET in WoW 12.0!
function ArcAuras.GetItemCooldownState(cdID)
    local arcType, id = ArcAuras.ParseArcID(cdID)
    if not arcType or not id then
        return false, 0, 0, 0
    end
    
    local startTime, duration, enable
    
    if arcType == "trinket" then
        startTime, duration, enable = GetInventoryItemCooldown("player", id)
    elseif arcType == "item" then
        startTime, duration, enable = C_Item.GetItemCooldown(id)
    end
    
    -- Calculate state (NON-SECRET - direct comparison works!)
    local isOnCooldown = duration and duration > 0
    local remaining = 0
    if isOnCooldown then
        remaining = (startTime + duration) - GetTime()
        if remaining < 0 then
            remaining = 0
            isOnCooldown = false
        end
    end
    
    return isOnCooldown, remaining, startTime or 0, duration or 0
end

-- Helper: Get item info for Arc Aura
-- Returns: itemID, name, icon
function ArcAuras.GetItemInfoForArcID(cdID)
    local arcType, id = ArcAuras.ParseArcID(cdID)
    if not arcType or not id then
        return nil, nil, nil
    end
    
    local itemID, name, icon
    
    if arcType == "trinket" then
        itemID = GetInventoryItemID("player", id)
        if itemID then
            local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
            name = itemName
            icon = itemIcon or GetInventoryItemTexture("player", id)
        else
            name = "Trinket " .. id
            icon = GetInventoryItemTexture("player", id) or 134400
        end
    elseif arcType == "item" then
        itemID = id
        local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(id)
        name = itemName
        icon = itemIcon or 134400
    end
    
    return itemID, name, icon
end
-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILER: Register local hot-path functions so ArcUIProfiler can wrap them.
-- Must run AFTER all local function definitions above.
-- RegisterLocals wraps immediately and returns wrapped versions — swap locals
-- so calls through local upvalues (the actual hot path) hit the wrappers.
-- ═══════════════════════════════════════════════════════════════════════════
do
    local _wrapped = _G.ArcUIProfiler_RegisterLocals and _G.ArcUIProfiler_RegisterLocals("ArcAuras", {
        UpdateArcItemFrame        = UpdateArcItemFrame,
        UpdateTrinketCooldown     = UpdateTrinketCooldown,
        UpdateItemCooldown        = UpdateItemCooldown,
        ApplyCooldownStateVisuals = ApplyCooldownStateVisuals,
        ApplyUsabilityVisuals     = ApplyUsabilityVisuals,
        GetCachedStateVisuals     = GetCachedStateVisuals,
        ApplyStackText            = ApplyStackText,
        GetStackDisplay           = GetStackDisplay,
        ComputeStackDisplay       = ComputeStackDisplay,
    })
    if _wrapped then
        if _wrapped.UpdateArcItemFrame        then UpdateArcItemFrame        = _wrapped.UpdateArcItemFrame        end
        if _wrapped.UpdateTrinketCooldown     then UpdateTrinketCooldown     = _wrapped.UpdateTrinketCooldown     end
        if _wrapped.UpdateItemCooldown        then UpdateItemCooldown        = _wrapped.UpdateItemCooldown        end
        if _wrapped.ApplyCooldownStateVisuals then ApplyCooldownStateVisuals = _wrapped.ApplyCooldownStateVisuals end
        if _wrapped.ApplyUsabilityVisuals     then ApplyUsabilityVisuals     = _wrapped.ApplyUsabilityVisuals     end
        if _wrapped.GetCachedStateVisuals     then GetCachedStateVisuals     = _wrapped.GetCachedStateVisuals     end
        if _wrapped.ApplyStackText            then ApplyStackText            = _wrapped.ApplyStackText            end
        if _wrapped.GetStackDisplay           then GetStackDisplay           = _wrapped.GetStackDisplay           end
        if _wrapped.ComputeStackDisplay       then ComputeStackDisplay       = _wrapped.ComputeStackDisplay       end
    end
end