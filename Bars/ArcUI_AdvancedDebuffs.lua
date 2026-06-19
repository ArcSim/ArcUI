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

-- ── Dispel type atlas names (SpellDispelType DB2 indices) ─────────────────
-- Curse (2) and Enrage (9) have no RaidFrame atlas; they rely on border color only.
local DISPEL_ATLAS = {
    [1]  = "RaidFrame-Icon-DebuffMagic",
    [3]  = "RaidFrame-Icon-DebuffDisease",
    [4]  = "RaidFrame-Icon-DebuffPoison",
    [11] = "RaidFrame-Icon-DebuffBleed",
}
-- All dispel indices used in the color curve (including those without badge icons)
local ALL_DISPEL_INDICES = { 0, 1, 2, 3, 4, 9, 11 }

local FILTER_NAMES = {
    "PLAYER", "RAID", "CROWD_CONTROL",
    "RAID_IN_COMBAT", "RAID_PLAYER_DISPELLABLE", "IMPORTANT",
}

local INSET = 2  -- border-strip width in pixels

-- ── Curves (initialised once at Init) ─────────────────────────────────────
local dispelColorCurve = nil    -- debuff border: dispel-type index → RGBA color
local dispelAlphaCurves = {}    -- [dispelIndex] = curve returning alpha=1 only for that type

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

local function ShouldShowAura(auraInstanceID, aura, filterStrings)
    if not aura then return false end
    local base = C_UnitAuras.IsAuraFilteredOutByInstanceID("player", auraInstanceID, "HARMFUL")
    if not issecretvalue(base) and base then return false end
    for _, filter in ipairs(filterStrings) do
        local filtered = C_UnitAuras.IsAuraFilteredOutByInstanceID("player", auraInstanceID, filter)
        if not issecretvalue(filtered) and not filtered then return false end
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
local function ApplyDebuffBorderColor(button, auraInstanceID, db)
    if not button.borderBg then return end
    if db.borderColorMode == "dispel" and dispelColorCurve then
        local color = C_UnitAuras.GetAuraDispelTypeColor("player", auraInstanceID, dispelColorCurve)
        if color then
            button.borderBg:SetVertexColor(color:GetRGBA())
        else
            button.borderBg:SetVertexColor(0.5, 0.5, 0.5, 0.4)
        end
    else
        local bc = db.borderColor or { r=0.8, g=0.8, b=0.8, a=1 }
        button.borderBg:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
    end
end

-- Show/hide the small dispel-type badge icons via per-type alpha curves.
-- GetAuraDispelTypeColor returns a secret ColorMixin; alpha component is safe sink.
local function UpdateDispelIcons(button, auraInstanceID)
    if not button.dispelIcons then return end
    for dispelIndex, icon in pairs(button.dispelIcons) do
        local curve = dispelAlphaCurves[dispelIndex]
        if curve then
            local color = C_UnitAuras.GetAuraDispelTypeColor("player", auraInstanceID, curve)
            if color then
                local _, _, _, a = color:GetRGBA()
                icon:SetAlpha(a)   -- secret alpha via safe sink
            else
                icon:SetAlpha(0)
            end
        end
    end
end

local function UpdateDebuffButton(button, data, db)
    if not data then button:Hide(); return end
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
    ApplyDebuffBorderColor(button, data.auraInstanceID, db)
    UpdateDispelIcons(button, data.auraInstanceID)
    button:Show()
end

-- ===================================================================
-- EXTERNALS — BUTTON VISUALS
-- ===================================================================

local function UpdateExtButton(button, data, db)
    if not data then button:Hide(); return end
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
    if button.borderBg then
        local bc = db.borderColor or { r=0.2, g=0.8, b=0.2, a=1 }
        button.borderBg:SetVertexColor(bc.r, bc.g, bc.b, bc.a)
    end
    button:Show()
end

-- ===================================================================
-- DEBUFFS — BUTTON POOL
-- ===================================================================

local function CreateDebuffButton(parent, db)
    local size   = db.iconSize or 40
    local button = CreateFrame("Frame", nil, parent)
    button:SetSize(size, size)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.85)

    button.borderBg = button:CreateTexture(nil, "BORDER")
    button.borderBg:SetAllPoints()
    button.borderBg:SetColorTexture(1, 1, 1, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT",     button, "TOPLEFT",      INSET, -INSET)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -INSET,  INSET)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetPoint("TOPLEFT",     button, "TOPLEFT",      INSET, -INSET)
    button.cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -INSET,  INSET)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(db.showSwipe ~= false)
    button.cooldown:SetReverse(db.reverseSwipe ~= false)
    button.cooldown:SetDrawBling(false)
    button.cooldown:SetHideCountdownNumbers(false)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.count:SetJustifyH("RIGHT")

    -- Dispel-type badge icons (one per type with atlas icon; alpha driven by per-type curve)
    local dispelOverlay = CreateFrame("Frame", nil, button)
    dispelOverlay:SetAllPoints()
    dispelOverlay:SetFrameLevel(button.cooldown:GetFrameLevel() + 1)

    button.dispelIcons = {}
    for dispelIndex, atlas in pairs(DISPEL_ATLAS) do
        local icon = dispelOverlay:CreateTexture(nil, "OVERLAY")
        icon:SetSize(12, 12)
        icon:SetPoint("TOPRIGHT", button, "TOPRIGHT", 0, 0)
        icon:SetAtlas(atlas)
        icon:SetAlpha(0)
        button.dispelIcons[dispelIndex] = icon
    end

    local showTips = db.showTooltips
    button:EnableMouse(showTips)
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
    local button = CreateFrame("Frame", nil, parent)
    button:SetSize(size, size)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetColorTexture(0, 0, 0, 0.85)

    button.borderBg = button:CreateTexture(nil, "BORDER")
    button.borderBg:SetAllPoints()
    button.borderBg:SetColorTexture(1, 1, 1, 1)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT",     button, "TOPLEFT",      INSET, -INSET)
    button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -INSET,  INSET)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetPoint("TOPLEFT",     button, "TOPLEFT",      INSET, -INSET)
    button.cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -INSET,  INSET)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetDrawSwipe(db.showSwipe ~= false)
    button.cooldown:SetReverse(db.reverseSwipe ~= false)
    button.cooldown:SetDrawBling(false)
    button.cooldown:SetHideCountdownNumbers(false)

    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    button.count:SetJustifyH("RIGHT")

    local showTips = db.showTooltips
    button:EnableMouse(showTips)
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
-- DEBUFFS — AURA REFRESH
-- ===================================================================

function AD.RefreshAllAuras()
    if not mainFrame or not isEnabled then return end
    local db = GetDB()
    if not db then return end

    wipe(auraCache)
    wipe(activeAuras)

    local filterStrings = BuildFilterStrings(db)
    local ids = C_UnitAuras.GetUnitAuraInstanceIDs("player", "HARMFUL")
    if not ids then
        for _, btn in ipairs(buttonPool) do btn:Hide() end
        return
    end

    local count = 0
    for _, id in ipairs(ids) do
        local aura = C_UnitAuras.GetAuraDataByAuraInstanceID("player", id)
        if aura and ShouldShowAura(id, aura, filterStrings) then
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
    local filterStrings = BuildFilterStrings(db)
    local changed = false

    if removedIDs then
        for _, id in ipairs(removedIDs) do
            if activeAuras[id] then activeAuras[id] = nil; changed = true end
        end
    end
    if addedAuras then
        for _, aura in ipairs(addedAuras) do
            if ShouldShowAura(aura.auraInstanceID, aura, filterStrings) then
                activeAuras[aura.auraInstanceID] = true; changed = true
            end
        end
    end
    if updatedIDs then
        for _, id in ipairs(updatedIDs) do
            local aura      = C_UnitAuras.GetAuraDataByAuraInstanceID("player", id)
            local should    = aura and ShouldShowAura(id, aura, filterStrings)
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

    local seen  = {}
    local count = 0

    -- Primary: external defensives cast on the player by others
    local slots = { C_UnitAuras.GetAuraSlots("player", "HELPFUL|EXTERNAL_DEFENSIVE") }
    for i = 2, #slots do
        local data = C_UnitAuras.GetAuraDataBySlot("player", slots[i])
        if data and not seen[data.auraInstanceID] then
            seen[data.auraInstanceID] = true
            count = count + 1
            extCache[count] = data
        end
    end

    -- Optional: big defensive cooldowns (includes self-cast defensive CDs)
    if db.showBigDefensives then
        local bigSlots = { C_UnitAuras.GetAuraSlots("player", "HELPFUL|BIG_DEFENSIVE") }
        for i = 2, #bigSlots do
            local data = C_UnitAuras.GetAuraDataBySlot("player", bigSlots[i])
            if data and not seen[data.auraInstanceID] then
                seen[data.auraInstanceID] = true
                count = count + 1
                extCache[count] = data
            end
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
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER",
        pos.x or 0, pos.y or -200)
    mainFrame:SetFrameStrata(db.strata or "MEDIUM")
end

function AD.ApplySettings()
    local db = GetDB()
    if not db then return end
    if db.enabled and not isEnabled then AD.Enable(); return end
    if not db.enabled and isEnabled then AD.Disable(); return end
    if not mainFrame then return end

    local size = db.iconSize or 40
    for btn in pairs(buttons) do
        btn:SetSize(size, size)
        local showTips = db.showTooltips
        btn:EnableMouse(showTips)
        if btn.SetMouseMotionEnabled then btn:SetMouseMotionEnabled(showTips) end
        if btn.cooldown then
            btn.cooldown:SetDrawSwipe(db.showSwipe ~= false)
            btn.cooldown:SetReverse(db.reverseSwipe ~= false)
        end
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
    extFrame:ClearAllPoints()
    extFrame:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER",
        pos.x or 0, pos.y or -260)
    extFrame:SetFrameStrata(db.strata or "MEDIUM")
end

function AD.ApplyExtSettings()
    local db = GetExtDB()
    if not db then return end
    if db.enabled and not extEnabled then AD.EnableExternals(); return end
    if not db.enabled and extEnabled then AD.DisableExternals(); return end
    if not extFrame then return end

    local size = db.iconSize or 40
    for btn in pairs(extButtons) do
        btn:SetSize(size, size)
        local showTips = db.showTooltips
        btn:EnableMouse(showTips)
        if btn.SetMouseMotionEnabled then btn:SetMouseMotionEnabled(showTips) end
        if btn.cooldown then
            btn.cooldown:SetDrawSwipe(db.showSwipe ~= false)
            btn.cooldown:SetReverse(db.reverseSwipe ~= false)
        end
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
    AD.ApplyPosition()
    mainFrame:Show()
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
    AD.ApplyExtPosition()
    extFrame:Show()
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
    for _, btn in ipairs(buttonPool) do btn:Hide() end
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
    for _, btn in ipairs(extPool) do btn:Hide() end
end

-- ===================================================================
-- CURVE INIT
-- ===================================================================

local function InitDispelCurves()
    -- Border color curve: dispel-type index → RGBA border color
    dispelColorCurve = C_CurveUtil.CreateColorCurve()
    dispelColorCurve:SetType(Enum.LuaCurveType.Step)
    dispelColorCurve:AddPoint(0,  CreateColor(0.5, 0.5, 0.5, 0.35))  -- None
    dispelColorCurve:AddPoint(1,  CreateColor(0.2, 0.6, 1.0, 1.0))   -- Magic
    dispelColorCurve:AddPoint(2,  CreateColor(0.6, 0.0, 1.0, 1.0))   -- Curse
    dispelColorCurve:AddPoint(3,  CreateColor(0.6, 0.4, 0.0, 1.0))   -- Disease
    dispelColorCurve:AddPoint(4,  CreateColor(0.0, 0.6, 0.0, 1.0))   -- Poison
    dispelColorCurve:AddPoint(9,  CreateColor(1.0, 0.2, 0.0, 1.0))   -- Enrage
    dispelColorCurve:AddPoint(11, CreateColor(1.0, 0.0, 0.0, 1.0))   -- Bleed

    -- Alpha curves: one per atlas-bearing dispel type.
    -- Each returns alpha=1 only when the aura matches that specific dispel type.
    local transparent = CreateColor(1, 1, 1, 0)
    local visible     = CreateColor(1, 1, 1, 1)
    for dispelIndex in pairs(DISPEL_ATLAS) do
        local curve = C_CurveUtil.CreateColorCurve()
        curve:SetType(Enum.LuaCurveType.Step)
        for _, idx in ipairs(ALL_DISPEL_INDICES) do
            curve:AddPoint(idx, idx == dispelIndex and visible or transparent)
        end
        dispelAlphaCurves[dispelIndex] = curve
    end
end

-- ===================================================================
-- INIT
-- ===================================================================

function AD.Init()
    if isInitialized then return end
    isInitialized = true
    InitDispelCurves()
    local db = GetDB()
    if db and db.enabled then AD.Enable() end
    local edb = GetExtDB()
    if edb and edb.enabled then AD.EnableExternals() end
end
