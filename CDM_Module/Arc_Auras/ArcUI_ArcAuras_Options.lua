-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras Options
-- Catalog-style options with embedded ItemDropBox widget for drag/drop
-- v1.3 - Unified Items + Spells catalog, single Add section
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ArcAuras = ns.ArcAuras
local Options = {}
ns.ArcAurasOptions = Options

-- ═══════════════════════════════════════════════════════════════════════════
-- UI STATE
-- ═══════════════════════════════════════════════════════════════════════════

local selectedArcAura = nil
local selectedArcAuras = {}

-- Collapsible sections
local collapsedSections = {
    trackedItems = false,
    autoTrackSlots = false,
    management = true,
}

-- Cache
local cachedItemList = nil
local cacheInvalidated = true

-- Input state
local pendingItemID = ""
local pendingSpellID = ""

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOG DATA (unified items + spells)
-- ═══════════════════════════════════════════════════════════════════════════

local function GetTrackedItemsList()
    if cachedItemList and not cacheInvalidated then
        return cachedItemList
    end
    
    if not ArcAuras then return {} end
    
    local db = ns.db and ns.db.char and ns.db.char.arcAuras
    if not db then return {} end
    
    local items = {}
    
    -- ── Items & Trinkets ──
    if db.trackedItems then
        for arcID, config in pairs(db.trackedItems) do
            local name, icon = nil, nil
            local arcType, id = ArcAuras.ParseArcID(arcID)
            local itemID = nil
            
            if arcType == "trinket" then
                itemID = GetInventoryItemID("player", id)
                if itemID then
                    name, icon = select(1, GetItemInfo(itemID)), select(10, GetItemInfo(itemID))
                    icon = icon or GetInventoryItemTexture("player", id)
                end
                name = name or ("Trinket Slot " .. id)
            elseif arcType == "item" then
                itemID = config.itemID
                if itemID then
                    name, icon = select(1, GetItemInfo(itemID)), select(10, GetItemInfo(itemID))
                end
                name = name or ("Item " .. (itemID or "?"))
            end
            
            table.insert(items, {
                arcID = arcID,
                arcType = arcType,       -- "trinket" or "item"
                itemID = itemID,
                name = name or "Unknown",
                icon = config.iconOverride or icon or 134400,
                config = config,
                enabled = config.enabled,
                isAutoTrackSlot = config.isAutoTrackSlot,
                hideWhenUnequipped = config.hideWhenUnequipped,
                hasIconOverride = config.iconOverride ~= nil,
            })
        end
    end
    
    -- ── Spells ──
    if db.trackedSpells then
        local ArcAurasCooldown = ns.ArcAurasCooldown
        local PlayerKnowsSpell = ArcAurasCooldown and ArcAurasCooldown.PlayerKnowsSpell
        local GetSpellNameAndIcon = ArcAurasCooldown and ArcAurasCooldown.GetSpellNameAndIcon
        local currentSpec = GetSpecialization() or 1
        
        for arcID, config in pairs(db.trackedSpells) do
            local spellID = config.spellID
            local name, icon = nil, nil
            if GetSpellNameAndIcon then
                name, icon = GetSpellNameAndIcon(spellID)
            end
            name = name or config.name or ("Spell " .. (spellID or "?"))
            icon = icon or config.icon or 134400
            
            local inSpec = true
            if PlayerKnowsSpell then
                inSpec = PlayerKnowsSpell(spellID)
            end
            -- forceShow bypasses spec check
            if config.forceShow and not inSpec then
                inSpec = true
            end

            -- Check user's per-spell spec filter
            local specFiltered = false
            if config.showOnSpecs and #config.showOnSpecs > 0 then
                local specAllowed = false
                for _, spec in ipairs(config.showOnSpecs) do
                    if spec == currentSpec then specAllowed = true break end
                end
                if not specAllowed then
                    specFiltered = true
                    inSpec = false   -- Treat as "not in spec" for display purposes
                end
            end

            -- Check talent conditions
            local talentFiltered = false
            if inSpec and config.talentConditions and #config.talentConditions > 0 then
                if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
                    local pass = ns.TalentPicker.CheckTalentConditions(
                        config.talentConditions, config.talentConditionMode or "all")
                    if not pass then
                        talentFiltered = true
                        inSpec = false
                    end
                end
            end
            
            -- Use icon override if set
            if config.iconOverride then
                icon = config.iconOverride
            end
            
            table.insert(items, {
                arcID = arcID,
                arcType = "spell",
                spellID = spellID,
                name = name,
                icon = icon,
                config = config,
                enabled = true,           -- Spells are always enabled (remove to untrack)
                inCurrentSpec = inSpec,
                specFiltered = specFiltered,
                talentFiltered = talentFiltered,
                hasSpecFilter = config.showOnSpecs and #config.showOnSpecs > 0,
                hasTalentFilter = config.talentConditions and #config.talentConditions > 0,
                forceShow = config.forceShow,
                hasIconOverride = config.iconOverride ~= nil,
            })
        end
    end
    
    -- Sort: trinkets first, then items, then spells, alpha within each
    local typeOrder = { trinket = 1, item = 2, spell = 3 }
    table.sort(items, function(a, b)
        local oa = typeOrder[a.arcType] or 9
        local ob = typeOrder[b.arcType] or 9
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)
    
    cachedItemList = items
    cacheInvalidated = false
    return items
end

local function GetItemByIndex(index)
    local items = GetTrackedItemsList()
    return items[index]
end

local function GetItemCount()
    local items = GetTrackedItemsList()
    return #items
end

local function GetSelectedItem()
    if not selectedArcAura then return nil end
    local items = GetTrackedItemsList()
    for _, item in ipairs(items) do
        if item.arcID == selectedArcAura then
            return item
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SELECTION HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function HideIfNoSelection()
    return selectedArcAura == nil and not next(selectedArcAuras)
end

local function GetSelectedCount()
    if next(selectedArcAuras) then
        local count = 0
        for _ in pairs(selectedArcAuras) do count = count + 1 end
        return count
    elseif selectedArcAura then
        return 1
    end
    return 0
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOG ICON ENTRY (unified: items, trinkets, and spells)
-- ═══════════════════════════════════════════════════════════════════════════

local function CreateCatalogIconEntry(index)
    return {
        type = "execute",
        name = function()
            local entry = GetItemByIndex(index)
            if not entry then return "" end
            
            local isSelected = selectedArcAura == entry.arcID or selectedArcAuras[entry.arcID]
            local isMulti = selectedArcAuras[entry.arcID]
            local hasCustom = ns.CDMEnhance and ns.CDMEnhance.HasPerIconSettings and ns.CDMEnhance.HasPerIconSettings(entry.arcID)
            
            -- Build status string
            local status = ""
            
            -- Type indicators
            if entry.arcType == "spell" then
                if entry.talentFiltered then
                    status = "|cffff8800T|r "   -- Orange T = talent-filtered (hidden)
                elseif entry.specFiltered then
                    status = "|cffff8800S|r "   -- Orange S = spec-filtered (user disabled)
                elseif entry.forceShow then
                    status = "|cff00ff00F|r "   -- Green F = force-shown (bypasses spec check)
                elseif entry.inCurrentSpec == false then
                    status = "|cff666666S|r "   -- Dimmed S = not in current spec
                else
                    status = "|cff88ccffS|r "   -- Light blue S = spell
                end
            elseif entry.isAutoTrackSlot then
                status = "|cff88ff88A|r "
            elseif entry.hideWhenUnequipped then
                status = "|cff88aaeeH|r "
            end
            
            if isMulti then
                status = status .. (hasCustom and "|cff00ff00Multi|r |cffaa55ff*|r" or "|cff00ff00Multi|r")
            elseif isSelected then
                status = status .. (hasCustom and "|cff00ff00Edit|r |cffaa55ff*|r" or "|cff00ff00Edit|r")
            elseif not entry.enabled then
                status = status .. "|cff666666OFF|r"
            elseif hasCustom then
                status = status .. "|cffaa55ff*|r"
            end
            
            return status
        end,
        desc = function()
            local entry = GetItemByIndex(index)
            if not entry then return "" end
            
            local desc = "|cffffd700" .. entry.name .. "|r"
            
            if entry.arcType == "spell" then
                desc = desc .. "\nSpell ID: " .. (entry.spellID or "?")
                desc = desc .. "\nArc ID: " .. entry.arcID
                desc = desc .. "\nType: |cff88ccffSpell|r"
                if entry.forceShow then
                    desc = desc .. "\n|cff00ff00Always Show|r (spec check bypassed)"
                end
                if entry.hasIconOverride then
                    desc = desc .. "\n|cffFFCC00Custom Icon|r (ID: " .. (entry.config.iconOverrideID or "?") .. ")"
                end
                if entry.specFiltered then
                    desc = desc .. "\n|cffff8800Hidden on this spec (user filter)|r"
                elseif entry.inCurrentSpec == false then
                    desc = desc .. "\n|cff888888Not in current spec|r"
                end
                if entry.hasSpecFilter then
                    local specNames = {}
                    for _, specNum in ipairs(entry.config.showOnSpecs or {}) do
                        local _, specName = GetSpecializationInfo(specNum)
                        if specName then table.insert(specNames, specName) end
                    end
                    if #specNames > 0 then
                        desc = desc .. "\n|cffffd700Specs:|r " .. table.concat(specNames, ", ")
                    end
                end
                if entry.talentFiltered then
                    desc = desc .. "\n|cffff8800Hidden (talent condition not met)|r"
                end
                if entry.hasTalentFilter then
                    if ns.TalentPicker and ns.TalentPicker.GetConditionSummary then
                        desc = desc .. "\n|cffffd700Talents:|r " ..
                            ns.TalentPicker.GetConditionSummary(entry.config.talentConditions, entry.config.talentConditionMode)
                    end
                end
            else
                local typeColor = entry.arcType == "trinket" and "|cff00ccff" or "|cff00ff00"
                local typeStr = entry.arcType == "trinket" and "Trinket" or "Item"
                if entry.itemID then
                    desc = desc .. "\nItem ID: " .. entry.itemID
                end
                desc = desc .. "\nArc ID: " .. entry.arcID
                desc = desc .. "\nType: " .. typeColor .. typeStr .. "|r"
                if entry.isAutoTrackSlot then
                    desc = desc .. "\n|cff88ff88Auto-Tracked Slot|r"
                end
                if entry.hideWhenUnequipped then
                    desc = desc .. "\n|cff88aaeeHides when unequipped|r"
                end
                if entry.hasIconOverride then
                    desc = desc .. "\n|cffFFCC00Custom Icon|r (ID: " .. (entry.config.iconOverrideID or "?") .. ")"
                end
                if not entry.enabled then
                    desc = desc .. "\n|cffff4444Disabled|r"
                end
            end
            
            local hasCustom = ns.CDMEnhance and ns.CDMEnhance.HasPerIconSettings and ns.CDMEnhance.HasPerIconSettings(entry.arcID)
            if hasCustom then
                desc = desc .. "\n|cffaa55ffCustom settings in CDM Icons|r"
            end
            
            desc = desc .. "\n\n|cff888888Click to select  •  Shift+Click multi-select|r"
            return desc
        end,
        func = function()
            local entry = GetItemByIndex(index)
            if not entry then return end
            
            local arcID = entry.arcID
            
            if IsShiftKeyDown() then
                if selectedArcAura and not next(selectedArcAuras) then
                    selectedArcAuras[selectedArcAura] = true
                end
                
                if selectedArcAuras[arcID] then
                    selectedArcAuras[arcID] = nil
                else
                    selectedArcAuras[arcID] = true
                    if not selectedArcAura then selectedArcAura = arcID end
                end
            else
                wipe(selectedArcAuras)
                if selectedArcAura == arcID then
                    selectedArcAura = nil
                else
                    selectedArcAura = arcID
                end
            end
            
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        image = function()
            local entry = GetItemByIndex(index)
            return entry and entry.icon or nil
        end,
        imageWidth = 32,
        imageHeight = 32,
        order = 50 + index,
        width = 0.25,
        hidden = function()
            if collapsedSections.trackedItems then return true end
            return GetItemByIndex(index) == nil
        end,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AUTO-TRACK SLOT ENTRY
-- Creates a toggle for each trinket slot (full row per slot)
-- ═══════════════════════════════════════════════════════════════════════════

local function CreateAutoTrackSlotEntry(slotInfo)
    local slotID = slotInfo.slotID
    local slotName = slotInfo.name
    
    return {
        type = "toggle",
        name = function()
            local itemID = GetInventoryItemID("player", slotID)
            if itemID then
                local itemName = GetItemInfo(itemID)
                local isOnUse = ArcAuras.IsItemOnUse(itemID)
                local onUseStr = isOnUse and "|cff00ff00On-Use|r" or "|cff888888Passive|r"
                return string.format("|T%s:18|t  |cffffd700%s:|r %s (%s)", 
                    GetInventoryItemTexture("player", slotID) or 134400,
                    slotName,
                    itemName or "Loading...",
                    onUseStr)
            else
                return string.format("|TInterface\\Icons\\INV_Misc_QuestionMark:18|t  |cffffd700%s:|r |cff666666(Empty)|r", slotName)
            end
        end,
        desc = function()
            local itemID = GetInventoryItemID("player", slotID)
            local desc = slotName .. "\n"
            if itemID then
                local itemName = GetItemInfo(itemID)
                local isOnUse = ArcAuras.IsItemOnUse(itemID)
                desc = desc .. "\n|cffffd700" .. (itemName or "Loading...") .. "|r"
                desc = desc .. "\nItem ID: " .. itemID
                desc = desc .. "\n" .. (isOnUse and "|cff00ff00Has On-Use Effect|r" or "|cff888888Passive (No On-Use)|r")
            else
                desc = desc .. "\n|cff666666No trinket equipped|r"
            end
            desc = desc .. "\n\n|cff888888Toggle to enable/disable auto-tracking for this slot.|r"
            return desc
        end,
        order = slotID,
        width = "full",
        get = function()
            return ArcAuras and ArcAuras.IsAutoTrackSlotEnabled(slotID)
        end,
        set = function(_, val)
            if ArcAuras and ArcAuras.SetAutoTrackSlotEnabled then
                ArcAuras.SetAutoTrackSlotEnabled(slotID, val)
                Options.InvalidateCache()
                if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                    ns.CDMEnhanceOptions.InvalidateCache()
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end
        end,
        hidden = function() 
            return collapsedSections.autoTrackSlots or not (ArcAuras and ArcAuras.IsAutoTrackEquippedTrinketsEnabled())
        end,
        disabled = function()
            if ArcAuras and ArcAuras.IsOnlyOnUseTrinketsEnabled() then
                local itemID = GetInventoryItemID("player", slotID)
                if itemID and ArcAuras.IsItemPassive(itemID) then
                    return true
                end
            end
            return false
        end,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACECONFIG OPTIONS TABLE
-- ═══════════════════════════════════════════════════════════════════════════

function ns.GetArcAurasOptionsTable()
    local args = {
        -- ═══════════════════════════════════════════════════════════════
        -- HEADER
        -- ═══════════════════════════════════════════════════════════════
        description = {
            type = "description",
            name = "|cff00CCFFArc Auras|r tracks item and spell cooldowns that aren't covered by the Cooldown Manager.\n\nOnce added, icons appear in the |cff00ff00CDM Icons|r catalog for appearance settings.\n",
            order = 1,
            fontSize = "medium",
        },
        enabled = {
            type = "toggle",
            name = "Enable Arc Auras",
            desc = "Enable custom item and spell cooldown tracking",
            order = 2,
            width = 1.2,
            get = function() 
                return ArcAuras and ArcAuras.IsEnabled and ArcAuras.IsEnabled() 
            end,
            set = function(_, val)
                if not ArcAuras then return end
                if val then ArcAuras.Enable() else ArcAuras.Disable() end
            end,
        },
        refreshBtn = {
            type = "execute",
            name = "Refresh",
            desc = "Show all frames at their saved positions (fixes missing icons after spec change)",
            order = 3,
            width = 0.6,
            func = function()
                if ArcAuras and ArcAuras.ForceShowAllFrames then
                    local count = ArcAuras.ForceShowAllFrames()
                    print("|cff00CCFF[Arc Auras]|r Showed " .. (count or 0) .. " frames")
                end
            end,
        },
        
        -- ═══════════════════════════════════════════════════════════════
        -- ADD ITEMS & SPELLS
        -- ═══════════════════════════════════════════════════════════════
        addHeader = {
            type = "header",
            name = "Add Items & Spells",
            order = 10,
        },
        addTrinketsBtn = {
            type = "execute",
            name = "|TInterface\\Icons\\INV_Trinket_80_Titan02a:16|t  Add On-Use Trinkets",
            desc = "Add frames for your currently equipped on-use trinkets.\n\n|cff88ff88These frames track the SPECIFIC ITEM|r - they won't change when you swap trinkets.\n\nUse this to add individual trinkets you want to track permanently.",
            order = 11,
            width = 1.1,
            func = function()
                if not ArcAuras then return end
                local added = ArcAuras.AutoAddTrinkets(true)
                print("|cff00CCFF[Arc Auras]|r Added " .. added .. " on-use trinket(s)")
                Options.InvalidateCache()
                if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                    ns.CDMEnhanceOptions.InvalidateCache()
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end,
        },
        itemIDInput = {
            type = "input",
            name = "Item ID",
            desc = "Enter an Item ID and press Enter to track it (e.g., 212456)",
            order = 12,
            width = 0.8,
            get = function() return pendingItemID end,
            set = function(_, val)
                val = val:gsub("%D", "")
                local itemID = tonumber(val)
                if not itemID or itemID <= 0 then
                    pendingItemID = ""
                    return
                end
                if ArcAuras and ArcAuras.AddTrackedItem then
                    local success = ArcAuras.AddTrackedItem({
                        type = "item",
                        itemID = itemID,
                        enabled = true,
                    })
                    if success then
                        local name = select(1, GetItemInfo(itemID)) or ("Item " .. itemID)
                        print("|cff00CCFF[Arc Auras]|r Added: " .. name)
                        pendingItemID = ""
                        Options.InvalidateCache()
                        if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                            ns.CDMEnhanceOptions.InvalidateCache()
                        end
                    else
                        print("|cff00CCFF[Arc Auras]|r Already tracked or invalid")
                        pendingItemID = ""
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end
            end,
        },
        spellIDInput = {
            type = "input",
            name = "Spell ID",
            desc = "Enter a Spell ID and press Enter to track it (e.g., 116011)",
            order = 13,
            width = 0.8,
            get = function() return pendingSpellID end,
            set = function(_, val)
                val = val:gsub("[^%d]", "")
                local spellID = tonumber(val)
                if not spellID or spellID <= 0 then
                    pendingSpellID = ""
                    return
                end
                local ArcAurasCooldown = ns.ArcAurasCooldown
                if ArcAurasCooldown and ArcAurasCooldown.AddTrackedSpell then
                    local success = ArcAurasCooldown.AddTrackedSpell(spellID)
                    if success then
                        local name = ArcAurasCooldown.GetSpellNameAndIcon(spellID) or ("Spell " .. spellID)
                        print("|cff00CCFF[Arc Auras]|r Added spell: " .. name)
                        pendingSpellID = ""
                        Options.InvalidateCache()
                        if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                            ns.CDMEnhanceOptions.InvalidateCache()
                        end
                    else
                        print("|cff00CCFF[Arc Auras]|r Already tracked or invalid spell")
                        pendingSpellID = ""
                    end
                    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                end
            end,
        },
        
        -- Embedded drag/drop box using custom AceGUI widget
        itemDropBox = {
            type = "execute",
            name = "|cff00CCFFDrag Item or Spell to Track|r",
            dialogControl = "ItemDropBox",
            order = 14,
            width = "full",
            func = function(info)
                -- Handling done in the widget's OnItemDropped callback
            end,
        },
        
        -- ═══════════════════════════════════════════════════════════════
        -- TRACKED CATALOG (unified items + spells)
        -- ═══════════════════════════════════════════════════════════════
        trackedItemsHeader = {
            type = "toggle",
            name = function()
                local count = GetItemCount()
                if count > 0 then
                    return "Tracked (" .. count .. ")"
                end
                return "Tracked"
            end,
            desc = "Click to expand/collapse",
            dialogControl = "CollapsibleHeader",
            get = function() return not collapsedSections.trackedItems end,
            set = function(_, v) 
                collapsedSections.trackedItems = not v 
            end,
            order = 40,
            width = "full",
        },
        catalogDesc = {
            type = "description",
            name = function()
                local count = GetItemCount()
                if count == 0 then
                    return "|cff888888No items or spells tracked. Use buttons above to add.|r"
                end
                local sel = GetSelectedCount()
                local legendStr = "|cff888888Legend: |cff88ff88A|r=Auto-Track  |cff88aaeeH|r=Hide Unequipped  |cff88ccffS|r=Spell  |cff00ff00F|r=Always Show  |cffaa55ff*|r=Custom Settings|r"
                if sel > 0 then
                    return string.format("|cff00ff00%d selected|r  |cff888888Click to select • Shift+Click multi-select|r\n%s", sel, legendStr)
                end
                return "|cff888888Click to select • Shift+Click multi-select|r\n" .. legendStr
            end,
            order = 41,
            fontSize = "small",
            hidden = function() return collapsedSections.trackedItems end,
        },
    }
    
    -- Add catalog icon entries (up to 40 — items + spells combined)
    for i = 1, 40 do
        args["catalogIcon" .. i] = CreateCatalogIconEntry(i)
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- SELECTED ACTIONS (works for both items and spells)
    -- ═══════════════════════════════════════════════════════════════
    args.selectedHeader = {
        type = "header",
        name = function()
            local sel = GetSelectedCount()
            if sel > 1 then
                return "Selected (" .. sel .. ")"
            end
            local item = GetSelectedItem()
            if item then
                local typeTag = ""
                if item.arcType == "spell" then
                    typeTag = " |cff88ccff(Spell)|r"
                elseif item.arcType == "trinket" then
                    typeTag = " |cff00ccff(Trinket)|r"
                else
                    typeTag = " |cff00ff00(Item)|r"
                end
                return item.name .. typeTag
            end
            return "No Selection"
        end,
        order = 100,
        hidden = function() return collapsedSections.trackedItems or HideIfNoSelection() end,
    }
    args.toggleBtn = {
        type = "execute",
        name = function()
            local item = GetSelectedItem()
            if item then
                return item.enabled and "Disable" or "Enable"
            end
            return "Toggle"
        end,
        desc = "Enable or disable the selected item(s)",
        order = 101,
        width = 0.6,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection() then return true end
            -- Hide toggle for spell entries (spells don't have enable/disable — remove to untrack)
            local item = GetSelectedItem()
            if item and item.arcType == "spell" then return true end
            return false
        end,
        func = function()
            if not ArcAuras then return end
            
            local toToggle = {}
            if next(selectedArcAuras) then
                for arcID in pairs(selectedArcAuras) do
                    table.insert(toToggle, arcID)
                end
            elseif selectedArcAura then
                table.insert(toToggle, selectedArcAura)
            end
            
            for _, arcID in ipairs(toToggle) do
                -- Only toggle items, not spells
                if not arcID:match("^arc_spell_") then
                    local db = ns.db and ns.db.char and ns.db.char.arcAuras
                    local config = db and db.trackedItems and db.trackedItems[arcID]
                    if config then
                        ArcAuras.SetTrackedItemEnabled(arcID, not config.enabled)
                    end
                end
            end
            
            Options.InvalidateCache()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.removeBtn = {
        type = "execute",
        name = "Remove",
        desc = "Remove the selected entry/entries",
        order = 102,
        width = 0.6,
        hidden = function() return collapsedSections.trackedItems or HideIfNoSelection() end,
        confirm = true,
        confirmText = "Remove selected?",
        func = function()
            if not ArcAuras then return end
            
            local toRemove = {}
            if next(selectedArcAuras) then
                for arcID in pairs(selectedArcAuras) do
                    table.insert(toRemove, arcID)
                end
            elseif selectedArcAura then
                table.insert(toRemove, selectedArcAura)
            end
            
            local removedItems, removedSpells = 0, 0
            for _, arcID in ipairs(toRemove) do
                if arcID:match("^arc_spell_") then
                    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RemoveTrackedSpell then
                        ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
                        removedSpells = removedSpells + 1
                    end
                else
                    ArcAuras.RemoveTrackedItem(arcID)
                    removedItems = removedItems + 1
                end
            end
            
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            
            local msg = "|cff00CCFF[Arc Auras]|r Removed "
            if removedItems > 0 and removedSpells > 0 then
                msg = msg .. removedItems .. " item(s) + " .. removedSpells .. " spell(s)"
            elseif removedSpells > 0 then
                msg = msg .. removedSpells .. " spell(s)"
            else
                msg = msg .. removedItems .. " item(s)"
            end
            print(msg)
            
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.deselectBtn = {
        type = "execute",
        name = "Deselect",
        order = 103,
        width = 0.6,
        hidden = function() return collapsedSections.trackedItems or HideIfNoSelection() end,
        func = function()
            selectedArcAura = nil
            wipe(selectedArcAuras)
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.configureBtn = {
        type = "execute",
        name = "|cff00ff00Configure in CDM Icons|r",
        desc = "Open CDM Icons catalog to configure appearance (Ready State glow, Cooldown State settings, etc)",
        order = 104,
        width = 1.4,
        hidden = function() 
            return collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1 
        end,
        func = function()
            if selectedArcAura and ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
                ns.CDMEnhanceOptions.SelectIcon(selectedArcAura, false)
            end
        end,
    }
    args.hideWhenUnequippedToggle = {
        type = "toggle",
        name = "Hide When Unequipped",
        desc = "Hide this item's frame when the trinket is not equipped.\n\n|cff888888This preserves the frame's position - when you equip the trinket again, it will appear in the same spot.|r",
        order = 105,
        width = 1.2,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1 then
                return true
            end
            local item = GetSelectedItem()
            if not item then return true end
            -- Only show for item-based frames (not auto-track slots, not spells)
            if item.arcType == "spell" then return true end
            if item.isAutoTrackSlot then return true end
            return item.arcType ~= "item"
        end,
        get = function()
            return ArcAuras and ArcAuras.IsHideWhenUnequippedEnabled and ArcAuras.IsHideWhenUnequippedEnabled(selectedArcAura)
        end,
        set = function(_, val)
            if ArcAuras and ArcAuras.SetHideWhenUnequipped and selectedArcAura then
                ArcAuras.SetHideWhenUnequipped(selectedArcAura, val)
                Options.InvalidateCache()
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end
        end,
    }

    -- Helper functions for spell-specific options (must be defined before use in closures)
    local function IsSpellSelected()
        local item = GetSelectedItem()
        return item and item.arcType == "spell"
    end

    local function GetSpellConfig()
        if not selectedArcAura then return nil end
        local db = ns.db and ns.db.char and ns.db.char.arcAuras
        return db and db.trackedSpells and db.trackedSpells[selectedArcAura]
    end

    -- ═══════════════════════════════════════════════════════════════
    -- ALWAYS SHOW (spell entries only — bypasses spec check)
    -- ═══════════════════════════════════════════════════════════════
    args.alwaysShowToggle = {
        type = "toggle",
        name = "|cff00FF00Always Show|r (bypass spec check)",
        desc = "When enabled, this spell frame will always show regardless of whether the game thinks you \"know\" the spell.\n\n|cff88ff88Use this for:|r\n• Engineering enchants (e.g., Nitro Boosts)\n• Profession abilities\n• Cross-class spells\n• Any spell that says \"not in current spec\" but you can still use\n\n|cff888888Spec filter and talent conditions still apply when set.|r",
        order = 106,
        width = 1.5,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1 then
                return true
            end
            return not IsSpellSelected()
        end,
        get = function()
            local cfg = GetSpellConfig()
            return cfg and cfg.forceShow or false
        end,
        set = function(_, val)
            local cfg = GetSpellConfig()
            if not cfg then return end
            cfg.forceShow = val or nil
            
            if val then
                -- If frame is hidden, show it now
                local fd = ns.ArcAurasCooldown and ns.ArcAurasCooldown.spellData and ns.ArcAurasCooldown.spellData[selectedArcAura]
                if fd and fd.frame and fd.frame._arcHiddenNotInSpec then
                    if ns.ArcAurasCooldown.ShowFrame then
                        ns.ArcAurasCooldown.ShowFrame(selectedArcAura)
                    end
                elseif not fd and ArcAuras.isEnabled then
                    -- Frame doesn't exist, create it
                    local arcID = selectedArcAura
                    local spellID = cfg.spellID
                    local spellConfig = {
                        type = "spell",
                        spellID = spellID,
                        name = cfg.name,
                        icon = cfg.iconOverride or cfg.icon,
                        enabled = true,
                    }
                    local frame = ArcAuras.CreateFrame(arcID, spellConfig)
                    if frame then
                        ArcAuras.LoadFramePosition(arcID, frame)
                        frame:Show()
                        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.InitializeSpellFrame then
                            ns.ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
                        end
                    end
                end
            else
                -- Re-evaluate visibility
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
                    ns.ArcAurasCooldown.RefreshSpecVisibility()
                end
            end
            
            Options.InvalidateCache()
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }

    -- ═══════════════════════════════════════════════════════════════
    -- ICON OVERRIDE (both items and spells)
    -- ═══════════════════════════════════════════════════════════════
    args.iconOverrideHeader = {
        type = "description",
        name = "\n|cffffd700Icon Override:|r",
        order = 107,
        width = "full",
        fontSize = "medium",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1
        end,
    }
    args.iconOverrideDesc = {
        type = "description",
        name = function()
            local item = GetSelectedItem()
            if not item then return "" end
            if item.hasIconOverride then
                local overrideID = item.config and (item.config.iconOverrideID or "?") or "?"
                return "|cffFFCC00Current: Custom Icon|r (Source ID: " .. tostring(overrideID) .. ")\n|cff888888Enter a new Spell ID or Item ID below, or 0 to reset.|r"
            end
            return "|cff888888Enter a Spell ID or Item ID to use its icon instead of the default. Enter 0 or leave blank to reset.|r"
        end,
        order = 108,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1
        end,
    }
    args.iconOverrideInput = {
        type = "input",
        name = "Icon Source ID",
        desc = "Enter a Spell ID or Item ID to use its icon.\nEnter 0 to reset to the default icon.",
        order = 109,
        width = 0.8,
        get = function()
            local item = GetSelectedItem()
            if item and item.config and item.config.iconOverrideID then
                return tostring(item.config.iconOverrideID)
            end
            return ""
        end,
        set = function(_, val)
            val = val:gsub("[^%d]", "")
            local overrideID = tonumber(val)
            if not selectedArcAura then return end
            
            local item = GetSelectedItem()
            if not item then return end
            
            if item.arcType == "spell" then
                -- Use ArcAurasCooldown's icon override
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ApplyIconOverride then
                    ns.ArcAurasCooldown.ApplyIconOverride(selectedArcAura, overrideID)
                end
            else
                -- Use ArcAuras' icon override for items
                if ArcAuras and ArcAuras.ApplyIconOverride then
                    ArcAuras.ApplyIconOverride(selectedArcAura, overrideID)
                end
            end
            
            Options.InvalidateCache()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1
        end,
    }
    args.iconOverrideResetBtn = {
        type = "execute",
        name = "Reset Icon",
        desc = "Remove the custom icon and use the default spell/item icon",
        order = 109.5,
        width = 0.6,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1 then
                return true
            end
            local item = GetSelectedItem()
            return not item or not item.hasIconOverride
        end,
        func = function()
            if not selectedArcAura then return end
            local item = GetSelectedItem()
            if not item then return end
            
            if item.arcType == "spell" then
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ApplyIconOverride then
                    ns.ArcAurasCooldown.ApplyIconOverride(selectedArcAura, nil)
                end
            else
                if ArcAuras and ArcAuras.ApplyIconOverride then
                    ArcAuras.ApplyIconOverride(selectedArcAura, nil)
                end
            end
            
            Options.InvalidateCache()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }

    -- ═══════════════════════════════════════════════════════════════
    -- SHOW ON SPECS (spell entries only)
    -- ═══════════════════════════════════════════════════════════════

    local function ToggleSpecInList(showOnSpecs, specNum, value)
        if value then
            local found = false
            for _, s in ipairs(showOnSpecs) do
                if s == specNum then found = true break end
            end
            if not found then table.insert(showOnSpecs, specNum) end
        else
            if #showOnSpecs == 0 then
                local numSpecs = GetNumSpecializations() or 4
                for i = 1, numSpecs do
                    table.insert(showOnSpecs, i)
                end
            end
            for i = #showOnSpecs, 1, -1 do
                if showOnSpecs[i] == specNum then
                    table.remove(showOnSpecs, i)
                end
            end
        end
    end

    local function IsSpecEnabled(specNum)
        local cfg = GetSpellConfig()
        if not cfg or not cfg.showOnSpecs or #cfg.showOnSpecs == 0 then return true end
        for _, spec in ipairs(cfg.showOnSpecs) do
            if spec == specNum then return true end
        end
        return false
    end

    local function SetSpecEnabled(specNum, value)
        local cfg = GetSpellConfig()
        if not cfg then return end
        if not cfg.showOnSpecs then cfg.showOnSpecs = {} end
        ToggleSpecInList(cfg.showOnSpecs, specNum, value)
        -- If all specs are checked, clear to nil (= show on all)
        if cfg.showOnSpecs then
            local numSpecs = GetNumSpecializations() or 4
            local allChecked = #cfg.showOnSpecs >= numSpecs
            if allChecked then
                local seen = {}
                for _, s in ipairs(cfg.showOnSpecs) do seen[s] = true end
                allChecked = true
                for i = 1, numSpecs do
                    if not seen[i] then allChecked = false break end
                end
            end
            if allChecked then cfg.showOnSpecs = nil end
        end
        -- Apply immediately
        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
            ns.ArcAurasCooldown.RefreshSpecVisibility()
        end
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end

    args.showOnSpecsHeader = {
        type = "description",
        name = "\n|cffffd700Show on Specs:|r",
        order = 110,
        width = "full",
        fontSize = "medium",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }
    args.showOnSpecsDesc = {
        type = "description",
        name = "|cff888888Choose which specs this spell frame appears on. Unchecked specs will hide the frame even if the spell is known. All checked (or none set) = show on every spec.|r",
        order = 111,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }

    for specNum = 1, 4 do
        args["showOnSpec" .. specNum] = {
            type = "toggle",
            name = function()
                local _, specName, _, specIcon = GetSpecializationInfo(specNum)
                if specIcon and specName then
                    return string.format("|T%s:14:14:0:0|t %s", specIcon, specName)
                end
                return specName or ("Spec " .. specNum)
            end,
            desc = function()
                local _, specName = GetSpecializationInfo(specNum)
                return specName and ("Show on " .. specName) or ("Show on Spec " .. specNum)
            end,
            order = 112 + (specNum * 0.1),
            width = 0.85,
            get = function() return IsSpecEnabled(specNum) end,
            set = function(_, val) SetSpecEnabled(specNum, val) end,
            hidden = function()
                if collapsedSections.trackedItems or HideIfNoSelection()
                    or GetSelectedCount() > 1 or not IsSpellSelected() then
                    return true
                end
                return (GetNumSpecializations() or 4) < specNum
            end,
        }
    end

    -- ═══════════════════════════════════════════════════════════════
    -- TALENT CONDITIONS (spell entries only)
    -- ═══════════════════════════════════════════════════════════════
    args.talentCondHeader = {
        type = "description",
        name = "\n|cffffd700Talent Conditions:|r",
        order = 120,
        width = "full",
        fontSize = "medium",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }
    args.talentCondDesc = {
        type = "description",
        name = "|cff888888Only show this frame when specific talents are active. If no conditions are set, the frame shows whenever the spell is known.|r",
        order = 121,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }
    args.talentCondSummary = {
        type = "description",
        name = function()
            local cfg = GetSpellConfig()
            if not cfg then return "" end
            if ns.TalentPicker and ns.TalentPicker.GetConditionSummary then
                return ns.TalentPicker.GetConditionSummary(cfg.talentConditions, cfg.talentConditionMode)
            end
            return "|cff888888No talent conditions|r"
        end,
        order = 122,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }
    args.talentCondEdit = {
        type = "execute",
        name = "Edit Talent Conditions",
        desc = "Open the talent picker to choose which talents must be active (or inactive) for this frame to show.",
        order = 123,
        width = 1.0,
        func = function()
            local cfg = GetSpellConfig()
            if not cfg or not ns.TalentPicker then return end
            ns.TalentPicker.OpenPicker(cfg.talentConditions, cfg.talentConditionMode, function(conditions, matchMode)
                cfg.talentConditions = conditions
                cfg.talentConditionMode = matchMode
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
                    ns.ArcAurasCooldown.RefreshSpecVisibility()
                end
                Options.InvalidateCache()
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end)
        end,
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected()
        end,
    }
    args.talentCondClear = {
        type = "execute",
        name = "Clear",
        desc = "Remove all talent conditions. The frame will show whenever the spell is known.",
        order = 124,
        width = 0.5,
        func = function()
            local cfg = GetSpellConfig()
            if not cfg then return end
            cfg.talentConditions = nil
            cfg.talentConditionMode = nil
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
                ns.ArcAurasCooldown.RefreshSpecVisibility()
            end
            Options.InvalidateCache()
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellSelected() then
                return true
            end
            local cfg = GetSpellConfig()
            return not cfg or not cfg.talentConditions or #cfg.talentConditions == 0
        end,
    }

    -- ═══════════════════════════════════════════════════════════════
    -- AUTO-TRACK EQUIPPED SLOTS
    -- ═══════════════════════════════════════════════════════════════
    args.autoTrackSlotsHeader = {
        type = "toggle",
        name = "Auto-Track Equipped Slots",
        desc = "Click to expand/collapse\n\nConfigure which equipment slots are automatically tracked. When enabled, frames automatically update when you change gear.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsedSections.autoTrackSlots end,
        set = function(_, v) collapsedSections.autoTrackSlots = not v end,
        order = 150,
        width = "full",
    }
    args.autoTrackSlotsDesc = {
        type = "description",
        name = "|cff888888Auto-tracked slots automatically update their icon when you swap gear.\nSlots marked |cff88ff88A|r in the catalog above are auto-tracked.|r",
        order = 151,
        fontSize = "small",
        hidden = function() return collapsedSections.autoTrackSlots end,
    }
    args.autoTrackMasterToggle = {
        type = "toggle",
        name = "|TInterface\\Icons\\INV_Misc_Bag_10:16|t  Enable Auto-Track Equipped Trinkets",
        desc = "Master toggle for auto-tracking equipped trinkets.\n\nWhen enabled, creates 2 persistent frames that always show your equipped trinkets.\n\n|cff88ff88These frames track the SLOT|r - icons automatically update when you swap trinkets.\n\nDisabling this removes only the auto-track frames, not manually added trinkets.",
        order = 152,
        width = "full",
        get = function()
            return ArcAuras and ArcAuras.IsAutoTrackEquippedTrinketsEnabled()
        end,
        set = function(_, val)
            if ArcAuras and ArcAuras.SetAutoTrackEquippedTrinkets then
                ArcAuras.SetAutoTrackEquippedTrinkets(val)
                Options.InvalidateCache()
                if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                    ns.CDMEnhanceOptions.InvalidateCache()
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
                if val then
                    print("|cff00CCFF[Arc Auras]|r Auto-tracking equipped trinkets enabled")
                else
                    print("|cff00CCFF[Arc Auras]|r Auto-tracking equipped trinkets disabled")
                end
            end
        end,
        hidden = function() return collapsedSections.autoTrackSlots end,
    }
    args.onlyOnUseTrinkets = {
        type = "toggle",
        name = "|TInterface\\Icons\\Spell_Nature_Lightning:16|t  Only Track On-Use Trinkets",
        desc = "When enabled, passive trinkets (those without an on-use effect) will not be auto-tracked.\n\nThis helps reduce clutter if you only care about active trinket cooldowns.",
        order = 153,
        width = "full",
        get = function()
            return ArcAuras and ArcAuras.IsOnlyOnUseTrinketsEnabled()
        end,
        set = function(_, val)
            if ArcAuras and ArcAuras.SetOnlyOnUseTrinkets then
                ArcAuras.SetOnlyOnUseTrinkets(val)
                Options.InvalidateCache()
                if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                    ns.CDMEnhanceOptions.InvalidateCache()
                end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end
        end,
        hidden = function() 
            return collapsedSections.autoTrackSlots or not (ArcAuras and ArcAuras.IsAutoTrackEquippedTrinketsEnabled())
        end,
    }
    args.slotsSpacer = {
        type = "description",
        name = "",
        order = 154,
        fontSize = "small",
        hidden = function() 
            return collapsedSections.autoTrackSlots or not (ArcAuras and ArcAuras.IsAutoTrackEquippedTrinketsEnabled())
        end,
    }
    
    -- Add slot toggles for each trinket slot
    if ArcAuras and ArcAuras.GetTrinketSlots then
        local slots = ArcAuras.GetTrinketSlots()
        for i, slotInfo in ipairs(slots) do
            args["autoTrackSlot" .. slotInfo.slotID] = CreateAutoTrackSlotEntry(slotInfo)
            args["autoTrackSlot" .. slotInfo.slotID].order = 155 + i
        end
    else
        args.autoTrackSlot13 = {
            type = "toggle",
            name = "|TInterface\\Icons\\INV_Misc_QuestionMark:18|t  |cffffd700Trinket 1:|r |cff666666(Loading...)|r",
            order = 156,
            width = "full",
            get = function() return true end,
            set = function() end,
            hidden = function() return collapsedSections.autoTrackSlots end,
        }
        args.autoTrackSlot14 = {
            type = "toggle",
            name = "|TInterface\\Icons\\INV_Misc_QuestionMark:18|t  |cffffd700Trinket 2:|r |cff666666(Loading...)|r",
            order = 157,
            width = "full",
            get = function() return true end,
            set = function() end,
            hidden = function() return collapsedSections.autoTrackSlots end,
        }
    end
    
    -- ═══════════════════════════════════════════════════════════════
    -- BULK MANAGEMENT
    -- ═══════════════════════════════════════════════════════════════
    args.managementHeader = {
        type = "toggle",
        name = "Bulk Management",
        desc = "Click to expand/collapse",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsedSections.management end,
        set = function(_, v) collapsedSections.management = not v end,
        order = 200,
        width = "full",
    }
    args.clearTrinkets = {
        type = "execute",
        name = "Clear Trinkets",
        desc = "Remove all trinkets from tracking",
        order = 201,
        width = 0.9,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all tracked trinkets?",
        func = function()
            if not ArcAuras then return end
            local removed = 0
            local db = ns.db and ns.db.char and ns.db.char.arcAuras
            if db and db.trackedItems then
                local toRemove = {}
                for arcID in pairs(db.trackedItems) do
                    local arcType = ArcAuras.ParseArcID(arcID)
                    if arcType == "trinket" then
                        table.insert(toRemove, arcID)
                    end
                end
                for _, arcID in ipairs(toRemove) do
                    ArcAuras.RemoveTrackedItem(arcID)
                    removed = removed + 1
                end
            end
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            print("|cff00CCFF[Arc Auras]|r Removed " .. removed .. " trinket(s)")
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.clearItems = {
        type = "execute",
        name = "Clear Custom Items",
        desc = "Remove all custom items (keeps trinkets and spells)",
        order = 202,
        width = 1.1,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all custom items?",
        func = function()
            if not ArcAuras then return end
            local removed = 0
            local db = ns.db and ns.db.char and ns.db.char.arcAuras
            if db and db.trackedItems then
                local toRemove = {}
                for arcID in pairs(db.trackedItems) do
                    local arcType = ArcAuras.ParseArcID(arcID)
                    if arcType == "item" then
                        table.insert(toRemove, arcID)
                    end
                end
                for _, arcID in ipairs(toRemove) do
                    ArcAuras.RemoveTrackedItem(arcID)
                    removed = removed + 1
                end
            end
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            print("|cff00CCFF[Arc Auras]|r Removed " .. removed .. " item(s)")
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.clearSpells = {
        type = "execute",
        name = "Clear Spells",
        desc = "Remove all tracked spells",
        order = 203,
        width = 0.8,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all tracked spells?",
        func = function()
            local db = ns.db and ns.db.char and ns.db.char.arcAuras
            if db and db.trackedSpells and ns.ArcAurasCooldown then
                local toRemove = {}
                for arcID in pairs(db.trackedSpells) do
                    table.insert(toRemove, arcID)
                end
                for _, arcID in ipairs(toRemove) do
                    ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
                end
                print("|cff00CCFF[Arc Auras]|r Removed " .. #toRemove .. " spell(s)")
            end
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    args.clearAll = {
        type = "execute",
        name = "Clear All",
        desc = "Remove everything (items + spells)",
        order = 204,
        width = 0.7,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove ALL tracked items and spells?",
        func = function()
            if not ArcAuras then return end
            local db = ns.db and ns.db.char and ns.db.char.arcAuras
            local totalRemoved = 0
            if db and db.trackedItems then
                local toRemove = {}
                for arcID in pairs(db.trackedItems) do
                    table.insert(toRemove, arcID)
                end
                for _, arcID in ipairs(toRemove) do
                    ArcAuras.RemoveTrackedItem(arcID)
                end
                totalRemoved = totalRemoved + #toRemove
            end
            if db and db.trackedSpells and ns.ArcAurasCooldown then
                local toRemove = {}
                for arcID in pairs(db.trackedSpells) do
                    table.insert(toRemove, arcID)
                end
                for _, arcID in ipairs(toRemove) do
                    ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
                end
                totalRemoved = totalRemoved + #toRemove
            end
            print("|cff00CCFF[Arc Auras]|r Removed " .. totalRemoved .. " total entries")
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                ns.CDMEnhanceOptions.InvalidateCache()
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    
    return {
        type = "group",
        name = "Arc Auras",
        order = 5,
        args = args,
    }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

function Options.InvalidateCache()
    cacheInvalidated = true
    cachedItemList = nil
end

function Options.Open()
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory("ArcUI")
    end
end

-- Allow CDM Enhance Options to select an Arc Aura icon
function Options.SelectIcon(arcID)
    if not arcID then return end
    wipe(selectedArcAuras)
    selectedArcAura = arcID
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT HANDLER: Refresh options when equipment changes
-- ═══════════════════════════════════════════════════════════════════════════

local optionsEventFrame = CreateFrame("Frame")
optionsEventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
optionsEventFrame:SetScript("OnEvent", function(self, event, slot)
    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if slot == 13 or slot == 14 then
            Options.InvalidateCache()
            C_Timer.After(0.1, function()
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end)
        end
    end
end)