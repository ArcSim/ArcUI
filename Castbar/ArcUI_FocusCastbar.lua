-- ===================================================================
-- ArcUI_FocusCastbar.lua
-- Castbar tracking what the focus target is casting.
-- Zero idle CPU: all timers/OnUpdate only run during an active cast
-- or preview. Events unregistered when disabled.
-- ===================================================================

local ADDON, ns = ...
ns.FocusCastbar = ns.FocusCastbar or {}
local FC = ns.FocusCastbar

local LSM          = LibStub and LibStub("LibSharedMedia-3.0", true)
local GLOW_KEY     = "_arcFCastGlow"
local IMP_GLOW_KEY = "_arcFCastImpGlow"

-- ===================================================================
-- Class interrupt spell IDs (checked once per spec change)
-- ===================================================================
local CLASS_INTERRUPTS = {
    [1]  = {6552},           -- Warrior: Pummel
    [2]  = {96231},          -- Paladin: Rebuke
    [3]  = {147362, 187707}, -- Hunter: Counter Shot / Muzzle
    [4]  = {1766},           -- Rogue: Kick
    [5]  = {15487},          -- Priest: Silence (Shadow)
    [6]  = {47528},          -- Death Knight: Mind Freeze
    [7]  = {57994},          -- Shaman: Wind Shear
    [8]  = {2139},           -- Mage: Counterspell
    [9]  = {119910},         -- Warlock: Spell Lock (pet/Grimoire)
    [10] = {116705},         -- Monk: Spear Hand Strike
    [11] = {106839},         -- Druid: Skull Bash
    [12] = {183752},         -- Demon Hunter: Disrupt
    [13] = {351338},         -- Evoker: Quell
}

-- ===================================================================
-- STATE
-- ===================================================================
local mainFrame          = nil
local isEnabled          = false
local isInitialized      = false
local castActive         = false
local isChannel          = false
local cachedDuration     = nil   -- duration object from UnitCastingDuration / UnitChannelDuration
local currentSpellID     = nil
local holdTimer          = nil   -- C_Timer handle
local holdActive         = false
local castWasInterrupted = false -- set when INTERRUPTED fires before STOP
local interruptId        = nil   -- player's interrupt spell ID
local castStart          = 0    -- GetTime() snapshot used only by PreviewOnUpdate
-- Secret boolean from UnitCastingInfo; passed only to WoW safe-sink APIs, never compared
local state_notInterruptible = nil
-- Cached Color objects (rebuilt when bar color settings change)
local castColorObj     = nil
local unintColorObj    = nil
local notReadyColorObj = nil

-- ===================================================================
-- DB
-- ===================================================================
local function GetDB()
    return ns.db and ns.db.char and ns.db.char.focusCastbar
end

-- ===================================================================
-- INTERRUPT CACHE
-- ===================================================================
local function CacheInterruptId()
    interruptId = nil
    local classID = select(3, UnitClass("player"))
    local ids = CLASS_INTERRUPTS[classID]
    if not ids then return end
    for _, id in ipairs(ids) do
        if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook
           and C_SpellBook.IsSpellKnownOrInSpellBook(id) then
            interruptId = id
            return
        end
    end
end

-- ===================================================================
-- COLOR OBJECTS  (rebuilt whenever bar colors change)
-- ===================================================================
local function RebuildColorObjects(cfg)
    local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    castColorObj = CreateColor(bc.r, bc.g, bc.b)
    local uc = cfg.uninterruptibleColor or {r=0.5,g=0.5,b=0.5,a=1}
    unintColorObj = CreateColor(uc.r, uc.g, uc.b)
    local nr = cfg.kickNotReadyColor or {r=0.55,g=0.55,b=0.55,a=1}
    notReadyColorObj = CreateColor(nr.r, nr.g, nr.b)
end

-- ===================================================================
-- BAR COLOR  (all secret boolean paths use WoW 12.0 safe-sink APIs)
-- ===================================================================
local function UpdateBarColor(cfg, kickCooldown)
    if not mainFrame then return end
    local texture = mainFrame.fillBar:GetStatusBarTexture()
    if not texture then return end

    if kickCooldown and cfg.kickEnabled and interruptId then
        -- EvaluateColorFromBoolean: picks castColor when kick is ready, notReady when on CD
        local kickColor = C_CurveUtil.EvaluateColorFromBoolean(
            kickCooldown:IsZero(), castColorObj, notReadyColorObj)
        if cfg.uninterruptibleEnabled then
            -- SetVertexColorFromBoolean: unintColor when cast is not-interruptible
            texture:SetVertexColorFromBoolean(state_notInterruptible, unintColorObj, kickColor)
        else
            texture:SetVertexColorFromBoolean(kickCooldown:IsZero(), castColorObj, notReadyColorObj)
        end
    elseif cfg.uninterruptibleEnabled then
        texture:SetVertexColorFromBoolean(state_notInterruptible, unintColorObj, castColorObj)
    else
        local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
        texture:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1)
    end
end

-- ===================================================================
-- KICK INDICATOR
-- ===================================================================
local function SetupKickBar(cfg)
    if not (cfg.kickEnabled and interruptId and not isChannel) then
        mainFrame.kickTick:SetAlpha(0)
        return
    end
    if not cachedDuration then
        mainFrame.kickTick:SetAlpha(0)
        return
    end
    local h = cfg.height or 18
    mainFrame.kickTick:SetHeight(h)
    local kc = cfg.kickTickColor or {r=1,g=1,b=1,a=1}
    mainFrame.kickTick:SetColorTexture(kc.r, kc.g, kc.b, kc.a or 1)

    local totalDur = cachedDuration:GetTotalDuration()
    mainFrame.positioner:SetMinMaxValues(0, totalDur)
    mainFrame.positioner:SetReverseFill(false)
    mainFrame.positioner:SetValue(0)

    mainFrame.kickCooldownBar:SetMinMaxValues(0, totalDur)
    mainFrame.kickCooldownBar:SetReverseFill(false)
    mainFrame.kickCooldownBar:ClearAllPoints()
    mainFrame.kickCooldownBar:SetPoint("LEFT",   mainFrame.positioner:GetStatusBarTexture(), "RIGHT")
    mainFrame.kickCooldownBar:SetPoint("RIGHT",  mainFrame.fillBar, "RIGHT")
    mainFrame.kickCooldownBar:SetPoint("TOP",    mainFrame.fillBar, "TOP")
    mainFrame.kickCooldownBar:SetPoint("BOTTOM", mainFrame.fillBar, "BOTTOM")
    mainFrame.kickTick:ClearAllPoints()
    mainFrame.kickTick:SetPoint("CENTER", mainFrame.kickCooldownBar:GetStatusBarTexture(), "RIGHT", 0, 0)
end

local function UpdateKickAndColor(cfg)
    if not (cfg.kickEnabled and interruptId and not isChannel) then
        mainFrame.kickTick:SetAlpha(0)
        UpdateBarColor(cfg, nil)
        return
    end
    if not (C_Spell and C_Spell.GetSpellCooldownDuration) then
        mainFrame.kickTick:SetAlpha(0)
        UpdateBarColor(cfg, nil)
        return
    end
    local cooldown = C_Spell.GetSpellCooldownDuration(interruptId)
    if not cooldown then
        mainFrame.kickTick:SetAlpha(0)
        UpdateBarColor(cfg, nil)
        return
    end
    mainFrame.kickCooldownBar:SetValue(cooldown:GetRemainingDuration()) -- secret via SetValue safe sink
    mainFrame.kickTick:SetAlphaFromBoolean(cooldown:IsZero(), 0, 1)    -- 0=hidden when kick ready
    UpdateBarColor(cfg, cooldown)
end

-- ===================================================================
-- IMPORTANT SPELL GLOW
-- ===================================================================
local function UpdateImportantGlow(spellID, cfg, forPreview)
    if not (cfg.importantGlowEnabled and ns.Glows) then
        if ns.Glows then ns.Glows.Stop(mainFrame, IMP_GLOW_KEY) end
        return
    end
    local show = forPreview or (C_Spell and C_Spell.IsSpellImportant and C_Spell.IsSpellImportant(spellID))
    if show then
        local gc = cfg.importantGlowColor or {r=1,g=0.2,b=0.2,a=1}
        ns.Glows.Start(mainFrame, IMP_GLOW_KEY, cfg.importantGlowType or "pixel", {
            color      = {gc.r, gc.g, gc.b, gc.a or 1},
            lines      = cfg.importantGlowLines or 8,
            frequency  = cfg.importantGlowFrequency or 0.25,
            thickness  = cfg.importantGlowThickness or 2,
            frameLevel = 15,
        })
    else
        ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
    end
end

-- ===================================================================
-- BORDER
-- ===================================================================
local function ApplyBorder(frame, cfg)
    local bo = frame.borderOverlay
    if cfg.showBorder then
        local bt = cfg.drawnBorderThickness or 2
        local bc = cfg.borderColor or {r=0,g=0,b=0,a=1}
        bo.top:ClearAllPoints()
        bo.top:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        bo.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        bo.top:SetHeight(bt)
        bo.top:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
        bo.bottom:ClearAllPoints()
        bo.bottom:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  0, 0)
        bo.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        bo.bottom:SetHeight(bt)
        bo.bottom:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
        bo.left:ClearAllPoints()
        bo.left:SetPoint("TOPLEFT",    frame, "TOPLEFT",    0, -bt)
        bo.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0,  bt)
        bo.left:SetWidth(bt)
        bo.left:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
        bo.right:ClearAllPoints()
        bo.right:SetPoint("TOPRIGHT",    frame, "TOPRIGHT",    0, -bt)
        bo.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0,  bt)
        bo.right:SetWidth(bt)
        bo.right:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
        for _, t in ipairs({bo.top,bo.bottom,bo.left,bo.right}) do t:Show() end
        bo:Show()
    else
        for _, t in ipairs({bo.top,bo.bottom,bo.left,bo.right}) do t:Hide() end
        bo:Hide()
    end
end

-- ===================================================================
-- RAID MARKER
-- ===================================================================
local function ApplyRaidMarkerSettings()
    if not mainFrame then return end
    local cfg = GetDB()
    if not cfg then return end
    local anchor  = cfg.raidMarkerAnchor  or "LEFT"
    local offsetX = cfg.raidMarkerOffsetX or 0
    local offsetY = cfg.raidMarkerOffsetY or 0
    local size    = cfg.raidMarkerSize    or 32
    mainFrame._raidMarker:SetSize(size, size)
    mainFrame._raidMarker:ClearAllPoints()
    mainFrame._raidMarker:SetPoint(anchor, mainFrame, anchor, offsetX, offsetY)
end

-- showDefault: when no focus marker exists, show raidMarkerDefault (for preview/edit)
local function UpdateRaidMarker(showDefault)
    if not mainFrame then return end
    local cfg = GetDB()
    if not (cfg and cfg.showRaidMarker) then
        mainFrame._raidMarker:Hide()
        return
    end
    ApplyRaidMarkerSettings()
    local idx = GetRaidTargetIndex("focus")
    if idx then
        ---@diagnostic disable-next-line: undefined-global
        SetRaidTargetIconTexture(mainFrame._raidMarker, idx)
        mainFrame._raidMarker:Show()
    elseif showDefault and (cfg.raidMarkerDefault or 0) > 0 then
        ---@diagnostic disable-next-line: undefined-global
        SetRaidTargetIconTexture(mainFrame._raidMarker, cfg.raidMarkerDefault)
        mainFrame._raidMarker:Show()
    else
        mainFrame._raidMarker:Hide()
    end
end

-- ===================================================================
-- POSITION
-- ===================================================================
local function SavePosition()
    if not mainFrame then return end
    local db2 = GetDB()
    if not db2 then return end
    local point, _, relPoint, x, y = mainFrame:GetPoint()
    if point then
        db2.barPosition = {point=point, relPoint=relPoint,
            x=math.floor(x+0.5), y=math.floor(y+0.5)}
    end
end

function FC.ApplyPosition()
    local cfg = GetDB()
    if not cfg or not mainFrame then return end
    local pos = cfg.barPosition or {point="CENTER", relPoint="CENTER", x=0, y=-120}
    local ap  = cfg.barAnchorPoint or pos.point or "CENTER"
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint(ap, UIParent, ap, pos.x or 0, pos.y or -120)
end

-- ===================================================================
-- FRAME CREATION
-- ===================================================================
local function CreateFocusFrames()
    if mainFrame then return end
    local cfg = GetDB()
    if not cfg then return end
    local w = cfg.width  or 220
    local h = cfg.height or 18

    local frame = CreateFrame("Frame", "ArcUIFocusCastbarMain", UIParent)
    frame:SetSize(w, h)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)
    frame:Hide()

    -- Background
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
    frame.bg:SetSnapToPixelGrid(false)
    frame.bg:SetTexelSnappingBias(0)

    -- Fill bar
    frame.fillBar = CreateFrame("StatusBar", nil, frame)
    frame.fillBar:SetAllPoints()
    frame.fillBar:SetMinMaxValues(0, 1)
    frame.fillBar:SetValue(0)
    frame.fillBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.fillBar:SetStatusBarColor(1, 0.65, 0, 1)
    frame.fillBar:SetFrameLevel(frame:GetFrameLevel() + 2)

    -- Positioner: invisible; mirrors cast elapsed for kick-tick anchor (non-secret values)
    frame.positioner = CreateFrame("StatusBar", nil, frame.fillBar)
    frame.positioner:SetAllPoints(frame.fillBar)
    frame.positioner:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    frame.positioner:SetStatusBarColor(0, 0, 0, 0)
    frame.positioner:SetMinMaxValues(0, 1)
    frame.positioner:SetValue(0)
    frame.positioner:SetFrameLevel(frame.fillBar:GetFrameLevel() + 1)

    -- Mask clips kick tick to the bar area
    local tickMask = frame.fillBar:CreateMaskTexture()
    tickMask:SetAllPoints(frame.fillBar)
    tickMask:SetTexture("Interface\\BUTTONS\\WHITE8X8", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")

    -- Kick cooldown bar: anchored from cast-progress position, fills with kick CD remaining
    frame.kickCooldownBar = CreateFrame("StatusBar", nil, frame.fillBar)
    frame.kickCooldownBar:SetAllPoints(frame.fillBar)
    frame.kickCooldownBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
    frame.kickCooldownBar:SetStatusBarColor(0, 0, 0, 0)
    frame.kickCooldownBar:SetMinMaxValues(0, 1)
    frame.kickCooldownBar:SetValue(0)
    frame.kickCooldownBar:SetFrameLevel(frame.fillBar:GetFrameLevel() + 4)

    -- Kick tick mark: 2px vertical line at the kick-ready position
    frame.kickTick = frame.kickCooldownBar:CreateTexture(nil, "OVERLAY", nil, 7)
    frame.kickTick:SetSize(2, h)
    frame.kickTick:SetColorTexture(1, 1, 1, 1)
    frame.kickTick:SetPoint("CENTER", frame.kickCooldownBar:GetStatusBarTexture(), "RIGHT", 0, 0)
    frame.kickTick:AddMaskTexture(tickMask)
    frame.kickTick:SetAlpha(0)

    -- Border overlay (4 edge textures)
    frame.borderOverlay = CreateFrame("Frame", nil, frame)
    frame.borderOverlay:SetAllPoints()
    frame.borderOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    frame.borderOverlay.top    = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
    frame.borderOverlay.bottom = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
    frame.borderOverlay.left   = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
    frame.borderOverlay.right  = frame.borderOverlay:CreateTexture(nil, "OVERLAY")
    for _, t in ipairs({frame.borderOverlay.top, frame.borderOverlay.bottom,
                        frame.borderOverlay.left, frame.borderOverlay.right}) do
        t:SetSnapToPixelGrid(false)
        t:SetTexelSnappingBias(0)
    end

    -- Raid target marker (anchored to main frame, position from DB)
    frame._raidMarker = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    frame._raidMarker:SetSize(32, 32)
    frame._raidMarker:SetPoint("LEFT", frame, "LEFT", 0, 0)
    -- SetSpriteSheetCell (used by SetRaidTargetIconTexture) requires the sprite sheet file to be set first
    frame._raidMarker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    frame._raidMarker:Hide()

    -- Text layer (spell name + timer + caster name)
    local textF = CreateFrame("Frame", "ArcUIFocusCastbarText", UIParent)
    textF:SetFrameStrata("HIGH")
    textF:SetFrameLevel(200)
    textF:SetSize(w, h)
    textF:SetPoint("CENTER", frame, "CENTER", 0, 0)
    textF:Hide()
    textF.nameText = textF:CreateFontString(nil, "OVERLAY")
    textF.nameText:SetPoint("LEFT",  textF, "LEFT",  4, 0)
    textF.nameText:SetPoint("RIGHT", textF, "RIGHT", -42, 0)
    textF.nameText:SetJustifyH("LEFT")
    textF.nameText:SetJustifyV("MIDDLE")
    textF.timerText = textF:CreateFontString(nil, "OVERLAY")
    textF.timerText:SetPoint("RIGHT", textF, "RIGHT", -4, 0)
    textF.timerText:SetJustifyH("RIGHT")
    textF.timerText:SetJustifyV("MIDDLE")
    textF.casterText = textF:CreateFontString(nil, "OVERLAY")
    textF.casterText:SetPoint("TOPLEFT",  frame, "BOTTOMLEFT",  0, -2)
    textF.casterText:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -2)
    textF.casterText:SetJustifyH("RIGHT")
    textF.casterText:SetJustifyV("TOP")
    textF.focusTargetText = textF:CreateFontString(nil, "OVERLAY")
    textF.focusTargetText:SetPoint("TOPLEFT",  frame, "BOTTOMLEFT",  0, -14)
    textF.focusTargetText:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -14)
    textF.focusTargetText:SetJustifyH("RIGHT")
    textF.focusTargetText:SetJustifyV("TOP")
    textF.focusTargetText:Hide()
    frame._textFrame = textF

    -- Drag handle button (visible while options panel is open)
    local dragBtn = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    dragBtn:SetSize(16, 16)
    dragBtn:SetFrameStrata("HIGH")
    dragBtn:SetFrameLevel(210)
    dragBtn:SetPoint("TOPRIGHT", frame, "TOPLEFT", -2, 0)
    dragBtn:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8",
                         edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
    dragBtn:SetBackdropColor(0.2, 0.2, 0.2, 0.85)
    dragBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    local moveIcon = dragBtn:CreateTexture(nil, "OVERLAY")
    moveIcon:SetSize(12, 12)
    moveIcon:SetPoint("CENTER")
    moveIcon:SetTexture("Interface\\CURSOR\\UI-Cursor-Move")
    moveIcon:SetVertexColor(0.8, 0.8, 0.8, 1)
    local function DragHighlight()
        dragBtn:SetBackdropColor(0.15, 0.4, 0.7, 0.95)
        dragBtn:SetBackdropBorderColor(0.3, 0.7, 1, 1)
        moveIcon:SetVertexColor(1, 1, 1, 1)
    end
    local function DragNormal()
        dragBtn:SetBackdropColor(0.2, 0.2, 0.2, 0.85)
        dragBtn:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
        moveIcon:SetVertexColor(0.8, 0.8, 0.8, 1)
    end
    dragBtn:RegisterForDrag("LeftButton")
    dragBtn:SetScript("OnDragStart", function() frame:StartMoving(); DragHighlight() end)
    dragBtn:SetScript("OnDragStop",  function() frame:StopMovingOrSizing(); DragNormal(); SavePosition() end)
    dragBtn:SetScript("OnEnter", DragHighlight)
    dragBtn:SetScript("OnLeave", DragNormal)
    dragBtn:Hide()
    frame._dragHandle = dragBtn

    -- Bar-body drag (click anywhere on bar while options open)
    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and ns._arcUIOptionsOpen then self:StartMoving() end
    end)
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then self:StopMovingOrSizing(); SavePosition() end
    end)

    mainFrame = frame
end

-- ===================================================================
-- FOCUS TARGET TEXT  (who the focus is targeting during a cast)
-- ===================================================================
local function UpdateFocusTargetText()
    if not mainFrame or not mainFrame._textFrame then return end
    local textF = mainFrame._textFrame
    if not textF.focusTargetText then return end
    local cfg = GetDB()
    if not (cfg and cfg.showFocusTarget and castActive) then
        textF.focusTargetText:Hide()
        return
    end
    local targetName = UnitName("focustarget")
    textF.focusTargetText:SetText(targetName or "")
    if targetName then
        textF.focusTargetText:Show()
    else
        textF.focusTargetText:Hide()
    end
end

-- ===================================================================
-- APPLY APPEARANCE / POSITION
-- ===================================================================
local function ApplyAppearanceInternal(cfg)
    local w = cfg.width  or 220
    local h = cfg.height or 18
    mainFrame:SetSize(w, h)
    mainFrame:SetFrameStrata(cfg.barFrameStrata or "MEDIUM")

    local textF = mainFrame._textFrame
    if textF then
        textF:SetSize(w, h)
        -- Spell name: dynamic width constraint (0 = full auto width)
        textF.nameText:ClearAllPoints()
        local nmw = cfg.spellNameMaxWidth or 0
        if nmw > 0 then
            textF.nameText:SetPoint("LEFT", textF, "LEFT", 4, 0)
            textF.nameText:SetWidth(nmw)
        else
            textF.nameText:SetPoint("LEFT",  textF, "LEFT",  4,   0)
            textF.nameText:SetPoint("RIGHT", textF, "RIGHT", -42, 0)
        end
        -- Caster name: anchor side + offset
        textF.casterText:ClearAllPoints()
        local cxo   = cfg.casterNameOffsetX or 0
        local cyo   = cfg.casterNameOffsetY or 0
        local cAnch = cfg.casterNameAnchor or "RIGHT"
        if cAnch == "LEFT" then
            textF.casterText:SetPoint("TOPLEFT", mainFrame, "BOTTOMLEFT",  cxo, -2 + cyo)
            textF.casterText:SetJustifyH("LEFT")
        elseif cAnch == "CENTER" then
            textF.casterText:SetPoint("TOP",     mainFrame, "BOTTOM",       cxo, -2 + cyo)
            textF.casterText:SetJustifyH("CENTER")
        else
            textF.casterText:SetPoint("TOPRIGHT", mainFrame, "BOTTOMRIGHT", cxo, -2 + cyo)
            textF.casterText:SetJustifyH("RIGHT")
        end
        -- Focus target: anchor side + offset
        if textF.focusTargetText then
            textF.focusTargetText:ClearAllPoints()
            local fxo   = cfg.focusTargetOffsetX or 0
            local fyo   = cfg.focusTargetOffsetY or 0
            local fAnch = cfg.focusTargetAnchor or "RIGHT"
            if fAnch == "LEFT" then
                textF.focusTargetText:SetPoint("TOPLEFT",  mainFrame, "BOTTOMLEFT",  fxo, -14 + fyo)
                textF.focusTargetText:SetJustifyH("LEFT")
            elseif fAnch == "CENTER" then
                textF.focusTargetText:SetPoint("TOP",      mainFrame, "BOTTOM",       fxo, -14 + fyo)
                textF.focusTargetText:SetJustifyH("CENTER")
            else
                textF.focusTargetText:SetPoint("TOPRIGHT", mainFrame, "BOTTOMRIGHT",  fxo, -14 + fyo)
                textF.focusTargetText:SetJustifyH("RIGHT")
            end
        end
    end

    local tex = (LSM and cfg.texture and cfg.texture ~= ""
                 and LSM:Fetch("statusbar", cfg.texture))
                or "Interface\\TargetingFrame\\UI-StatusBar"
    mainFrame.fillBar:SetStatusBarTexture(tex)
    mainFrame.positioner:SetStatusBarTexture(tex)

    local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    mainFrame.fillBar:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a or 1)

    if cfg.showBackground then
        local bg = cfg.backgroundColor or {r=0.1,g=0.1,b=0.1,a=0.9}
        mainFrame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a or 0.9)
        mainFrame.bg:Show()
    else
        mainFrame.bg:Hide()
    end

    ApplyBorder(mainFrame, cfg)

    local kc = cfg.kickTickColor or {r=1,g=1,b=1,a=1}
    mainFrame.kickTick:SetColorTexture(kc.r, kc.g, kc.b, kc.a or 1)
    mainFrame.kickTick:SetHeight(h)

    local fontPath = (LSM and cfg.font and LSM:Fetch("font", cfg.font)) or STANDARD_TEXT_FONT
    local fSize    = cfg.fontSize    or 11
    local outline  = cfg.textOutline or "THICKOUTLINE"
    local tc       = cfg.textColor   or {r=1,g=1,b=1,a=1}
    if textF then
        textF.nameText:SetFont(fontPath, fSize, outline)
        textF.nameText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
        textF.timerText:SetFont(fontPath, fSize, outline)
        textF.timerText:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
        local smallSize = math.max(8, fSize - 2)
        textF.casterText:SetFont(fontPath, smallSize, outline)
        textF.casterText:SetTextColor(1, 0.82, 0, 1)
        if textF.focusTargetText then
            textF.focusTargetText:SetFont(fontPath, smallSize, outline)
            textF.focusTargetText:SetTextColor(0.6, 0.8, 1, 1)
        end
    end

    ApplyRaidMarkerSettings()
    RebuildColorObjects(cfg)
    UpdateFocusTargetText()
end

function FC.ApplyAppearance()
    if not mainFrame then return end
    local cfg = GetDB()
    if not cfg then return end
    if not cfg.enabled then
        mainFrame:Hide()
        mainFrame:EnableMouse(false)
        if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
        if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
        if mainFrame._iconFrame  then mainFrame._iconFrame:Hide()  end
        if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
        if ns.Glows then
            ns.Glows.Stop(mainFrame, GLOW_KEY)
            ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
        end
        mainFrame:SetScript("OnUpdate", nil)
        return
    end
    ApplyAppearanceInternal(cfg)
    mainFrame:EnableMouse(ns._arcUIOptionsOpen or false)
    FC.ApplyPosition()
    if ns._arcUIOptionsOpen and not castActive and not holdActive then
        FC.ShowPreview()
    end
end

-- ===================================================================
-- ONUPDATE — real cast timer (bar driven by SetTimerDuration; we update text + kick)
-- ===================================================================
local function OnUpdate()
    local cfg = GetDB()
    if not cfg or not castActive then return end

    local duration = mainFrame.fillBar:GetTimerDuration()
    if not duration then return end

    -- Timer text via SetFormattedText (secret-safe sink for duration values)
    local textF = mainFrame._textFrame
    if textF and cfg.showTimer then
        textF.timerText:SetFormattedText("%.1f", duration:GetRemainingDuration())
    end

    -- Positioner mirrors elapsed for kick-tick anchor (SetValue is a secret-safe sink)
    if not isChannel then
        mainFrame.positioner:SetValue(duration:GetElapsedDuration())
    end

    UpdateKickAndColor(cfg)
end

-- ===================================================================
-- PREVIEW ANIMATION  (looping, 3-second fake cast)
-- ===================================================================
local PREVIEW_DURATION = 3.0

local function PreviewOnUpdate()
    if not mainFrame then return end
    -- Self-stop: if options panel closed (or callback chain failed), kill preview immediately.
    if not ns._arcUIOptionsOpen then
        mainFrame:SetScript("OnUpdate", nil)
        if mainFrame._textFrame then mainFrame._textFrame:Hide() end
        if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
        if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
        if ns.Glows then
            ns.Glows.Stop(mainFrame, GLOW_KEY)
            ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
        end
        mainFrame:EnableMouse(false)
        mainFrame:Hide()
        return
    end
    local elapsed = GetTime() - castStart
    if elapsed >= PREVIEW_DURATION then
        castStart = GetTime()
        elapsed   = 0
    end
    mainFrame.fillBar:SetValue(elapsed / PREVIEW_DURATION)
    local cfg = GetDB()
    local textF = mainFrame._textFrame
    if textF and cfg and cfg.showTimer then
        textF.timerText:SetText(string.format("%.1f", PREVIEW_DURATION - elapsed))
    end
end

-- ===================================================================
-- HOLD TIMER  (freeze bar for a moment after cast ends)
-- ===================================================================
local function CancelHoldTimer()
    if holdTimer then holdTimer:Cancel(); holdTimer = nil end
    holdActive = false
end

-- Returns true if hold timer was started.
local function StartHoldTimer(cfg, endReason)
    CancelHoldTimer()
    if not (cfg.holdEnabled and cfg.holdDuration and cfg.holdDuration > 0) then
        return false
    end
    holdActive = true

    local texture = mainFrame.fillBar:GetStatusBarTexture()
    local col
    if endReason == "interrupted" then
        col = cfg.holdInterruptedColor or {r=0.2,g=0.4,b=1,a=1}
        mainFrame.fillBar:SetValue(1)
        if mainFrame._textFrame then
            mainFrame._textFrame.timerText:SetText("")
            mainFrame._textFrame.nameText:SetText("Interrupted!")
        end
    elseif endReason == "failed" then
        col = cfg.holdFailColor or {r=1,g=0.5,b=0,a=1}
        if mainFrame._textFrame then mainFrame._textFrame.timerText:SetText("") end
    else
        col = cfg.holdSuccessColor or {r=0.2,g=1,b=0.2,a=1}
        mainFrame.fillBar:SetValue(1)
        if mainFrame._textFrame then mainFrame._textFrame.timerText:SetText("") end
    end
    if texture then texture:SetVertexColor(col.r, col.g, col.b, col.a or 1) end
    mainFrame.kickTick:SetAlpha(0)

    holdTimer = C_Timer.NewTimer(cfg.holdDuration, function()
        holdTimer  = nil
        holdActive = false
        if not castActive then
            if mainFrame then mainFrame:Hide() end
            if mainFrame and mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
            if mainFrame and mainFrame._iconFrame  then mainFrame._iconFrame:Hide()  end
            if mainFrame and mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
            if ns.Glows then
                ns.Glows.Stop(mainFrame, GLOW_KEY)
                ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
            end
            if ns._arcUIOptionsOpen then FC.ShowPreview() end
        end
    end)
    return true
end

-- ===================================================================
-- SHOW / HIDE CAST
-- ===================================================================
local function ShowCast(channel)
    if not mainFrame then return end
    local cfg = GetDB()
    if not cfg or not cfg.enabled then return end
    CancelHoldTimer()
    castWasInterrupted = false

    local name, text, notInt, spellID, isEmpowered
    local duration
    local direction = Enum.StatusBarTimerDirection.ElapsedTime

    if channel then
        -- UnitChannelInfo: name,text,texture,startMS,endMS,isTradeSkill,notInterruptible,spellID,isEmpowered,...
        name, text, _, _, _, _, notInt, spellID, isEmpowered = UnitChannelInfo("focus")
        if name then
            if isEmpowered and UnitEmpoweredChannelDuration then
                duration = UnitEmpoweredChannelDuration("focus")
            else
                duration  = UnitChannelDuration("focus")
                direction = Enum.StatusBarTimerDirection.RemainingTime
            end
        end
    else
        -- UnitCastingInfo: name,text,texture,startMS,endMS,isTradeSkill,castID,notInterruptible,spellID
        name, text, _, _, _, _, _, notInt, spellID = UnitCastingInfo("focus")
        if name then
            duration = UnitCastingDuration("focus")
        end
    end

    if not name or not duration then return end

    isChannel              = channel or false
    cachedDuration         = duration
    castActive             = true
    currentSpellID         = spellID
    state_notInterruptible = notInt  -- secret boolean; never compared directly
    RebuildColorObjects(cfg)

    if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
    mainFrame:EnableMouse(false)
    mainFrame:SetAlpha(1)

    local textF = mainFrame._textFrame
    if textF then
        textF.nameText:SetText(cfg.showSpellName   and (text or name) or "")
        textF.casterText:SetText(cfg.showCasterName and UnitName("focus") or "")
        textF:Show()
    end
    UpdateFocusTargetText()

    local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    local fillTex = mainFrame.fillBar:GetStatusBarTexture()
    if fillTex then fillTex:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1) end

    if cfg.hideNotInterruptible then
        mainFrame:SetAlphaFromBoolean(state_notInterruptible, 0, 1)
    end

    -- Drive bar animation automatically via the duration object
    mainFrame.fillBar:SetTimerDuration(duration, Enum.StatusBarInterpolation.Immediate, direction)

    -- Positioner mirrors cast elapsed time for kick-tick anchoring
    mainFrame.positioner:SetMinMaxValues(0, duration:GetTotalDuration())
    mainFrame.positioner:SetReverseFill(isChannel)
    mainFrame.positioner:SetValue(0)

    UpdateRaidMarker(false)
    mainFrame.kickTick:SetAlpha(0)
    SetupKickBar(cfg)

    if cfg.showGlow and ns.Glows then
        local gc = cfg.glowColor or {r=1,g=0.65,b=0,a=1}
        ns.Glows.Start(mainFrame, GLOW_KEY, cfg.glowType or "pixel", {
            color      = {gc.r, gc.g, gc.b, gc.a or 1},
            thickness  = cfg.glowWidth     or 2,
            lines      = cfg.glowLines     or 8,
            frequency  = cfg.glowFrequency or 0.25,
            frameLevel = 15,
        })
    elseif ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
    end

    if spellID then UpdateImportantGlow(spellID, cfg, false) end

    mainFrame:Show()
    mainFrame._textFrame:Show()
    mainFrame:SetScript("OnUpdate", OnUpdate)
end

local function EndCast(endReason)
    if not castActive then return end
    if not mainFrame or not mainFrame:IsShown() then castActive = false; return end
    if holdTimer then return end
    castActive = false
    cachedDuration = nil
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.kickTick:SetAlpha(0)
    local cfg = GetDB()
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
    end
    if mainFrame._iconFrame  then mainFrame._iconFrame:Hide()  end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
    if cfg and not StartHoldTimer(cfg, endReason) then
        mainFrame:Hide()
        if mainFrame._textFrame then mainFrame._textFrame:Hide() end
        if ns._arcUIOptionsOpen then FC.ShowPreview() end
    end
end

local function HideCast()
    castActive = false
    cachedDuration = nil
    CancelHoldTimer()
    if not mainFrame then return end
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fillBar:SetValue(0)
    mainFrame.kickTick:SetAlpha(0)
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
    end
    if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
    if mainFrame._iconFrame  then mainFrame._iconFrame:Hide()  end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
    mainFrame:Hide()
    if ns._arcUIOptionsOpen then FC.ShowPreview() end
end

-- ===================================================================
-- EVENTS
-- ===================================================================
local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(_, event, unit, ...)
    if event == "PLAYER_SPECIALIZATION_CHANGED"
    or event == "ZONE_CHANGED_NEW_AREA"
    or event == "LOADING_SCREEN_DISABLED" then
        CacheInterruptId()
        return
    end

    if event == "EDIT_MODE_ENTERED" then
        -- Only show preview when the ArcUI panel is open, or when the user explicitly
        -- entered WoW's native Edit Mode (not triggered by LibEQOL drag mode).
        local nativeEM = EditModeManagerFrame and EditModeManagerFrame:IsShown()
        if not castActive and not holdActive and (ns._arcUIOptionsOpen or nativeEM) then
            FC.ShowPreview()
        end
        return
    end
    if event == "EDIT_MODE_EXITED" then
        if not castActive and not holdActive and not ns._arcUIOptionsOpen then FC.HidePreview() end
        return
    end

    if event == "RAID_TARGET_UPDATE" then
        if castActive then UpdateRaidMarker(false) end
        return
    end

    if event == "PLAYER_FOCUS_CHANGED" then
        if ns._arcUIOptionsOpen then
            -- Keep preview alive; just refresh the raid marker for the new focus
            UpdateRaidMarker(true)
            return
        end
        castWasInterrupted = false
        CancelHoldTimer()
        HideCast()
        local n = UnitCastingInfo("focus")
        if n then ShowCast(false); return end
        local cn = UnitChannelInfo("focus")
        if cn then ShowCast(true); return end
        -- UnitCastingInfo can return nil right at the moment focus changes; retry briefly.
        C_Timer.After(0.1, function()
            if castActive then return end
            local n2 = UnitCastingInfo("focus")
            if n2 then ShowCast(false); return end
            local cn2 = UnitChannelInfo("focus")
            if cn2 then ShowCast(true) end
        end)
        UpdateFocusTargetText()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        HideCast()
        local n = UnitCastingInfo("focus")
        if n then ShowCast(false); return end
        local cn = UnitChannelInfo("focus")
        if cn then ShowCast(true) end
        return
    end

    if unit ~= "focus" then return end

    if event == "UNIT_SPELLCAST_START" then
        castWasInterrupted = false
        ShowCast(false)

    elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
        castWasInterrupted = false
        ShowCast(true)

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        if castActive then
            castWasInterrupted = true
            EndCast("interrupted")
        end

    elseif event == "UNIT_SPELLCAST_STOP" then
        -- STOP fires after INTERRUPTED for the same cast — ignore if already handled
        if castActive and not castWasInterrupted then
            EndCast("success")
        end
        castWasInterrupted = false

    elseif event == "UNIT_SPELLCAST_FAILED" then
        castWasInterrupted = false
        EndCast("failed")

    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        castWasInterrupted = false
        EndCast("success")

    elseif event == "UNIT_SPELLCAST_DELAYED" then
        -- Cast pushed back — re-query to get the updated duration object
        if not castActive or isChannel then return end
        ShowCast(false)

    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        -- Haste changed mid-channel — re-query to get the updated duration object
        if not castActive or not isChannel then return end
        ShowCast(true)

    elseif event == "UNIT_TARGET" then
        UpdateFocusTargetText()

    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE"
        or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        if not castActive or not mainFrame then return end
        -- Refresh the stored secret boolean from the appropriate API
        local newNotInt
        if isChannel then
            local _,_,_,_,_,_, ni = UnitChannelInfo("focus")
            newNotInt = ni
        else
            local _,_,_,_,_,_,_, ni = UnitCastingInfo("focus")
            newNotInt = ni
        end
        state_notInterruptible = newNotInt
        local cfg = GetDB()
        if cfg then
            if cfg.hideNotInterruptible then
                mainFrame:SetAlphaFromBoolean(state_notInterruptible, 0, 1)
            end
            UpdateBarColor(cfg, nil)
        end
    end
end)

-- ===================================================================
-- PUBLIC LIFECYCLE
-- ===================================================================
function FC.Enable()
    if isEnabled then return end
    isEnabled = true
    CreateFocusFrames()
    CacheInterruptId()
    FC.ApplyAppearance()
    eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("LOADING_SCREEN_DISABLED")
    eventFrame:RegisterEvent("RAID_TARGET_UPDATE")
    -- Global registration so events fire reliably for the "focus" unit token.
    -- The handler filters with `if unit ~= "focus" then return end`.
    -- RegisterUnitEvent("focus") guarantees unit="focus" in the handler for NPC focus targets.
    -- Global RegisterEvent fires with the mob's internal token (nameplate5, boss1, etc.),
    -- which our unit~="focus" guard would drop, causing missed STOP/START events.
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START",             "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_STOP",              "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED",            "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED",       "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START",     "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP",      "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_DELAYED",           "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_UPDATE",    "focus")
    eventFrame:RegisterUnitEvent("UNIT_TARGET",                      "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTIBLE",     "focus")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE", "focus")
    -- Check if the focus is already mid-cast when the feature is first enabled
    local n = UnitCastingInfo("focus")
    if n then ShowCast(false); return end
    local cn = UnitChannelInfo("focus")
    if cn then ShowCast(true) end
end

function FC.Disable()
    if not isEnabled then return end
    isEnabled = false
    HideCast()
    eventFrame:UnregisterAllEvents()
    -- Keep Edit Mode events so the bar still shows for positioning
    eventFrame:RegisterEvent("EDIT_MODE_ENTERED")
    eventFrame:RegisterEvent("EDIT_MODE_EXITED")
end

-- ===================================================================
-- PREVIEW  (shown whenever options panel is open or WoW Edit Mode active)
-- ===================================================================
function FC.ShowPreview()
    if castActive or holdActive then return end
    -- Only show the preview when the options panel is open, or in native WoW Edit Mode.
    -- This is the authoritative gate: nothing should display a preview otherwise.
    local nativeEM = EditModeManagerFrame and EditModeManagerFrame:IsShown()
    if not ns._arcUIOptionsOpen and not nativeEM then return end
    CreateFocusFrames()
    if not mainFrame then return end
    local cfg = GetDB()
    if not cfg or not cfg.enabled then return end

    ApplyAppearanceInternal(cfg)
    FC.ApplyPosition()
    RebuildColorObjects(cfg)

    mainFrame:EnableMouse(true)
    mainFrame:SetAlpha(1)

    -- Only reset animation clock on first entry; keep it running across setting changes
    if mainFrame:GetScript("OnUpdate") ~= PreviewOnUpdate then
        castStart = GetTime()
        mainFrame:SetScript("OnUpdate", PreviewOnUpdate)
    end

    local bc      = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    local fillTex = mainFrame.fillBar:GetStatusBarTexture()
    if fillTex then fillTex:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1) end

    local textF = mainFrame._textFrame
    if textF then
        textF.nameText:SetText(cfg.showSpellName    and "Focus Castbar" or "")
        textF.casterText:SetText(cfg.showCasterName and "Focus Target"  or "")
        textF:Show()
    end

    -- Raid marker: show configured default (moon=8) in preview for positioning
    if cfg.showRaidMarker then
        local defIdx = cfg.raidMarkerDefault or 8
        if defIdx > 0 then
            ApplyRaidMarkerSettings()
            ---@diagnostic disable-next-line: undefined-global
            SetRaidTargetIconTexture(mainFrame._raidMarker, defIdx)
            mainFrame._raidMarker:Show()
        else
            mainFrame._raidMarker:Hide()
        end
    end

    -- Focus target placeholder in preview
    if textF and textF.focusTargetText then
        if cfg.showFocusTarget then
            textF.focusTargetText:SetText("Enemy Name")
            textF.focusTargetText:Show()
        else
            textF.focusTargetText:Hide()
        end
    end

    -- Always show a glow outline in preview so the bar is easy to see and position
    if ns.Glows then
        local gc = cfg.showGlow and cfg.glowColor or {r=1, g=0.65, b=0, a=1}
        ns.Glows.Start(mainFrame, GLOW_KEY, cfg.glowType or "pixel", {
            color      = {gc.r, gc.g, gc.b, gc.a or 1},
            thickness  = cfg.glowWidth     or 2,
            lines      = cfg.glowLines     or 8,
            frequency  = cfg.glowFrequency or 0.25,
            frameLevel = 15,
        })
    end

    -- Important spell glow shown in preview if enabled (so user can tune it)
    UpdateImportantGlow(nil, cfg, cfg.importantGlowEnabled)

    mainFrame.kickTick:SetAlpha(0)
    if mainFrame._dragHandle then mainFrame._dragHandle:Show() end
    mainFrame:Show()
end

function FC.HidePreview()
    if not mainFrame then return end
    if castActive or holdActive then return end
    mainFrame:SetScript("OnUpdate", nil)
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        ns.Glows.Stop(mainFrame, IMP_GLOW_KEY)
    end
    mainFrame:EnableMouse(false)
    if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
    if mainFrame._iconFrame  then mainFrame._iconFrame:Hide()  end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
    if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
    mainFrame.kickTick:SetAlpha(0)
    mainFrame:Hide()
end

-- ===================================================================
-- INIT
-- ===================================================================
function FC.Init()
    if isInitialized then return end
    isInitialized = true
    CreateFocusFrames()
    CacheInterruptId()
    -- Always listen for Edit Mode so the bar shows for positioning even when disabled
    eventFrame:RegisterEvent("EDIT_MODE_ENTERED")
    eventFrame:RegisterEvent("EDIT_MODE_EXITED")
    local cfg = GetDB()
    if cfg and cfg.enabled then FC.Enable() end
    if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
        ns.CDMShared.RegisterPanelCallback("FocusCastbar", {
            onOpen  = FC.ShowPreview,
            onClose = FC.HidePreview,
        })
    end
    FC.ApplyAppearance()
end

-- ===================================================================
-- DEBUG SLASH COMMAND  (/arcfcdebug)
-- ===================================================================
SLASH_ARCFCDEBUG1 = "/arcfcdebug"
SlashCmdList["ARCFCDEBUG"] = function()
    local cfg = GetDB()
    local castName, _, _, sT, eT = UnitCastingInfo("focus")
    local chanName, _, _, csT, ceT = UnitChannelInfo("focus")
    local focusName = UnitName("focus") or "none"
    print("|cff00ff00[ArcFC]|r Debug dump:")
    print("  cfg.enabled=" .. tostring(cfg and cfg.enabled))
    print("  events registered (isEnabled)=" .. tostring(isEnabled))
    print("  isInitialized=" .. tostring(isInitialized))
    print("  castActive=" .. tostring(castActive))
    print("  focus unit=" .. focusName)
    print("  UnitCastingInfo: name=" .. tostring(castName) .. " startMS=" .. tostring(sT) .. " endMS=" .. tostring(eT))
    print("  UnitChannelInfo: name=" .. tostring(chanName) .. " startMS=" .. tostring(csT) .. " endMS=" .. tostring(ceT))
    print("  hideNotInterruptible=" .. tostring(cfg and cfg.hideNotInterruptible))
    print("  ns._arcUIOptionsOpen=" .. tostring(ns._arcUIOptionsOpen))
    if not (cfg and cfg.enabled) then
        print("|cffff4444[ArcFC]|r Feature is DISABLED. Enable via /arcui → Castbar → Focus Castbar.")
    elseif not isEnabled then
        print("|cffff4444[ArcFC]|r Events not registered. Try /reload.")
    elseif cfg and cfg.hideNotInterruptible then
        print("|cffffff00[ArcFC]|r WARNING: hideNotInterruptible=true — bar is invisible for non-interruptible casts.")
    else
        print("|cff00ff00[ArcFC]|r Feature is enabled and events are registered.")
    end
end
