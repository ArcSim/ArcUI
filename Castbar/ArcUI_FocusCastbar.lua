-- ===================================================================
-- ArcUI_FocusCastbar.lua
-- Castbar tracking what the focus target is casting.
-- Uses the WoW 12.0 duration-object model: the StatusBar knows its own
-- end time and fills itself, so OnUpdate only reads state.
-- Zero idle CPU: all timers/OnUpdate only run during an active cast
-- or preview. Events unregistered when disabled.
-- ===================================================================

local ADDON, ns = ...
ns.FocusCastbar = ns.FocusCastbar or {}
local FC = ns.FocusCastbar

local LSM          = LibStub and LibStub("LibSharedMedia-3.0", true)
local GLOW_KEY     = "_arcFCastGlow"
local IMP_GLOW_KEY = "_arcFCastImpGlow"

local FALLBACK_ICON     = 136243
local INTERRUPTED       = "Interrupted"
local INTERRUPTED_BY    = "Interrupted by %s"
local PREVIEW_DURATION  = 20   -- NorskenUI-style long preview cast

-- Locals for hot paths
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local UnitCastingDuration, UnitChannelDuration = UnitCastingDuration, UnitChannelDuration
local UnitEmpoweredChannelDuration = UnitEmpoweredChannelDuration
local UnitExists, UnitName, UnitClass = UnitExists, UnitName, UnitClass
local GetRaidTargetIndex = GetRaidTargetIndex
local GetTime = GetTime
local select, ipairs = select, ipairs
local random = math.random

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
local mainFrame     = nil
local isEnabled     = false
local isInitialized = false

-- Active-cast state (NorskenUI-style tri-flag)
local casting       = nil
local channeling    = nil
local empowering    = nil
local currentSpellID = nil
local cachedDuration = nil   -- the live duration object for the current cast/preview

-- Secret boolean from Unit*Info; only ever passed to WoW safe-sink APIs, never compared
local state_notInterruptible = nil

local interruptId   = nil    -- player's interrupt spell ID

-- Hold timer (freeze bar briefly after a cast ends)
local holdTimer     = nil
local holdActive    = false

-- Preview state
local isPreview     = false
local previewTicker    = nil
local previewHoldTimer = nil

-- Cached Color objects (rebuilt when bar color settings change)
local castColorObj     = nil
local unintColorObj    = nil
local notReadyColorObj = nil

-- Update throttle (NorskenUI uses 0.1s for text; tick/kick run every frame)
local UPDATE_THROTTLE = 0.1
local updateElapsed   = 0

-- Forward declarations (called before definition)
local EndCast
local StartCast
local UpdateKickAndColor

-- ===================================================================
-- DB
-- ===================================================================
local function GetDB()
    return ns.db and ns.db.char and ns.db.char.focusCastbar
end

-- ===================================================================
-- STATE RESET
-- ===================================================================
local function ResetCastState()
    casting, channeling, empowering = nil, nil, nil
    currentSpellID = nil
    state_notInterruptible = nil
    cachedDuration = nil
end

local function HasActiveCast()
    return casting or channeling or empowering
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
           and (C_SpellBook.IsSpellKnownOrInSpellBook(id)
                or C_SpellBook.IsSpellKnownOrInSpellBook(id, Enum.SpellBookSpellBank.Pet)) then
            interruptId = id
            return
        end
    end
end

-- ===================================================================
-- COLOR OBJECTS (rebuilt whenever bar colors change)
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
-- BAR COLOR (all secret boolean paths use WoW 12.0 safe-sink APIs)
-- ===================================================================
local function UpdateBarColor(cfg, kickCooldown)
    if not mainFrame then return end
    local texture = mainFrame.fillBar:GetStatusBarTexture()
    if not texture then return end

    if isPreview then
        local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
        texture:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1)
        return
    end

    if kickCooldown and cfg.kickEnabled and interruptId and HasActiveCast() then
        -- EvaluateColorFromBoolean: castColor when kick is ready, notReady when on CD
        local kickColor = C_CurveUtil.EvaluateColorFromBoolean(
            kickCooldown:IsZero(), castColorObj, notReadyColorObj)
        if cfg.uninterruptibleEnabled then
            texture:SetVertexColorFromBoolean(state_notInterruptible, unintColorObj, kickColor)
        else
            texture:SetVertexColorFromBoolean(kickCooldown:IsZero(), castColorObj, notReadyColorObj)
        end
        return
    end

    if cfg.uninterruptibleEnabled and HasActiveCast() then
        texture:SetVertexColorFromBoolean(state_notInterruptible, unintColorObj, castColorObj)
        return
    end

    local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    texture:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1)
end

-- ===================================================================
-- KICK INDICATOR
-- Positioner mirrors cast progress (via duration object) so the kick
-- cooldown bar and tick anchor from the live fill position.
-- ===================================================================
local function SetupKickBar(cfg)
    if not (cfg.kickEnabled and interruptId) then
        mainFrame.kickTick:SetAlpha(0)
        return
    end
    local duration = cachedDuration
    if not duration then
        mainFrame.kickTick:SetAlpha(0)
        return
    end

    local h = cfg.height or 18
    local isChan = channeling or false

    mainFrame.kickTick:SetHeight(h)
    local kc = cfg.kickTickColor or {r=1,g=1,b=1,a=1}
    mainFrame.kickTick:SetColorTexture(kc.r, kc.g, kc.b, kc.a or 1)

    -- total is a SECRET number for focus casts — safe to pass to SetMinMaxValues,
    -- never to compare. SetMinMaxValues accepts secrets as a safe sink.
    local total = duration:GetTotalDuration()

    mainFrame.positioner:SetMinMaxValues(0, total)
    mainFrame.positioner:SetReverseFill(isChan)

    mainFrame.kickCooldownBar:ClearAllPoints()
    mainFrame.kickCooldownBar:SetMinMaxValues(0, total)
    mainFrame.kickCooldownBar:SetReverseFill(isChan)
    mainFrame.kickCooldownBar:SetPoint("TOP",    mainFrame.fillBar, "TOP")
    mainFrame.kickCooldownBar:SetPoint("BOTTOM", mainFrame.fillBar, "BOTTOM")

    mainFrame.kickTick:ClearAllPoints()
    mainFrame.kickTick:SetSize(2, h)

    if isChan then
        mainFrame.kickCooldownBar:SetPoint("RIGHT", mainFrame.positioner:GetStatusBarTexture(), "LEFT")
        mainFrame.kickTick:SetPoint("RIGHT", mainFrame.kickCooldownBar:GetStatusBarTexture(), "LEFT")
    else
        mainFrame.kickCooldownBar:SetPoint("LEFT", mainFrame.positioner:GetStatusBarTexture(), "RIGHT")
        mainFrame.kickTick:SetPoint("LEFT", mainFrame.kickCooldownBar:GetStatusBarTexture(), "RIGHT")
    end
end

-- Called every frame from OnUpdate while a cast is active.
UpdateKickAndColor = function(cfg)
    if isPreview then return end
    if not (cfg.kickEnabled and interruptId and HasActiveCast()) then
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
    -- secret via SetValue safe sink
    mainFrame.kickCooldownBar:SetValue(cooldown:GetRemainingDuration())
    -- 0 = hidden when kick ready; visible (but hidden on uninterruptible) otherwise
    mainFrame.kickTick:SetAlphaFromBoolean(cooldown:IsZero(), 0,
        C_CurveUtil.EvaluateColorValueFromBoolean(state_notInterruptible, 0, 1))
    UpdateBarColor(cfg, cooldown)
end

-- Advance the positioner (kick-tick anchor) from the live duration object.
-- GetElapsedDuration is a SECRET number for focus casts; SetValue is a safe sink.
local function UpdateTickPosition(cfg, duration)
    if not (cfg.kickEnabled and interruptId) then return end
    mainFrame.positioner:SetValue(duration:GetElapsedDuration())
end

-- ===================================================================
-- IMPORTANT SPELL GLOW
-- C_Spell.IsSpellImportant returns a SECRET boolean in 12.0 — it must
-- never be tested in Lua (doing so taints and errors). Instead we start
-- the glow on a dedicated host frame and toggle only its alpha via the
-- SetAlphaFromBoolean safe sink, exactly as NorskenUI does.
-- ===================================================================
local function StartImportantGlowVisual(cfg)
    if not (ns.Glows and mainFrame.impGlowHost) then return end
    local gc = cfg.importantGlowColor or {r=1,g=0.2,b=0.2,a=1}
    ns.Glows.Start(mainFrame.impGlowHost, IMP_GLOW_KEY, cfg.importantGlowType or "pixel", {
        color      = {gc.r, gc.g, gc.b, gc.a or 1},
        lines      = cfg.importantGlowLines or 8,
        frequency  = cfg.importantGlowFrequency or 0.25,
        thickness  = cfg.importantGlowThickness or 2,
        frameLevel = 15,
    })
end

local function StopImportantGlowVisual()
    if ns.Glows and mainFrame.impGlowHost then
        ns.Glows.Stop(mainFrame.impGlowHost, IMP_GLOW_KEY)
    end
    if mainFrame.impGlowHost then mainFrame.impGlowHost:SetAlpha(0) end
end

-- Apply the main glow outline from current settings, respecting the showGlow
-- toggle. We Stop before Start so option changes (color/width/lines/frequency)
-- re-apply immediately: ns.Glows.Start only rebuilds a running glow when the
-- TYPE changes, so a same-type param tweak would otherwise not take effect until
-- a full stop/restart (panel reopen).
local function RefreshGlow(cfg)
    if not (mainFrame and ns.Glows) then return end
    ns.Glows.Stop(mainFrame, GLOW_KEY)
    if cfg.showGlow then
        local gc = cfg.glowColor or {r=1, g=0.65, b=0, a=1}
        ns.Glows.Start(mainFrame, GLOW_KEY, cfg.glowType or "pixel", {
            color      = {gc.r, gc.g, gc.b, gc.a or 1},
            thickness  = cfg.glowWidth     or 2,
            lines      = cfg.glowLines     or 8,
            frequency  = cfg.glowFrequency or 0.25,
            frameLevel = 15,
        })
    end
end

-- Real-cast path: spellID is a secret number; its importance is a secret
-- boolean. We pass that secret straight to SetAlphaFromBoolean and never
-- branch on it.
local function UpdateImportantGlow(spellID, cfg)
    if not (cfg.importantGlowEnabled and ns.Glows and mainFrame.impGlowHost) then
        StopImportantGlowVisual()
        return
    end
    -- Start the glow animation unconditionally, then reveal/hide the host
    -- based on the secret importance boolean (0 = hidden, 1 = shown).
    StartImportantGlowVisual(cfg)
    if C_Spell and C_Spell.IsSpellImportant and spellID then
        local isImportant = C_Spell.IsSpellImportant(spellID) -- secret boolean, never tested
        mainFrame.impGlowHost:SetAlphaFromBoolean(isImportant, 1, 0)
    else
        mainFrame.impGlowHost:SetAlpha(0)
    end
end

-- Real-cast path: spell importance and interruptibility may be secret
-- booleans. We combine them through C_CurveUtil and pass the resulting
-- secret alpha directly to safe-sink UI APIs, without branching on
-- either secret value.
--
-- When "Hide Non-Important Casts" is enabled, Blizzard must mark the
-- spell as important. When "Hide Non-Interruptible Casts" is enabled,
-- the cast must also be interruptible.
local function UpdateImportantCastVisibility(spellID, cfg)
    if not mainFrame then return end

    local alpha

    if cfg.hideNotImportant then
        if not (C_Spell and C_Spell.IsSpellImportant and spellID) then
            alpha = 0
        else
            local isImportant = C_Spell.IsSpellImportant(spellID) -- secret boolean, never tested
            local importantAlpha = C_CurveUtil.EvaluateColorValueFromBoolean(isImportant, 1, 0)

            if cfg.hideNotInterruptible then
                -- Visible only when important AND interruptible.
                alpha = C_CurveUtil.EvaluateColorValueFromBoolean(state_notInterruptible, 0, importantAlpha)
            else
                -- Visible whenever the cast is important.
                alpha = importantAlpha
            end
        end
    elseif cfg.hideNotInterruptible then
        -- Importance is ignored, but the cast must be interruptible.
        alpha = C_CurveUtil.EvaluateColorValueFromBoolean(state_notInterruptible, 0, 1)
    else
        -- Neither visibility filter is enabled.
        alpha = 1
    end

    mainFrame:SetAlpha(alpha)
    if mainFrame._textFrame then
        mainFrame._textFrame:SetAlpha(alpha)
    end
end

-- Preview path: no secret values involved. `show` is a plain boolean.
local function UpdateImportantGlowPreview(cfg, show)
    if not (cfg.importantGlowEnabled and ns.Glows and mainFrame.impGlowHost) then
        StopImportantGlowVisual()
        return
    end
    if show then
        StartImportantGlowVisual(cfg)
        mainFrame.impGlowHost:SetAlpha(1)
    else
        StopImportantGlowVisual()
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

-- Safely resolve a global frame name to a usable (non-forbidden) frame object.
local function SafeGetFrame(name)
    if type(name) ~= "string" or name == "" then return nil end
    local f = _G[name]
    if not f then return nil end
    if f.IsForbidden and f:IsForbidden() then return nil end
    if not f.GetObjectType then return nil end
    return f
end
FC.SafeGetFrame = SafeGetFrame

-- Whether the bar is currently pinned to another frame (drag disabled while so).
local function IsFrameAnchored()
    local cfg = GetDB()
    return cfg and cfg.anchorToFrame and SafeGetFrame(cfg.anchorFrameName) ~= nil
end
FC.IsFrameAnchored = IsFrameAnchored

function FC.ApplyPosition()
    local cfg = GetDB()
    if not cfg or not mainFrame then return end
    mainFrame:ClearAllPoints()

    -- Frame anchoring: pin the castbar to another UI frame by global name.
    -- Falls back to the free screen position if the target frame is missing.
    if cfg.anchorToFrame then
        local target = SafeGetFrame(cfg.anchorFrameName)
        if target then
            mainFrame:SetPoint(
                cfg.anchorPoint         or "CENTER",
                target,
                cfg.anchorRelativePoint or "CENTER",
                cfg.anchorOffsetX or 0,
                cfg.anchorOffsetY or 0)
            return
        end
    end

    -- Restore EXACTLY what SavePosition captured (GetPoint's point/relPoint may
    -- differ from barAnchorPoint after a drag). Forcing barAnchorPoint here made
    -- a dragged bar jump back toward center whenever appearance re-applied.
    local pos = cfg.barPosition or {point="CENTER", relPoint="CENTER", x=0, y=-120}
    local p   = pos.point    or cfg.barAnchorPoint or "CENTER"
    local rp  = pos.relPoint or p
    mainFrame:SetPoint(p, UIParent, rp, pos.x or 0, pos.y or -120)
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

    -- Fill bar — driven entirely by SetTimerDuration (client interpolation).
    -- We NEVER call SetValue on it during a cast; the client owns the fill.
    frame.fillBar = CreateFrame("StatusBar", nil, frame)
    frame.fillBar:SetAllPoints()
    frame.fillBar:SetMinMaxValues(0, 1)
    frame.fillBar:SetValue(0)
    frame.fillBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.fillBar:SetStatusBarColor(1, 0.65, 0, 1)
    frame.fillBar:SetFrameLevel(frame:GetFrameLevel() + 2)

    -- Spark rides the leading edge of the fill
    frame.spark = frame.fillBar:CreateTexture(nil, "OVERLAY")
    frame.spark:SetSize(12, h)
    frame.spark:SetBlendMode("ADD")
    frame.spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
    frame.spark:SetPoint("CENTER", frame.fillBar:GetStatusBarTexture(), "RIGHT", 0, 0)
    frame.spark:Hide()

    -- Important-glow host: the important-spell glow is started on THIS frame, and
    -- its visibility is toggled purely via SetAlphaFromBoolean(secret) — so the
    -- secret boolean from C_Spell.IsSpellImportant is never tested in Lua (which
    -- would taint and error). Overlaps the bar exactly so the glow frames it.
    frame.impGlowHost = CreateFrame("Frame", nil, frame)
    frame.impGlowHost:SetAllPoints(frame)
    frame.impGlowHost:SetFrameLevel(frame:GetFrameLevel() + 6)
    frame.impGlowHost:SetAlpha(0)

    -- Positioner: invisible; mirrors cast elapsed for kick-tick anchor.
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
    frame.kickCooldownBar:SetClipsChildren(true)
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
    frame._raidMarker:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
    frame._raidMarker:Hide()

    -- Text layer (spell name + timer + caster name + focus target)
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
    dragBtn:SetScript("OnDragStart", function()
        if IsFrameAnchored() then return end   -- pinned to a frame: offsets control position
        frame:StartMoving(); DragHighlight()
    end)
    dragBtn:SetScript("OnDragStop",  function() frame:StopMovingOrSizing(); DragNormal(); SavePosition() end)
    dragBtn:SetScript("OnEnter", DragHighlight)
    dragBtn:SetScript("OnLeave", DragNormal)
    dragBtn:Hide()
    frame._dragHandle = dragBtn

    -- Bar-body drag (click anywhere on bar while options open)
    frame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and ns._arcUIOptionsOpen and not IsFrameAnchored() then self:StartMoving() end
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
    if not (cfg and cfg.showFocusTarget and HasActiveCast()) then
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

    mainFrame.spark:SetSize(12, h)

    local textF = mainFrame._textFrame
    if textF then
        textF:SetSize(w, h)
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
        local cnc = cfg.casterNameColor or {r=1,g=0.82,b=0,a=1}
        textF.casterText:SetFont(fontPath, smallSize, outline)
        textF.casterText:SetTextColor(cnc.r, cnc.g, cnc.b, cnc.a or 1)
        if textF.focusTargetText then
            local ftc = cfg.focusTargetColor or {r=0.6,g=0.8,b=1,a=1}
            textF.focusTargetText:SetFont(fontPath, smallSize, outline)
            textF.focusTargetText:SetTextColor(ftc.r, ftc.g, ftc.b, ftc.a or 1)
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
        mainFrame.spark:Hide()
        if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
        if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
        if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
        if ns.Glows then
            ns.Glows.Stop(mainFrame, GLOW_KEY)
            StopImportantGlowVisual()
        end
        mainFrame:SetScript("OnUpdate", nil)
        return
    end
    ApplyAppearanceInternal(cfg)
    mainFrame:EnableMouse(ns._arcUIOptionsOpen or false)
    FC.ApplyPosition()
    if ns._arcUIOptionsOpen and not HasActiveCast() and not holdActive then
        FC.ShowPreview()
    elseif isPreview then
        -- Already previewing: the branch above is skipped because the preview sets
        -- casting=true (HasActiveCast() is true), so option changes never re-applied
        -- the glow. Refresh it (and the important glow) live, without restarting the
        -- cast fill. StopImportantGlowVisual() forces a rebuild with the new params.
        RefreshGlow(cfg)
        StopImportantGlowVisual()
        UpdateImportantGlowPreview(cfg, cfg.importantGlowEnabled)
    end
end

-- ===================================================================
-- HOLD TIMER  (freeze bar for a moment after a cast ends)
-- ===================================================================
local function CancelHoldTimer()
    if holdTimer then holdTimer:Cancel(); holdTimer = nil end
    holdActive = false
end

-- Returns true if hold timer was started.
local function StartHoldTimer(cfg, endReason, interruptedBy)
    CancelHoldTimer()
    if not (cfg.holdEnabled and cfg.holdDuration and cfg.holdDuration > 0) then
        return false
    end
    holdActive = true

    mainFrame.spark:Hide()
    mainFrame.kickTick:SetAlpha(0)

    -- Freeze the fill full. Hold is a plain 0..1 range with a literal value —
    -- no secret duration involved, so SetValue(1) is fine here.
    mainFrame.fillBar:SetMinMaxValues(0, 1)
    mainFrame.fillBar:SetValue(1)
    mainFrame.positioner:SetMinMaxValues(0, 1)
    mainFrame.positioner:SetValue(1)

    local texture = mainFrame.fillBar:GetStatusBarTexture()
    local col
    local textF = mainFrame._textFrame
    if endReason == "interrupted" then
        col = cfg.holdInterruptedColor or {r=0.2,g=0.4,b=1,a=1}
        if textF then
            local label = INTERRUPTED
            if interruptedBy then label = INTERRUPTED_BY:format(interruptedBy) end
            textF.nameText:SetText(label)
            textF.timerText:SetText("")
        end
    elseif endReason == "failed" then
        col = cfg.holdFailColor or {r=1,g=0.5,b=0,a=1}
        if textF then textF.timerText:SetText("") end
    else
        col = cfg.holdSuccessColor or {r=0.2,g=1,b=0.2,a=1}
        if textF then textF.timerText:SetText("") end
    end
    if texture then texture:SetVertexColor(col.r, col.g, col.b, col.a or 1) end

    holdTimer = C_Timer.NewTimer(cfg.holdDuration, function()
        holdTimer  = nil
        holdActive = false
        if not HasActiveCast() then
            if mainFrame then mainFrame:Hide() end
            if mainFrame and mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
            if mainFrame and mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
            if ns.Glows then
                ns.Glows.Stop(mainFrame, GLOW_KEY)
                StopImportantGlowVisual()
            end
            if ns._arcUIOptionsOpen then FC.ShowPreview() end
        end
    end)
    return true
end

-- ===================================================================
-- ONUPDATE — the StatusBar fills ITSELF from SetTimerDuration.
-- OnUpdate only reads the duration to move the kick tick and to format
-- the countdown text. It NEVER calls fillBar:SetValue during a cast —
-- doing so fights the client interpolation and makes the fill stutter.
-- ===================================================================
local function OnUpdate(_, elapsed)
    local cfg = GetDB()
    if not cfg then return end

    if isPreview then
        -- Preview fill is owned by SetTimerDuration too; just move the tick.
        local duration = mainFrame.fillBar:GetTimerDuration()
        if duration then
            mainFrame.positioner:SetValue(duration:GetElapsedDuration())
        end
        return
    end

    if not HasActiveCast() then
        mainFrame.kickTick:SetAlpha(0)
        return
    end

    local duration = mainFrame.fillBar:GetTimerDuration()
    if duration and cachedDuration then
        -- Move the kick-tick anchor and refresh kick colour. The fill itself
        -- is left entirely to the client (SetTimerDuration).
        UpdateTickPosition(cfg, duration)
        UpdateKickAndColor(cfg)
    end

    updateElapsed = updateElapsed + elapsed
    if updateElapsed < UPDATE_THROTTLE then return end
    updateElapsed = 0

    if holdActive then return end
    if not duration then return end

    if cfg.showTimer and mainFrame._textFrame then
        -- remaining is a SECRET number; SetFormattedText is a safe sink and the
        -- format string is a literal, so this prints the countdown without a
        -- taint error. Never compare `remaining`.
        local remaining = duration:GetRemainingDuration()
        if remaining then
            mainFrame._textFrame.timerText:SetFormattedText('%.1f', remaining)
        end
    end

    UpdateFocusTargetText()
end

local function EnsureOnUpdate()
    if mainFrame and mainFrame:GetScript("OnUpdate") ~= OnUpdate then
        mainFrame:SetScript("OnUpdate", OnUpdate)
    end
end

-- ===================================================================
-- START CAST — queries Unit*Info + Unit*Duration and hands the
-- duration object to the StatusBar (NorskenUI model)
-- ===================================================================
StartCast = function()
    if not mainFrame or not UnitExists("focus") then return end
    local cfg = GetDB()
    if not cfg or not cfg.enabled then return end

    local name, text, texture, notInterruptible, spellID, isEmpowered
    local duration
    local direction = Enum.StatusBarTimerDirection.ElapsedTime

    -- Try regular cast first
    name, text, texture, _, _, _, _, notInterruptible, spellID = UnitCastingInfo("focus")
    if name then
        casting, channeling, empowering = true, nil, nil
        duration = UnitCastingDuration("focus")
    else
        -- Try channel / empower
        name, text, texture, _, _, _, notInterruptible, spellID, isEmpowered = UnitChannelInfo("focus")
        if name then
            casting = nil
            if isEmpowered then
                empowering, channeling = true, nil
                duration = UnitEmpoweredChannelDuration("focus")
            else
                channeling, empowering = true, nil
                duration = UnitChannelDuration("focus")
                direction = Enum.StatusBarTimerDirection.RemainingTime
            end
        end
    end

    if not name then
        -- Nothing to show. Don't wipe a running hold timer.
        if not holdTimer then
            ResetCastState()
            mainFrame:Hide()
            if mainFrame._textFrame then mainFrame._textFrame:Hide() end
        end
        return
    end

    -- New real cast supersedes any pending hold AND any running preview.
    -- Without clearing isPreview here the OnUpdate would stay on the preview
    -- branch and the preview ticker would keep firing "interrupted" flashes
    -- even after the options panel closes.
    CancelHoldTimer()
    isPreview = false
    if previewTicker    then previewTicker:Cancel();    previewTicker    = nil end
    if previewHoldTimer then previewHoldTimer:Cancel(); previewHoldTimer = nil end
    mainFrame:SetFrameStrata(cfg.barFrameStrata or "MEDIUM")
    if mainFrame._textFrame then mainFrame._textFrame:SetFrameStrata("HIGH") end

    currentSpellID         = spellID
    state_notInterruptible = notInterruptible
    cachedDuration         = duration
    RebuildColorObjects(cfg)

    if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
    mainFrame:EnableMouse(false)
    mainFrame:SetAlpha(1)

    -- Hand the duration to the StatusBar; the client owns the fill from here.
    -- SetTimerDuration sets its own min/max from the duration total — we do
    -- NOT force (0,1) first, and we do NOT call SetValue afterwards.
    mainFrame.fillBar:SetTimerDuration(duration, Enum.StatusBarInterpolation.Immediate, direction)

    -- Positioner mirrors cast progress for tick anchoring
    local isChan = channeling == true
    mainFrame.positioner:SetReverseFill(isChan)
    if duration then
        mainFrame.positioner:SetMinMaxValues(0, duration:GetTotalDuration())
    end
    mainFrame.positioner:SetValue(0)

    -- Text
    local textF = mainFrame._textFrame
    if textF then
        textF.nameText:SetText(cfg.showSpellName   and (text or name) or "")
        textF.casterText:SetText(cfg.showCasterName and UnitName("focus") or "")
        textF.timerText:SetText("")
        textF:Show()
    end
    UpdateFocusTargetText()

    -- Spark
    mainFrame.spark:Show()

    UpdateBarColor(cfg, nil)
    UpdateRaidMarker(false)
    mainFrame.kickTick:SetAlpha(0)
    SetupKickBar(cfg)

    -- Glows
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
    if spellID then UpdateImportantGlow(spellID, cfg) end

    EnsureOnUpdate()
    mainFrame:Show()
    if textF then textF:Show() end
    UpdateImportantCastVisibility(spellID, cfg)
end

-- ===================================================================
-- END CAST
-- ===================================================================
EndCast = function(endReason, interruptedBy)
    if not HasActiveCast() then return end
    if not mainFrame or not mainFrame:IsShown() then ResetCastState(); return end
    if holdTimer then return end

    mainFrame.spark:Hide()
    mainFrame.kickTick:SetAlpha(0)
    UpdateFocusTargetText() -- will hide since HasActiveCast() about to be false
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        StopImportantGlowVisual()
    end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end

    local cfg = GetDB()

    ResetCastState()
    mainFrame:SetScript("OnUpdate", nil)

    if not (cfg and StartHoldTimer(cfg, endReason, interruptedBy)) then
        mainFrame:Hide()
        if mainFrame._textFrame then mainFrame._textFrame:Hide() end
        if ns._arcUIOptionsOpen then FC.ShowPreview() end
    end
end

local function HideCast()
    ResetCastState()
    CancelHoldTimer()
    if not mainFrame then return end
    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.spark:Hide()
    mainFrame.fillBar:SetValue(0)
    mainFrame.kickTick:SetAlpha(0)
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        StopImportantGlowVisual()
    end
    if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
    mainFrame:Hide()
    if ns._arcUIOptionsOpen then FC.ShowPreview() end
end

-- ===================================================================
-- INTERRUPTIBLE REFRESH
-- ===================================================================
local function UpdateInterruptible()
    if not HasActiveCast() or not mainFrame then return end
    local newNotInt
    if channeling or empowering then
        local _,_,_,_,_,_, ni = UnitChannelInfo("focus")
        newNotInt = ni
    else
        local _,_,_,_,_,_,_, ni = UnitCastingInfo("focus")
        newNotInt = ni
    end
    state_notInterruptible = newNotInt
    local cfg = GetDB()
    if not cfg then return end
    -- Reapply both visibility conditions: interruptibility can change while the
    -- cast is already in progress (and importance stays constant for the spell).
    UpdateImportantCastVisibility(currentSpellID, cfg)
    UpdateBarColor(cfg, nil)
end

-- ===================================================================
-- PREVIEW  (NorskenUI-style: looping fake cast -> interrupt -> recast)
-- Only shown while options panel is open or native Edit Mode active.
-- The preview uses a NON-secret duration (C_DurationUtil) so its numeric
-- getters are safe to read for the timer text as well.
-- ===================================================================
local function StartPreviewTimer()
    local duration = C_DurationUtil.CreateDuration()
    duration:SetTimeFromStart(GetTime(), PREVIEW_DURATION)
    mainFrame.fillBar:SetTimerDuration(duration, Enum.StatusBarInterpolation.Immediate,
        Enum.StatusBarTimerDirection.ElapsedTime)
    cachedDuration = duration
    mainFrame.positioner:SetMinMaxValues(0, PREVIEW_DURATION)
    mainFrame.positioner:SetReverseFill(false)
    mainFrame.positioner:SetValue(0)
end

local function PreviewSetCastVisuals(cfg)
    local textF = mainFrame._textFrame
    if textF then
        textF.nameText:SetText(cfg.showSpellName    and "Focus Castbar" or "")
        -- Placeholder text matches the option group names ("Caster Name" /
        -- "Focus Target") so each color option maps 1:1 to the line it controls.
        textF.casterText:SetText(cfg.showCasterName and "Caster Name"   or "")
        textF.timerText:SetText("")
        if textF.focusTargetText then
            if cfg.showFocusTarget then
                textF.focusTargetText:SetText("Focus Target")
                textF.focusTargetText:Show()
            else
                textF.focusTargetText:Hide()
            end
        end
        textF:Show()
    end

    mainFrame.spark:Show()
    local bc = cfg.barColor or {r=1,g=0.65,b=0,a=1}
    local fillTex = mainFrame.fillBar:GetStatusBarTexture()
    if fillTex then fillTex:SetVertexColor(bc.r, bc.g, bc.b, bc.a or 1) end

    -- Raid marker default (moon = 8) for positioning
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

    -- Glow outline in preview -- respect the showGlow toggle (RefreshGlow force-
    -- restarts so live option changes apply). Previously this always started the
    -- glow, so disabling it in the options panel never took effect while previewing.
    RefreshGlow(cfg)
    UpdateImportantGlowPreview(cfg, cfg.importantGlowEnabled)
end

local function PreviewShowInterrupted(cfg)
    isPreview = true
    casting = false  -- interrupted display; not an active cast
    mainFrame.spark:Hide()
    mainFrame.kickTick:SetAlpha(0)
    mainFrame.kickCooldownBar:SetValue(0)
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end

    mainFrame.fillBar:SetMinMaxValues(0, 1)
    mainFrame.fillBar:SetValue(1)
    mainFrame.positioner:SetMinMaxValues(0, 1)
    mainFrame.positioner:SetValue(1)

    local textF = mainFrame._textFrame
    if textF then
        textF.nameText:SetText(INTERRUPTED_BY:format("Focus Target"))
        textF.timerText:SetText("")
    end

    local holdColor = cfg.holdInterruptedColor or {r=0.2,g=0.4,b=1,a=1}
    local texture = mainFrame.fillBar:GetStatusBarTexture()
    if texture then texture:SetVertexColor(holdColor.r, holdColor.g, holdColor.b, holdColor.a or 1) end

    if previewHoldTimer then previewHoldTimer:Cancel() end
    local holdDur = (cfg.holdEnabled and cfg.holdDuration and cfg.holdDuration > 0)
                    and cfg.holdDuration or 1.5
    previewHoldTimer = C_Timer.NewTimer(holdDur, function()
        previewHoldTimer = nil
        -- Self-terminate if the panel closed while we were holding.
        local nativeEM = EditModeManagerFrame and EditModeManagerFrame:IsShown()
        if not isPreview or not (ns._arcUIOptionsOpen or nativeEM) then
            FC.HidePreview()
            return
        end
        casting = true
        StartPreviewTimer()
        PreviewSetCastVisuals(GetDB())
    end)
end

function FC.ShowPreview()
    if HasActiveCast() or holdActive then return end
    local nativeEM = EditModeManagerFrame and EditModeManagerFrame:IsShown()
    if not ns._arcUIOptionsOpen and not nativeEM then return end

    CreateFocusFrames()
    if not mainFrame then return end
    local cfg = GetDB()
    if not cfg or not cfg.enabled then return end
    if not isEnabled then FC.Enable() end

    ApplyAppearanceInternal(cfg)

    -- Elevate above AceConfigDialog (FULLSCREEN_DIALOG); restored on hide/real cast
    mainFrame:SetFrameStrata("TOOLTIP")
    if mainFrame._textFrame then mainFrame._textFrame:SetFrameStrata("TOOLTIP") end

    FC.ApplyPosition()
    RebuildColorObjects(cfg)

    mainFrame:EnableMouse(true)
    mainFrame:SetAlpha(1)
    if mainFrame._textFrame then mainFrame._textFrame:SetAlpha(1) end

    isPreview = true
    casting   = true

    StartPreviewTimer()
    PreviewSetCastVisuals(cfg)

    mainFrame.kickTick:SetAlpha(0)
    if mainFrame._dragHandle then mainFrame._dragHandle:Show() end

    EnsureOnUpdate()
    mainFrame:Show()

    -- Loop: after each full preview cast, show interrupt then recast.
    -- Self-terminates if the options panel / Edit Mode closed underneath us.
    if previewTicker then previewTicker:Cancel() end
    previewTicker = C_Timer.NewTicker(PREVIEW_DURATION, function()
        local nativeEM2 = EditModeManagerFrame and EditModeManagerFrame:IsShown()
        if not isPreview or not (ns._arcUIOptionsOpen or nativeEM2) then
            FC.HidePreview()
            return
        end
        if previewHoldTimer then return end
        PreviewShowInterrupted(GetDB())
    end)
end

function FC.HidePreview()
    -- Authoritative teardown of preview state. Idempotent and does NOT
    -- depend on ns._arcUIOptionsOpen (which the panel may clear after onClose).
    local wasPreview = isPreview
    isPreview = false
    if previewTicker then previewTicker:Cancel(); previewTicker = nil end
    if previewHoldTimer then previewHoldTimer:Cancel(); previewHoldTimer = nil end
    if not mainFrame then return end

    -- Preview sets casting=true, so HasActiveCast() is true DURING a preview.
    -- Only bail for a GENUINE cast (wasPreview == false). If wasPreview is true,
    -- the active-cast flags belong to the preview and must be torn down here.
    if not wasPreview and (HasActiveCast() or holdActive) then return end

    casting, channeling, empowering = nil, nil, nil
    cachedDuration = nil

    mainFrame:SetScript("OnUpdate", nil)
    mainFrame.fillBar:SetValue(0)
    mainFrame.spark:Hide()
    if ns.Glows then
        ns.Glows.Stop(mainFrame, GLOW_KEY)
        StopImportantGlowVisual()
    end
    mainFrame:EnableMouse(false)
    if mainFrame._textFrame  then mainFrame._textFrame:Hide()  end
    if mainFrame._raidMarker then mainFrame._raidMarker:Hide() end
    if mainFrame._dragHandle then mainFrame._dragHandle:Hide() end
    mainFrame.kickTick:SetAlpha(0)
    mainFrame:Hide()

    local cfg2 = GetDB()
    mainFrame:SetFrameStrata(cfg2 and cfg2.barFrameStrata or "MEDIUM")
    if mainFrame._textFrame then mainFrame._textFrame:SetFrameStrata("HIGH") end
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

    if event == "RAID_TARGET_UPDATE" then
        if HasActiveCast() then UpdateRaidMarker(false) end
        return
    end

    if event == "PLAYER_FOCUS_CHANGED" then
        if ns._arcUIOptionsOpen then
            UpdateRaidMarker(true)
            return
        end
        CancelHoldTimer()
        if UnitExists("focus") then
            StartCast()
            UpdateRaidMarker(false)
        else
            HideCast()
        end
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        HideCast()
        if UnitExists("focus") then StartCast() end
        return
    end

    -- Global RegisterEvent delivers unit="focus" for NPC focus targets.
    if unit ~= "focus" then return end

    if event == "UNIT_SPELLCAST_START"
    or event == "UNIT_SPELLCAST_CHANNEL_START"
    or event == "UNIT_SPELLCAST_EMPOWER_START" then
        StartCast()

    elseif event == "UNIT_SPELLCAST_STOP"
        or event == "UNIT_SPELLCAST_CHANNEL_STOP"
        or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
        -- STOP may carry an "interrupted by" GUID on channel/empower variants
        local interruptedBy
        if event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            interruptedBy = select(2, ...)
        elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
            interruptedBy = select(3, ...)
        end
        if interruptedBy then
            local by = UnitNameFromGUID and UnitNameFromGUID(interruptedBy)
            EndCast("interrupted", by)
        else
            EndCast("success")
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        local guid = select(2, ...)
        local by = guid and UnitNameFromGUID and UnitNameFromGUID(guid)
        EndCast("interrupted", by)

    elseif event == "UNIT_SPELLCAST_FAILED" then
        EndCast("failed")

    elseif event == "UNIT_SPELLCAST_DELAYED" then
        if casting then StartCast() end   -- re-query for updated duration object

    elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
        if channeling or empowering then StartCast() end

    elseif event == "UNIT_TARGET" then
        UpdateFocusTargetText()

    elseif event == "UNIT_SPELLCAST_INTERRUPTIBLE"
        or event == "UNIT_SPELLCAST_NOT_INTERRUPTIBLE" then
        UpdateInterruptible()
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

    -- Global registration: RegisterUnitEvent("focus") does not reliably fire for
    -- NPC focus targets in WoW 12.0; the handler filters on unit == "focus".
    eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_FAILED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_DELAYED")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_UPDATE")
    eventFrame:RegisterUnitEvent("UNIT_TARGET", "focus")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTIBLE")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_NOT_INTERRUPTIBLE")

    -- Catch a focus already mid-cast when first enabled
    if UnitExists("focus") then StartCast() end
end

function FC.Disable()
    if not isEnabled then return end
    isEnabled = false
    HideCast()
    eventFrame:UnregisterAllEvents()
    -- Edit Mode preview is driven by hooks on EditModeManagerFrame (installed in
    -- Init), not events, so there is nothing to re-register here.
end

-- ===================================================================
-- INIT
-- ===================================================================
function FC.Init()
    if isInitialized then return end
    isInitialized = true
    CreateFocusFrames()
    CacheInterruptId()
    -- Show/hide the preview with native Edit Mode too. EDIT_MODE_ENTERED/EXITED
    -- are NOT real events (RegisterEvent throws on them) — hook the Edit Mode
    -- manager's enter/exit methods instead (same pattern as EditModeContainers).
    if EditModeManagerFrame and not FC._editModeHooked then
        FC._editModeHooked = true
        hooksecurefunc(EditModeManagerFrame, "EnterEditMode", function()
            if not HasActiveCast() and not holdActive then FC.ShowPreview() end
        end)
        hooksecurefunc(EditModeManagerFrame, "ExitEditMode", function()
            if not HasActiveCast() and not holdActive and not ns._arcUIOptionsOpen then
                FC.HidePreview()
            end
        end)
    end
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