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
    totemSlots = true,
    management = true,
}

-- Every options-panel open starts with the Tracked catalog EXPANDED (the
-- collapse state is session-sticky otherwise)
if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("ArcAurasTrackedCatalog", {
        onOpen = function() collapsedSections.trackedItems = false end,
    })
end

-- Cache
local cachedItemList = nil
local cacheInvalidated = true

-- Input state
local pendingItemID = ""
local pendingSpellID = ""
local pendingAuraID = ""
local pendingAuraMode = "buff"   -- "buff" | "debuff" | "both" (12.1 aura icons)
local pendingAuraOwnOnly = false

-- ═══════════════════════════════════════════════════════════════════════════
-- CONFIRMATION DIALOG: Passive spell warning (buff/debuff detected)
-- Simple standalone frame, not anchored to anything
-- ═══════════════════════════════════════════════════════════════════════════

local confirmFrame = nil

local function ShowPassiveSpellWarning(spellID, displayName)
    if confirmFrame then
        confirmFrame:Hide()
    end

    if not confirmFrame then
        local f = CreateFrame("Frame", "ArcAurasPassiveWarning", UIParent, "BackdropTemplate")
        f:SetSize(400, 160)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
        f:SetFrameStrata("TOOLTIP")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0, 0, 0, 1)

        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -16)
        title:SetText("Arc Auras")
        f.title = title

        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", 20, -38)
        text:SetPoint("TOPRIGHT", -20, -38)
        text:SetJustifyH("LEFT")
        text:SetSpacing(2)
        f.text = text

        local addBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        addBtn:SetSize(120, 24)
        addBtn:SetPoint("BOTTOMLEFT", 20, 16)
        addBtn:SetText("Add Anyway")
        f.addBtn = addBtn

        local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        cancelBtn:SetSize(120, 24)
        cancelBtn:SetPoint("BOTTOMRIGHT", -20, 16)
        cancelBtn:SetText("Cancel")
        cancelBtn:SetScript("OnClick", function() f:Hide() end)

        confirmFrame = f
    end

    confirmFrame.text:SetText(
        displayName .. " (ID: " .. spellID .. ") looks like a buff or debuff, " ..
        "not a castable cooldown.\n\n" ..
        "Arc Auras only tracks spell cooldowns. For buff/debuff timers, " ..
        "use Blizzard's Cooldown Manager (Tracked Buffs) instead."
    )

    confirmFrame.addBtn:SetScript("OnClick", function()
        confirmFrame:Hide()
        local ArcAurasCooldown = ns.ArcAurasCooldown
        if ArcAurasCooldown and ArcAurasCooldown.AddTrackedSpell then
            local success = ArcAurasCooldown.AddTrackedSpell(spellID)
            if success then
                local name = ArcAurasCooldown.GetSpellNameAndIcon(spellID) or ("Spell " .. spellID)
                print("|cff00CCFF[Arc Auras]|r Added spell: " .. name)
                Options.InvalidateCache()
                if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
                    ns.CDMEnhanceOptions.InvalidateCache()
                end
            else
                print("|cff00CCFF[Arc Auras]|r Already tracked or invalid spell")
            end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end
    end)

    confirmFrame:Show()
    confirmFrame:Raise()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ADD SUBMIT HELPERS — one source of truth for adding each icon kind. Used
-- by BOTH the legacy add inputs and the catalog "+" tile's Add New section
-- (the legacy blocks retire once the new flow is approved).
-- ═══════════════════════════════════════════════════════════════════════════

local function NotifyCatalogChanged()
    Options.InvalidateCache()
    if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then
        ns.CDMEnhanceOptions.InvalidateCache()
    end
    LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EXPORTED ARC-ICON OPERATIONS — the Icon Catalog renders arc lifecycle
-- controls (remove / load conditions / bulk) through these, so both panels
-- share one implementation.
-- ═══════════════════════════════════════════════════════════════════════════

-- Resolve the config table (carrying showOnSpecs/talentConditions) for any
-- arcID. Totem slots have no such config -> nil.
function Options.GetArcConfigByID(arcID)
    if type(arcID) ~= "string" then return nil end
    local db = ns.db and ns.db.char and ns.db.char.arcAuras
    if arcID:match("^arc_spell_") then
        return db and db.trackedSpells and db.trackedSpells[arcID]
    elseif arcID:match("^arc_aura_") then
        return ns.AuraIcons and ns.AuraIcons.Get and ns.AuraIcons.Get(arcID)
    elseif arcID:match("^arc_timer_") then
        return db and db.customTimers and db.customTimers[arcID]
    elseif arcID:match("^arc_trinket_") or arcID:match("^arc_item_") then
        return db and db.trackedItems and db.trackedItems[arcID]
    end
    return nil
end

-- Re-evaluate visibility for every arc system after a condition edit.
function Options.RefreshArcVisibility()
    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
        ns.ArcAurasCooldown.RefreshSpecVisibility()
    elseif ArcAuras and ArcAuras.RefreshVisibility then
        ArcAuras.RefreshVisibility()
    end
    if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
        ns.AuraIcons.RefreshVisibility()
    end
    NotifyCatalogChanged()
end

-- Spec-toggle write with the all-checked -> nil normalization (nil = show
-- everywhere). cfg is a table from GetArcConfigByID.
function Options.ApplyArcSpecToggle(cfg, specNum, value)
    if not cfg then return end
    if not cfg.showOnSpecs then cfg.showOnSpecs = {} end
    if value then
        local found = false
        for _, s in ipairs(cfg.showOnSpecs) do
            if s == specNum then found = true break end
        end
        if not found then table.insert(cfg.showOnSpecs, specNum) end
    else
        if #cfg.showOnSpecs == 0 then
            local numSpecs = GetNumSpecializations() or 4
            for i = 1, numSpecs do table.insert(cfg.showOnSpecs, i) end
        end
        for i = #cfg.showOnSpecs, 1, -1 do
            if cfg.showOnSpecs[i] == specNum then
                table.remove(cfg.showOnSpecs, i)
            end
        end
    end
    local numSpecs = GetNumSpecializations() or 4
    if #cfg.showOnSpecs >= numSpecs then
        local seen = {}
        for _, s in ipairs(cfg.showOnSpecs) do seen[s] = true end
        local allChecked = true
        for i = 1, numSpecs do
            if not seen[i] then allChecked = false break end
        end
        if allChecked then cfg.showOnSpecs = nil end
    end
    Options.RefreshArcVisibility()
end

-- Icon override for any arc kind (0/nil = reset). Shared with the catalog.
-- idType (optional): "spell" | "item" | "icon" — the user's declaration of
-- what the number IS, killing the spell-ID-vs-FileDataID ambiguity (the
-- numbers can overlap; guessing is wrong). nil = legacy per-kind semantics
-- (source ID for spells/auras/items, FileDataID for timers).
function Options.ApplyArcIconOverride(arcID, overrideID, idType)
    if type(arcID) ~= "string" then return end
    if overrideID == 0 then overrideID = nil end

    -- "icon" = a raw texture FileDataID: store + repaint directly, no
    -- source lookup (works for ANY texture, not just spell/item icons)
    if overrideID and idType == "icon" then
        if arcID:match("^arc_timer_") then
            if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
                ns.ArcAurasTimer.ApplyIconOverride(arcID, overrideID)
            end
        else
            local cfg = Options.GetArcConfigByID(arcID)
            if not cfg then return end
            cfg.iconOverride = overrideID
            cfg.iconOverrideID = overrideID
            local frame = ArcAuras and ArcAuras.frames and ArcAuras.frames[arcID]
            if frame and frame.Icon then frame.Icon:SetTexture(overrideID) end
            if arcID:match("^arc_aura_") and ns.AuraIcons and ns.AuraIcons.GetEntry then
                local e = ns.AuraIcons.GetEntry(arcID)
                if e and e.holder and e.holder.Icon then
                    e.holder.Icon:SetTexture(overrideID)
                end
            end
        end
        NotifyCatalogChanged()
        return
    end

    -- timers store a FileDataID — resolve a declared spell/item source first
    if overrideID and arcID:match("^arc_timer_") and idType then
        local fileID
        if idType == "item" then
            fileID = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(overrideID)
        else
            local info = C_Spell.GetSpellInfo(overrideID)
            fileID = info and (info.iconID or info.originalIconID)
        end
        if not fileID then
            print("|cff00CCFF[Arc Auras]|r Could not resolve an icon from that "
                .. (idType == "item" and "Item" or "Spell") .. " ID")
            return
        end
        overrideID = fileID
    end

    if arcID:match("^arc_spell_") then
        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.ApplyIconOverride then
            ns.ArcAurasCooldown.ApplyIconOverride(arcID, overrideID)
        end
    elseif arcID:match("^arc_aura_") then
        if ns.AuraIcons and ns.AuraIcons.ApplyIconOverride then
            ns.AuraIcons.ApplyIconOverride(arcID, overrideID)
        end
    elseif arcID:match("^arc_timer_") then
        if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
            ns.ArcAurasTimer.ApplyIconOverride(arcID, overrideID)
        end
    elseif ArcAuras and ArcAuras.ApplyIconOverride then
        ArcAuras.ApplyIconOverride(arcID, overrideID)
    end
    NotifyCatalogChanged()
end

-- Remove a list of arc icons of ANY kind (the tab Remove dispatch, shared).
-- Totem slots map to their per-slot disable.
function Options.RemoveArcIcons(list)
    for _, arcID in ipairs(list) do
        if arcID:match("^arc_spell_") then
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RemoveTrackedSpell then
                ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
            end
        elseif arcID:match("^arc_aura_") then
            if ns.AuraIcons and ns.AuraIcons.Delete then
                ns.AuraIcons.Delete(arcID)
            end
        elseif arcID:match("^arc_timer_") then
            if ns.ArcAurasTimer and ns.ArcAurasTimer.RemoveTimer then
                ns.ArcAurasTimer.RemoveTimer(arcID)
            end
        elseif arcID:match("^arc_totem_") then
            local slot = tonumber(arcID:match("^arc_totem_(%d+)"))
            if slot and ns.ArcAurasTotems and ns.ArcAurasTotems.SetSlotEnabled then
                ns.ArcAurasTotems.SetSlotEnabled(slot, false)
            end
        elseif ArcAuras and ArcAuras.RemoveTrackedItem then
            ArcAuras.RemoveTrackedItem(arcID)
        end
    end
    selectedArcAura = nil
    wipe(selectedArcAuras)
    NotifyCatalogChanged()
end

-- Bulk clear, one operation per kind: "trinket" | "item" | "spell" | "aura"
-- | "all". EXPORTED — the Icon Catalog's Arc Icons filter renders its own
-- bulk buttons through this, so both panels share one implementation.
function Options.ClearArcCategory(kind)
    if not ArcAuras then return end
    local db = ns.db and ns.db.char and ns.db.char.arcAuras
    local removed = 0
    local function clearItemsOfType(arcType)
        if not (db and db.trackedItems) then return end
        local toRemove = {}
        for arcID in pairs(db.trackedItems) do
            if ArcAuras.ParseArcID(arcID) == arcType then
                table.insert(toRemove, arcID)
            end
        end
        for _, arcID in ipairs(toRemove) do
            ArcAuras.RemoveTrackedItem(arcID)
            removed = removed + 1
        end
    end
    local function clearSpells()
        if not (db and db.trackedSpells and ns.ArcAurasCooldown) then return end
        local toRemove = {}
        for arcID in pairs(db.trackedSpells) do
            table.insert(toRemove, arcID)
        end
        for _, arcID in ipairs(toRemove) do
            ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
            removed = removed + 1
        end
    end
    local function clearAuras()
        if not (ns.AuraIcons and ns.AuraIcons.All and ns.AuraIcons.Delete) then return end
        local toRemove = {}
        for arcID in pairs(ns.AuraIcons.All()) do
            table.insert(toRemove, arcID)
        end
        for _, arcID in ipairs(toRemove) do
            ns.AuraIcons.Delete(arcID)
            removed = removed + 1
        end
    end
    if kind == "trinket" then clearItemsOfType("trinket")
    elseif kind == "item" then clearItemsOfType("item")
    elseif kind == "spell" then clearSpells()
    elseif kind == "aura" then clearAuras()
    elseif kind == "all" then
        clearItemsOfType("trinket")
        clearItemsOfType("item")
        clearSpells()
        clearAuras()
    end
    selectedArcAura = nil
    wipe(selectedArcAuras)
    print("|cff00CCFF[Arc Auras]|r Removed " .. removed .. " tracked icon(s)")
    NotifyCatalogChanged()
end

-- Each returns: true, "name" on success | false, "reason" on failure |
-- nil on empty/no-op input (the popup shows these inline; chat prints stay
-- for parity with the legacy inputs).
local function SubmitAddItem(val)
    val = val:gsub("%D", "")
    local itemID = tonumber(val)
    pendingItemID = ""
    if not itemID or itemID <= 0 then return nil end
    if not (ArcAuras and ArcAuras.AddTrackedItem) then return nil end
    local success = ArcAuras.AddTrackedItem({
        type = "item",
        itemID = itemID,
        enabled = true,
    })
    local name = select(1, GetItemInfo(itemID)) or ("Item " .. itemID)
    if success then
        print("|cff00CCFF[Arc Auras]|r Added: " .. name)
    else
        print("|cff00CCFF[Arc Auras]|r Already tracked or invalid")
    end
    NotifyCatalogChanged()
    return success and true or false, success and name or "Already tracked or invalid",
        success and ArcAuras.MakeItemID and ArcAuras.MakeItemID(itemID) or nil
end

local function SubmitAddSpell(val)
    val = val:gsub("[^%d]", "")
    local spellID = tonumber(val)
    pendingSpellID = ""
    if not spellID or spellID <= 0 then return nil end
    local isPassive = C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellID)
    local spellName = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if isPassive then
        ShowPassiveSpellWarning(spellID, spellName or ("Spell " .. spellID))
        return false, "Passive spell (see the warning dialog)"
    end
    local ArcAurasCooldown = ns.ArcAurasCooldown
    if not (ArcAurasCooldown and ArcAurasCooldown.AddTrackedSpell) then return nil end
    local success = ArcAurasCooldown.AddTrackedSpell(spellID)
    local name = ArcAurasCooldown.GetSpellNameAndIcon(spellID) or ("Spell " .. spellID)
    if success then
        print("|cff00CCFF[Arc Auras]|r Added spell: " .. name)
    else
        print("|cff00CCFF[Arc Auras]|r Already tracked or invalid spell")
    end
    NotifyCatalogChanged()
    return success and true or false, success and name or "Already tracked or invalid spell",
        success and ArcAuras.MakeSpellID and ArcAuras.MakeSpellID(spellID) or nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AURA PRESETS (quick-add buttons on the Add popup's Aura page)
-- Multi-ID presets ride ONE icon via the def's spellIDs candidate map — the
-- engine lights whichever variant is actually on you (the same one-slot,
-- many-IDs shape EQOL uses for lust). Primary ID supplies the icon.
-- ═══════════════════════════════════════════════════════════════════════════
local AURA_PRESETS = {
    {
        key      = "powerinfusion",
        name     = "Power Infusion",
        spellID  = 10060,            -- cast AND buff are the same ID
        unitMode = "buff",
        desc     = "Priest haste buff on you.",
    },
    {
        key      = "bloodlust",
        name     = "Bloodlust / Heroism",
        spellID  = 2825,             -- primary: supplies the icon
        unitMode = "buff",
        -- every lust-equivalent BUFF on one icon (Blizzard ships no shared
        -- list; verified individually against the 12.1 spell data)
        spellIDs = {
            [2825]   = true,   -- Bloodlust (shaman, Horde)
            [32182]  = true,   -- Heroism (shaman, Alliance)
            [80353]  = true,   -- Time Warp (mage)
            [264667] = true,   -- Primal Rage (hunter pet)
            [390386] = true,   -- Fury of the Aspects (evoker)
            [466904] = true,   -- Harrier's Cry (marksmanship hunter)
            [90355]  = true,   -- Ancient Hysteria (legacy exotic pet)
            [160452] = true,   -- Netherwinds (legacy exotic pet)
            [146555] = true,   -- Drums of Rage
            [178207] = true,   -- Drums of Fury
            [230935] = true,   -- Drums of the Mountain
            [256740] = true,   -- Drums of the Maelstrom
            [309658] = true,   -- Drums of Deathly Ferocity
            [381301] = true,   -- Feral Hide Drums
            [444257] = true,   -- Thunderous Drums
            [1243972] = true,  -- Void-touched Drums
        },
        desc     = "Any lust: Bloodlust, Heroism, Time Warp, Primal Rage,\nFury of the Aspects, Harrier's Cry and drums — one icon.",
    },
}

local function IsAuraPresetInstalled(preset)
    if not (ns.AuraIcons and ns.AuraIcons.MakeID and ns.AuraIcons.Get) then return false end
    return ns.AuraIcons.Get(ns.AuraIcons.MakeID(preset.spellID)) ~= nil
end

local function AddAuraPreset(preset)
    if not (ns.AuraIcons and ns.AuraIcons.Create) then return false, "12.1 required" end
    if IsAuraPresetInstalled(preset) then return false, "Already tracked" end
    local arcID = ns.AuraIcons.Create({
        spellID  = preset.spellID,
        spellIDs = preset.spellIDs,
        unitMode = preset.unitMode or "buff",
        name     = preset.name,
    })
    if not arcID then return false, "Could not create icon" end
    print("|cff00CCFF[Arc Auras]|r Added aura icon: " .. (preset.name or "?"))
    NotifyCatalogChanged()
    return true, preset.name, arcID
end

local function SubmitAddAura(val)
    val = val:gsub("[^%d]", "")
    local spellID = tonumber(val)
    pendingAuraID = ""
    if not spellID or spellID <= 0 then return nil end
    if not (ns.AuraIcons and ns.AuraIcons.Create) then return nil end
    local arcID = ns.AuraIcons.Create({
        spellID = spellID,
        unitMode = pendingAuraMode,
        ownOnly = pendingAuraOwnOnly,
    })
    if arcID then
        local def = ns.AuraIcons.Get(arcID)
        local name = (def and def.name) or ("Aura " .. spellID)
        print("|cff00CCFF[Arc Auras]|r Added aura icon: " .. name)
        NotifyCatalogChanged()
        return true, name, arcID
    end
    print("|cff00CCFF[Arc Auras]|r Could not add aura icon (invalid ID or already tracked)")
    NotifyCatalogChanged()
    return false, "Invalid ID or already tracked"
end

local function SubmitAddTimer(idVal, durVal)
    local spellID = tonumber((idVal or ""):gsub("[^%d]", ""))
    local dur = tonumber(durVal or "")
    if not spellID or spellID <= 0 then return false, "Invalid spell ID" end
    if not dur or dur <= 0 then return false, "Duration must be a positive number" end
    if dur > 7200 then dur = 7200 end
    if not (ns.ArcAurasTimer and ns.ArcAurasTimer.AddTimer) then return nil end
    local ok, result = ns.ArcAurasTimer.AddTimer(spellID, dur, {
        startTrigger = { events = { cast = true }, spellID = nil, restartOnRefire = false },
        endTrigger   = { events = {} },
    })
    if ok then
        local info = C_Spell.GetSpellInfo(spellID)
        local name = (info and info.name) or ("Spell " .. spellID)
        print(string.format("|cff00CCFF[Arc Auras]|r Added timer: %s |cff888888(%.3gs, starts on cast)|r", name, dur))
        NotifyCatalogChanged()
        return true, name, result
    end
    print("|cff00CCFF[Arc Auras]|r Timer failed: " .. tostring(result))
    return false, tostring(result)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ADD POPUP — the "+" tile's window (Arc 2.0 navy skin). One place to add
-- every icon kind: Item / Trinkets / Spell Cooldown / Aura Icon / Timer,
-- plus a smart drop zone (dragged castable spell -> cooldown icon; dragged
-- passive/buff -> aura icon; dragged item -> item icon).
-- ═══════════════════════════════════════════════════════════════════════════

local addPopup
-- ARC 2.0 SKIN FLAG: false = classic ArcUI dialog look (current). The navy
-- branch below is the approved Arc 2.0 style (matches ArcPingFeed) — flip
-- this when the makeover ships; the layout is identical in both skins.
local ARC2_SKIN = false
local ADD_COL = {
    bg    = { 0.043, 0.059, 0.102 },
    panel = { 0.063, 0.094, 0.153 },
    well  = { 0.039, 0.067, 0.125 },
    line  = { 0.114, 0.165, 0.247 },
    ink   = { 0.950, 0.970, 1.000 },
    dim   = { 0.700, 0.780, 0.880 },
    arc   = { 0.247, 0.788, 0.949 },
}
local WHITE8 = "Interface\\Buttons\\WHITE8X8"

local function PopupSkin(f, bg, border)
    f:SetBackdrop({ bgFile = WHITE8, edgeFile = WHITE8, edgeSize = 1 })
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    local b = border or ADD_COL.line
    f:SetBackdropBorderColor(b[1], b[2], b[3], 1)
end

local function SkinWindow(f)
    if ARC2_SKIN then
        PopupSkin(f, ADD_COL.bg, ADD_COL.line)
    else
        -- SOLID background: the stock UI-DialogBox-Background texture is
        -- inherently translucent — a plain fill keeps the popup fully opaque
        f:SetBackdrop({
            bgFile = WHITE8,
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
        f:SetBackdropColor(0.05, 0.05, 0.07, 1)
    end
end

local function SkinWell(f)
    if ARC2_SKIN then
        PopupSkin(f, ADD_COL.panel)
    else
        f:SetBackdrop({
            bgFile = WHITE8,
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0.10, 0.10, 0.13, 1)
        f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
end

local function PopupText(parent, text, font, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetText(text)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

local function PopupEdit(parent, w)
    local e
    if ARC2_SKIN then
        e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        e:SetFontObject(GameFontHighlightSmall)
        e:SetTextInsets(6, 6, 0, 0)
        PopupSkin(e, ADD_COL.well)
        e:SetScript("OnEditFocusGained", function(s) s:SetBackdropBorderColor(ADD_COL.arc[1], ADD_COL.arc[2], ADD_COL.arc[3], 1) end)
        e:SetScript("OnEditFocusLost", function(s) s:SetBackdropBorderColor(ADD_COL.line[1], ADD_COL.line[2], ADD_COL.line[3], 1) end)
    else
        e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    end
    e:SetAutoFocus(false)
    e:SetSize(w, 22)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

-- Button with a SetLabelSelected(sel) method for tab/radio highlighting in
-- either skin. Width auto-fits the label when w is nil.
-- GameTooltip lives at TOOLTIP strata — the SAME strata as the Add popup — so
-- a plain SetOwner renders the tooltip BEHIND the window. Lift it above the
-- popup's frame level for the hover.
local function PopupTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if addPopup then
        GameTooltip:SetFrameStrata("TOOLTIP")
        GameTooltip:SetFrameLevel((addPopup:GetFrameLevel() or 0) + 30)
    end
    return GameTooltip
end

local function PopupBtn(parent, text, w, h)
    local b
    if ARC2_SKIN then
        b = CreateFrame("Button", nil, parent, "BackdropTemplate")
        PopupSkin(b, ADD_COL.panel)
        b.txt = PopupText(b, text)
        b.txt:SetPoint("CENTER", 0, 0)
        b:SetScript("OnEnter", function(s)
            s:SetBackdropBorderColor(ADD_COL.arc[1], ADD_COL.arc[2], ADD_COL.arc[3], 1)
        end)
        b:SetScript("OnLeave", function(s)
            if not s.selected then
                s:SetBackdropBorderColor(ADD_COL.line[1], ADD_COL.line[2], ADD_COL.line[3], 1)
            end
        end)
        b.SetLabelSelected = function(s, sel)
            s.selected = sel
            if sel then
                s:SetBackdropColor(ADD_COL.panel[1] * 1.6, ADD_COL.panel[2] * 1.6, ADD_COL.panel[3] * 1.6, 1)
                s:SetBackdropBorderColor(ADD_COL.arc[1], ADD_COL.arc[2], ADD_COL.arc[3], 1)
                s.txt:SetTextColor(ADD_COL.arc[1], ADD_COL.arc[2], ADD_COL.arc[3])
            else
                s:SetBackdropColor(ADD_COL.panel[1], ADD_COL.panel[2], ADD_COL.panel[3], 1)
                s:SetBackdropBorderColor(ADD_COL.line[1], ADD_COL.line[2], ADD_COL.line[3], 1)
                s.txt:SetTextColor(ADD_COL.dim[1], ADD_COL.dim[2], ADD_COL.dim[3])
            end
        end
        b:SetSize(w or (b.txt:GetStringWidth() + 22), h or 22)
    else
        b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b.baseLabel = text
        b:SetText(text)
        b.SetLabelSelected = function(s, sel)
            s.selected = sel
            s:SetText(sel and ("|cffffd700" .. s.baseLabel .. "|r") or s.baseLabel)
        end
        b:SetSize(w or (b:GetTextWidth() + 22), h or 22)
    end
    return b
end

-- center the popup over the ArcUI options window (wherever the user moved
-- it); falls back to screen center when the panel isn't open
local function AnchorAddPopup(P)
    P:ClearAllPoints()
    local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
    local host = acd and acd.OpenFrames and acd.OpenFrames["ArcUI"]
    local hf = host and host.frame
    if hf and hf:IsShown() then
        P:SetPoint("CENTER", hf, "CENTER", 0, 0)
    else
        P:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
end

local function ShowAddPopup()
    if addPopup then
        if addPopup:IsShown() then
            addPopup:Hide()
        else
            AnchorAddPopup(addPopup)
            addPopup:Show()
        end
        return
    end

    local P = CreateFrame("Frame", "ArcUIAddIconPopup", UIParent, "BackdropTemplate")
    addPopup = P
    P:SetSize(410, 340)
    P:SetFrameStrata("TOOLTIP")   -- above the options window (FULLSCREEN_DIALOG)
    P:SetMovable(true)
    P:EnableMouse(true)
    P:RegisterForDrag("LeftButton")
    P:SetScript("OnDragStart", P.StartMoving)
    P:SetScript("OnDragStop", P.StopMovingOrSizing)
    P:SetClampedToScreen(true)
    SkinWindow(P)
    AnchorAddPopup(P)

    local title
    if ARC2_SKIN then
        title = PopupText(P, "|cff3fc9f2Add|r|cff8298b4 Arc Icon|r", "GameFontNormal")
        title:SetPoint("TOPLEFT", 12, -10)
        local closeBtn = PopupBtn(P, "|cff8298b4X|r", 20, 20)
        closeBtn:SetPoint("TOPRIGHT", -8, -8)
        closeBtn:SetScript("OnClick", function() P:Hide() end)
    else
        title = PopupText(P, "Add Arc Icon", "GameFontNormal")
        title:SetPoint("TOP", 0, -14)
        local closeBtn = CreateFrame("Button", nil, P, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() P:Hide() end)
    end

    -- status line (above the drop zone)
    P.status = PopupText(P, "", "GameFontHighlightSmall")
    P.status:SetPoint("BOTTOMLEFT", 12, 84)
    P.status:SetPoint("BOTTOMRIGHT", -12, 84)
    P.status:SetJustifyH("LEFT")
    local statusToken = 0
    local function SetStatus(msg)
        P.status:SetText(msg or "")
        statusToken = statusToken + 1
        local tok = statusToken
        C_Timer.After(4, function()
            if statusToken == tok and P:IsShown() then P.status:SetText("") end
        end)
    end
    local function Report(ok, msg, addedKind)
        if ok == nil then return end
        if ok then
            SetStatus("|cff00ff00Added " .. (addedKind or "") .. ": " .. (msg or "") .. "|r")
        else
            SetStatus("|cffff4444" .. (msg or "Failed") .. "|r")
        end
    end

    -- Successful creation: close the popup and land in the Icon Catalog
    -- with the new icon selected — unmistakable "it worked" feedback.
    local function FinishAdd(arcID)
        P:Hide()
        if arcID and ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
            ns.CDMEnhanceOptions.SelectIcon(arcID, arcID:match("^arc_aura_") ~= nil)
        end
        local acd = LibStub and LibStub("AceConfigDialog-3.0", true)
        if acd and acd.SelectGroup then
            acd:SelectGroup("ArcUI", "icons", "cdmIcons")
        end
        LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
    end

    -- ── kind selector row ──
    -- drag-and-drop only applies to item/trinket/spell — the drop square
    -- (created below) hides on the other kinds
    local DROP_KINDS = { item = true, trinket = true, spell = true }
    local KINDS = {
        { key = "item",    label = "Item" },
        { key = "trinket", label = "Trinkets" },
        { key = "spell",   label = "Spell" },
        { key = "aura",    label = "Aura" },
        { key = "timer",   label = "Timer" },
        { key = "totem",   label = "Totems" },
    }
    local kindBtns, pages = {}, {}
    local currentKind
    local function SelectKind(key)
        currentKind = key
        for k, btn in pairs(kindBtns) do
            btn:SetLabelSelected(k == key)
        end
        for k, page in pairs(pages) do page:SetShown(k == key) end
        if P.UpdateDropShown then P.UpdateDropShown(DROP_KINDS[key] and true or false) end
    end

    local auraOK = ns.AuraIcons and ns.AuraIcons.IsAvailable and ns.AuraIcons.IsAvailable()
    local totemOK = ns.ArcAurasTotems and ns.ArcAurasTotems.GetNumSlots
        and ns.ArcAurasTotems.GetNumSlots() > 0
    local x = 14
    for _, kind in ipairs(KINDS) do
        local ok = true
        if kind.key == "aura" then ok = auraOK end
        if kind.key == "totem" then ok = totemOK end
        if ok then
            local b = PopupBtn(P, kind.label, nil, 22)
            b:SetPoint("TOPLEFT", x, -36)
            b:SetScript("OnClick", function() SelectKind(kind.key) end)
            kindBtns[kind.key] = b
            x = x + b:GetWidth() + 4
        end
    end

    -- ── content well ──
    local well = CreateFrame("Frame", nil, P, "BackdropTemplate")
    well:SetPoint("TOPLEFT", 14, -64)
    well:SetPoint("TOPRIGHT", -14, -64)
    well:SetHeight(126)
    SkinWell(well)

    local function NewPage(key)
        local pg = CreateFrame("Frame", nil, well)
        pg:SetAllPoints(well)
        pg:Hide()
        pages[key] = pg
        return pg
    end

    -- ITEM page
    do
        local pg = NewPage("item")
        local lbl = PopupText(pg, "Item ID:")
        lbl:SetPoint("TOPLEFT", 10, -14)
        local edit = PopupEdit(pg, 110)
        edit:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        edit:SetNumeric(true)
        local go = PopupBtn(pg, "Add", 60)
        go:SetPoint("LEFT", edit, "RIGHT", 8, 0)
        local function doAdd()
            local ok, msg, newID = SubmitAddItem(edit:GetText() or "")
            edit:SetText("")
            edit:ClearFocus()
            if ok then FinishAdd(newID) else Report(ok, msg, "item") end
        end
        edit:SetScript("OnEnterPressed", doAdd)
        go:SetScript("OnClick", doAdd)
        local hint = PopupText(pg, "|cff8298b4Track an item's cooldown/usability by its Item ID (e.g. 212456).|r")
        hint:SetPoint("TOPLEFT", 10, -48)
        hint:SetPoint("RIGHT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
    end

    -- TRINKETS page
    do
        local pg = NewPage("trinket")
        local hint = PopupText(pg, "|cff8298b4Adds your currently equipped on-use trinkets as tracked icons. They keep tracking the specific item even after you swap trinkets.|r")
        hint:SetPoint("TOPLEFT", 10, -12)
        hint:SetPoint("RIGHT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        local go = PopupBtn(pg, "Add Equipped On-Use Trinkets", 210, 24)
        go:SetPoint("TOPLEFT", 10, -62)
        go:SetScript("OnClick", function()
            if not (ArcAuras and ArcAuras.AutoAddTrinkets) then return end
            local added = ArcAuras.AutoAddTrinkets(true)
            print("|cff00CCFF[Arc Auras]|r Added " .. added .. " on-use trinket(s)")
            NotifyCatalogChanged()
            if added > 0 then
                FinishAdd(nil)   -- multiple icons: close + show the catalog
            else
                SetStatus("|cffff4444No new on-use trinkets found|r")
            end
        end)
    end

    -- SPELL page
    do
        local pg = NewPage("spell")
        local lbl = PopupText(pg, "Spell ID:")
        lbl:SetPoint("TOPLEFT", 10, -14)
        local edit = PopupEdit(pg, 110)
        edit:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        edit:SetNumeric(true)
        local go = PopupBtn(pg, "Add", 60)
        go:SetPoint("LEFT", edit, "RIGHT", 8, 0)
        local function doAdd()
            local ok, msg, newID = SubmitAddSpell(edit:GetText() or "")
            edit:SetText("")
            edit:ClearFocus()
            if ok then FinishAdd(newID) else Report(ok, msg, "spell") end
        end
        edit:SetScript("OnEnterPressed", doAdd)
        go:SetScript("OnClick", doAdd)
        local hint = PopupText(pg, "|cff8298b4Castable ability cooldowns only. For buffs and debuffs use the Aura kind" .. (auraOK and "" or " (needs patch 12.1)") .. ".|r")
        hint:SetPoint("TOPLEFT", 10, -48)
        hint:SetPoint("RIGHT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
    end

    -- AURA page (12.1)
    if auraOK then
        local pg = NewPage("aura")
        local modeBtns = {}
        local function SelectMode(m)
            pendingAuraMode = m
            for key, btn in pairs(modeBtns) do
                btn:SetLabelSelected(key == m)
            end
            if pg.ownCheck then pg.ownCheck:SetShown(m ~= "buff") end
            if pg.ownLbl then pg.ownLbl:SetShown(m ~= "buff") end
        end
        local mx = 10
        for _, m in ipairs({ { "buff", "Buff (you)" }, { "debuff", "Debuff (target)" }, { "both", "Both" } }) do
            local b = PopupBtn(pg, m[2], nil, 22)
            b:SetPoint("TOPLEFT", mx, -10)
            b:SetScript("OnClick", function() SelectMode(m[1]) end)
            modeBtns[m[1]] = b
            mx = mx + b:GetWidth() + 6
        end
        pg.ownCheck = CreateFrame("CheckButton", nil, pg, "UICheckButtonTemplate")
        pg.ownCheck:SetSize(24, 24)
        pg.ownCheck:SetPoint("TOPLEFT", 6, -36)
        pg.ownCheck:SetScript("OnClick", function(s) pendingAuraOwnOnly = s:GetChecked() and true or false end)
        pg.ownLbl = PopupText(pg, "Own debuffs only (ignore other players' copies)")
        pg.ownLbl:SetPoint("LEFT", pg.ownCheck, "RIGHT", 2, 0)
        local lbl = PopupText(pg, "Spell ID:")
        lbl:SetPoint("TOPLEFT", 10, -70)
        local edit = PopupEdit(pg, 100)
        edit:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        edit:SetNumeric(true)
        local go = PopupBtn(pg, "Add", 50)
        go:SetPoint("LEFT", edit, "RIGHT", 6, 0)
        local function doAdd()
            local ok, msg, newID = SubmitAddAura(edit:GetText() or "")
            edit:SetText("")
            edit:ClearFocus()
            if ok then FinishAdd(newID) else Report(ok, msg, "aura icon") end
        end
        edit:SetScript("OnEnterPressed", doAdd)
        go:SetScript("OnClick", doAdd)
        local imp = PopupBtn(pg, "Import CDM Tracked Buffs", 170, 22)
        imp:SetPoint("TOPLEFT", 10, -94)
        imp:SetScript("OnClick", function()
            local added = ns.AuraIcons.ImportFromCDM and ns.AuraIcons.ImportFromCDM()
            SetStatus((added and added > 0)
                and ("|cff00ff00Imported " .. added .. " aura icon(s) from CDM|r")
                or "|cff8298b4Nothing new to import|r")
            NotifyCatalogChanged()
        end)

        -- QUICK-ADD PRESETS: icon buttons (installed ones desaturated), same
        -- shape as the timer page's preset row
        local presetLbl = PopupText(pg, "Quick add:")
        presetLbl:SetPoint("TOPLEFT", 192, -100)
        pg.presetBtns = {}
        local function RefreshAuraPresets()
            for i, preset in ipairs(AURA_PRESETS) do
                local pb = pg.presetBtns[i]
                if not pb then
                    pb = CreateFrame("Button", nil, pg)
                    pb:SetSize(24, 24)
                    pb.icon = pb:CreateTexture(nil, "ARTWORK")
                    pb.icon:SetAllPoints()
                    pb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    pb:SetPoint("TOPLEFT", 254 + (i - 1) * 28, -94)
                    pg.presetBtns[i] = pb
                end
                local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(preset.spellID)
                pb.icon:SetTexture(info and (info.iconID or info.originalIconID) or 134400)
                local installed = IsAuraPresetInstalled(preset)
                pb.icon:SetDesaturated(installed and true or false)
                pb.icon:SetAlpha(installed and 0.4 or 1)
                pb:SetScript("OnEnter", function(s)
                    PopupTooltip(s)
                    GameTooltip:SetText(preset.name or "?")
                    if preset.desc then
                        GameTooltip:AddLine(preset.desc, 0.65, 0.65, 0.65, true)
                    end
                    GameTooltip:AddLine(installed and "Already tracked" or "Click to add",
                        0.6, 0.6, 0.6)
                    GameTooltip:Show()
                end)
                pb:SetScript("OnLeave", function() GameTooltip:Hide() end)
                pb:SetScript("OnClick", function()
                    local ok, msg, newID = AddAuraPreset(preset)
                    if ok then
                        FinishAdd(newID)
                    else
                        SetStatus("|cff888888" .. tostring(msg) .. "|r")
                        RefreshAuraPresets()
                    end
                end)
                pb:Show()
            end
        end

        SelectMode(pendingAuraMode)
        pg:SetScript("OnShow", function()
            SelectMode(pendingAuraMode)
            RefreshAuraPresets()
        end)
    end

    -- TIMER page
    do
        local pg = NewPage("timer")
        local lbl = PopupText(pg, "Spell ID:")
        lbl:SetPoint("TOPLEFT", 10, -14)
        local idEdit = PopupEdit(pg, 90)
        idEdit:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        idEdit:SetNumeric(true)
        local durLbl = PopupText(pg, "Duration (s):")
        durLbl:SetPoint("LEFT", idEdit, "RIGHT", 10, 0)
        local durEdit = PopupEdit(pg, 60)
        durEdit:SetPoint("LEFT", durLbl, "RIGHT", 8, 0)
        local go = PopupBtn(pg, "Add Timer", 80)
        go:SetPoint("TOPLEFT", 10, -44)
        local function doAdd()
            local ok, msg, newID = SubmitAddTimer(idEdit:GetText(), durEdit:GetText())
            idEdit:ClearFocus()
            durEdit:ClearFocus()
            if ok then
                idEdit:SetText("")
                durEdit:SetText("")
                FinishAdd(newID)
            else
                Report(ok, msg, "timer")
            end
        end
        idEdit:SetScript("OnEnterPressed", doAdd)
        durEdit:SetScript("OnEnterPressed", doAdd)
        go:SetScript("OnClick", doAdd)

        -- PRESET ROW: one icon button per class-relevant preset (installed
        -- ones desaturated); click installs. Mirrors the Custom Icons tab's
        -- preset library through the same APIs.
        local presetLbl = PopupText(pg, "Presets:")
        presetLbl:SetPoint("TOPLEFT", 10, -78)
        pg.presetBtns = {}
        local function RefreshPresets()
            local presets = (ns.GetCustomIconPresetsForPlayer
                and ns.GetCustomIconPresetsForPlayer()) or {}
            for _, pb in ipairs(pg.presetBtns) do pb:Hide() end
            for i, preset in ipairs(presets) do
                if i > 9 then break end
                local pb = pg.presetBtns[i]
                if not pb then
                    pb = CreateFrame("Button", nil, pg)
                    pb:SetSize(24, 24)
                    pb.icon = pb:CreateTexture(nil, "ARTWORK")
                    pb.icon:SetAllPoints()
                    pb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    pg.presetBtns[i] = pb
                end
                pb:ClearAllPoints()
                pb:SetPoint("TOPLEFT", 62 + (i - 1) * 28, -74)
                local info = preset.spellID and C_Spell.GetSpellInfo(preset.spellID)
                pb.icon:SetTexture(info and (info.iconID or info.originalIconID) or 134400)
                local installed = ns.IsPresetInstalled and ns.IsPresetInstalled(preset)
                pb.icon:SetDesaturated(installed and true or false)
                pb.icon:SetAlpha(installed and 0.4 or 1)
                pb:SetScript("OnEnter", function(s)
                    PopupTooltip(s)
                    GameTooltip:SetText(preset.name or "?")
                    GameTooltip:AddLine(installed and "Already installed" or "Click to install",
                        0.6, 0.6, 0.6)
                    GameTooltip:Show()
                end)
                pb:SetScript("OnLeave", function() GameTooltip:Hide() end)
                pb:SetScript("OnClick", function()
                    if ns.IsPresetInstalled and ns.IsPresetInstalled(preset) then
                        SetStatus("|cff888888Preset already installed|r")
                        return
                    end
                    if not ns.AddTimerFromPreset then return end
                    local okP, result = ns.AddTimerFromPreset(preset)
                    if okP then
                        print("|cff00CCFF[Arc Auras]|r Installed preset: " .. (preset.name or "?"))
                        NotifyCatalogChanged()
                        FinishAdd(type(result) == "string" and result or nil)
                    else
                        SetStatus("|cffff4444Preset failed: " .. tostring(result) .. "|r")
                    end
                end)
                pb:Show()
            end
            presetLbl:SetShown(#presets > 0)
        end
        pg:SetScript("OnShow", RefreshPresets)

        local hint = PopupText(pg, "|cff888888Starts on cast; fine-tune triggers, stacks and end events in the Custom Icons tab.|r")
        hint:SetPoint("TOPLEFT", 10, -104)
        hint:SetPoint("RIGHT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
    end

    -- TOTEMS page (only for classes with totem slots): master toggle,
    -- per-slot toggles, and the group-placement choice (only offered while
    -- the "Totems" group doesn't exist yet — once it does, placement is
    -- whatever the user arranged)
    if totemOK then
        local pg = NewPage("totem")
        local Totems = ns.ArcAurasTotems

        local master = CreateFrame("CheckButton", nil, pg, "UICheckButtonTemplate")
        master:SetSize(26, 26)
        master:SetPoint("TOPLEFT", 6, -6)
        local masterLbl = PopupText(pg, "Track totem slots")
        masterLbl:SetPoint("LEFT", master, "RIGHT", 2, 0)

        local groupCheck = CreateFrame("CheckButton", nil, pg, "UICheckButtonTemplate")
        groupCheck:SetSize(26, 26)
        groupCheck:SetPoint("TOPLEFT", 6, -32)
        local groupLbl = PopupText(pg, "Place in a centered \"Totems\" group (uncheck = free icons)")
        groupLbl:SetPoint("LEFT", groupCheck, "RIGHT", 2, 0)
        groupCheck:SetScript("OnClick", function(s)
            Totems.SetUseGroup(s:GetChecked() and true or false)
        end)

        local slotsLbl = PopupText(pg, "Slots:")
        slotsLbl:SetPoint("TOPLEFT", 12, -66)
        local slotChecks = {}
        for slot = 1, 8 do
            local sc = CreateFrame("CheckButton", nil, pg, "UICheckButtonTemplate")
            sc:SetSize(22, 22)
            sc:SetPoint("TOPLEFT", 40 + (slot - 1) * 40, -62)
            local scl = PopupText(sc, tostring(slot))
            scl:SetPoint("LEFT", sc, "RIGHT", 0, 0)
            sc:SetScript("OnClick", function(s)
                Totems.SetSlotEnabled(slot, s:GetChecked() and true or false)
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end)
            slotChecks[slot] = sc
        end

        local hint = PopupText(pg, "|cff888888Each slot's icon lights with whatever totem is in it — works fully in combat.|r")
        hint:SetPoint("TOPLEFT", 10, -94)
        hint:SetPoint("RIGHT", -10, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)

        local function RefreshTotemPage()
            local on = Totems.IsEnabled() and true or false
            master:SetChecked(on)
            -- group choice only offered before the group exists
            local groupExists = ns.CDMGroups and ns.CDMGroups.groups
                and ns.CDMGroups.groups["Totems"] ~= nil
            groupCheck:SetShown(not groupExists)
            groupLbl:SetShown(not groupExists)
            groupCheck:SetChecked(Totems.GetUseGroup() and true or false)
            local n = Totems.GetNumSlots()
            for slot = 1, 8 do
                local sc = slotChecks[slot]
                sc:SetShown(slot <= n)
                sc:SetChecked(Totems.IsSlotEnabled(slot) and true or false)
                sc:SetEnabled(on)
            end
        end
        master:SetScript("OnClick", function(s)
            local on = s:GetChecked() and true or false
            Totems.SetEnabled(on)
            SetStatus(on and "|cff00ff00Totem slot icons enabled|r"
                or "|cff888888Totem slot icons disabled|r")
            RefreshTotemPage()
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end)
        pg:SetScript("OnShow", RefreshTotemPage)
    end

    -- ── drop SQUARE (item / trinkets / spell kinds only) ──
    local drop = CreateFrame("Button", nil, P, "BackdropTemplate")
    drop:SetSize(56, 56)
    drop:SetPoint("BOTTOMLEFT", 16, 16)
    SkinWell(drop)
    drop.icon = drop:CreateTexture(nil, "ARTWORK")
    drop.icon:SetPoint("TOPLEFT", 5, -5)
    drop.icon:SetPoint("BOTTOMRIGHT", -5, 5)
    drop.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    drop.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    drop.icon:SetAlpha(0.35)
    local dropText = PopupText(P, "|cffffd700Drag an item or spell here to track it|r\n|cff888888Items and castable cooldowns only — use the Aura and Timer tabs for those kinds.|r")
    dropText:SetPoint("LEFT", drop, "RIGHT", 10, 0)
    dropText:SetPoint("RIGHT", P, "RIGHT", -16, 0)
    dropText:SetJustifyH("LEFT")
    dropText:SetWordWrap(true)
    P.UpdateDropShown = function(shown)
        drop:SetShown(shown)
        dropText:SetShown(shown)
    end
    -- (successful drops close the popup via FinishAdd — the catalog showing
    -- the new icon IS the feedback; no in-square icon flash needed)
    local function HandlePopupDrop()
        local infoType, dropA, _, dropSpellID = GetCursorInfo()
        if infoType == "item" then
            ClearCursor()
            local itemID = dropA
            local ok, msg, newID = SubmitAddItem(tostring(itemID))
            if ok then
                FinishAdd(newID)
            else
                Report(ok, msg, "item")
            end
        elseif infoType == "spell" then
            local spellID = dropSpellID or dropA
            ClearCursor()
            local passive = C_Spell.IsSpellPassive and C_Spell.IsSpellPassive(spellID)
            if passive then
                -- dragging covers items/cooldowns only — point at the Aura tab
                SetStatus(auraOK
                    and "|cffff4444That's a passive/buff — add it from the Aura tab instead.|r"
                    or "|cffff4444Passive spell — cooldown tracking is for castable abilities.|r")
            else
                local ok, msg, newID = SubmitAddSpell(tostring(spellID))
                if ok then
                    FinishAdd(newID)
                else
                    Report(ok, msg, "spell")
                end
            end
        end
    end
    drop:SetScript("OnReceiveDrag", HandlePopupDrop)
    drop:SetScript("OnMouseUp", HandlePopupDrop)

    SelectKind("item")
    P.SelectKind = SelectKind   -- guided tour opens the popup on a given kind
    P:Show()
end

-- Exposed so other panels (the CDM Icon Catalog's "+" tile) share the SAME
-- Add window instead of growing their own.
Options.ShowAddPopup = ShowAddPopup

-- Guided tour: open the Add window on a specific kind ("aura", "timer", ...)
-- so a step shows the section it is describing. ShowAddPopup TOGGLES, so this
-- only opens when it is closed, and re-selecting is safe either way.
Options.TourOpenAddPopup = function(kind)
    if not (addPopup and addPopup:IsShown()) then ShowAddPopup() end
    if kind and addPopup and addPopup.SelectKind then addPopup.SelectKind(kind) end
    return true
end

-- Guided tour: select the first icon in the catalog so the per-icon options
-- are on screen for the step that describes them.
Options.TourSelectAnyIcon = function()
    if not (ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon) then return false end
    local db = ns.ArcAuras and ns.ArcAuras.GetDB and ns.ArcAuras.GetDB()
    local pick, isAura
    for _, store in ipairs({ "auraIcons", "spells", "items" }) do
        local t = db and db[store]
        if type(t) == "table" then
            for arcID in pairs(t) do
                if type(arcID) == "string" and (not pick or arcID < pick) then
                    pick, isAura = arcID, store == "auraIcons"
                end
            end
        end
        if pick then break end
    end
    if not pick then return false end
    ns.CDMEnhanceOptions.SelectIcon(pick, isAura)
    return true
end

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
    
    -- ── Custom Timers ──
    if db.customTimers then
        local GetSpellNameAndIcon = ns.ArcAurasCooldown and ns.ArcAurasCooldown.GetSpellNameAndIcon
        for arcID, config in pairs(db.customTimers) do
            local spellID = config.spellID
            local name, icon = nil, nil
            if GetSpellNameAndIcon and spellID then
                name, icon = GetSpellNameAndIcon(spellID)
            end
            name = name or ("Spell " .. (spellID or "?"))
            icon = config.icon or icon or 134400
            table.insert(items, {
                arcID = arcID,
                arcType = "timer",
                spellID = spellID,
                name = name,
                icon = icon,
                config = config,
                enabled = true,
                inCurrentSpec = true,   -- timers don't do spec gating
                duration = config.duration,
                resetOnRecast = config.resetOnRecast ~= false,
                resetOnDeath = config.resetOnDeath == true,
                hasIconOverride = config.icon ~= nil,
            })
        end
    end

    -- ── Aura Icons (12.1) ──
    if db.auraIcons then
        local currentSpec = GetSpecialization() or 1
        for arcID, config in pairs(db.auraIcons) do
            local name = config.name or ("Aura " .. (config.spellID or "?"))
            local icon = config.iconOverride or config.icon or 134400

            local inSpec = true
            local specFiltered = false
            if config.showOnSpecs and #config.showOnSpecs > 0 then
                local specAllowed = false
                for _, spec in ipairs(config.showOnSpecs) do
                    if spec == currentSpec then specAllowed = true break end
                end
                if not specAllowed then
                    specFiltered = true
                    inSpec = false
                end
            end
            local talentFiltered = false
            if inSpec and config.talentConditions and #config.talentConditions > 0 then
                if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
                    if not ns.TalentPicker.CheckTalentConditions(
                        config.talentConditions, config.talentConditionMode or "all") then
                        talentFiltered = true
                        inSpec = false
                    end
                end
            end

            table.insert(items, {
                arcID = arcID,
                arcType = "aura",
                spellID = config.spellID,
                name = name,
                icon = icon,
                config = config,
                enabled = true,          -- remove to untrack, like spells
                inCurrentSpec = inSpec,
                specFiltered = specFiltered,
                talentFiltered = talentFiltered,
                hasSpecFilter = config.showOnSpecs and #config.showOnSpecs > 0,
                hasTalentFilter = config.talentConditions and #config.talentConditions > 0,
                hasIconOverride = config.iconOverride ~= nil,
                unitMode = config.unitMode,
            })
        end
    end

    -- Sort: trinkets first, then items, then spells, then auras, then timers
    local typeOrder = { trinket = 1, item = 2, spell = 3, aura = 3.5, timer = 4 }
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
            elseif entry.arcType == "aura" then
                if entry.talentFiltered or entry.specFiltered then
                    status = "|cffff8800Au|r "  -- Orange Au = aura, filtered out
                else
                    status = "|cffff88ffAu|r "  -- Pink Au = aura icon (12.1)
                end
            elseif entry.arcType == "timer" then
                status = "|cffffcc00T|r "   -- Gold T = custom timer
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
            elseif entry.arcType == "aura" then
                desc = desc .. "\nSpell ID: " .. (entry.spellID or "?")
                desc = desc .. "\nArc ID: " .. entry.arcID
                local mode = entry.unitMode == "debuff" and "Debuff (target)"
                    or entry.unitMode == "both" and "Buff + Debuff" or "Buff (you)"
                desc = desc .. "\nType: |cffff88ffAura Icon|r — " .. mode
                if entry.hasIconOverride then
                    desc = desc .. "\n|cffFFCC00Custom Icon|r (ID: " .. (entry.config.iconOverrideID or "?") .. ")"
                end
                if entry.specFiltered then
                    desc = desc .. "\n|cffff8800Hidden on this spec (user filter)|r"
                end
                if entry.talentFiltered then
                    desc = desc .. "\n|cffff8800Hidden (talent condition not met)|r"
                end
            elseif entry.arcType == "timer" then
                desc = desc .. "\nSpell ID: " .. (entry.spellID or "?")
                desc = desc .. "\nArc ID: " .. entry.arcID
                desc = desc .. "\nType: |cffffcc00Custom Timer|r"
                desc = desc .. "\nDuration: " .. tostring(entry.duration or "?") .. "s"
                desc = desc .. "\nReset on Recast: " .. (entry.resetOnRecast and "|cff00ff00Yes|r" or "|cffff8800No|r")
                desc = desc .. "\nReset on Death: " .. (entry.resetOnDeath and "|cff00ff00Yes|r" or "|cffff8800No|r")
                if entry.hasIconOverride then
                    desc = desc .. "\n|cffFFCC00Custom Icon|r (ID: " .. tostring(entry.config.iconID or entry.config.icon or "?") .. ")"
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
    -- Helper: returns true when Arc Auras is disabled (grays out controls)
    local function IsArcDisabled()
        return not (ArcAuras and ArcAuras.IsEnabled and ArcAuras.IsEnabled())
    end
    
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
                -- aura icons (12.1) follow the master toggle too
                if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
                    ns.AuraIcons.RefreshVisibility()
                end
            end,
        },
        disabledNotice = {
            type = "description",
            name = "\n|cffFF4444Arc Auras is currently disabled.|r  Toggle the checkbox above to enable tracking.\n",
            order = 2.5,
            fontSize = "medium",
            hidden = function() return not IsArcDisabled() end,
        },
        refreshBtn = {
            type = "execute",
            name = "Refresh",
            desc = "Show all frames at their saved positions (fixes missing icons after spec change)",
            order = 3,
            width = 0.6,
            disabled = IsArcDisabled,
            func = function()
                if ArcAuras and ArcAuras.ForceShowAllFrames then
                    local count = ArcAuras.ForceShowAllFrames()
                    print("|cff00CCFF[Arc Auras]|r Showed " .. (count or 0) .. " frames")
                end
            end,
        },
        
        -- ═══════════════════════════════════════════════════════════════
        -- (Legacy "Add Items & Spell Cooldowns" / "Add Aura Icons" input
        -- blocks RETIRED 2026-08-09 — adding now lives in the "+" tile's
        -- Add Arc Icon popup at the end of the tracked catalog. The shared
        -- SubmitAdd* helpers carry the logic. Totem Slots keeps its own
        -- section above the catalog.)
        -- ═══════════════════════════════════════════════════════════════

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
                local legendStr = "|cff888888Legend: |cff88ff88A|r=Auto-Track  |cff88aaeeH|r=Hide Unequipped  |cff88ccffS|r=Spell  |cffff88ffAu|r=Aura  |cff00ff00F|r=Always Show  |cffaa55ff*|r=Custom Settings|r"
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
    -- "+" ADD TILE — rendered after the last tracked icon; opens the
    -- Add Arc Icon popup (one entry point for every icon kind; replaces
    -- the legacy add-input blocks once approved)
    -- ═══════════════════════════════════════════════════════════════
    args.catalogAddTile = {
        type = "execute",
        name = "|cff3fc9f2Add|r",
        desc = "|cffffd700Add a new Arc icon|r\nItem, trinkets, spell cooldown, aura icon, or custom timer — plus a drag-and-drop zone.\n\nClick to open the Add window.",
        image = "Interface\\AddOns\\ArcUI\\Textures\\add_tile.tga",
        imageWidth = 32,
        imageHeight = 32,
        order = 91,
        width = 0.25,
        disabled = IsArcDisabled,
        hidden = function() return collapsedSections.trackedItems end,
        func = function() ShowAddPopup() end,
    }
    
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
                elseif item.arcType == "aura" then
                    local mode = item.unitMode == "debuff" and "Debuff"
                        or item.unitMode == "both" and "Buff+Debuff" or "Buff"
                    typeTag = " |cffff88ff(Aura: " .. mode .. ")|r"
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
            
            local removedItems, removedSpells, removedTimers = 0, 0, 0
            for _, arcID in ipairs(toRemove) do
                if arcID:match("^arc_spell_") then
                    if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RemoveTrackedSpell then
                        ns.ArcAurasCooldown.RemoveTrackedSpell(arcID)
                        removedSpells = removedSpells + 1
                    end
                elseif arcID:match("^arc_aura_") then
                    if ns.AuraIcons and ns.AuraIcons.Delete then
                        ns.AuraIcons.Delete(arcID)
                        removedSpells = removedSpells + 1
                    end
                elseif arcID:match("^arc_timer_") then
                    if ns.ArcAurasTimer and ns.ArcAurasTimer.RemoveTimer then
                        ns.ArcAurasTimer.RemoveTimer(arcID)
                        removedTimers = removedTimers + 1
                    end
                else
                    ArcAuras.RemoveTrackedItem(arcID)
                    removedItems = removedItems + 1
                end
            end
            
            selectedArcAura = nil
            wipe(selectedArcAuras)
            Options.InvalidateCache()
            
            local parts = {}
            if removedItems  > 0 then table.insert(parts, removedItems  .. " item(s)")  end
            if removedSpells > 0 then table.insert(parts, removedSpells .. " spell(s)") end
            if removedTimers > 0 then table.insert(parts, removedTimers .. " timer(s)") end
            print("|cff00CCFF[Arc Auras]|r Removed " .. (table.concat(parts, " + ")))
            
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
                -- aura icons live on the AURAS side of the Icon Catalog —
                -- selecting them as cooldowns targeted the wrong catalog
                local item = GetSelectedItem()
                ns.CDMEnhanceOptions.SelectIcon(selectedArcAura, item and item.arcType == "aura" or false)
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

    -- Helper: manual item selected (arc_item_*, NOT trinket slots)
    local function IsManualItemSelected()
        local item = GetSelectedItem()
        return item and item.arcType == "item"
    end

    local function GetItemConfig()
        if not selectedArcAura then return nil end
        local db = ns.db and ns.db.char and ns.db.char.arcAuras
        return db and db.trackedItems and db.trackedItems[selectedArcAura]
    end

    -- Aura icons (12.1) share the spec/talent condition options too
    local function IsAuraSelected()
        local item = GetSelectedItem()
        return item and item.arcType == "aura"
    end

    local function GetAuraConfig()
        if not selectedArcAura then return nil end
        local db = ns.db and ns.db.char and ns.db.char.arcAuras
        return db and db.auraIcons and db.auraIcons[selectedArcAura]
    end

    -- Shared helpers: spec/talent options apply to spells, manual items, and auras
    local function IsSpellOrItemSelected()
        return IsSpellSelected() or IsManualItemSelected() or IsAuraSelected()
    end

    local function GetSpellOrItemConfig()
        if IsSpellSelected() then return GetSpellConfig() end
        if IsManualItemSelected() then return GetItemConfig() end
        if IsAuraSelected() then return GetAuraConfig() end
        return nil
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
            if item.arcType == "timer" then
                if item.hasIconOverride then
                    local overrideID = item.config and (item.config.iconID or "?")
                    return "|cffFFCC00Current: Custom Icon|r (IconID: " .. tostring(overrideID) .. ")\n|cff888888Enter a new IconID below, or 0 to reset to the tracked spell's icon.|r"
                end
                return "|cff888888Enter an IconID (FileDataID) to use that texture. This is the number shown as 'IconID' in spell tooltips.  Enter 0 or leave blank to reset.|r"
            end
            if item.hasIconOverride then
                local overrideID = item.config and (item.config.iconOverrideID or item.config.iconID or "?") or "?"
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
        name = function()
            local item = GetSelectedItem()
            if item and item.arcType == "timer" then return "Icon ID" end
            return "Icon Source ID"
        end,
        desc = function()
            local item = GetSelectedItem()
            if item and item.arcType == "timer" then
                return "Enter an IconID (FileDataID) — the number shown as 'IconID' in the spell tooltip.  0 resets to the tracked spell's icon."
            end
            return "Enter a Spell ID or Item ID to use its icon.\nEnter 0 to reset to the default icon."
        end,
        order = 109,
        width = 0.8,
        get = function()
            local item = GetSelectedItem()
            if item and item.config then
                -- Spells/items use iconOverrideID, timers use iconID
                if item.config.iconOverrideID then return tostring(item.config.iconOverrideID) end
                if item.arcType == "timer" and item.config.iconID then return tostring(item.config.iconID) end
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
            elseif item.arcType == "aura" then
                if ns.AuraIcons and ns.AuraIcons.ApplyIconOverride then
                    ns.AuraIcons.ApplyIconOverride(selectedArcAura, overrideID)
                end
            elseif item.arcType == "timer" then
                -- Timer icon override — resolve source ID to an icon texture
                -- (accepts either a spellID or itemID). Store numeric iconID
                -- into db.customTimers[arcID].icon + .iconID for the picker
                -- to round-trip. ApplyIconOverride lives on ArcAurasTimer.
                if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
                    ns.ArcAurasTimer.ApplyIconOverride(selectedArcAura, overrideID)
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
            elseif item.arcType == "aura" then
                if ns.AuraIcons and ns.AuraIcons.ApplyIconOverride then
                    ns.AuraIcons.ApplyIconOverride(selectedArcAura, nil)
                end
            elseif item.arcType == "timer" then
                if ns.ArcAurasTimer and ns.ArcAurasTimer.ApplyIconOverride then
                    ns.ArcAurasTimer.ApplyIconOverride(selectedArcAura, nil)
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
    -- CUSTOM TIMER SETTINGS (only visible for timer-type entries)
    -- ═══════════════════════════════════════════════════════════════
    local function IsTimerSelected()
        if collapsedSections.trackedItems or HideIfNoSelection() or GetSelectedCount() > 1 then
            return false
        end
        local item = GetSelectedItem()
        return item and item.arcType == "timer"
    end
    local function TimerHidden() return not IsTimerSelected() end

    -- ──────────────────────────────────────────────────────────────────────
    -- CUSTOM TIMER SETTINGS — REDIRECT TO CUSTOM ICONS TAB
    --
    -- All per-timer editor controls (trigger / duration / stacks / reset /
    -- start & end conditions / actions / icon override) live in the
    -- Custom Icons tab's editor pane. That pane reads the same selection
    -- state we expose via Options.GetSelectedArcAura(), so whichever
    -- timer the user has highlighted on this Main tab is automatically
    -- the active editor target on the Custom Icons tab.
    --
    -- This panel previously duplicated the trigger/duration/reset/test
    -- controls inline. The duplication drifted from the canonical Custom
    -- Icons editor (it lacked stacks, end-conditions, actions, etc.) and
    -- was a maintenance hazard. Now it just points the user at the
    -- canonical place.
    -- ──────────────────────────────────────────────────────────────────────
    args.timerSettingsHeader = {
        type = "description",
        name = "\n|cffffd700====================================|r\n"
            .. "|cffffd700  Custom Timer Settings|r\n"
            .. "|cffffd700====================================|r\n"
            .. "|cff888888All custom-timer options live on the |cffffd700Custom Icons|r tab, "
            .. "|cff888888which already has the timer you selected here highlighted.|r\n",
        order = 109.80,
        width = "full",
        fontSize = "medium",
        hidden = TimerHidden,
    }
    args.timerOpenCustomIcons = {
        type = "execute",
        name = "Open Custom Icons Editor",
        desc = "Switches to the Custom Icons tab. Your selected timer carries over automatically - its editor pane will be the active target.",
        order = 109.81,
        width = "full",
        hidden = TimerHidden,
        func = function()
            -- AceConfigDialog navigation. The path is the chain of group
            -- keys from the registered app root down to the destination
            -- tab. ArcUI's master tree mounts Arc Auras under the
            -- "icons" top-level group (see ArcUI_Options.lua line 346
            -- and 417), so the full path is:
            --     ArcUI / icons / arcAuras / customIcons
            -- That's four args to SelectGroup. Calling it with only
            -- three (skipping "icons") was the bug — SelectGroup looked
            -- for "arcAuras" at the top level of ArcUI and never found
            -- it, so the call silently no-op'd.
            --
            -- Two prerequisites for SelectGroup to actually navigate:
            --   1. NotifyChange first so AceConfig rebuilds internal
            --      tree state. Otherwise SelectGroup may target stale
            --      nodes.
            --   2. Defer SelectGroup by one tick so it runs AFTER
            --      AceConfig finishes its post-execute-callback re-
            --      render. Calling synchronously inside func would let
            --      that re-render overwrite the navigation.
            local ACR = LibStub and LibStub("AceConfigRegistry-3.0", true)
            if ACR and ACR.NotifyChange then
                ACR:NotifyChange("ArcUI")
            end
            C_Timer.After(0, function()
                local ACD = LibStub and LibStub("AceConfigDialog-3.0", true)
                if ACD and ACD.SelectGroup then
                    -- Custom Icons is now its own top-level tab (was nested under Arc Icons).
                    ACD:SelectGroup("ArcUI", "icons", "customIcons")
                end
            end)
        end,
    }
    args.timerFooter = {
        type = "description",
        name = "\n|cffffd700====================================|r\n",
        order = 109.90,
        width = "full",
        hidden = TimerHidden,
    }

    -- ═══════════════════════════════════════════════════════════════
    -- SHOW ON SPECS (spell and item entries)
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
        local cfg = GetSpellOrItemConfig()
        if not cfg or not cfg.showOnSpecs or #cfg.showOnSpecs == 0 then return true end
        for _, spec in ipairs(cfg.showOnSpecs) do
            if spec == specNum then return true end
        end
        return false
    end

    local function SetSpecEnabled(specNum, value)
        local cfg = GetSpellOrItemConfig()
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
        -- Apply immediately (handles spells, items, and aura icons)
        if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
            ns.ArcAurasCooldown.RefreshSpecVisibility()
        elseif ArcAuras and ArcAuras.RefreshVisibility then
            ArcAuras.RefreshVisibility()
        end
        if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
            ns.AuraIcons.RefreshVisibility()
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
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
        end,
    }
    args.showOnSpecsDesc = {
        type = "description",
        name = "|cff888888Choose which specs this frame appears on. Unchecked specs will hide the frame. All checked (or none set) = show on every spec.|r",
        order = 111,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
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
                    or GetSelectedCount() > 1 or not IsSpellOrItemSelected() then
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
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
        end,
    }
    args.talentCondDesc = {
        type = "description",
        name = "|cff888888Only show this frame when specific talents are active. If no conditions are set, the frame shows whenever it would normally be visible.|r",
        order = 121,
        width = "full",
        fontSize = "small",
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
        end,
    }
    args.talentCondSummary = {
        type = "description",
        name = function()
            local cfg = GetSpellOrItemConfig()
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
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
        end,
    }
    args.talentCondEdit = {
        type = "execute",
        name = "Edit Talent Conditions",
        desc = "Open the talent picker to choose which talents must be active (or inactive) for this frame to show.",
        order = 123,
        width = 1.0,
        func = function()
            local cfg = GetSpellOrItemConfig()
            if not cfg or not ns.TalentPicker then return end
            ns.TalentPicker.OpenPicker(cfg.talentConditions, cfg.talentConditionMode, function(conditions, matchMode)
                cfg.talentConditions = conditions
                cfg.talentConditionMode = matchMode
                if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
                    ns.ArcAurasCooldown.RefreshSpecVisibility()
                end
                if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
                    ns.AuraIcons.RefreshVisibility()
                end
                Options.InvalidateCache()
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end)
        end,
        hidden = function()
            return collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected()
        end,
    }
    args.talentCondClear = {
        type = "execute",
        name = "Clear",
        desc = "Remove all talent conditions. The frame will show whenever it would normally be visible.",
        order = 124,
        width = 0.5,
        func = function()
            local cfg = GetSpellOrItemConfig()
            if not cfg then return end
            cfg.talentConditions = nil
            cfg.talentConditionMode = nil
            if ns.ArcAurasCooldown and ns.ArcAurasCooldown.RefreshSpecVisibility then
                ns.ArcAurasCooldown.RefreshSpecVisibility()
            end
            if ns.AuraIcons and ns.AuraIcons.RefreshVisibility then
                ns.AuraIcons.RefreshVisibility()
            end
            Options.InvalidateCache()
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
        hidden = function()
            if collapsedSections.trackedItems or HideIfNoSelection()
                or GetSelectedCount() > 1 or not IsSpellOrItemSelected() then
                return true
            end
            local cfg = GetSpellOrItemConfig()
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
        order = 20,
        width = "full",
    }
    args.autoTrackSlotsDesc = {
        type = "description",
        name = "|cff888888Auto-tracked slots automatically update their icon when you swap gear.\nSlots marked |cff88ff88A|r in the catalog above are auto-tracked.|r",
        order = 20.1,
        fontSize = "small",
        hidden = function() return collapsedSections.autoTrackSlots end,
    }
    args.autoTrackMasterToggle = {
        type = "toggle",
        name = "|TInterface\\Icons\\INV_Misc_Bag_10:16|t  Enable Auto-Track Equipped Trinkets",
        desc = "Master toggle for auto-tracking equipped trinkets.\n\nWhen enabled, creates 2 persistent frames that always show your equipped trinkets.\n\n|cff88ff88These frames track the SLOT|r - icons automatically update when you swap trinkets.\n\nDisabling this removes only the auto-track frames, not manually added trinkets.",
        order = 20.2,
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
        order = 20.3,
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
        order = 20.4,
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
            args["autoTrackSlot" .. slotInfo.slotID].order = 20.5 + i * 0.1
        end
    else
        args.autoTrackSlot13 = {
            type = "toggle",
            name = "|TInterface\\Icons\\INV_Misc_QuestionMark:18|t  |cffffd700Trinket 1:|r |cff666666(Loading...)|r",
            order = 20.6,
            width = "full",
            get = function() return true end,
            set = function() end,
            hidden = function() return collapsedSections.autoTrackSlots end,
        }
        args.autoTrackSlot14 = {
            type = "toggle",
            name = "|TInterface\\Icons\\INV_Misc_QuestionMark:18|t  |cffffd700Trinket 2:|r |cff666666(Loading...)|r",
            order = 20.7,
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
        order = 30,
        width = "full",
    }
    args.clearTrinkets = {
        type = "execute",
        name = "Clear Trinkets",
        desc = "Remove all trinkets from tracking",
        order = 30.1,
        width = 0.9,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all tracked trinkets?",
        func = function() Options.ClearArcCategory("trinket") end,
    }
    args.clearItems = {
        type = "execute",
        name = "Clear Custom Items",
        desc = "Remove all custom items (keeps trinkets and spells)",
        order = 30.2,
        width = 1.1,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all custom items?",
        func = function() Options.ClearArcCategory("item") end,
    }
    args.clearSpells = {
        type = "execute",
        name = "Clear Arc Spells",
        desc = "Remove all tracked spell cooldowns",
        order = 30.3,
        width = 0.9,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove all tracked spells?",
        func = function() Options.ClearArcCategory("spell") end,
    }
    args.clearArcAuras = {
        type = "execute",
        name = "Clear Arc Auras",
        desc = "Remove all Arc aura icons",
        order = 30.35,
        width = 0.9,
        hidden = function()
            return collapsedSections.management
                or not (ns.AuraIcons and ns.AuraIcons.IsAvailable())
        end,
        confirm = true,
        confirmText = "Remove all Arc aura icons?",
        func = function() Options.ClearArcCategory("aura") end,
    }
    args.clearAll = {
        type = "execute",
        name = "Clear All",
        desc = "Remove everything (items + trinkets + spells + aura icons)",
        order = 30.4,
        width = 0.7,
        hidden = function() return collapsedSections.management end,
        confirm = true,
        confirmText = "Remove ALL tracked Arc icons?",
        func = function() Options.ClearArcCategory("all") end,
    }
    
    -- ═══════════════════════════════════════════════════════════════
    -- AUTO-DISABLE: Gray out all interactive controls when Arc Auras is off
    -- Skip the enable toggle itself, descriptions, and headers
    -- ═══════════════════════════════════════════════════════════════
    -- ═══════════════════════════════════════════════════════════════
    -- TOTEM SLOTS  (only shown for classes that have totem slots)
    -- Enabling creates a centered "Totems" group with every slot; slots stay
    -- independent so the user can drag any into another group. Master enable
    -- turns them all on; per-slot toggles switch individual slots off.
    -- ═══════════════════════════════════════════════════════════════
    local function HasTotemSlots()
        return ns.ArcAurasTotems and ns.ArcAurasTotems.GetNumSlots
           and ns.ArcAurasTotems.GetNumSlots() > 0
    end
    -- Collapsible header (matches "Auto-Track Equipped Slots"): click to expand.
    args.totemHeader = {
        type = "toggle",
        name = "Totem Slots",
        desc = "Click to expand/collapse.\n\nTrack your totem slots as icons — each slot shows whatever totem is currently in it.",
        dialogControl = "CollapsibleHeader",
        get = function() return not collapsedSections.totemSlots end,
        set = function(_, v) collapsedSections.totemSlots = not v end,
        order = 4, width = "full",
        hidden = function() return not HasTotemSlots() end,
    }
    local function HideTotemContent()
        return not HasTotemSlots() or collapsedSections.totemSlots
    end
    args.totemDesc = {
        type = "description",
        name = "Each slot shows whatever totem is currently in it. Enabling creates a centered \"Totems\" group with all slots; drag any of them into another group to mix and match.",
        order = 4.05, fontSize = "small",
        hidden = HideTotemContent,
    }
    args.totemEnable = {
        type = "toggle",
        name = "Enable Totem Slot Tracking",
        desc = "Show an icon for each of your totem slots.",
        order = 4.1, width = 1.5,
        hidden = HideTotemContent,
        get = function() return ns.ArcAurasTotems and ns.ArcAurasTotems.IsEnabled() end,
        set = function(_, v)
            if ns.ArcAurasTotems then ns.ArcAurasTotems.SetEnabled(v) end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end,
    }
    -- Per-slot toggles, generated up to a safe maximum; each hides past the
    -- real slot count, when collapsed, and when totem tracking is disabled.
    for slot = 1, 8 do
        local thisSlot = slot
        args["totemSlot" .. thisSlot] = {
            type = "toggle",
            name = "Slot " .. thisSlot,
            desc = "Track totem slot " .. thisSlot .. ".",
            order = 4.1 + thisSlot * 0.01, width = 0.7,
            hidden = function()
                if HideTotemContent() then return true end
                if not (ns.ArcAurasTotems and ns.ArcAurasTotems.IsEnabled()) then return true end
                return thisSlot > ns.ArcAurasTotems.GetNumSlots()
            end,
            get = function()
                return ns.ArcAurasTotems and ns.ArcAurasTotems.IsSlotEnabled(thisSlot)
            end,
            set = function(_, v)
                if ns.ArcAurasTotems then ns.ArcAurasTotems.SetSlotEnabled(thisSlot, v) end
                LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
            end,
        }
    end

    local skipKeys = { enabled = true, description = true, disabledNotice = true }
    for key, entry in pairs(args) do
        if not skipKeys[key] and entry.type ~= "header" and entry.type ~= "description" then
            if not entry.disabled then
                entry.disabled = IsArcDisabled
            end
        end
    end

    return {
        type = "group",
        name = "Arc Auras",
        order = 5,
        childGroups = "tab",
        args = {
            main = {
                type = "group",
                name = "Main",
                order = 1,
                args = args,
            },
            customIcons = (ns.GetCustomIconsOptionsTable and ns.GetCustomIconsOptionsTable()) or {
                type = "group",
                name = "Custom Icons",
                order = 2,
                args = {
                    stub = {
                        type = "description",
                        name = "|cffff8800Custom Icons module not loaded.|r",
                        order = 1,
                    },
                },
            },
        },
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
-- PUBLIC ACCESSORS FOR SIBLING OPTIONS MODULES (e.g. Custom Icons tab)
-- ═══════════════════════════════════════════════════════════════════════════

-- Returns the currently single-selected arcID, or nil. This is the same
-- selection state the Tracked catalog uses on the Main tab, so a timer
-- selected in either place is editable from both.
function Options.GetSelectedArcAura()
    return selectedArcAura
end

-- Returns the multi-select map (arcID -> true). Read-only intent; sibling
-- modules should not mutate — use Options.SetSelected to modify.
function Options.GetSelectedArcAuras()
    return selectedArcAuras
end

-- Set the single-selection arcID. Clears multi-select. Pass nil to deselect.
function Options.SetSelected(arcID)
    wipe(selectedArcAuras)
    selectedArcAura = arcID
end

-- Toggle an arcID in the multi-select set (for shift-click equivalents on
-- sibling tabs). Clears single selection when multi is non-empty.
function Options.ToggleMultiSelect(arcID)
    if not arcID then return end
    if selectedArcAuras[arcID] then
        selectedArcAuras[arcID] = nil
    else
        selectedArcAuras[arcID] = true
        selectedArcAura = arcID   -- track most-recent for single-select fallback
    end
end

-- Return the cached tracked list (items + spells + timers). Sibling modules
-- that want to render a filtered sub-catalog (e.g. timer-only) iterate this
-- and skip non-matching arcType entries.
function Options.GetTrackedItems()
    return GetTrackedItemsList()
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