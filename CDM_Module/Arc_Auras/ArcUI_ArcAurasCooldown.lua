-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras Cooldown - Spell Cooldown Tracking Module
-- v3.0 - Clean engine ported from ArcAuras_Core.lua standalone
--
-- Core engine only: frame creation, cooldown swipe, desaturation,
-- charge count, GCD filtering, proc glows.
--
-- Architecture:
--   EVENT-DRIVEN: Cooldown feeding (swipe/desat) happens on events only.
--     CooldownFrameTemplate is self-animating once fed a DurationObject.
--     No OnUpdate loop needed for cooldown display.
--   DESAT: Hidden DesatCooldown frame + hooks drive icon desaturation.
--     Zero secret comparisons. Pure frame state.
--   CHARGES: GetSpellCharges is non-secret. Cached isChargeSpell flag
--     prevents flickering from nil returns during GCD transitions.
--   GCD: isOnGCD cached from SPELL_UPDATE_COOLDOWN (only reliable there).
-- ═══════════════════════════════════════════════════════════════════════════

local ADDON, ns = ...

local ArcAuras = ns.ArcAuras
if not ArcAuras then
    print("|cffFF4444[Arc Auras Cooldown]|r ERROR: ArcAuras core not loaded")
    return
end

local ArcAurasCooldown = {}
ns.ArcAurasCooldown = ArcAurasCooldown

-- ═══════════════════════════════════════════════════════════════════════════
-- LIBRARIES
-- ═══════════════════════════════════════════════════════════════════════════

local function GetLCG()
    return LibStub and LibStub("LibCustomGlow-1.0", true)
end

local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════

local DEFAULT_ICON_SIZE = 40

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

ArcAurasCooldown.initialized = false
ArcAurasCooldown.spellFrames = {}   -- arcID -> frame
ArcAurasCooldown.spellData   = {}   -- arcID -> frameData (engine state)
ArcAurasCooldown.spellsByID  = {}   -- spellID -> { [arcID]=true, ... } (set for duplicates)

-- ═══════════════════════════════════════════════════════════════════════════
-- UNIQUE ID GENERATION (allows multiple copies of same spell)
-- ═══════════════════════════════════════════════════════════════════════════

local function GenerateUniqueSpellArcID(spellID, db)
    local baseID = ArcAuras.MakeSpellID(spellID)
    if not db.trackedSpells[baseID] then return baseID end
    local n = 2
    while db.trackedSpells[baseID .. "_" .. n] do n = n + 1 end
    return baseID .. "_" .. n
end

-- Set-based reverse lookup helpers
local function RegisterSpellByID(spellID, arcID)
    if not ArcAurasCooldown.spellsByID[spellID] then
        ArcAurasCooldown.spellsByID[spellID] = {}
    end
    ArcAurasCooldown.spellsByID[spellID][arcID] = true
end

local function UnregisterSpellByID(spellID, arcID)
    local set = ArcAurasCooldown.spellsByID[spellID]
    if set then
        set[arcID] = nil
        if not next(set) then ArcAurasCooldown.spellsByID[spellID] = nil end
    end
end

local function ForEachSpellArcID(spellID, fn)
    local set = ArcAurasCooldown.spellsByID[spellID]
    if not set then return end
    for arcID in pairs(set) do
        local fd = ArcAurasCooldown.spellData[arcID]
        if fd then fn(arcID, fd) end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DATABASE
-- Uses ArcAuras.GetDB() → raw SavedVariables (bypasses AceDB removeDefaults)
-- ═══════════════════════════════════════════════════════════════════════════

local function GetDB()
    if ArcAuras.GetDB then
        local db = ArcAuras.GetDB()
        if db then
            if not db.trackedSpells then db.trackedSpells = {} end
            return db
        end
    end
    -- Fallback for early loading before main module exports
    if not ns.db or not ns.db.char then return nil end
    if not ns.db.char.arcAuras then return nil end
    local db = ns.db.char.arcAuras
    if not db.trackedSpells then db.trackedSpells = {} end
    return db
end

-- ═══════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function GetSpellNameAndIcon(spellID)
    if not spellID then return nil, nil end
    local info = C_Spell.GetSpellInfo(spellID)
    if info then return info.name, (info.iconID or info.originalIconID) end
    return nil, nil
end

local function PlayerKnowsSpell(spellID)
    if not spellID then return false end
    if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    if IsSpellKnown and IsSpellKnown(spellID) then return true end
    return false
end

ArcAurasCooldown.PlayerKnowsSpell = PlayerKnowsSpell
ArcAurasCooldown.GetSpellNameAndIcon = GetSpellNameAndIcon

-- ═══════════════════════════════════════════════════════════════════════════
-- GLOW HELPERS (from ArcAuras_Core.lua)
-- ═══════════════════════════════════════════════════════════════════════════

local function StartGlow(frame, glowType, color, opts)
    if not frame then return end
    if glowType == "blizzard" then
        if ActionButtonSpellAlertManager then
            ActionButtonSpellAlertManager:ShowAlert(frame)
            if color then
                local alert = frame.SpellActivationAlert
                if alert then
                    local r, g, b, a = color.r or 1, color.g or 1, color.b or 1, color.a or 1
                    local isDefaultGold = (r >= 0.95 and g >= 0.7 and g <= 0.9 and b < 0.15)
                    for _, texName in ipairs({"ProcStartFlipbook", "ProcLoopFlipbook", "ProcAltGlow"}) do
                        local tex = alert[texName]
                        if tex then
                            if not isDefaultGold then
                                tex:SetDesaturated(true)
                                tex:SetVertexColor(r, g, b, a)
                            else
                                tex:SetDesaturated(false)
                                tex:SetVertexColor(1, 1, 1, 1)
                            end
                        end
                    end
                end
            end
        end
        return
    end
    local LCG = GetLCG()
    if not LCG then return end
    opts = opts or {}
    local ca = color and {color.r or 1, color.g or 1, color.b or 1, color.a or 1} or nil
    local key = opts.key
    if glowType == "button" then
        LCG.ButtonGlow_Start(frame, ca, opts.frequency)
    elseif glowType == "pixel" then
        LCG.PixelGlow_Start(frame, ca, opts.lines or 8, opts.frequency or 0.25, opts.length, opts.thickness or 2, opts.xOffset or 0, opts.yOffset or 0, false, key)
    elseif glowType == "autocast" then
        LCG.AutoCastGlow_Start(frame, ca, opts.particles or 4, opts.frequency or 0.25, opts.scale or 1, opts.xOffset or 0, opts.yOffset or 0, key)
    elseif glowType == "glow" then
        LCG.ProcGlow_Start(frame, {color = ca, startAnim = opts.startAnim ~= false, xOffset = opts.xOffset or 0, yOffset = opts.yOffset or 0, key = key})
    end
    -- Elevate glow frames above swipe but below charge count
    local baseLevel = frame:GetFrameLevel()
    local gf
    if glowType == "button" then gf = frame._ButtonGlow
    elseif glowType == "pixel" then gf = frame["_PixelGlow" .. (key or "")]
    elseif glowType == "autocast" then gf = frame["_AutoCastGlow" .. (key or "")]
    elseif glowType == "glow" then gf = frame["_ProcGlow" .. (key or "")]
    end
    if gf and gf.SetFrameLevel then gf:SetFrameLevel(baseLevel + 15) end
end

local function StopGlow(frame, glowType, key)
    if not frame then return end
    if glowType == "blizzard" then
        if ActionButtonSpellAlertManager then pcall(function() ActionButtonSpellAlertManager:HideAlert(frame) end) end
        return
    end
    local LCG = GetLCG()
    if not LCG then return end
    if glowType == "button" then LCG.ButtonGlow_Stop(frame)
    elseif glowType == "pixel" then LCG.PixelGlow_Stop(frame, key)
    elseif glowType == "autocast" then LCG.AutoCastGlow_Stop(frame, key)
    elseif glowType == "glow" and LCG.ProcGlow_Stop then LCG.ProcGlow_Stop(frame, key)
    end
end

local function StopAllGlows(frame, key)
    if not frame then return end
    if ActionButtonSpellAlertManager then pcall(function() ActionButtonSpellAlertManager:HideAlert(frame) end) end
    local LCG = GetLCG()
    if not LCG then return end
    LCG.ButtonGlow_Stop(frame)
    LCG.PixelGlow_Stop(frame, key)
    LCG.AutoCastGlow_Stop(frame, key)
    if LCG.ProcGlow_Stop then LCG.ProcGlow_Stop(frame, key) end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FORWARD DECLARATIONS
-- ═══════════════════════════════════════════════════════════════════════════

local FeedCooldown          -- Event-driven: feeds visible cooldown + desat cooldown
local UpdateChargeText      -- Updates charge count display
local UpdateProcGlow        -- Proc glow state
local ApplySpellStateVisuals -- CDMEnhance state visuals (alpha, glow, tint)

-- ═══════════════════════════════════════════════════════════════════════════
-- SETTINGS SYNC
-- Reads CDMEnhance settings and caches them on frameData so hooks/visuals
-- use the correct values (desaturate, noGCD, waitForNoCharges, etc.)
-- ═══════════════════════════════════════════════════════════════════════════

local function SyncSettingsToFrameData(fd)
    if not fd then return end
    local settings = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(fd.arcID)
    if not settings then return end

    local csv = settings.cooldownStateVisuals or {}
    local cs = csv.cooldownState or {}
    local rs = csv.readyState or {}

    -- Sync desaturate to fd so desat hooks respect CDMEnhance noDesaturate option
    fd.desaturate = (cs.noDesaturate ~= true) and (cs.desaturate ~= false)

    -- Sync noGCD
    if settings.cooldownSwipe and settings.cooldownSwipe.noGCDSwipe ~= nil then
        fd.noGCD = settings.cooldownSwipe.noGCDSwipe
    end

    -- Sync waitForNoCharges (charge spells: desat on any recharge vs only at 0)
    fd.waitForNoCharges = cs.waitForNoCharges or false

    -- Cache resolved settings on fd for state visual application
    fd._cdmSettings = settings
    fd._readyState = rs
    fd._cooldownState = cs
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FEED COOLDOWN (EVENT-DRIVEN ONLY)
--
-- This is the core engine. Called from events, NOT from OnUpdate.
-- CooldownFrameTemplate is self-animating once fed a DurationObject.
--
-- Flow:
--   1. Cache isOnGCD from GetSpellCooldown (only reliable in SPELL_UPDATE_COOLDOWN)
--   2. Feed DesatCooldown (hidden): drives icon desaturation via hooks
--   3. Feed visible Cooldown: drives swipe + countdown text
--   4. Update charge text
-- ═══════════════════════════════════════════════════════════════════════════

FeedCooldown = function(fd)
    if not fd or not fd.frame or not fd.frame:IsShown() then return end
    if fd.frame._arcHiddenNotInSpec then return end

    local spellID = fd.spellID
    local isChargeSpell = fd.isChargeSpell

    -- ───────────────────────────────────────────────────────────────────
    -- 1. GCD STATE (already cached by event handler before calling us)
    -- ───────────────────────────────────────────────────────────────────
    local isOnGCD = fd.lastIsOnGCD == true
    local noGCD = fd.noGCD -- setting: hide GCD-only cooldowns

    -- ───────────────────────────────────────────────────────────────────
    -- 1b. GATHER ALL DURATION OBJECTS (one API call each, reuse below)
    -- ───────────────────────────────────────────────────────────────────
    local cooldownDurObj, chargeDurObj
    pcall(function() cooldownDurObj = C_Spell.GetSpellCooldownDuration(spellID) end)
    if isChargeSpell then
        pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 2. DESATURATION + SHADOW COOLDOWN FEED
    --
    -- Two mechanisms, belt-and-suspenders:
    --   A) Shadow frame hooks (fire during SetCooldown calls, use IsShown())
    --   B) DIRECT SetDesaturated here (uses non-secret durObj nil check)
    --
    -- The direct call ensures desat works even if hooks don't fire
    -- for any reason (pcall eating errors, timing, etc.).
    --
    -- cooldownDurObj nil check is NON-SECRET — safe to branch on.
    -- ───────────────────────────────────────────────────────────────────
    local shouldDesaturate = false

    if noGCD and isOnGCD then
        -- GCD only + noGCD → freeze ready state, no desat
        shouldDesaturate = false
        if fd.desatCooldown then
            fd.desatCooldown:SetCooldown(0, 0)
        end
    elseif cooldownDurObj then
        -- Real cooldown active
        shouldDesaturate = true
        if fd.desatCooldown then
            fd.desatCooldown:Clear()
            pcall(function()
                fd.desatCooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
            end)
        end
    else
        -- No cooldown → spell ready, no desat
        shouldDesaturate = false
        -- Don't touch shadow frame — OnCooldownDone already cleared it
    end

    -- DIRECT desat application (backup for hooks)
    if fd.icon and fd.desaturate then
        fd.icon:SetDesaturated(shouldDesaturate)
    elseif fd.icon then
        fd.icon:SetDesaturated(false)
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 2b. VISUAL STATE FLAG (_isOnCooldown)
    --
    -- Separate from desat! Based on "visualDurObj" concept from standalone:
    --   Normal spells:                     cooldownDurObj (nil = ready)
    --   Charge + waitForNoCharges=true:    cooldownDurObj (only at 0 charges)
    --   Charge + waitForNoCharges=false:   chargeDurObj   (any charge recharging)
    --
    -- nil vs not-nil is NON-SECRET — safe to branch on.
    -- ApplySpellStateVisuals reads this for alpha/glow decisions.
    -- ───────────────────────────────────────────────────────────────────
    if noGCD and isOnGCD then
        fd._isOnCooldown = false
    elseif isChargeSpell and not fd.waitForNoCharges then
        fd._isOnCooldown = (chargeDurObj ~= nil)
    else
        fd._isOnCooldown = (cooldownDurObj ~= nil)
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 3. FEED VISIBLE COOLDOWN (swipe + countdown)
    --
    -- Charge spells: Use chargeDurObj (tracks recharge timer, ignores GCD)
    -- Normal spells: Use cooldownDurObj (but noGCD clears it on GCD)
    -- ───────────────────────────────────────────────────────────────────
    local cooldown = fd.cooldown

    if isChargeSpell then
        if chargeDurObj then
            cooldown:Clear()
            pcall(function()
                cooldown:SetCooldownFromDurationObject(chargeDurObj, true)
            end)
        else
            cooldown:Clear()
        end
    else
        if noGCD and isOnGCD then
            cooldown:Clear()
        elseif cooldownDurObj then
            pcall(function()
                cooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
            end)
        else
            cooldown:Clear()
        end
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 4. CHARGE TEXT
    -- ───────────────────────────────────────────────────────────────────
    UpdateChargeText(fd)

    -- ───────────────────────────────────────────────────────────────────
    -- 5. CDM ENHANCE STATE VISUALS (alpha, glow, tint)
    -- ───────────────────────────────────────────────────────────────────
    ApplySpellStateVisuals(fd)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CHARGE TEXT (non-secret, safe to read directly)
-- ═══════════════════════════════════════════════════════════════════════════

UpdateChargeText = function(fd)
    if not fd or not fd.chargeText then return end
    if not fd.isChargeSpell then
        fd.chargeText:SetText("")
        return
    end

    local chargeInfo = nil
    pcall(function() chargeInfo = C_Spell.GetSpellCharges(fd.spellID) end)
    if chargeInfo then
        -- currentCharges is SECRET in combat — SetText accepts secrets, no comparisons!
        -- Just pass it directly. SetText will display the number.
        fd.chargeText:SetText(chargeInfo.currentCharges or "")
        fd.chargeText:Show()
    end
    -- If chargeInfo is nil (GCD transition), keep last text — don't clear/flicker
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROC GLOW (SPELL_ACTIVATION_OVERLAY events, spellID is non-secret)
-- Reads glow type/color from CDMEnhance procGlow settings if available
-- ═══════════════════════════════════════════════════════════════════════════

UpdateProcGlow = function(fd, forceShow)
    if not fd or not fd.frame then return end

    local spellID = fd.spellID
    local isOverlayed = forceShow

    if isOverlayed == nil then
        pcall(function()
            isOverlayed = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed(spellID)
        end)
    end

    -- Read proc glow settings from CDMEnhance (or use defaults)
    local settings = fd._cdmSettings
    local pg = settings and settings.procGlow or nil

    -- Check if proc glow is disabled in settings
    if pg and pg.enabled == false then
        if fd.procGlowActive then
            StopGlow(fd.frame, fd.procGlowType or "pixel", "proc")
            fd.procGlowActive = false
        end
        return
    end

    if isOverlayed then
        if not fd.procGlowActive then
            local glowType = (pg and pg.glowType) or "default"
            -- "default" means use Blizzard's built-in proc overlay (no color tint)
            if glowType == "default" then glowType = "blizzard" end

            -- Only apply custom color for non-blizzard glow types
            -- Blizzard's built-in proc overlay has its own animation/color
            local gc = nil
            if glowType ~= "blizzard" then
                if pg and pg.color then
                    gc = pg.color
                else
                    gc = {r = 1, g = 0.84, b = 0, a = 1}  -- Default gold
                end
            end

            StartGlow(fd.frame, glowType, gc, {
                key = "proc",
                lines = (pg and pg.lines) or 8,
                frequency = (pg and pg.frequency) or 0.25,
                thickness = (pg and pg.thickness) or 2,
            })
            fd.procGlowActive = true
            fd.procGlowType = glowType
        end
    elseif fd.procGlowActive then
        StopGlow(fd.frame, fd.procGlowType or "pixel", "proc")
        fd.procGlowActive = false
    end
end
ArcAurasCooldown.UpdateProcGlow = UpdateProcGlow

-- ═══════════════════════════════════════════════════════════════════════════
-- STATE VISUALS (CDMEnhance integration)
--
-- Applied after every FeedCooldown. Uses desatCooldown:IsShown() as the
-- NON-SECRET state indicator (true = on CD, false = ready).
--
-- Handles: alpha, ready glow, tint, preserveDurationText
-- Desaturation is already handled by the desat hooks on desatCooldown.
-- ═══════════════════════════════════════════════════════════════════════════

ApplySpellStateVisuals = function(fd)
    if not fd or not fd.frame then return end
    local frame = fd.frame
    local LCG = GetLCG()

    -- Sync settings if not cached yet
    if not fd._cdmSettings then
        SyncSettingsToFrameData(fd)
    end
    local rs = fd._readyState or {}
    local cs = fd._cooldownState or {}

    -- ─── STATE DETECTION (non-secret!) ───────────────────────────────
    -- fd._isOnCooldown is set in FeedCooldown from durObj nil checks:
    --   durObj exists = on cooldown, durObj nil = ready
    -- This is NON-SECRET (nil vs not-nil, no value comparison).
    -- We use this instead of desatCooldown:IsShown() which is unreliable
    -- (child frame IsShown() reflects parent visibility, not CD state).
    local isOnCooldown = fd._isOnCooldown or false

    -- Check glow preview from CDMEnhance options panel
    local isGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive
        and ns.CDMEnhanceOptions.IsGlowPreviewActive(fd.arcID)

    if isOnCooldown and not isGlowPreview then
        -- ═════════════════════════════════════════════════════════════
        -- ON COOLDOWN STATE
        -- ═════════════════════════════════════════════════════════════

        -- Alpha
        local cooldownAlpha = cs.alpha or 1.0
        if cooldownAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                cooldownAlpha = 0.35
            end
        end
        if frame._lastAppliedAlpha ~= cooldownAlpha then
            frame:SetAlpha(cooldownAlpha)
            frame._lastAppliedAlpha = cooldownAlpha
        end

        -- Tint
        local cooldownTint = cs.tint == true
        local tintColor = cs.tintColor
        if fd.icon then
            if cooldownTint and tintColor then
                fd.icon:SetVertexColor(tintColor.r or 0.5, tintColor.g or 0.5, tintColor.b or 0.5, 1)
            else
                fd.icon:SetVertexColor(1, 1, 1, 1)
            end
        end

        -- Preserve Duration Text
        local preserveText = cs.preserveDurationText == true
        if preserveText then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(true)
                frame.Cooldown.Text:SetAlpha(1)
            end
        else
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(false)
            end
        end

        -- Stop ready glow on state change
        if frame._lastVisualState ~= "cooldown" then
            frame._lastVisualState = "cooldown"
            if frame._arcReadyGlowActive then
                frame._arcReadyGlowActive = false
                if ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
                    ns.CDMEnhance.HideReadyGlow(frame)
                elseif LCG then
                    pcall(LCG.PixelGlow_Stop, frame, "ArcAura_ReadyGlow")
                    pcall(LCG.PixelGlow_Stop, frame, "ArcUI_ReadyGlow")
                    pcall(LCG.AutoCastGlow_Stop, frame, "ArcAura_ReadyGlow")
                    pcall(LCG.AutoCastGlow_Stop, frame, "ArcUI_ReadyGlow")
                    pcall(LCG.ButtonGlow_Stop, frame)
                end
            end
        end

    else
        -- ═════════════════════════════════════════════════════════════
        -- READY STATE
        -- ═════════════════════════════════════════════════════════════

        -- Alpha
        local readyAlpha = rs.alpha or 1.0
        if readyAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                readyAlpha = 0.35
            end
        end
        if frame._lastAppliedAlpha ~= readyAlpha then
            frame:SetAlpha(readyAlpha)
            frame._lastAppliedAlpha = readyAlpha
        end

        -- Desaturation: NOT touched here. Hooks on desatCooldown handle it
        -- exclusively. We only clear vertex color tint when ready.
        if fd.icon then
            fd.icon:SetVertexColor(1, 1, 1, 1)
        end

        -- Reset text alpha
        if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
            frame.Cooldown.Text:SetIgnoreParentAlpha(false)
        end

        -- State change detection
        local stateJustChanged = (frame._lastVisualState ~= "ready")
        frame._lastVisualState = "ready"

        -- ─── READY GLOW ─────────────────────────────────────────────
        local shouldShowGlow = isGlowPreview or (rs.glow == true)

        -- Combat-only restriction
        local glowCombatOnly = rs.glowCombatOnly == true
        if glowCombatOnly and not InCombatLockdown() and not isGlowPreview then
            shouldShowGlow = false
        end

        local glowCurrentlyShowing = frame._arcReadyGlowActive or false

        if shouldShowGlow and (stateJustChanged or not glowCurrentlyShowing) then
            -- START ready glow
            frame._arcReadyGlowActive = true

            -- Get CDMEnhance stateVisuals for glow params
            local stateVisuals = nil
            if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
                stateVisuals = ns.CDMEnhance.GetEffectiveStateVisuals(fd._cdmSettings)
            end

            local glowSettings = stateVisuals
            if not glowSettings then
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

            if ns.CDMEnhance and ns.CDMEnhance.ShowReadyGlow then
                ns.CDMEnhance.ShowReadyGlow(frame, glowSettings)
            elseif LCG then
                local glowType = glowSettings.readyGlowType or rs.glowType or "button"
                local glowColor = glowSettings.readyGlowColor or rs.glowColor
                local intensity = glowSettings.readyGlowIntensity or 1.0
                local speed = glowSettings.readyGlowSpeed or 0.25
                local lines = glowSettings.readyGlowLines or 8
                local thickness = glowSettings.readyGlowThickness or 2
                local particles = glowSettings.readyGlowParticles or 4
                local xOffset = glowSettings.readyGlowXOffset or 0
                local yOffset = glowSettings.readyGlowYOffset or 0
                local r, g, b = 1, 0.85, 0
                if glowColor then
                    r = glowColor.r or glowColor[1] or 1
                    g = glowColor.g or glowColor[2] or 0.85
                    b = glowColor.b or glowColor[3] or 0
                end
                local color = {r, g, b, intensity}

                if glowType == "pixel" then
                    pcall(LCG.PixelGlow_Start, frame, color, lines, speed, nil, thickness, xOffset, yOffset, true, "ArcAura_ReadyGlow")
                elseif glowType == "autocast" then
                    pcall(LCG.AutoCastGlow_Start, frame, color, particles, speed, 1, xOffset, yOffset, "ArcAura_ReadyGlow")
                else
                    pcall(LCG.ButtonGlow_Start, frame, color, speed)
                end
            end

        elseif not shouldShowGlow and glowCurrentlyShowing then
            -- STOP ready glow
            frame._arcReadyGlowActive = false
            if ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
                ns.CDMEnhance.HideReadyGlow(frame)
            elseif LCG then
                pcall(LCG.PixelGlow_Stop, frame, "ArcAura_ReadyGlow")
                pcall(LCG.PixelGlow_Stop, frame, "ArcUI_ReadyGlow")
                pcall(LCG.AutoCastGlow_Stop, frame, "ArcAura_ReadyGlow")
                pcall(LCG.AutoCastGlow_Stop, frame, "ArcUI_ReadyGlow")
                pcall(LCG.ButtonGlow_Stop, frame)
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME CREATION
-- ═══════════════════════════════════════════════════════════════════════════

local function CreateSpellCooldownFrame(arcID, config)
    local spellID = config.spellID
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    if not spellInfo then return nil end

    local frameName = "ArcAura_" .. arcID:gsub("[^%w]", "_")

    -- ───────────────────────────────────────────────────────────────────
    -- MAIN CONTAINER
    -- ───────────────────────────────────────────────────────────────────
    local frame = CreateFrame("Button", frameName, UIParent, "BackdropTemplate")
    frame.cooldownID = arcID
    frame._arcAuraID = arcID
    frame._arcIconType = "spell"
    frame._arcSpellID = spellID
    frame._arcConfig = {
        type = "spell",
        spellID = spellID,
        name = spellInfo.name,
        icon = spellInfo.iconID or spellInfo.originalIconID,
    }
    frame:SetSize(DEFAULT_ICON_SIZE, DEFAULT_ICON_SIZE)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    -- Background (matches item frames - transparent by default)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    frame:SetBackdropColor(0, 0, 0, 0)
    frame:SetBackdropBorderColor(0, 0, 0, 0)

    -- ───────────────────────────────────────────────────────────────────
    -- ICON TEXTURE
    -- ───────────────────────────────────────────────────────────────────
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    local iconID = spellInfo.iconID or spellInfo.originalIconID
    icon:SetTexture(iconID or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.Icon = icon

    -- ───────────────────────────────────────────────────────────────────
    -- VISIBLE COOLDOWN (swipe + edge + Blizzard countdown)
    -- CooldownFrameTemplate is self-animating once fed a DurationObject.
    -- We only need to feed it on events, not on OnUpdate.
    -- ───────────────────────────────────────────────────────────────────
    local cooldown = CreateFrame("Cooldown", frameName .. "_CD", frame, "CooldownFrameTemplate")
    cooldown:SetAllPoints(icon)
    cooldown:SetDrawSwipe(true)
    cooldown:SetDrawEdge(true)
    cooldown:SetHideCountdownNumbers(false)
    -- Match item frame textures for CDMEnhance colorization
    cooldown:SetSwipeTexture("Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe", 1, 1, 1, 1)
    cooldown:SetEdgeTexture("Interface\\Cooldown\\UI-HUD-ActionBar-SecondaryCooldown", 1, 1, 1, 1)
    frame.Cooldown = cooldown

    -- ───────────────────────────────────────────────────────────────────
    -- HIDDEN DESATURATION COOLDOWN
    --
    -- Drives icon desaturation entirely through hooks — zero secret comparisons.
    --
    -- How it works:
    --   SetCooldown(0,0) → frame not shown → hooks read IsShown()=false → desat OFF
    --   SetCooldownFromDurationObject(durObj) → frame shown → IsShown()=true → desat ON
    --   OnCooldownDone fires → CD expired → desat OFF instantly
    --
    -- Fed from events only. GCD is filtered out before feeding.
    -- ───────────────────────────────────────────────────────────────────
    local desatCooldown = CreateFrame("Cooldown", frameName .. "_DesatCD", frame, "CooldownFrameTemplate")
    desatCooldown:SetAllPoints(icon)
    desatCooldown:SetDrawSwipe(false)
    desatCooldown:SetDrawEdge(false)
    desatCooldown:SetDrawBling(false)
    desatCooldown:SetHideCountdownNumbers(true)
    desatCooldown:SetAlpha(0) -- INVISIBLE! But IsShown() still reflects CD state.

    -- Build frameData FIRST so hooks can reference it via back-pointer
    local frameData = {
        frame          = frame,
        icon           = icon,
        cooldown       = cooldown,
        desatCooldown  = desatCooldown,
        chargeText     = nil,  -- set below after creation
        spellID        = spellID,
        arcID          = arcID,
        spellInfo      = spellInfo,
        -- Engine state
        isChargeSpell  = false, -- set at init, cached to prevent flicker
        noGCD          = true,  -- default: hide GCD-only cooldowns
        desaturate     = true,  -- default: desaturate when on CD
        _isOnCooldown  = false, -- tracked from durObj nil checks (non-secret)
        lastIsOnGCD    = nil,   -- cached from SPELL_UPDATE_COOLDOWN
        procGlowActive = false,
        procGlowType   = nil,
    }

    -- Store back-reference on both cooldown frames so hooks can find frameData
    desatCooldown._arcFrameData = frameData
    cooldown._arcFrameData = frameData

    -- ───────────────────────────────────────────────────────────────────
    -- DESAT HOOKS (on hidden DesatCooldown)
    -- ───────────────────────────────────────────────────────────────────

    -- Hook: SetCooldown → drive desaturation from IsShown()
    hooksecurefunc(desatCooldown, "SetCooldown", function(self)
        local fd = self._arcFrameData
        if not fd or not fd.icon then return end
        if fd.desaturate then
            fd.icon:SetDesaturated(self:IsShown())
        else
            fd.icon:SetDesaturated(false)
        end
    end)

    -- Hook: SetCooldownFromDurationObject → same desat logic
    hooksecurefunc(desatCooldown, "SetCooldownFromDurationObject", function(self)
        local fd = self._arcFrameData
        if not fd or not fd.icon then return end
        if fd.desaturate then
            fd.icon:SetDesaturated(self:IsShown())
        else
            fd.icon:SetDesaturated(false)
        end
    end)

    -- Hook: OnCooldownDone → CD expired, remove desat instantly
    desatCooldown:HookScript("OnCooldownDone", function(self)
        local fd = self._arcFrameData
        if not fd or not fd.icon then return end
        fd.icon:SetDesaturated(false)
        fd._isOnCooldown = false  -- CD expired = ready
        ApplySpellStateVisuals(fd)
    end)

    -- ───────────────────────────────────────────────────────────────────
    -- VISIBLE COOLDOWN: OnCooldownDone hook
    -- When visible cooldown naturally expires, immediately re-feed
    -- so desat clears and visuals update without waiting for next event.
    -- ───────────────────────────────────────────────────────────────────
    cooldown:HookScript("OnCooldownDone", function(self)
        local fd = self._arcFrameData
        if not fd then return end
        -- Immediately clear desat (CD done = spell ready)
        if fd.icon then fd.icon:SetDesaturated(false) end
        -- Re-feed both cooldowns with fresh state
        FeedCooldown(fd)
    end)

    -- ───────────────────────────────────────────────────────────────────
    -- FRAME HIERARCHY (matches item frames for CDMEnhance/Masque compat)
    -- ───────────────────────────────────────────────────────────────────

    local baseLevel = frame:GetFrameLevel()

    -- Shadow/overlay texture (matches item frames)
    local shadow = frame:CreateTexture(nil, "OVERLAY", nil, 1)
    shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
    shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
    shadow:SetTexture("Interface\\Cooldown\\IconCooldownEdge")
    shadow:SetVertexColor(0, 0, 0, 0.5)
    shadow:Hide()
    frame.IconOverlay = shadow

    -- Border overlay frame (matches item frames)
    local borderOverlay = CreateFrame("Frame", nil, frame)
    borderOverlay:SetAllPoints()
    borderOverlay:SetFrameLevel(baseLevel + 5)
    frame._arcBorderOverlay = borderOverlay

    -- Glow anchor frame (matches item frames)
    local glowAnchor = CreateFrame("Frame", nil, frame)
    glowAnchor:SetAllPoints()
    glowAnchor:SetFrameLevel(baseLevel + 3)
    frame._arcGlowAnchor = glowAnchor

    -- Count container frame (level +50 = above glows so count is always readable)
    local countContainer = CreateFrame("Frame", nil, frame)
    countContainer:SetAllPoints()
    countContainer:SetFrameLevel(baseLevel + 50)
    countContainer:EnableMouse(false)
    frame._arcCountContainer = countContainer
    frame.ChargeCount = countContainer  -- Engine compat alias

    -- Charge text - uses _arcStackText (not Count) so Masque doesn't auto-manage
    local LSM = GetLSM()
    local fontPath = LSM and LSM:Fetch("font", "Friz Quadrata TT") or "Fonts\\FRIZQT__.TTF"
    local chargeText = countContainer:CreateFontString(nil, "OVERLAY")
    chargeText:SetDrawLayer("OVERLAY", 7)
    chargeText:SetFont(fontPath, 16, "OUTLINE")
    chargeText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    chargeText:SetTextColor(1, 1, 0, 1)
    chargeText:SetText("")
    frame._arcStackText = chargeText
    countContainer.Current = chargeText

    -- Store chargeText in frameData
    frameData.chargeText = chargeText

    -- CooldownFlash (reserved, hidden - matches item frames)
    local cooldownFlash = CreateFrame("Frame", nil, frame)
    cooldownFlash:SetAllPoints()
    cooldownFlash:Hide()
    frame.CooldownFlash = cooldownFlash

    -- Cooldown state tracking (matches item frames)
    frame._lastCooldownState = nil
    frame._lastStartTime = nil
    frame._lastDuration = nil

    -- ───────────────────────────────────────────────────────────────────
    -- DETECT CHARGE SPELL (cached once, prevents flicker)
    -- ───────────────────────────────────────────────────────────────────
    local chargeInfo = nil
    pcall(function() chargeInfo = C_Spell.GetSpellCharges(spellID) end)
    frameData.isChargeSpell = (chargeInfo ~= nil)

    -- ───────────────────────────────────────────────────────────────────
    -- DRAG HANDLING
    -- ───────────────────────────────────────────────────────────────────
    frame:SetScript("OnDragStart", function(self)
        if self._isDraggable then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local id = self._arcAuraID
        -- CDMGroups position save
        if ns.CDMGroups and ns.CDMGroups.savedPositions then
            local saved = ns.CDMGroups.savedPositions[id]
            if saved and saved.type == "group" then return end
            local cx, cy = self:GetCenter()
            local ux, uy = UIParent:GetCenter()
            local newX, newY = cx - ux, cy - uy
            local iconSize = 36
            if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[id] then
                ns.CDMGroups.freeIcons[id].x = newX
                ns.CDMGroups.freeIcons[id].y = newY
                iconSize = ns.CDMGroups.freeIcons[id].iconSize or iconSize
            end
            ns.CDMGroups.savedPositions[id] = {type = "free", x = newX, y = newY, iconSize = iconSize}
            if ns.CDMGroups.SavePositionToSpec then ns.CDMGroups.SavePositionToSpec(id, ns.CDMGroups.savedPositions[id]) end
            if ns.CDMGroups.SaveFreeIconToSpec then ns.CDMGroups.SaveFreeIconToSpec(id, {x = newX, y = newY, iconSize = iconSize}) end
        else
            local point, _, relPoint, x, y = self:GetPoint()
            ArcAuras.SaveFramePosition(id, point, relPoint, x, y)
        end
    end)

    -- ───────────────────────────────────────────────────────────────────
    -- TOOLTIP + RIGHT-CLICK
    -- ───────────────────────────────────────────────────────────────────
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local name = GetSpellNameAndIcon(self._arcSpellID)
        GameTooltip:AddLine(name or ("Spell " .. (self._arcSpellID or "?")), 1, 1, 1)
        if self._arcSpellID then GameTooltip:AddLine("Spell ID: " .. self._arcSpellID, 0.6, 0.6, 0.6) end
        if not PlayerKnowsSpell(self._arcSpellID) then GameTooltip:AddLine("|cff888888Not in current spec|r") end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cff888888Right-click for options|r", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame:RegisterForClicks("RightButtonUp")
    frame:SetScript("OnClick", function(self, button)
        if button == "RightButton" then ArcAurasCooldown.ShowContextMenu(self) end
    end)

    return frame, frameData
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTEXT MENU
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.ShowContextMenu(frame)
    if not frame or not frame._arcAuraID then return end
    local arcID = frame._arcAuraID
    local spellName = GetSpellNameAndIcon(frame._arcSpellID) or arcID
    local menuList = {
        {text = spellName, isTitle = true},
        {text = "Configure in CDM Icons", func = function()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
                ns.CDMEnhanceOptions.SelectIcon(arcID, false)
            end
        end},
        {text = "Remove Spell", func = function()
            StaticPopup_Show("ARCAURAS_CD_REMOVE_SPELL", spellName, nil, {arcID = arcID})
        end},
    }
    local menuFrame = CreateFrame("Frame", "ArcAurasCDContextMenu", UIParent, "UIDropDownMenuTemplate")
    EasyMenu(menuList, menuFrame, "cursor", 0, 0, "MENU")
end

StaticPopupDialogs["ARCAURAS_CD_REMOVE_SPELL"] = {
    text = "Remove %s from spell tracking?",
    button1 = "Remove", button2 = "Cancel",
    OnAccept = function(self, data)
        if data and data.arcID then
            ArcAurasCooldown.RemoveTrackedSpell(data.arcID)
            if ns.ArcAurasOptions and ns.ArcAurasOptions.InvalidateCache then ns.ArcAurasOptions.InvalidateCache() end
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.InvalidateCache then ns.CDMEnhanceOptions.InvalidateCache() end
            LibStub("AceConfigRegistry-3.0"):NotifyChange("ArcUI")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME LIFECYCLE (create / destroy / hide / show)
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.CreateFrame(arcID, config)
    if ArcAuras.frames[arcID] then return ArcAuras.frames[arcID] end

    local frame, fd = CreateSpellCooldownFrame(arcID, config)
    if not frame or not fd then return nil end

    -- Register in all tables
    ArcAuras.frames[arcID] = frame
    ArcAurasCooldown.spellFrames[arcID] = frame
    ArcAurasCooldown.spellData[arcID] = fd
    RegisterSpellByID(config.spellID, arcID)

    -- CDMGroups registration
    if ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
        ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", "Essential")
    else
        C_Timer.After(1.0, function()
            if ArcAuras.frames[arcID] and ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
                ns.CDMGroups.RegisterExternalFrame(arcID, frame, "cooldown", "Essential")
            end
        end)
    end

    -- CDMEnhance + Masque (use shared Masque group from main module)
    ArcAuras.RegisterWithCDMEnhance(arcID, frame)
    if ArcAuras.RegisterWithMasque then
        ArcAuras.RegisterWithMasque(frame)
    end

    -- Sync CDMEnhance settings to frameData (desaturate, noGCD, waitForNoCharges)
    SyncSettingsToFrameData(fd)

    return frame
end

function ArcAurasCooldown.DestroyFrame(arcID)
    local fd = ArcAurasCooldown.spellData[arcID]
    if not fd then return end

    StopAllGlows(fd.frame, "proc")
    StopAllGlows(fd.frame, "ready")

    if fd.spellID then
        UnregisterSpellByID(fd.spellID, arcID)
    end
    ArcAurasCooldown.spellFrames[arcID] = nil
    ArcAurasCooldown.spellData[arcID] = nil

    ArcAuras.DestroyFrame(arcID)
end

function ArcAurasCooldown.HideFrame(arcID)
    local fd = ArcAurasCooldown.spellData[arcID]
    if not fd or not fd.frame then return end
    fd.frame._arcHiddenNotInSpec = true
    if fd.procGlowActive then
        StopGlow(fd.frame, fd.procGlowType or "pixel", "proc")
        fd.procGlowActive = false
    end
    if ns.CDMGroups and ns.CDMGroups.UnregisterExternalFrame then
        ns.CDMGroups.UnregisterExternalFrame(arcID)
    end
    fd.frame:Hide()
end

function ArcAurasCooldown.ShowFrame(arcID)
    local fd = ArcAurasCooldown.spellData[arcID]
    if not fd or not fd.frame then return end
    fd.frame._arcHiddenNotInSpec = nil
    fd.frame:Show()

    if ns.CDMGroups and ns.CDMGroups.RegisterExternalFrame then
        ns.CDMGroups.RegisterExternalFrame(arcID, fd.frame, "cooldown", "Essential")
    end

    -- Re-sync settings (may have changed while hidden)
    fd._cdmSettings = nil
    SyncSettingsToFrameData(fd)
    -- Re-check charge spell status (may change between specs)
    local chargeInfo = nil
    pcall(function() chargeInfo = C_Spell.GetSpellCharges(fd.spellID) end)
    fd.isChargeSpell = (chargeInfo ~= nil)
    -- Feed fresh cooldown state
    FeedCooldown(fd)
    UpdateProcGlow(fd)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TRACKED SPELL MANAGEMENT (PUBLIC API)
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.AddTrackedSpell(spellID)
    if not spellID or type(spellID) ~= "number" or spellID <= 0 then return nil end
    local db = GetDB()
    if not db then return nil end

    -- Validate spell exists before creating entry
    local name, icon = GetSpellNameAndIcon(spellID)
    if not name and not icon then
        local info = C_Spell.GetSpellInfo(spellID)
        if not info then return nil end
        name = info.name
        icon = info.iconID or info.originalIconID
    end

    -- Generate unique ID (allows multiple copies of same spell)
    local arcID = GenerateUniqueSpellArcID(spellID, db)

    db.trackedSpells[arcID] = {
        spellID = spellID,
        name = name or ("Spell " .. spellID),
        icon = icon or 134400,
    }

    if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end

    if ArcAuras.isEnabled and PlayerKnowsSpell(spellID) then
        local frame = ArcAurasCooldown.CreateFrame(arcID, db.trackedSpells[arcID])
        if frame then
            ArcAuras.LoadFramePosition(arcID, frame)
            frame:Show()
            local fd = ArcAurasCooldown.spellData[arcID]
            if fd then
                FeedCooldown(fd)
                UpdateProcGlow(fd)
            end
        end
    end
    return arcID
end

function ArcAurasCooldown.RemoveTrackedSpell(arcID)
    local db = GetDB()
    if not db or not db.trackedSpells then return end
    if db.trackedSpells[arcID] then
        local name = db.trackedSpells[arcID].name or arcID
        db.trackedSpells[arcID] = nil
        ArcAurasCooldown.DestroyFrame(arcID)
        if ns.CDMGroups then
            if ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID] then ns.CDMGroups.savedPositions[arcID] = nil end
            if ns.CDMGroups.ClearPositionFromSpec then ns.CDMGroups.ClearPositionFromSpec(arcID) end
        end
        if ns.db and ns.db.profile and ns.db.profile.cdmEnhance then
            local iconSettings = ns.db.profile.cdmEnhance.iconSettings
            if iconSettings and iconSettings[arcID] then iconSettings[arcID] = nil end
        end
        print("|cff00CCFF[Arc Auras]|r Removed: " .. name)
    end
end

function ArcAurasCooldown.GetTrackedSpells()
    local db = GetDB()
    if not db then return {} end
    return db.trackedSpells or {}
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC CHANGE
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.RefreshSpecVisibility()
    if not ArcAuras.isEnabled then return end
    local db = GetDB()
    if not db or not db.trackedSpells then return end

    local changed = false
    for arcID, config in pairs(db.trackedSpells) do
        local spellID = config.spellID
        local fd = ArcAurasCooldown.spellData[arcID]
        local knows = PlayerKnowsSpell(spellID)

        if knows then
            if not fd then
                -- New spell available in this spec
                local frame = ArcAurasCooldown.CreateFrame(arcID, config)
                if frame then
                    ArcAuras.LoadFramePosition(arcID, frame)
                    frame:Show()
                    fd = ArcAurasCooldown.spellData[arcID]
                    if fd then FeedCooldown(fd); UpdateProcGlow(fd) end
                    changed = true
                end
            elseif fd.frame._arcHiddenNotInSpec then
                ArcAurasCooldown.ShowFrame(arcID)
                changed = true
            end
        else
            if fd and not fd.frame._arcHiddenNotInSpec then
                ArcAurasCooldown.HideFrame(arcID)
                changed = true
            end
        end
    end

    if changed and ns.CDMGroups and ns.CDMGroups.groups then
        for _, group in pairs(ns.CDMGroups.groups) do
            if group.Layout then group:Layout() end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT HANDLING
--
-- This is event-driven only. No OnUpdate loop.
-- CooldownFrameTemplate self-animates the swipe once fed a DurationObject.
-- DesatCooldown hooks drive desaturation from frame state.
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("SPELL_UPDATE_USES")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")

local specChangePending = false

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2)

    -- ═══════════════════════════════════════════════════════════════════
    -- SPELL_UPDATE_COOLDOWN: Primary update event.
    -- isOnGCD is ONLY reliable during this event!
    -- Flow: Cache GCD → Feed desat → Feed swipe → Update charge text
    -- ═══════════════════════════════════════════════════════════════════
    if event == "SPELL_UPDATE_COOLDOWN" then
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                -- Cache isOnGCD (only reliable here!)
                local cooldownInfo = nil
                pcall(function() cooldownInfo = C_Spell.GetSpellCooldown(fd.spellID) end)
                if cooldownInfo then
                    fd.lastIsOnGCD = cooldownInfo.isOnGCD
                end
                -- Feed both cooldowns + update charge text
                FeedCooldown(fd)
            end
        end

    -- ═══════════════════════════════════════════════════════════════════
    -- SPELL_UPDATE_USES: Targeted charge update (arg1=spellID, arg2=baseSpellID)
    -- Fires when a specific spell's charges change.
    -- ═══════════════════════════════════════════════════════════════════
    elseif event == "SPELL_UPDATE_USES" then
        local spellID = arg1
        local baseSpellID = arg2
        ForEachSpellArcID(spellID, function(arcID, fd)
            if fd.frame and fd.frame:IsShown() then
                FeedCooldown(fd)
            end
        end)
        if baseSpellID and baseSpellID ~= spellID then
            ForEachSpellArcID(baseSpellID, function(arcID, fd)
                if fd.frame and fd.frame:IsShown() then
                    FeedCooldown(fd)
                end
            end)
        end

    -- ═══════════════════════════════════════════════════════════════════
    -- SPELL_UPDATE_CHARGES: Broadcast charge update (no spellID arg).
    -- Fires when any charge count changes.
    -- ═══════════════════════════════════════════════════════════════════
    elseif event == "SPELL_UPDATE_CHARGES" then
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.isChargeSpell and fd.frame and fd.frame:IsShown() then
                FeedCooldown(fd)
            end
        end

    -- ═══════════════════════════════════════════════════════════════════
    -- PROC GLOW: spellID in event payload is non-secret.
    -- ═══════════════════════════════════════════════════════════════════
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        local spellID = arg1
        ForEachSpellArcID(spellID, function(arcID, fd)
            UpdateProcGlow(fd, true)
            FeedCooldown(fd)
        end)

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = arg1
        ForEachSpellArcID(spellID, function(arcID, fd)
            UpdateProcGlow(fd, false)
            FeedCooldown(fd)
        end)

    -- ═══════════════════════════════════════════════════════════════════
    -- SPEC CHANGE / SPELLBOOK CHANGE
    -- ═══════════════════════════════════════════════════════════════════
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" then
        if ArcAurasCooldown.initialized and not specChangePending then
            C_Timer.After(0.5, function()
                ArcAurasCooldown.RefreshSpecVisibility()
            end)
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if not specChangePending then
            specChangePending = true
            C_Timer.After(3.5, function()
                specChangePending = false
                ArcAurasCooldown.RefreshSpecVisibility()
            end)
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.Initialize()
    if ArcAurasCooldown.initialized then return end
    local db = GetDB()
    if not db then
        C_Timer.After(1, ArcAurasCooldown.Initialize)
        return
    end

    ArcAurasCooldown.initialized = true
    if not ArcAuras.isEnabled then return end

    for arcID, config in pairs(db.trackedSpells) do
        if PlayerKnowsSpell(config.spellID) then
            local frame = ArcAurasCooldown.CreateFrame(arcID, config)
            if frame then
                ArcAuras.LoadFramePosition(arcID, frame)
                frame:Show()
                -- FeedCooldown handles desat (hooks) + state visuals
                local fd = ArcAurasCooldown.spellData[arcID]
                if fd then FeedCooldown(fd) end
            end
        end
    end

    -- Delayed initial feed (after CDMEnhance/CDMGroups ready)
    C_Timer.After(1.5, function()
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() then
                -- Re-check charge status now that spellbook is fully loaded
                local chargeInfo = nil
                pcall(function() chargeInfo = C_Spell.GetSpellCharges(fd.spellID) end)
                fd.isChargeSpell = (chargeInfo ~= nil)
                FeedCooldown(fd)
                UpdateProcGlow(fd)
            end
        end
    end)
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    C_Timer.After(3, function()
        ArcAurasCooldown.Initialize()
    end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH ALL (called on settings change)
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.RefreshAllSettings()
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
            if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end
            -- Clear cached CDMEnhance settings so they're re-read
            fd._cdmSettings = nil
            fd._readyState = nil
            fd._cooldownState = nil
            SyncSettingsToFrameData(fd)
            -- Stop active glows so they restart with new settings
            if fd.procGlowActive then
                StopGlow(fd.frame, fd.procGlowType or "pixel", "proc")
                fd.procGlowActive = false
            end
            if fd.frame._arcReadyGlowActive then
                StopAllGlows(fd.frame, "ready")
                fd.frame._arcReadyGlowActive = false
                fd.frame._lastVisualState = nil  -- Force state re-evaluation
            end
            if ArcAuras.ApplySettingsToFrame then ArcAuras.ApplySettingsToFrame(arcID, fd.frame) end
            -- FeedCooldown handles desat (via hooks) + state visuals (alpha/glow/tint)
            -- Do NOT call ApplyInitialStateVisuals here — it delegates back to FeedCooldown
            FeedCooldown(fd)
            UpdateProcGlow(fd)
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API (for Options / CDMEnhance catalog / ArcAuras main module)
-- ═══════════════════════════════════════════════════════════════════════════

-- Exported so ArcAuras.ApplyInitialStateVisuals can delegate to spell module
ArcAurasCooldown.FeedCooldown = function(fd) return FeedCooldown(fd) end
ArcAurasCooldown.SyncSettingsToFrameData = function(fd) return SyncSettingsToFrameData(fd) end

function ArcAurasCooldown.GetSpellCount()
    local db = GetDB()
    if not db or not db.trackedSpells then return 0 end
    local count = 0
    for _ in pairs(db.trackedSpells) do count = count + 1 end
    return count
end

function ArcAurasCooldown.GetAllSpellsForOptions()
    local db = GetDB()
    if not db or not db.trackedSpells then return {} end
    local spells = {}
    -- Count copies per spellID for labeling duplicates
    local copyCount = {}
    for arcID, config in pairs(db.trackedSpells) do
        copyCount[config.spellID] = (copyCount[config.spellID] or 0) + 1
    end
    local copyIndex = {}
    for arcID, config in pairs(db.trackedSpells) do
        local spellID = config.spellID
        local name, icon = GetSpellNameAndIcon(spellID)
        local displayName = name or config.name or "Unknown"
        -- Label duplicates: "Spell Name #1", "Spell Name #2", etc.
        if copyCount[spellID] and copyCount[spellID] > 1 then
            copyIndex[spellID] = (copyIndex[spellID] or 0) + 1
            displayName = displayName .. " #" .. copyIndex[spellID]
        end
        table.insert(spells, {
            arcID = arcID,
            spellID = spellID,
            name = displayName,
            icon = icon or config.icon or 134400,
            inCurrentSpec = PlayerKnowsSpell(spellID),
            hasCustomSettings = ns.CDMEnhance and ns.CDMEnhance.HasPerIconSettings and ns.CDMEnhance.HasPerIconSettings(arcID),
        })
    end
    table.sort(spells, function(a, b)
        if a.inCurrentSpec ~= b.inCurrentSpec then return a.inCurrentSpec end
        return a.name < b.name
    end)
    return spells
end

function ArcAurasCooldown.CreateCatalogEntry(cdID, frame)
    if not cdID or type(cdID) ~= "string" or not cdID:match("^arc_spell_") then return nil end
    local spellID = frame and frame._arcSpellID
    local name, icon = nil, nil
    if spellID then name, icon = GetSpellNameAndIcon(spellID) end
    if not name or not icon then
        local db = GetDB()
        if db and db.trackedSpells and db.trackedSpells[cdID] then
            name = name or db.trackedSpells[cdID].name
            icon = icon or db.trackedSpells[cdID].icon
        end
    end
    return {
        cdID = cdID, spellID = spellID,
        name = name or ("Spell " .. (spellID or "?")),
        icon = icon or 134400, frame = frame,
        isArcAura = true, isSpellCooldown = true,
        notInSpec = spellID and not PlayerKnowsSpell(spellID) or false,
    }
end

function ArcAurasCooldown.GetSpellInfoForArcID(arcID)
    local db = GetDB()
    if not db or not db.trackedSpells then return nil end
    local config = db.trackedSpells[arcID]
    if not config then return nil end
    local name, icon = GetSpellNameAndIcon(config.spellID)
    return {
        spellID = config.spellID,
        name = name or config.name or "Unknown",
        icon = icon or config.icon or 134400,
        inCurrentSpec = PlayerKnowsSpell(config.spellID),
    }
end