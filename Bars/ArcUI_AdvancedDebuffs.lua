-- ===================================================================
-- ArcUI_AdvancedDebuffs.lua
-- Two standalone draggable icon frames:
--   Debuffs  — harmful auras on the player (HARMFUL filter)
--   Externals — external defensive / big-defensive buffs (HELPFUL|EXTERNAL_DEFENSIVE)
-- Secret-safe: all aura data flows through safe sinks only.
-- ===================================================================

local ADDON, ns = ...
ns.AdvancedDebuffs = {}
local AD = ns.AdvancedDebuffs

-- ── Dispel type colors and badge atlases (keyed by AuraData.dispelName string) ──
-- dispelName is a non-secret string: "Magic", "Curse", "Disease", "Poison", "Enrage", "Bleed"
local DISPEL_COLORS = {
    Magic   = {0.2, 0.6, 1.0},
    Curse   = {0.6, 0.0, 1.0},
    Disease = {0.6, 0.4, 0.0},
    Poison  = {0.0, 0.6, 0.0},
    Enrage  = {1.0, 0.2, 0.0},
    Bleed   = {1.0, 0.0, 0.0},
}
-- Badge atlas icons keyed by dispelName (Enrage has no standard RaidFrame atlas)
local DISPEL_ATLAS = {
    Magic   = "RaidFrame-Icon-DebuffMagic",
    Curse   = "RaidFrame-Icon-DebuffCurse",
    Disease = "RaidFrame-Icon-DebuffDisease",
    Poison  = "RaidFrame-Icon-DebuffPoison",
    Bleed   = "RaidFrame-Icon-DebuffBleed",
}

local FILTER_NAMES = {
    "PLAYER", "RAID", "CROWD_CONTROL",
    "RAID_IN_COMBAT", "RAID_PLAYER_DISPELLABLE", "IMPORTANT",
}

local INSET = 2  -- border-strip width in pixels

-- ── Active-tracker reference counter (shared event frame) ─────────────────
local activeTrackerCount = 0
local eventFrame = CreateFrame("Frame")

-- ── Debuffs tracker state ──────────────────────────────────────────────────
local mainFrame      = nil
local buttonPool     = {}   -- ordered; slot i holds auraCache[i]
local buttons        = {}   -- set of all created buttons (for ApplySettings sweeps)
local auraCache      = {}   -- ordered AuraData for currently visible debuffs
local activeAuras    = {}   -- [auraInstanceID] = true
local pendingRefresh = false
local isEnabled      = false

-- ── Externals tracker state ────────────────────────────────────────────────
local extFrame       = nil
local extPool        = {}
local extButtons     = {}
local extCache       = {}
local extPending     = false
local extEnabled     = false

local isInitialized  = false

-- ── Preview mode ──────────────────────────────────────────────────────────────
-- When the options panel is open and no real auras are active, we show placeholder
-- icons for each dispel type so the user can see the visual style and frame position.
local debuffPreviewActive = false
local extPreviewActive    = false

-- FileDataIDs for preview icons — stable cross-patch Blizzard textures (same set as NorskenUI)
local PREVIEW_ICON_IDS    = { 136139, 136188, 132090, 135849, 132095, 136197 }
-- Dispel type cycle for the debuff preview (nil = no type / generic icon)
local PREVIEW_DISPEL_CYCLE = { "Magic", "Curse", "Disease", "Poison", "Bleed", "Enrage", nil, nil }

-- ===================================================================
-- DB ACCESSORS
-- ===================================================================

local function GetDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedDebuffs
end

local function GetExtDB()
    local db = ns.API.GetDB and ns.API.GetDB()
    return db and db.advancedExternals
end

-- Bloodlust-family spell IDs to suppress by default (matches NorskenUI's DEFAULT_BLOCKLIST)
local DEFAULT_BLACKLIST = {
    [57723]  = true,   -- Exhaustion (Bloodlust)
    [57724]  = true,   -- Sated (Heroism)
    [80354]  = true,   -- Temporal Displacement (Time Warp – Mage)
    [160455] = true,   -- Fatigued (Drums of Fury / Battle)
    [390435] = true,   -- Exhaustion (variant)
    [95809]  = true,   -- Exhaustion (variant)
    [264689] = true,   -- Fatigued (variant)
    [308312] = true,   -- Time Trial (Mythic+)
}

-- Ensures default entries are explicitly written to SavedVariables.
-- AceDB's metatable makes db.blacklist[id] fall back to the defaults table (returning true)
-- rather than nil, so the plain == nil check never fires and pairs() sees nothing.
-- rawget bypasses the metatable and checks only what is actually in the saved table.
local function ApplyDefaultBlacklist()
    local db = GetDB()
    if not db then return end
    if not db.blacklist then db.blacklist = {} end
    for id in pairs(DEFAULT_BLACKLIST) do
        -- rawget: nil  = "never set" → write true so pairs() sees it in the UI
        -- rawget: false = "user removed" → leave alone
        -- rawget: true  = "already explicit" → leave alone
        if rawget(db.blacklist, id) == nil then
            db.blacklist[id] = true
        end
    end
end

-- ===================================================================
-- SHARED EVENT MANAGEMENT
-- ===================================================================

local function EnsureEventsRegistered()
    if activeTrackerCount == 0 then
        eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    end
    activeTrackerCount = activeTrackerCount + 1
end

local function ReleaseEvents()
    activeTrackerCount = activeTrackerCount - 1
    if activeTrackerCount <= 0 then
        activeTrackerCount = 0
        eventFrame:UnregisterEvent("UNIT_AURA")
        eventFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end
end

-- ===================================================================
-- DEBUFFS — FILTER HELPERS
-- ===================================================================

local function BuildFilterStrings(db)
    local out = {}
    if not db.filters then return out end
    for _, name in ipairs(FILTER_NAMES) do
        if db.filters[name] then
            out[#out + 1] = "HARMFUL|" .. name
        end
    end
    return out
end

local function ShouldShowAura(auraInstanceID, aura, filterStrings, blacklist, blacklistEnabled, watchlist)
    if not aura then return false end
    -- Skip non-harmful auras (safety; IDs are sourced from the HARMFUL pool already)
    local base = C_UnitAuras.IsAuraFilteredOutByInstanceID("player", auraInstanceID, "HARMFUL")
    if not issecretvalue(base) and base then return false end
    -- Blocklist takes top priority (spellId is secret in instances; guard with issecretvalue)
    if blacklistEnabled and blacklist then
        local sid = aura.spellId
        if sid and not issecretvalue(sid) and blacklist[sid] then return false end
    end
    -- Watchlist: bypass secondary filter restrictions for explicitly tracked spells
    if watchlist then
        local sid = aura.spellId
        if sid and not issecretvalue(sid) and watchlist[sid] then return true end
    end
    -- Secondary filters: each enabled filter must pass (aura must NOT be filtered out)
    for _, filter in ipairs(filterStrings) do
        local filtered = C_UnitAuras.IsAuraFilteredOutByInstanceID("player", auraInstanceID, filter)
        if not issecretvalue(filtered) and filtered then return false end
    end
    return true
end

-- ===================================================================
-- SHARED LAYOUT HELPERS
-- ===================================================================

local function GetAnchorPoint(db)
    local h = db.growHorizontal or "RIGHT"
    local v = db.growVertical   or "DOWN"
    if     h == "RIGHT" and v == "DOWN" then return "TOPLEFT"
    elseif h == "RIGHT" and v == "UP"   then return "BOTTOMLEFT"
    elseif h == "LEFT"  and v == "DOWN" then return "TOPRIGHT"
    else                                     return "BOTTOMRIGHT"
    end
end

local function SortAuras(a, b)
    return a.auraInstanceID < b.auraInstanceID
end

-- Resize 'frame' to exactly contain the visible icon grid so dragging works.
local function ResizeFrame(pool, frame, db)
    local visible = 0
    for _, btn in ipairs(pool) do
        if btn:IsShown() then visible = visible + 1 end
    end
    if visible == 0 then frame:SetSize(1, 1); return end
    local size    = db.iconSize    or 40
    local spacing = db.iconSpacing or 4
    local perRow  = db.iconsPerRow or 8
    local cols    = math.min(visible, perRow)
    local rows    = math.ceil(visible / perRow)
    frame:SetSize(
        cols * size + math.max(0, cols - 1) * spacing,
        rows * size + math.max(0, rows - 1) * spacing
    )
end

-- Position all shown pool buttons in a grid anchored to 'frame'.
local function PositionPool(pool, frame, db)
    if not frame then return end
    local size    = db.iconSize    or 40
    local spacing = db.iconSpacing or 4
    local step    = size + spacing
    local perRow  = db.iconsPerRow or 8
    local growH   = (db.growHorizontal or "RIGHT") == "RIGHT" and 1 or -1
    local growV   = (db.growVertical   or "DOWN")  == "DOWN"  and -1 or 1
    local anchor  = GetAnchorPoint(db)
    local visible = 0

    for _, btn in ipairs(pool) do
        if btn:IsShown() then
            visible = visible + 1
            local col = (visible - 1) % perRow
            local row = math.floor((visible - 1) / perRow)
            btn:ClearAllPoints()
            btn:SetPoint(anchor, frame, anchor, col * step * growH, row * step * growV)
        end
    end
end

-- ===================================================================
-- DEBUFFS — BUTTON VISUALS
-- ===================================================================

-- Apply dispel or custom border color via SetVertexColor (safe sink).
-- dispelName is a non-secret string field from AuraData ("Magic", "Curse", etc.)
local function ApplyDebuffBorderColor(button, dispelName, db)
    if not button.borderBg then return end
    if db.borderColorMode ~= "custom" then
        local c = DISPEL_COLORS[dispelName] or {0.5, 0.5, 0.5}
        button.borderBg:SetVertexColor(c[1], c[2], c[3], 1.0)
    else
        local bc = db.borderColor or { r=0.8, g=0.8, b=0.8, a=1 }
        button.borderBg:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
    end
end

-- Show the badge icon matching this aura's dispel type; hide all others.
local function UpdateDispelIcons(button, dispelName)
    if not button.dispelIcons then return end
    for dn, icon in pairs(button.dispelIcons) do
        icon:SetAlpha(dn == dispelName and 1 or 0)
    end
end

-- ===================================================================
-- BORDER WIDTH AND GLOW HELPERS
-- ===================================================================

local function ApplyBorderWidth(btn, inset)
    btn.icon:ClearAllPoints()
    btn.icon:SetPoint("TOPLEFT",     btn, "TOPLEFT",      inset, -inset)
    btn.icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -inset,  inset)
    btn.cooldown:ClearAllPoints()
    btn.cooldown:SetPoint("TOPLEFT",     btn, "TOPLEFT",      inset, -inset)
    btn.cooldown:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -inset,  inset)
end

local GLOW_KEY = "_arcAdGlow"

local function ApplyIconGlow(button, r, g, b, db)
    if not ns.Glows then return end
    ns.Glows.Start(button, GLOW_KEY, "pixel", {
        color     = { r, g, b, 1 },
        thickness = (db and db.glowWidth) or 2,
        lines     = 8,
        frequency = 0.25,
    })
end

local function RemoveIconGlow(button)
    if not ns.Glows then return end
    ns.Glows.Stop(button, GLOW_KEY)
end

local function ResolveRelFrame(pos)
    local name = pos and pos.relativeFrame
    if name and name ~= "UIParent" then
        local f = _G[name]
        if f then return f end
    end
    return UIParent
end

local function UpdateDebuffButton(button, data, db)
    if not data then RemoveIconGlow(button); button:Hide(); return end
    button.auraInstanceID = data.auraInstanceID
    button.icon:SetTexture(data.icon)   -- secret → SetTexture safe sink
    local count = C_UnitAuras.GetAuraApplicationDisplayCount("player", data.auraInstanceID, 2, 999)
    button.count:SetText(count)         -- secret → SetText safe sink
    local duration = C_UnitAuras.GetAuraDuration("player", data.auraInstanceID)
    if duration then
        button.cooldown:SetCooldownFromDurationObject(duration)
        button.cooldown:Show()
    else
        button.cooldown:Hide()
    end
    local dispelName = data.dispelName  -- non-secret string: "Magic", "Curse", "Disease", etc.
    ApplyDebuffBorderColor(button, dispelName, db)
    UpdateDispelIcons(button, dispelName)
    if db.borderGlow then
        if db.borderColorMode ~= "custom" then
            local c = DISPEL_COLORS[dispelName] or {0.5, 0.5, 0.5}
            ApplyIconGlow(button, c[1], c[2], c[3], db)
        else
            local bc = db.borderColor or {r=0.8,g=0.8,b=0.8,a=1}
            ApplyIconGlow(button, bc.r, bc.g, bc.b, db)
        end
    else
        RemoveIconGlow(button)
    end
    button:Show()
end

-- ===================================================================
-- EXTERNALS — BUTTON VISUALS
-- ===================================================================

local function UpdateExtButton(button, data, db)
    if not data then RemoveIconGlow(button); button:Hide(); return end
    button.auraInstanceID = data.auraInstanceID
    button.icon:SetTexture(data.icon)
    local count = C_UnitAuras.GetAuraApplicationDisplayCount("player", data.auraInstanceID, 2, 999)
    button.count:SetText(count)
    local duration = C_UnitAuras.GetAuraDuration("player", data.auraInstanceID)
    if duration then
        button.cooldown:SetCooldownFromDurationObject(duration)
        button.cooldown:Show()
    else
        button.cooldown:Hide()
    end
    local bc = db.borderColor or { r=0.2, g=0.8, b=0.2, a=1 }
    if button.borderBg then
        button.borderBg:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
    end
    if db.borderGlow then
        ApplyIconGlow(button, bc.r, bc.g, bc.b, db)
    else
        RemoveIconGlow(button)
    end
    button:Show()
end

-- ===================================================================
-- DEBUFFS — BUTTON POOL
-- ===================================================================

local function CreateDebuffButton(parent, db)
    local size   = db.iconSize or 40
    local inset  = db.borderWidth or INSET
    local button = CreateFrame("Frame", nil, parent)
    button:SetSize(size, size)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.85)

    button.borderBg = button:CreateTexture(nil, "BORDER")
    button.borderBg:SetAllPoints()
    button.borderBg:SetColorTexture(1, 1, 1, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT",     button, "TOPLEFT",      inset, -inset)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -inset,  inset)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetPoint("TOPLEFT",     button, "TOPLEFT",      inset, -inset)
    button.cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -inset,  inset)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(db.showSwipe ~= false)
    button.cooldown:SetReverse(db.reverseSwipe ~= false)
    button.cooldown:SetDrawBling(false)
    button.cooldown:SetHideCountdownNumbers(false)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.count:SetJustifyH("RIGHT")

    -- Dispel-type badge icons (one per type; shown/hidden by matching dispelName)
    local dispelOverlay = CreateFrame("Frame", nil, button)
    dispelOverlay:SetAllPoints()
    dispelOverlay:SetFrameLevel(button.cooldown:GetFrameLevel() + 1)

    button.dispelIcons = {}
    for dispelName, atlas in pairs(DISPEL_ATLAS) do
        local icon = dispelOverlay:CreateTexture(nil, "OVERLAY")
        icon:SetSize(12, 12)
        icon:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
        icon:SetAtlas(atlas)
        icon:SetAlpha(0)
        button.dispelIcons[dispelName] = icon
    end

    -- Always enable mouse so drag passthrough works; suppress clicks.
    local showTips = db.showTooltips
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function() parent:StartMoving() end)
    button:SetScript("OnDragStop", function()
        parent:StopMovingOrSizing()
        local point, _, relPoint, x, y = parent:GetPoint(1)
        local d = ns.API.GetDB and ns.API.GetDB()
        if d and d.advancedDebuffs then
            d.advancedDebuffs.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)
    if button.SetMouseClickEnabled  then button:SetMouseClickEnabled(false)  end
    if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(showTips) end
    if showTips then
        button:SetScript("OnEnter", function(self)
            if not self.auraInstanceID then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetUnitAuraByAuraInstanceID("player", self.auraInstanceID)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    button:Hide()
    buttons[button] = true
    buttonPool[#buttonPool + 1] = button
    return button
end

-- ===================================================================
-- EXTERNALS — BUTTON POOL
-- ===================================================================

local function CreateExtButton(parent, db)
    local size   = db.iconSize or 40
    local inset  = db.borderWidth or INSET
    local button = CreateFrame("Frame", nil, parent)
    button:SetSize(size, size)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.85)

    button.borderBg = button:CreateTexture(nil, "BORDER")
    button.borderBg:SetAllPoints()
    button.borderBg:SetColorTexture(1, 1, 1, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT",     button, "TOPLEFT",      inset, -inset)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -inset,  inset)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetPoint("TOPLEFT",     button, "TOPLEFT",      inset, -inset)
    button.cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -inset,  inset)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(db.showSwipe ~= false)
    button.cooldown:SetReverse(db.reverseSwipe ~= false)
    button.cooldown:SetDrawBling(false)
    button.cooldown:SetHideCountdownNumbers(false)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.count:SetJustifyH("RIGHT")

    local showTips = db.showTooltips
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function() parent:StartMoving() end)
    button:SetScript("OnDragStop", function()
        parent:StopMovingOrSizing()
        local point, _, relPoint, x, y = parent:GetPoint(1)
        local d = ns.API.GetDB and ns.API.GetDB()
        if d and d.advancedExternals then
            d.advancedExternals.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)
    if button.SetMouseClickEnabled  then button:SetMouseClickEnabled(false)  end
    if button.SetMouseMotionEnabled then button:SetMouseMotionEnabled(showTips) end
    if showTips then
        button:SetScript("OnEnter", function(self)
            if not self.auraInstanceID then return end
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetUnitAuraByAuraInstanceID("player", self.auraInstanceID)
            GameTooltip:Show()
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    button:Hide()
    extButtons[button] = true
    extPool[#extPool + 1] = button
    return button
end

-- ===================================================================
-- PREVIEW (shown when panel is open and no real auras are active)
-- ===================================================================

local function ShowDebuffPreview()
    if not mainFrame or not isEnabled then return end
    local db    = GetDB()
    if not db then return end
    local count = (db.iconsPerRow or 8) * (db.maxRows or 2)
    while #buttonPool < count do CreateDebuffButton(mainFrame, db) end
    local now = GetTime()
    for i = 1, count do
        local btn        = buttonPool[i]
        local iconIdx    = ((i - 1) % #PREVIEW_ICON_IDS)    + 1
        local dispelIdx  = ((i - 1) % #PREVIEW_DISPEL_CYCLE) + 1
        local dispelName = PREVIEW_DISPEL_CYCLE[dispelIdx]
        btn.icon:SetTexture(PREVIEW_ICON_IDS[iconIdx])
        -- Fake stack counts (same pattern as NorskenUI)
        if     i % 4 == 1 then btn.count:SetText(2)
        elseif i % 4 == 2 then btn.count:SetText(5)
        else                    btn.count:SetText("") end
        -- Fake cooldown swipes with locally-computed non-secret values
        if i % 3 ~= 0 then
            local dur   = 20 + ((i * 5) % 30)
            local start = now - (dur * (0.2 + (i % 5) * 0.1))
            btn.cooldown:SetCooldown(start, dur)
            btn.cooldown:Show()
        else
            btn.cooldown:Hide()
        end
        ApplyDebuffBorderColor(btn, dispelName, db)
        UpdateDispelIcons(btn, dispelName)
        if db.borderGlow then
            if db.borderColorMode ~= "custom" then
                local c = DISPEL_COLORS[dispelName] or {0.5, 0.5, 0.5}
                ApplyIconGlow(btn, c[1], c[2], c[3], db)
            else
                local bc = db.borderColor or {r=0.8,g=0.8,b=0.8,a=1}
                ApplyIconGlow(btn, bc.r, bc.g, bc.b, db)
            end
        else
            RemoveIconGlow(btn)
        end
        btn:Show()
    end
    for i = count + 1, #buttonPool do buttonPool[i]:Hide() end
    PositionPool(buttonPool, mainFrame, db)
    ResizeFrame(buttonPool, mainFrame, db)
end

local function ShowExtPreview()
    if not extFrame or not extEnabled then return end
    local db    = GetExtDB()
    if not db then return end
    local count = (db.iconsPerRow or 8) * (db.maxRows or 1)
    while #extPool < count do CreateExtButton(extFrame, db) end
    local now = GetTime()
    local bc  = db.borderColor or { r=0.2, g=0.8, b=0.2, a=1 }
    for i = 1, count do
        local btn = extPool[i]
        btn.icon:SetTexture(PREVIEW_ICON_IDS[((i - 1) % #PREVIEW_ICON_IDS) + 1])
        if     i % 4 == 1 then btn.count:SetText(2)
        elseif i % 4 == 2 then btn.count:SetText(5)
        else                    btn.count:SetText("") end
        if i % 3 ~= 0 then
            local dur   = 20 + ((i * 5) % 30)
            local start = now - (dur * (0.2 + (i % 5) * 0.1))
            btn.cooldown:SetCooldown(start, dur)
            btn.cooldown:Show()
        else
            btn.cooldown:Hide()
        end
        if btn.borderBg then btn.borderBg:SetVertexColor(bc.r, bc.g, bc.b, bc.a) end
        if db.borderGlow then
            ApplyIconGlow(btn, bc.r, bc.g, bc.b, db)
        else
            RemoveIconGlow(btn)
        end
        btn:Show()
    end
    for i = count + 1, #extPool do extPool[i]:Hide() end
    PositionPool(extPool, extFrame, db)
    ResizeFrame(extPool, extFrame, db)
end

-- ===================================================================
-- DEBUFFS — AURA REFRESH
-- ===================================================================

function AD.RefreshAllAuras()
    if not mainFrame or not isEnabled then return end
    local db = GetDB()
    if not db then return end

    wipe(auraCache)
    wipe(activeAuras)

    local filterStrings    = BuildFilterStrings(db)
    local blacklist        = db.blacklist
    local blacklistEnabled = db.blacklistEnabled ~= false
    local watchlist        = db.watchlist
    local ids = C_UnitAuras.GetUnitAuraInstanceIDs("player", "HARMFUL")
    if not ids then
        for _, btn in ipairs(buttonPool) do btn:Hide() end
        return
    end

    local count = 0
    for _, id in ipairs(ids) do
        local aura = C_UnitAuras.GetAuraDataByAuraInstanceID("player", id)
        if aura and ShouldShowAura(id, aura, filterStrings, blacklist, blacklistEnabled, watchlist) then
            activeAuras[id] = true
            count = count + 1
            auraCache[count] = aura
        end
    end

    if count > 1 then table.sort(auraCache, SortAuras) end

    local maxVisible = math.min((db.iconsPerRow or 8) * (db.maxRows or 2), count)
    while #buttonPool < maxVisible do CreateDebuffButton(mainFrame, db) end

    for i = 1, #buttonPool do
        if i <= maxVisible and auraCache[i] then
            UpdateDebuffButton(buttonPool[i], auraCache[i], db)
        else
            buttonPool[i]:Hide()
        end
    end

    PositionPool(buttonPool, mainFrame, db)
    ResizeFrame(buttonPool, mainFrame, db)

    if debuffPreviewActive and count == 0 then ShowDebuffPreview() end
end

local function QueueFullRefresh()
    if pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(0, function()
        pendingRefresh = false
        AD.RefreshAllAuras()
    end)
end

local function ProcessAuraUpdate(addedAuras, updatedIDs, removedIDs)
    if not mainFrame or not isEnabled then return end
    local db = GetDB()
    if not db then return end
    local filterStrings    = BuildFilterStrings(db)
    local blacklist        = db.blacklist
    local blacklistEnabled = db.blacklistEnabled ~= false
    local watchlist        = db.watchlist
    local changed          = false

    if removedIDs then
        for _, id in ipairs(removedIDs) do
            if activeAuras[id] then activeAuras[id] = nil; changed = true end
        end
    end
    if addedAuras then
        for _, aura in ipairs(addedAuras) do
            if ShouldShowAura(aura.auraInstanceID, aura, filterStrings, blacklist, blacklistEnabled, watchlist) then
                activeAuras[aura.auraInstanceID] = true; changed = true
            end
        end
    end
    if updatedIDs then
        for _, id in ipairs(updatedIDs) do
            local aura      = C_UnitAuras.GetAuraDataByAuraInstanceID("player", id)
            local should    = aura and ShouldShowAura(id, aura, filterStrings, blacklist, blacklistEnabled, watchlist)
            local was       = activeAuras[id]
            if should and not was then
                activeAuras[id] = true; changed = true
            elseif not should and was then
                activeAuras[id] = nil; changed = true
            elseif should and was then
                changed = true
            end
        end
    end

    if changed then AD.RefreshAllAuras() end
end

-- ===================================================================
-- EXTERNALS — AURA REFRESH (slot API; no incremental path)
-- ===================================================================

function AD.RefreshExternals()
    if not extFrame or not extEnabled then return end
    local db = GetExtDB()
    if not db then return end

    wipe(extCache)

    local seen           = {}
    local count          = 0
    local blacklist      = db.blacklist
    local blacklistEnabled = db.blacklistEnabled ~= false

    local function tryAdd(data)
        if not data then return end
        if seen[data.auraInstanceID] then return end
        if blacklistEnabled and blacklist then
            local sid = data.spellId
            if sid and not issecretvalue(sid) and blacklist[sid] then return end
        end
        seen[data.auraInstanceID] = true
        count = count + 1
        extCache[count] = data
    end

    -- Primary: external defensives cast on the player by others
    local slots = { C_UnitAuras.GetAuraSlots("player", "HELPFUL|EXTERNAL_DEFENSIVE") }
    for i = 2, #slots do
        tryAdd(C_UnitAuras.GetAuraDataBySlot("player", slots[i]))
    end

    -- Optional: big defensive cooldowns (includes self-cast defensive CDs)
    if db.showBigDefensives then
        local bigSlots = { C_UnitAuras.GetAuraSlots("player", "HELPFUL|BIG_DEFENSIVE") }
        for i = 2, #bigSlots do
            tryAdd(C_UnitAuras.GetAuraDataBySlot("player", bigSlots[i]))
        end
    end

    if count > 1 then table.sort(extCache, SortAuras) end

    local maxVisible = math.min((db.iconsPerRow or 8) * (db.maxRows or 1), count)
    while #extPool < maxVisible do CreateExtButton(extFrame, db) end

    for i = 1, #extPool do
        if i <= maxVisible and extCache[i] then
            UpdateExtButton(extPool[i], extCache[i], db)
        else
            extPool[i]:Hide()
        end
    end

    PositionPool(extPool, extFrame, db)
    ResizeFrame(extPool, extFrame, db)

    if extPreviewActive and count == 0 then ShowExtPreview() end
end

local function QueueExtRefresh()
    if extPending then return end
    extPending = true
    C_Timer.After(0, function()
        extPending = false
        AD.RefreshExternals()
    end)
end

-- ===================================================================
-- SHARED EVENT HANDLER
-- ===================================================================

eventFrame:SetScript("OnEvent", function(_, event, unit, updateInfo)
    if event == "UNIT_AURA" then
        if unit ~= "player" then return end
        -- Externals always do a full refresh (slot API lacks incremental support)
        if extEnabled then QueueExtRefresh() end
        -- Debuffs: incremental when possible
        if isEnabled then
            if not updateInfo or updateInfo.isFullUpdate then
                QueueFullRefresh()
            elseif updateInfo.addedAuras
                or updateInfo.updatedAuraInstanceIDs
                or updateInfo.removedAuraInstanceIDs then
                ProcessAuraUpdate(
                    updateInfo.addedAuras,
                    updateInfo.updatedAuraInstanceIDs,
                    updateInfo.removedAuraInstanceIDs
                )
            end
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if isEnabled   then QueueFullRefresh() end
        if extEnabled  then QueueExtRefresh()  end
    end
end)

-- ===================================================================
-- DEBUFFS — POSITION & SETTINGS
-- ===================================================================

function AD.ApplyPosition()
    if not mainFrame then return end
    local db = GetDB()
    if not db then return end
    local pos = db.position or { point="CENTER", relativePoint="CENTER", x=0, y=-200 }
    local relFrame = ResolveRelFrame(pos)
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(pos.point or "CENTER", relFrame, pos.relativePoint or "CENTER",
        pos.x or 0, pos.y or -200)
    mainFrame:SetFrameStrata(db.strata or "MEDIUM")
end

function AD.ApplySettings()
    local db = GetDB()
    if not db then return end
    if db.enabled and not isEnabled then AD.Enable(); return end
    if not db.enabled and isEnabled then AD.Disable(); return end
    if not mainFrame then return end

    local size  = db.iconSize or 40
    local inset = db.borderWidth or INSET
    for btn in pairs(buttons) do
        btn:SetSize(size, size)
        ApplyBorderWidth(btn, inset)
        local showTips = db.showTooltips
        btn:EnableMouse(showTips)
        if btn.SetMouseMotionEnabled then btn:SetMouseMotionEnabled(showTips) end
        if btn.cooldown then
            btn.cooldown:SetDrawSwipe(db.showSwipe ~= false)
            btn.cooldown:SetReverse(db.reverseSwipe ~= false)
        end
        if not db.borderGlow then RemoveIconGlow(btn) end
    end

    AD.ApplyPosition()
    AD.RefreshAllAuras()
end

-- ===================================================================
-- EXTERNALS — POSITION & SETTINGS
-- ===================================================================

function AD.ApplyExtPosition()
    if not extFrame then return end
    local db = GetExtDB()
    if not db then return end
    local pos = db.position or { point="CENTER", relativePoint="CENTER", x=0, y=-260 }
    local relFrame = ResolveRelFrame(pos)
    extFrame:ClearAllPoints()
    extFrame:SetPoint(pos.point or "CENTER", relFrame, pos.relativePoint or "CENTER",
        pos.x or 0, pos.y or -260)
    extFrame:SetFrameStrata(db.strata or "MEDIUM")
end

function AD.ApplyExtSettings()
    local db = GetExtDB()
    if not db then return end
    if db.enabled and not extEnabled then AD.EnableExternals(); return end
    if not db.enabled and extEnabled then AD.DisableExternals(); return end
    if not extFrame then return end

    local size  = db.iconSize or 40
    local inset = db.borderWidth or INSET
    for btn in pairs(extButtons) do
        btn:SetSize(size, size)
        ApplyBorderWidth(btn, inset)
        local showTips = db.showTooltips
        btn:EnableMouse(showTips)
        if btn.SetMouseMotionEnabled then btn:SetMouseMotionEnabled(showTips) end
        if btn.cooldown then
            btn.cooldown:SetDrawSwipe(db.showSwipe ~= false)
            btn.cooldown:SetReverse(db.reverseSwipe ~= false)
        end
        if not db.borderGlow then RemoveIconGlow(btn) end
    end

    AD.ApplyExtPosition()
    AD.RefreshExternals()
end

-- ===================================================================
-- FRAME CREATION
-- ===================================================================

local function CreateMainFrame()
    if mainFrame then return end
    mainFrame = CreateFrame("Frame", "ArcUIAdvancedDebuffsFrame", UIParent)
    mainFrame:SetSize(1, 1)
    mainFrame:EnableMouse(true)
    mainFrame:SetMovable(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    mainFrame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint(1)
        local d = ns.API.GetDB and ns.API.GetDB()
        if d and d.advancedDebuffs then
            d.advancedDebuffs.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)

    -- Drag bar: shown when options panel is open so the frame is visible/draggable
    local db = CreateFrame("Button", nil, mainFrame, "BackdropTemplate")
    db:SetSize(160, 16)
    db:SetFrameStrata("HIGH")
    db:SetFrameLevel(100)
    db:SetPoint("BOTTOMLEFT", mainFrame, "TOPLEFT", 0, 2)
    db:SetClampedToScreen(true)
    db:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1 })
    db:SetBackdropColor(0.12, 0.12, 0.12, 0.92)
    db:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    local dbIcon = db:CreateTexture(nil, "OVERLAY")
    dbIcon:SetSize(10, 10)
    dbIcon:SetPoint("LEFT", db, "LEFT", 4, 0)
    dbIcon:SetTexture("Interface\\CURSOR\\UI-Cursor-Move")
    dbIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    local dbLabel = db:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dbLabel:SetPoint("LEFT", dbIcon, "RIGHT", 4, 0)
    dbLabel:SetPoint("RIGHT", db, "RIGHT", -4, 0)
    dbLabel:SetText("|cffffd100Advanced Debuffs|r")
    dbLabel:SetJustifyH("LEFT")
    db:EnableMouse(true)
    db:RegisterForDrag("LeftButton")
    db:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        db:SetBackdropColor(0.12, 0.30, 0.55, 0.95)
        db:SetBackdropBorderColor(0.25, 0.65, 1.0, 1)
        dbIcon:SetVertexColor(1, 1, 1, 1)
        mainFrame:StartMoving()
    end)
    db:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing()
        db:SetBackdropColor(0.12, 0.12, 0.12, 0.92)
        db:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        dbIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
        local point, _, relPoint, x, y = mainFrame:GetPoint(1)
        local d2 = ns.API.GetDB and ns.API.GetDB()
        if d2 and d2.advancedDebuffs then
            d2.advancedDebuffs.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)
    db:Hide()
    mainFrame._dragBar = db

    AD.ApplyPosition()
    mainFrame:Show()
    -- Show drag bar immediately if panel is already open
    if ns.optionsPanelOpen then db:Show() end
end

local function CreateExtFrame()
    if extFrame then return end
    extFrame = CreateFrame("Frame", "ArcUIAdvancedExternalsFrame", UIParent)
    extFrame:SetSize(1, 1)
    extFrame:EnableMouse(true)
    extFrame:SetMovable(true)
    extFrame:RegisterForDrag("LeftButton")
    extFrame:SetClampedToScreen(true)
    extFrame:SetScript("OnDragStart", function(f) f:StartMoving() end)
    extFrame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        local point, _, relPoint, x, y = f:GetPoint(1)
        local d = ns.API.GetDB and ns.API.GetDB()
        if d and d.advancedExternals then
            d.advancedExternals.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)

    -- Drag bar: shown when options panel is open
    local eb = CreateFrame("Button", nil, extFrame, "BackdropTemplate")
    eb:SetSize(130, 16)
    eb:SetFrameStrata("HIGH")
    eb:SetFrameLevel(100)
    eb:SetPoint("BOTTOMLEFT", extFrame, "TOPLEFT", 0, 2)
    eb:SetClampedToScreen(true)
    eb:SetBackdrop({ bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1 })
    eb:SetBackdropColor(0.12, 0.12, 0.12, 0.92)
    eb:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
    local ebIcon = eb:CreateTexture(nil, "OVERLAY")
    ebIcon:SetSize(10, 10)
    ebIcon:SetPoint("LEFT", eb, "LEFT", 4, 0)
    ebIcon:SetTexture("Interface\\CURSOR\\UI-Cursor-Move")
    ebIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
    local ebLabel = eb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ebLabel:SetPoint("LEFT", ebIcon, "RIGHT", 4, 0)
    ebLabel:SetPoint("RIGHT", eb, "RIGHT", -4, 0)
    ebLabel:SetText("|cffffd100Externals|r")
    ebLabel:SetJustifyH("LEFT")
    eb:EnableMouse(true)
    eb:RegisterForDrag("LeftButton")
    eb:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        eb:SetBackdropColor(0.12, 0.30, 0.55, 0.95)
        eb:SetBackdropBorderColor(0.25, 0.65, 1.0, 1)
        ebIcon:SetVertexColor(1, 1, 1, 1)
        extFrame:StartMoving()
    end)
    eb:SetScript("OnDragStop", function()
        extFrame:StopMovingOrSizing()
        eb:SetBackdropColor(0.12, 0.12, 0.12, 0.92)
        eb:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        ebIcon:SetVertexColor(0.7, 0.7, 0.7, 1)
        local point, _, relPoint, x, y = extFrame:GetPoint(1)
        local d2 = ns.API.GetDB and ns.API.GetDB()
        if d2 and d2.advancedExternals then
            d2.advancedExternals.position = {
                point=point or "CENTER", relativePoint=relPoint or "CENTER", x=x or 0, y=y or 0,
            }
        end
    end)
    eb:Hide()
    extFrame._dragBar = eb

    AD.ApplyExtPosition()
    extFrame:Show()
    -- Show drag bar immediately if panel is already open
    if ns.optionsPanelOpen then eb:Show() end
end

-- ===================================================================
-- PUBLIC LIFECYCLE
-- ===================================================================

function AD.Enable()
    if isEnabled then return end
    isEnabled = true
    CreateMainFrame()
    EnsureEventsRegistered()
    QueueFullRefresh()
end

function AD.Disable()
    if not isEnabled then return end
    isEnabled = false
    ReleaseEvents()
    if mainFrame then mainFrame:Hide() end
    for _, btn in ipairs(buttonPool) do RemoveIconGlow(btn); btn:Hide() end
end

function AD.EnableExternals()
    if extEnabled then return end
    extEnabled = true
    CreateExtFrame()
    EnsureEventsRegistered()
    QueueExtRefresh()
end

function AD.DisableExternals()
    if not extEnabled then return end
    extEnabled = false
    ReleaseEvents()
    if extFrame then extFrame:Hide() end
    for _, btn in ipairs(extPool) do RemoveIconGlow(btn); btn:Hide() end
end

-- ===================================================================
-- INIT
-- ===================================================================

function AD.Init()
    if isInitialized then return end
    isInitialized = true
    ApplyDefaultBlacklist()  -- seed BL entries for existing saves that have an empty blacklist
    local db = GetDB()
    if db and db.enabled then AD.Enable() end
    local edb = GetExtDB()
    if edb and edb.enabled then AD.EnableExternals() end

    -- Show drag bars and preview icons when ArcUI options panel opens; clean up on close
    if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
        ns.CDMShared.RegisterPanelCallback("AdvancedDebuffs", {
            onOpen = function()
                debuffPreviewActive = true
                extPreviewActive    = true
                if mainFrame and mainFrame._dragBar then mainFrame._dragBar:Show() end
                if extFrame  and extFrame._dragBar  then extFrame._dragBar:Show()  end
                -- Refresh so preview kicks in if no real auras are active
                if mainFrame and isEnabled  then QueueFullRefresh() end
                if extFrame  and extEnabled then QueueExtRefresh()  end
            end,
            onClose = function()
                debuffPreviewActive = false
                extPreviewActive    = false
                if mainFrame and mainFrame._dragBar then mainFrame._dragBar:Hide() end
                if extFrame  and extFrame._dragBar  then extFrame._dragBar:Hide()  end
                -- Refresh to clear preview icons; real auras take over naturally
                if mainFrame and isEnabled  then QueueFullRefresh() end
                if extFrame  and extEnabled then QueueExtRefresh()  end
            end,
        })
    end
end
