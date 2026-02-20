-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras Cooldown - Spell Cooldown Event Engine
-- v4.0 - Merged architecture: ArcAuras.CreateFrame owns frame creation,
--         this module is the event-driven spell cooldown engine only.
--
-- Architecture:
--   FRAME CREATION: Done by ArcAuras.CreateFrame(arcID, {type="spell"})
--     Creates DesatCooldown + hooks, Icon, Cooldown, Masque, CDMGroups, etc.
--   THIS MODULE: Pure event engine + state visuals for spell frames.
--     Listens to SPELL_UPDATE_COOLDOWN, SPELL_UPDATE_CHARGES, proc events.
--     Feeds cooldown swipe/desat via DurationObjects.
--     Applies state visuals (alpha/desat/tint/glow) — CDMEnhance READS settings
--       but this module is the ONLY writer for spell frame visuals.
--   DESAT: Hidden DesatCooldown frame + hooks drive icon desaturation.
--     Zero secret comparisons. Pure frame state.
--   CHARGES: GetSpellCharges is non-secret. Cached isChargeSpell flag
--     prevents flickering from nil returns during GCD transitions.
--   GCD: isOnGCD cached from SPELL_UPDATE_COOLDOWN (only reliable there).
--        DesatCooldown ALWAYS filters GCD (keeps desat correct).
--        Visible Cooldown filters GCD only when noGCDSwipe toggle is ON
--        (read from frame._arcNoGCDSwipeEnabled set by CDMEnhance).
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
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════

ArcAurasCooldown.initialized = false
ArcAurasCooldown.spellFrames = {}   -- arcID -> frame
ArcAurasCooldown.spellData   = {}   -- arcID -> frameData (engine state)
ArcAurasCooldown.spellsByID  = {}   -- spellID -> arcID (reverse lookup for events)

-- ═══════════════════════════════════════════════════════════════════════════
-- USABILITY COLORS (matches CDM's CooldownViewerConstants)
-- Applied as default vertex color when no custom tint is configured.
-- Driven by SPELL_UPDATE_USABLE + SPELL_RANGE_CHECK_UPDATE events.
-- All values are non-secret — no pcall needed.
-- ═══════════════════════════════════════════════════════════════════════════

local USABLE_COLOR       = { r = 1.0,  g = 1.0,  b = 1.0,  a = 1.0 }  -- Castable now
local NOT_ENOUGH_MANA    = { r = 0.5,  g = 0.5,  b = 1.0,  a = 1.0 }  -- Insufficient resource
local NOT_USABLE_COLOR   = { r = 0.4,  g = 0.4,  b = 0.4,  a = 1.0 }  -- Can't cast (other reason)
local OUT_OF_RANGE_COLOR = { r = 0.64, g = 0.15, b = 0.15, a = 1.0 }  -- Target out of range

-- ═══════════════════════════════════════════════════════════════════════════
-- DATABASE
-- ═══════════════════════════════════════════════════════════════════════════

local function GetDB()
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
-- GLOW HELPERS
-- ═══════════════════════════════════════════════════════════════════════════

local function StartGlow(frame, glowType, color, opts)
    if not frame then return end
    if glowType == "blizzard" then
        if ActionButtonSpellAlertManager then
            ActionButtonSpellAlertManager:ShowAlert(frame)
            local alert = frame.SpellActivationAlert
            if alert then
                -- Suppress the initial burst animation — just show the steady-state loop.
                -- ShowAlert plays the full intro (ProcStartFlipbook) which causes a visual
                -- flash of mini proc animations. For a persistent usable indicator we only
                -- want the looping glow.
                if alert.ProcStartFlipbook then
                    alert.ProcStartFlipbook:SetAlpha(0)
                    alert.ProcStartFlipbook:Hide()
                end
                if color then
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
    local key = opts.key or ""
    if glowType == "button" then
        LCG.ButtonGlow_Start(frame, ca, opts.frequency)
        -- ButtonGlow stores as frame._ButtonGlow (no key support)
        if frame._ButtonGlow and opts.scale and opts.scale ~= 1.0 and frame._ButtonGlow.SetScale then
            pcall(frame._ButtonGlow.SetScale, frame._ButtonGlow, opts.scale)
        end
    elseif glowType == "pixel" then
        LCG.PixelGlow_Start(frame, ca, opts.lines or 8, opts.frequency or 0.25, opts.length, opts.thickness or 2, opts.xOffset or 0, opts.yOffset or 0, true, key)
        -- Apply scale manually (LCG doesn't have scale param for pixel glow)
        local gf = frame["_PixelGlow" .. key]
        if gf and opts.scale and opts.scale ~= 1.0 and gf.SetScale then
            pcall(gf.SetScale, gf, opts.scale)
        end
    elseif glowType == "autocast" then
        LCG.AutoCastGlow_Start(frame, ca, opts.particles or 4, opts.frequency or 0.25, opts.scale or 1, opts.xOffset or 0, opts.yOffset or 0, key)
    elseif glowType == "glow" then
        LCG.ProcGlow_Start(frame, {color = ca, startAnim = false, xOffset = opts.xOffset or 0, yOffset = opts.yOffset or 0, key = key})
        -- Apply scale manually for proc glow
        local gf = frame["_ProcGlow" .. key]
        if gf then
            if opts.scale and opts.scale ~= 1.0 and gf.SetScale then
                pcall(gf.SetScale, gf, opts.scale)
            end
            -- Fix initial state: suppress start animation, show loop at correct intensity
            if gf.ProcStart then gf.ProcStart:Hide() end
            if gf.ProcLoop then
                gf.ProcLoop:Show()
                gf.ProcLoop:SetAlpha(opts.intensity or 1.0)
            end
        end
    end
    -- Elevate glow frames above swipe but below border (+5) and count text (+10/+50)
    local baseLevel = frame:GetFrameLevel()
    local gf
    if glowType == "button" then gf = frame._ButtonGlow  -- ButtonGlow has no key
    elseif glowType == "pixel" then gf = frame["_PixelGlow" .. key]
    elseif glowType == "autocast" then gf = frame["_AutoCastGlow" .. key]
    elseif glowType == "glow" then gf = frame["_ProcGlow" .. key]
    end
    if gf and gf.SetFrameLevel then gf:SetFrameLevel(baseLevel + 3) end
end

local function StopGlow(frame, glowType, key)
    if not frame then return end
    key = key or ""
    if glowType == "blizzard" then
        if ActionButtonSpellAlertManager then pcall(function() ActionButtonSpellAlertManager:HideAlert(frame) end) end
        return
    end
    local LCG = GetLCG()
    if not LCG then return end
    if glowType == "button" then LCG.ButtonGlow_Stop(frame, key)
    elseif glowType == "pixel" then LCG.PixelGlow_Stop(frame, key)
    elseif glowType == "autocast" then LCG.AutoCastGlow_Stop(frame, key)
    elseif glowType == "glow" and LCG.ProcGlow_Stop then LCG.ProcGlow_Stop(frame, key)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- IMMEDIATE READY GLOW STOP
-- Stops ALL glow types on the frame AND force-hides glow frames instantly.
-- ButtonGlow_Stop plays a slow fade animation — this bypasses that.
-- Matches CDMEnhance's HideReadyGlow approach for instant visual feedback.
-- ═══════════════════════════════════════════════════════════════════════════

local function StopAllGlows(frame, key)
    if not frame then return end
    key = key or ""
    if ActionButtonSpellAlertManager then pcall(function() ActionButtonSpellAlertManager:HideAlert(frame) end) end
    local LCG = GetLCG()
    if not LCG then return end
    LCG.ButtonGlow_Stop(frame, key)
    LCG.PixelGlow_Stop(frame, key)
    LCG.AutoCastGlow_Stop(frame, key)
    if LCG.ProcGlow_Stop then LCG.ProcGlow_Stop(frame, key) end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- USABLE GLOW OVERLAY
-- Creates a dedicated child frame per icon for usable glow.
-- This gives usable glow its own _ButtonGlow (LCG stores one per frame),
-- eliminating all conflicts with ready glow on the parent CDM icon frame.
-- Same technique used by EllesmereBarGlows.
-- ═══════════════════════════════════════════════════════════════════════════

local function GetUsableGlowOverlay(frame)
    if frame._arcUsableGlowOverlay then return frame._arcUsableGlowOverlay end
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    overlay:Show()
    frame._arcUsableGlowOverlay = overlay
    return overlay
end

local function StopUsableGlow(frame)
    local overlay = frame._arcUsableGlowOverlay
    if not overlay then return end
    -- Hide overlay FIRST — LCG's ButtonGlow_Stop checks r:IsVisible().
    -- When hidden it skips the fade animation, releases to pool immediately,
    -- and ButtonGlowResetter properly clears all _ButtonGlow references.
    -- This means next ButtonGlow_Start creates a fresh frame from the pool.
    overlay:Hide()
    overlay:SetAlpha(0)
    -- StopAllGlows handles keyed types (pixel, autocast, proc) with "usable" key.
    StopAllGlows(overlay, "usable")
    -- ButtonGlow_Start is called WITHOUT a key (defaults to ""), but StopAllGlows
    -- passes "usable" to ButtonGlow_Stop which looks for _ButtonGlow"usable" — miss!
    -- Explicitly stop with empty key to match how it was started.
    local LCG = GetLCG()
    if LCG then LCG.ButtonGlow_Stop(overlay) end
    -- Also clean up blizzard SpellActivationAlert if it exists
    if overlay.SpellActivationAlert then
        overlay.SpellActivationAlert:Hide()
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FORWARD DECLARATIONS
-- ═══════════════════════════════════════════════════════════════════════════

local FeedCooldown      -- Event-driven: feeds visible cooldown + desat cooldown
local UpdateChargeText  -- Updates charge count display
local UpdateProcGlow    -- Proc glow state

-- ═══════════════════════════════════════════════════════════════════════════
-- USABILITY STATE + COLOR HELPER
--
-- Returns usability state, vertex color, and alpha override.
-- Priority: Out of Range (red) > Usable (white) > Not Enough Mana (blue) > Not Usable (gray)
-- Reads custom colors/alphas from spellUsability settings if configured.
-- Range tint respects rangeIndicator.enabled from CDMEnhance settings.
-- All APIs used here return non-secret values — safe for direct comparison.
--
-- Returns: state ("usable"|"notEnoughResource"|"notUsable"|"outOfRange"),
--          color {r,g,b,a}, alphaOverride (number or nil)
-- ═══════════════════════════════════════════════════════════════════════════

local function GetUsabilityState(fd, settings)
    if not fd or not fd.spellID then return "usable", USABLE_COLOR, nil end

    local su = settings and settings.spellUsability
    local suEnabled = not su or su.enabled ~= false  -- default: enabled

    -- Range check (highest priority) — respects rangeIndicator.enabled toggle
    if fd.spellOutOfRange then
        local ri = settings and settings.rangeIndicator
        local rangeEnabled = not ri or ri.enabled ~= false
        if rangeEnabled then
            return "outOfRange", OUT_OF_RANGE_COLOR, nil
        end
    end

    -- Usability check — C_Spell.IsSpellUsable returns non-secret booleans
    local isUsable, notEnoughMana = C_Spell.IsSpellUsable(fd.spellID)

    if isUsable then
        return "usable", USABLE_COLOR, nil
    elseif not suEnabled then
        -- Usability tinting disabled — return white (no tint applied)
        return "usable", USABLE_COLOR, nil
    elseif notEnoughMana then
        local color = (su and su.notEnoughResourceColor) or NOT_ENOUGH_MANA
        if not color.a then color = { r = color.r, g = color.g, b = color.b, a = 1.0 } end
        local alpha = su and su.notEnoughResourceAlpha  -- nil = don't override
        return "notEnoughResource", color, alpha
    else
        local color = (su and su.notUsableColor) or NOT_USABLE_COLOR
        if not color.a then color = { r = color.r, g = color.g, b = color.b, a = 1.0 } end
        local alpha = su and su.notUsableAlpha  -- nil = don't override
        return "notUsable", color, alpha
    end
end

-- Backward-compat wrapper (returns just the color)
local function GetUsabilityColor(fd, settings)
    local _, color = GetUsabilityState(fd, settings)
    return color
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL STATE VISUALS
--
-- THIS is the ONLY system that writes alpha/desat/tint/glow for spell frames.
-- CDMEnhance settings are READ for config but NEVER applied directly.
-- Called from DesatCooldown hooks and FeedCooldown.
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
    if not fd or not fd.frame or not fd.icon then return end

    local frame = fd.frame
    local arcID = fd.arcID
    local iconTex = fd.icon

    -- Get CDMEnhance settings (READ ONLY — we decide when to apply)
    local settings = nil
    if ArcAuras.GetCachedSettings then
        settings = ArcAuras.GetCachedSettings(arcID)
    end

    -- Compute usability state once (used for tint, alpha, glow decisions)
    local usabilityState, usabilityColor, usabilityAlpha = GetUsabilityState(fd, settings)

    -- Get state visuals from settings
    local csv = settings and settings.cooldownStateVisuals or {}
    local rs = csv.readyState or {}
    local cs = csv.cooldownState or {}

    -- Get effective state visuals from CDMEnhance (handles cascade properly)
    local stateVisuals = nil
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
        stateVisuals = ns.CDMEnhance.GetEffectiveStateVisuals(settings)
    end

    -- Check if glow preview is active
    local isGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive
                          and ns.CDMEnhanceOptions.IsGlowPreviewActive(arcID)

    -- ═══════════════════════════════════════════════════════════════════
    -- CHARGE SPELL STATE DETECTION
    -- We already have the shadow frame trick that tells us everything:
    --   desatCooldown:IsShown() = true  → ALL charges spent (depleted)
    --   desatCooldown:IsShown() = false → has charge(s) available
    --   cooldown:IsShown() = true       → recharge timer running
    --   cooldown:IsShown() = false      → no cooldown swipe active
    --
    -- Three states for charge spells:
    --   FULLY READY:  desatCD=false, visibleCD=false  (all charges up)
    --   RECHARGING:   desatCD=false, visibleCD=true   (has charges, recharge running)
    --   DEPLETED:     desatCD=true                    (all charges spent)
    --
    -- Normal spells only have two states:
    --   READY:        desatCD=false
    --   ON COOLDOWN:  desatCD=true
    -- ═══════════════════════════════════════════════════════════════════
    local isRecharging = false
    if fd.isChargeSpell and not isOnCD then
        -- Has charges available but recharge timer is running
        isRecharging = fd.cooldown and fd.cooldown:IsShown() or false
    end

    -- ── waitForNoCharges controls alpha/desat/tint during recharge ──
    -- false (default): recharging → COOLDOWN visuals (desat, dim)
    -- true:            recharging → READY visuals  (bright, no desat)
    --
    -- ── glowWhileChargesAvailable controls glow during recharge ──
    -- false (default): recharging → no glow
    -- true:            recharging → glow (if enabled)
    local waitForNoCharges = (stateVisuals and stateVisuals.waitForNoCharges)
                          or (cs.waitForNoCharges == true)
    local glowWhileCharges = (stateVisuals and stateVisuals.glowWhileChargesAvailable)
                          or (rs.glowWhileChargesAvailable == true)

    -- Determine which visual branch to use for alpha/desat/tint
    local useCooldownVisuals
    if isOnCD then
        useCooldownVisuals = true   -- depleted = always cooldown
    elseif fd.isChargeSpell and isRecharging then
        useCooldownVisuals = not waitForNoCharges  -- default: CD visuals during recharge
    else
        useCooldownVisuals = false  -- fully ready = always ready
    end

    -- Determine glow eligibility (independent of alpha/desat)
    local isGlowEligible
    if isGlowPreview then
        isGlowEligible = true  -- preview always shows
    elseif isOnCD then
        isGlowEligible = false  -- depleted/on CD = never glow
    elseif fd.isChargeSpell and isRecharging and not glowWhileCharges then
        isGlowEligible = false  -- recharging without glowWhileCharges = no glow
    else
        isGlowEligible = true   -- ready (or has charges with glowWhileCharges)
    end

    local LCG = GetLCG()

    if useCooldownVisuals and not isGlowPreview then
        -- ═══════════════════════════════════════════════════════════════
        -- ON COOLDOWN: Desaturate, dim, stop ready glow
        -- ═══════════════════════════════════════════════════════════════

        -- Desaturation
        local noDesat = (stateVisuals and stateVisuals.noDesaturate)
                     or cs.noDesaturate
        if fd.desaturate == false then noDesat = true end
        -- During recharge (not fully depleted), suppress desat if only using CD visuals for alpha
        if isRecharging and not isOnCD then noDesat = true end
        iconTex:SetDesaturated(not noDesat)

        -- Alpha
        local cdAlpha = (stateVisuals and stateVisuals.cooldownAlpha)
                     or cs.alpha or 1.0
        -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
        if cdAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                cdAlpha = 0.35
            end
        end
        -- Set enforcement flags so CDMEnhance's SetAlpha hook protects our value
        frame._arcEnforceReadyAlpha = false
        frame._arcReadyAlphaValue = nil
        frame._arcTargetAlpha = cdAlpha
        if frame._lastAppliedAlpha ~= cdAlpha then
            frame._arcBypassFrameAlphaHook = true
            frame:SetAlpha(cdAlpha)
            frame._arcBypassFrameAlphaHook = false
            frame._lastAppliedAlpha = cdAlpha
        end

        -- Preserve duration text: keep countdown + charge text at full opacity when frame is dimmed
        local preserve = (stateVisuals and stateVisuals.preserveDurationText)
                      or cs.preserveDurationText
        if preserve then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(true)
                frame.Cooldown.Text:SetAlpha(1)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(true)
                frame._arcCooldownText:SetAlpha(1)
            end
            if frame._arcStackText and frame._arcStackText.SetIgnoreParentAlpha then
                frame._arcStackText:SetIgnoreParentAlpha(true)
                frame._arcStackText:SetAlpha(1)
            end
            frame._arcPreservingDurationText = true
        elseif frame._arcPreservingDurationText then
            -- Was preserving but no longer — reset
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(false)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(false)
            end
            if frame._arcStackText and frame._arcStackText.SetIgnoreParentAlpha then
                frame._arcStackText:SetIgnoreParentAlpha(false)
            end
            frame._arcPreservingDurationText = false
        end

        -- Tint
        local tint = (stateVisuals and stateVisuals.cooldownTintColor)
                  or cs.tintColor
        if tint and tint.r then
            iconTex:SetVertexColor(tint.r, tint.g, tint.b, tint.a or 1)
        else
            -- No custom tint — apply usability-based coloring (matches CDM behavior)
            local uc = GetUsabilityColor(fd, settings)
            iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a)
        end

    else
        -- ═══════════════════════════════════════════════════════════════
        -- READY: Clear desat, restore alpha
        -- ═══════════════════════════════════════════════════════════════

        iconTex:SetDesaturated(false)

        -- Reset preserve duration text (was set during cooldown state)
        if frame._arcPreservingDurationText then
            if frame.Cooldown and frame.Cooldown.Text and frame.Cooldown.Text.SetIgnoreParentAlpha then
                frame.Cooldown.Text:SetIgnoreParentAlpha(false)
            end
            if frame._arcCooldownText and frame._arcCooldownText.SetIgnoreParentAlpha then
                frame._arcCooldownText:SetIgnoreParentAlpha(false)
            end
            if frame._arcStackText and frame._arcStackText.SetIgnoreParentAlpha then
                frame._arcStackText:SetIgnoreParentAlpha(false)
            end
            frame._arcPreservingDurationText = false
        end

        -- Alpha
        local readyAlpha = (stateVisuals and stateVisuals.readyAlpha)
                        or rs.alpha or 1.0
        -- Usability alpha override: when spell is NOT usable, override readyAlpha
        if usabilityAlpha and usabilityState ~= "usable" and usabilityState ~= "outOfRange" then
            readyAlpha = usabilityAlpha
        end
        -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
        if readyAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                readyAlpha = 0.35
            end
        end
        -- Set enforcement flags so CDMEnhance's SetAlpha hook protects our value
        -- Without these, CDM's internal SetAlpha(1.0) calls override our readyAlpha
        frame._arcTargetAlpha = nil  -- Clear cooldown target
        if readyAlpha < 1.0 then
            frame._arcEnforceReadyAlpha = true
            frame._arcReadyAlphaValue = readyAlpha
        else
            frame._arcEnforceReadyAlpha = false
            frame._arcReadyAlphaValue = nil
        end
        if frame._lastAppliedAlpha ~= readyAlpha then
            frame._arcBypassFrameAlphaHook = true
            frame:SetAlpha(readyAlpha)
            frame._arcBypassFrameAlphaHook = false
            frame._lastAppliedAlpha = readyAlpha
        end

        -- Tint
        local tint = (stateVisuals and stateVisuals.readyTintColor)
                  or rs.tintColor
        if tint and tint.r then
            iconTex:SetVertexColor(tint.r, tint.g, tint.b, tint.a or 1)
        else
            -- No custom tint — apply usability-based coloring (matches CDM behavior)
            local uc = GetUsabilityColor(fd, settings)
            iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a)
        end
    end

    -- ═══════════════════════════════════════════════════════════════
    -- READY GLOW — runs AFTER alpha/desat branch (independent control)
    --
    -- isGlowEligible is computed from glowWhileChargesAvailable,
    -- independent of useCooldownVisuals / waitForNoCharges.
    -- A charge spell can be dimmed (waitForNoCharges=false) but still
    -- glowing (glowWhileChargesAvailable=true) during recharge.
    -- ═══════════════════════════════════════════════════════════════
    local shouldShowGlow = false

    if isGlowEligible then
        -- ShouldShowReadyGlow checks: preview override, glow==true, combatOnly
        if ns.CDMEnhance and ns.CDMEnhance.ShouldShowReadyGlow and stateVisuals then
            shouldShowGlow = ns.CDMEnhance.ShouldShowReadyGlow(stateVisuals, frame)
        elseif isGlowPreview then
            shouldShowGlow = true
        elseif (stateVisuals and stateVisuals.readyGlow) or (rs.glow == true) then
            local combatOnly = (stateVisuals and stateVisuals.readyGlowCombatOnly)
                            or (rs.glowCombatOnly == true)
            shouldShowGlow = not combatOnly or InCombatLockdown()
        end
    end

    if shouldShowGlow then
        -- Build glow settings from stateVisuals (same structure item frames use)
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
        end
    else
        -- Glow should be OFF
        if ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
            ns.CDMEnhance.HideReadyGlow(frame)
        end
    end

    -- ═══════════════════════════════════════════════════════════════
    -- USABLE GLOW — shows while spell has enough resources to cast
    --
    -- Independent of ready glow. Uses "usable" key to avoid conflicts.
    -- Only applies in READY state (not on CD). Respects combatOnly.
    -- Preview mode forces glow ON regardless of actual usability.
    -- ═══════════════════════════════════════════════════════════════
    local su = settings and settings.spellUsability
    local isUsableGlowPreview = ns.CDMEnhanceOptions
        and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive
        and ns.CDMEnhanceOptions.IsUsableGlowPreviewActive(arcID)
    local shouldShowUsableGlow = false

    if isUsableGlowPreview then
        -- Preview always shows (regardless of CD state or usability)
        shouldShowUsableGlow = true
    elseif not isOnCD and su and su.usableGlow then
        if usabilityState == "usable" then
            local combatOnly = su.usableGlowCombatOnly
            shouldShowUsableGlow = not combatOnly or InCombatLockdown()
        end
    end

    if shouldShowUsableGlow then
        local glowSu = su or {}
        local glowType = glowSu.usableGlowType or "button"
        if glowType == "blizzard" then glowType = "glow" end  -- migrate removed option
        -- Only restart glow if type changed or not active
        if not fd.usableGlowActive or fd.usableGlowType ~= glowType then
            -- Stop old glow if type changed
            if fd.usableGlowActive and fd.usableGlowType then
                StopUsableGlow(frame)
            end
            local gc = glowSu.usableGlowColor
            local overlay = GetUsableGlowOverlay(frame)
            overlay:Show()
            overlay:SetAlpha(1)
            StartGlow(overlay, glowType, gc, {
                key = "usable",
                lines = glowSu.usableGlowLines or 8,
                frequency = glowSu.usableGlowSpeed or 0.25,
                thickness = glowSu.usableGlowThickness or 2,
                particles = glowSu.usableGlowParticles or 4,
                scale = glowSu.usableGlowScale or 1,
            })
            fd.usableGlowActive = true
            fd.usableGlowType = glowType
        end
    elseif fd.usableGlowActive then
        StopUsableGlow(frame)
        fd.usableGlowActive = false
        fd.usableGlowType = nil
    end

    -- Track visual state for change detection
    if isOnCD then
        frame._lastVisualState = "cooldown"
    elseif isRecharging then
        frame._lastVisualState = "recharging"
    else
        frame._lastVisualState = "ready"
    end

    -- Notify CDMEnhance for border sync + trigger CooldownFlash bling
    if frame._lastCooldownState ~= isOnCD then
        local wasOnCD = frame._lastCooldownState
        frame._lastCooldownState = isOnCD
        
        -- Play end-of-cooldown flash on CD→ready transition
        -- CDMEnhance hooks FlashAnim:Play to suppress if showBling == false
        if wasOnCD == true and not isOnCD then
            local cf = frame.CooldownFlash
            if cf and cf.FlashAnim and not frame._arcHideCooldownFlash then
                cf:Show()
                cf.FlashAnim:Stop()
                if cf.FlashAnim.ShowAnim and cf.FlashAnim.ShowAnim.SetStartDelay then
                    cf.FlashAnim.ShowAnim:SetStartDelay(0)
                end
                if cf.FlashAnim.PlayAnim and cf.FlashAnim.PlayAnim.SetStartDelay then
                    cf.FlashAnim.PlayAnim:SetStartDelay(0)
                end
                cf.FlashAnim:Play()
                C_Timer.After(0.8, function()
                    if cf and cf:IsShown() then
                        cf:Hide()
                        if cf.FlashAnim then cf.FlashAnim:Stop() end
                    end
                end)
            end
        end
        
        if ArcAuras.NotifyStateChanged then
            ArcAuras.NotifyStateChanged(arcID, isOnCD, 0, 0)
        end
    end
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
--      NOTE: DesatCooldown hooks call ApplySpellStateVisuals automatically
--   3. Feed visible Cooldown: drives swipe + countdown text
--   4. Update charge text
-- ═══════════════════════════════════════════════════════════════════════════

FeedCooldown = function(fd)
    if not fd or not fd.frame or not fd.frame:IsShown() then return end
    if fd.frame._arcHiddenNotInSpec then return end

    local spellID = fd.spellID
    local isChargeSpell = fd.isChargeSpell

    -- Get CDMEnhance settings for charge text / cooldown text decisions
    local settings = nil
    if ArcAuras.GetCachedSettings then
        settings = ArcAuras.GetCachedSettings(fd.arcID)
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 1. GCD STATE (already cached by event handler before calling us)
    -- ───────────────────────────────────────────────────────────────────
    local isOnGCD = fd.lastIsOnGCD == true
    -- Read noGCD setting from CDMEnhance frame flag (set by ApplyIconStyle)
    -- Defaults to true (filter GCD) if CDMEnhance hasn't configured it yet
    local noGCD = fd.frame._arcNoGCDSwipeEnabled
    if noGCD == nil then noGCD = true end

    -- ───────────────────────────────────────────────────────────────────
    -- 2. FEED HIDDEN DESAT COOLDOWN (shadow frame)
    --    ALWAYS filters GCD regardless of noGCD toggle.
    --    This keeps icon desaturation correct even when visible cooldown shows GCD.
    --    isOnGCD → SetCooldown(0,0) → IsShown()=false → hooks clear desat
    --    real CD  → SetCooldownFromDurationObject → IsShown()=true → hooks apply desat
    -- ───────────────────────────────────────────────────────────────────
    if fd.desatCooldown then
        if isOnGCD then
            -- GCD only → force desat off (shadow frame always filters GCD)
            fd.desatCooldown:SetCooldown(0, 0)
        else
            local durObj = nil
            pcall(function() durObj = C_Spell.GetSpellCooldownDuration(spellID) end)
            if durObj then
                fd.desatCooldown:Clear()
                pcall(function()
                    fd.desatCooldown:SetCooldownFromDurationObject(durObj, true)
                end)
            else
                -- No duration = spell ready
                fd.desatCooldown:SetCooldown(0, 0)
            end
        end
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 3. FEED VISIBLE COOLDOWN (swipe + countdown)
    --
    -- Charge spells: Use chargeDurObj (tracks recharge timer, ignores GCD)
    -- Normal spells: Use cooldownDurObj (but noGCD clears it on GCD)
    -- ───────────────────────────────────────────────────────────────────
    local cooldown = fd.cooldown

    if isChargeSpell then
        local chargeDurObj = nil
        pcall(function() chargeDurObj = C_Spell.GetSpellChargeDuration(spellID) end)
        if chargeDurObj then
            cooldown:Clear()
            pcall(function()
                cooldown:SetCooldownFromDurationObject(chargeDurObj, true)
            end)
        else
            cooldown:Clear()
        end
        
        -- Charge spell swipe behavior (secret-safe via desatCooldown.IsShown):
        -- swipeWaitForNoCharges: hide swipe during recharge (CDM default), show only when depleted
        -- edgeWaitForNoCharges: hide edge during recharge, show only when depleted
        -- Both OFF (default): swipe + edge both visible during recharge
        if fd.desatCooldown then
            local fullyDepleted = fd.desatCooldown:IsShown()
            local swipeWait = fd.frame._arcSwipeWaitForNoCharges
            local edgeWait = fd.frame._arcEdgeWaitForNoCharges
            fd.frame._arcBypassSwipeHook = true
            if fullyDepleted then
                -- All charges consumed: always show both swipe and edge
                cooldown:SetDrawSwipe(true)
                cooldown:SetDrawEdge(true)
            else
                -- Recharging: respect per-component wait settings
                cooldown:SetDrawSwipe(not swipeWait)
                cooldown:SetDrawEdge(not edgeWait)
            end
            fd.frame._arcBypassSwipeHook = false
        end
    else
        if noGCD and isOnGCD then
            cooldown:Clear()
        else
            local cooldownDurObj = nil
            pcall(function() cooldownDurObj = C_Spell.GetSpellCooldownDuration(spellID) end)
            if cooldownDurObj then
                pcall(function()
                    cooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
                end)
            else
                cooldown:Clear()
            end
        end
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 4. CHARGE TEXT
    -- ───────────────────────────────────────────────────────────────────
    UpdateChargeText(fd, settings)

    -- ───────────────────────────────────────────────────────────────────
    -- 5. GLOW STATE UPDATE (explicit call for ALL spells)
    --    desatCooldown hooks drive ApplySpellStateVisuals on state CHANGES,
    --    but several scenarios need evaluation without a state change:
    --    - Charge spells: FULLY READY → RECHARGING (desatCD stays hidden)
    --    - Preview toggle: spell already ready, desatCD stays hidden
    --    - Combat state changes affecting combatOnly glows
    --    - Settings changes via UpdateIcon
    --    The glow signature check prevents redundant glow restarts,
    --    so calling this every FeedCooldown is effectively free.
    -- ───────────────────────────────────────────────────────────────────
    local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
    ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
end

-- Expose FeedCooldown for ArcAuras hooks to call
ArcAurasCooldown.FeedCooldown = FeedCooldown

-- ═══════════════════════════════════════════════════════════════════════════
-- CHARGE TEXT (non-secret, safe to read directly)
-- ═══════════════════════════════════════════════════════════════════════════

UpdateChargeText = function(fd, settings)
    if not fd or not fd.chargeText then return end
    if not fd.isChargeSpell then
        fd.chargeText:SetText("")
        return
    end

    -- Respect chargeText.enabled from settings cascade (DEFAULT → global → per-icon)
    -- Without this, hiding charge text via options gets overridden every cooldown event
    local chargeCfg = settings and settings.chargeText
    if chargeCfg and chargeCfg.enabled == false then
        fd.chargeText:SetText("")
        fd.chargeText:Hide()
        return
    end

    local chargeInfo = nil
    pcall(function() chargeInfo = C_Spell.GetSpellCharges(fd.spellID) end)
    if chargeInfo then
        -- currentCharges is SECRET in combat — SetText accepts secrets, no comparisons!
        fd.chargeText:SetText(chargeInfo.currentCharges or "")
        fd.chargeText:Show()
    end
    -- If chargeInfo is nil (GCD transition), keep last text — don't clear/flicker
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROC GLOW (SPELL_ACTIVATION_OVERLAY events, spellID is non-secret)
-- ═══════════════════════════════════════════════════════════════════════════

UpdateProcGlow = function(fd, forceShow)
    if not fd or not fd.frame then return end

    local spellID = fd.spellID
    local isOverlayed = forceShow

    if isOverlayed == nil then
        local ok = pcall(function()
            isOverlayed = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed(spellID)
        end)
        -- If pcall failed (secret value / API unavailable in combat),
        -- DON'T change state — keep glow running if already active
        if not ok then
            return
        end
    end

    -- Read proc glow settings from CDMEnhance per-icon config
    local settings = nil
    if ArcAuras.GetCachedSettings then
        settings = ArcAuras.GetCachedSettings(fd.arcID)
    end
    local procCfg = settings and settings.procGlow

    -- Check if proc glow is disabled via per-icon settings
    if procCfg and procCfg.enabled == false then
        if fd.procGlowActive then
            StopGlow(fd.frame, fd.procGlowType or "blizzard", "proc")
            fd.procGlowActive = false
            fd.procGlowType = nil
        end
        return
    end

    if isOverlayed then
        if not fd.procGlowActive then
            -- Map CDMEnhance glowType names to our StartGlow names:
            --   CDMEnhance "default" → our "blizzard" (ActionButtonSpellAlertManager)
            --   CDMEnhance "proc"    → our "glow"     (LCG ProcGlow)
            --   pixel/autocast/button pass through unchanged
            local cfgType = procCfg and procCfg.glowType or "default"
            local glowType
            if cfgType == "default" then
                glowType = "blizzard"
            elseif cfgType == "proc" then
                glowType = "glow"
            else
                glowType = cfgType  -- "pixel", "autocast", "button"
            end

            -- Color: nil = Blizzard default gold for blizzard type
            local gc = nil
            if procCfg and procCfg.color then
                gc = procCfg.color
            end

            if glowType == "button" then
            end

            StartGlow(fd.frame, glowType, gc, {
                key = "proc",
                lines = procCfg and procCfg.lines or 8,
                frequency = procCfg and procCfg.speed or 0.25,
                thickness = procCfg and procCfg.thickness or 2,
                particles = procCfg and procCfg.particles or 4,
                scale = procCfg and procCfg.scale or 1,
            })
            fd.procGlowActive = true
            fd.procGlowType = glowType
            -- Mirror to frame so CDMEnhance.StopAllGlows knows proc owns ButtonGlow
            fd.frame._arcProcGlowActive = true
            fd.frame._arcProcGlowType = glowType
        end
    elseif fd.procGlowActive then
        StopGlow(fd.frame, fd.procGlowType or "blizzard", "proc")
        fd.procGlowActive = false
        fd.procGlowType = nil
        fd.frame._arcProcGlowActive = false
        fd.frame._arcProcGlowType = nil
    end
end
ArcAurasCooldown.UpdateProcGlow = UpdateProcGlow

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZE SPELL FRAME
--
-- Called by ArcAuras.Enable() after ArcAuras.CreateFrame() builds the frame.
-- Builds the frameData engine state for an existing frame.
-- ArcAuras.CreateFrame already created: Icon, Cooldown, DesatCooldown + hooks,
-- _arcCountContainer, _arcStackText, _arcGlowAnchor, _arcBorderOverlay, etc.
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.InitializeSpellFrame(arcID, frame, config)
    if not frame or not config or not config.spellID then return nil end
    if ArcAurasCooldown.spellData[arcID] then return ArcAurasCooldown.spellData[arcID] end

    local spellID = config.spellID
    local spellInfo = C_Spell.GetSpellInfo(spellID)

    -- Build frameData — the engine state that drives FeedCooldown
    local fd = {
        frame          = frame,
        icon           = frame.Icon,
        cooldown       = frame.Cooldown,
        desatCooldown  = frame._arcDesatCooldown,
        chargeText     = frame._arcStackText,
        spellID        = spellID,
        arcID          = arcID,
        spellInfo      = spellInfo,
        -- Engine state
        isChargeSpell  = false, -- set below, cached to prevent flicker
        desaturate     = true,  -- default: desaturate when on CD
        lastIsOnGCD    = nil,   -- cached from SPELL_UPDATE_COOLDOWN
        procGlowActive = false,
        procGlowType   = nil,
        -- Usability / range state
        needsRangeCheck = false,
        rangeCheckSpellID = nil,
        spellOutOfRange = false,
        -- Usable glow state
        usableGlowActive = false,
        usableGlowType = nil,
    }

    -- Store back-reference on both cooldown frames so hooks can find frameData
    if frame._arcDesatCooldown then
        frame._arcDesatCooldown._arcFrameData = fd
    end
    if frame.Cooldown then
        frame.Cooldown._arcFrameData = fd
    end

    -- Detect charge spell (cached once, prevents flicker)
    local chargeInfo = nil
    pcall(function() chargeInfo = C_Spell.GetSpellCharges(spellID) end)
    fd.isChargeSpell = (chargeInfo ~= nil)

    -- Range check setup — EnableSpellRangeCheck opts in to SPELL_RANGE_CHECK_UPDATE
    if C_Spell.SpellHasRange and C_Spell.EnableSpellRangeCheck then
        local hasRange = C_Spell.SpellHasRange(spellID)
        if hasRange then
            fd.needsRangeCheck = true
            fd.rangeCheckSpellID = spellID
            C_Spell.EnableSpellRangeCheck(spellID, true)
            local inRange = C_Spell.IsSpellInRange(spellID)
            fd.spellOutOfRange = (inRange == false)
        end
    end

    -- Register in all tables
    ArcAurasCooldown.spellFrames[arcID] = frame
    ArcAurasCooldown.spellData[arcID] = fd
    ArcAurasCooldown.spellsByID[spellID] = arcID

    -- CDMEnhance registration + Masque
    ArcAuras.RegisterWithCDMEnhance(arcID, frame)
    if ns.Masque and ns.Masque.RegisterFrame then ns.Masque.RegisterFrame(frame) end

    -- Apply structural settings from CDMEnhance (size, borders, swipe config)
    if ArcAuras.ApplySettingsToFrame then
        ArcAuras.ApplySettingsToFrame(arcID, frame)
    end
    if ns.CDMEnhance and ns.CDMEnhance.ApplyIconStyle then
        ns.CDMEnhance.ApplyIconStyle(frame, arcID)
    end

    -- Initial feed + proc glow
    FeedCooldown(fd)
    UpdateProcGlow(fd)

    return fd
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTEXT MENU
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.ShowContextMenu(frame)
    if not frame or not frame._arcAuraID then return end
    local arcID = frame._arcAuraID
    local spellName = GetSpellNameAndIcon(frame._arcSpellID) or arcID
    
    -- Get config for current state
    local db = GetDB()
    local config = db and db.trackedSpells and db.trackedSpells[arcID]
    local isForceShow = config and config.forceShow or false
    
    local menuList = {
        {text = spellName, isTitle = true},
        {text = "Configure in CDM Icons", func = function()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
                ns.CDMEnhanceOptions.SelectIcon(arcID, false)
            end
        end},
        {text = isForceShow and "|cff00FF00✓|r Always Show (bypass spec check)" or "Always Show (bypass spec check)", func = function()
            if config then
                config.forceShow = not config.forceShow
                if config.forceShow then
                    print("|cff00CCFF[Arc Auras]|r " .. spellName .. " will now always show regardless of spec.")
                    -- If frame was hidden, show it now
                    if frame._arcHiddenNotInSpec then
                        ArcAurasCooldown.ShowFrame(arcID)
                    end
                    -- If frame doesn't exist yet, create it
                    if not ArcAurasCooldown.spellData[arcID] and ArcAuras.isEnabled then
                        local spellConfig = {
                            type = "spell",
                            spellID = config.spellID,
                            name = config.name,
                            icon = config.iconOverride or config.icon,
                            enabled = true,
                        }
                        local newFrame = ArcAuras.CreateFrame(arcID, spellConfig)
                        if newFrame then
                            ArcAuras.LoadFramePosition(arcID, newFrame)
                            newFrame:Show()
                            ArcAurasCooldown.InitializeSpellFrame(arcID, newFrame, spellConfig)
                        end
                    end
                else
                    print("|cff00CCFF[Arc Auras]|r " .. spellName .. " will respect spec checks again.")
                    ArcAurasCooldown.RefreshSpecVisibility()
                end
            end
        end},
        {text = "Change Icon...", func = function()
            ArcAurasCooldown.ShowIconOverridePicker(arcID, frame)
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
-- ICON OVERRIDE
-- Lets users change the displayed icon for any Arc Aura spell frame.
-- Accepts a spell ID or item ID; stores iconOverride in trackedSpells config.
-- ═══════════════════════════════════════════════════════════════════════════

StaticPopupDialogs["ARCAURAS_CD_ICON_OVERRIDE"] = {
    text = "Enter a Spell ID or Item ID for the new icon:\n(Enter 0 or leave blank to reset to default)",
    button1 = "Apply", button2 = "Cancel",
    hasEditBox = true,
    OnShow = function(self)
        self.editBox:SetNumeric(true)
        self.editBox:SetFocus()
        -- Pre-fill with current override if any
        local data = self.data
        if data and data.currentOverrideID then
            self.editBox:SetText(tostring(data.currentOverrideID))
            self.editBox:HighlightText()
        end
    end,
    OnAccept = function(self, data)
        local inputID = tonumber(self.editBox:GetText())
        if data and data.arcID then
            ArcAurasCooldown.ApplyIconOverride(data.arcID, inputID)
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        local inputID = tonumber(self:GetText())
        local data = dialog.data
        if data and data.arcID then
            ArcAurasCooldown.ApplyIconOverride(data.arcID, inputID)
        end
        dialog:Hide()
    end,
    timeout = 0, whileDead = true, hideOnEscape = true,
}

function ArcAurasCooldown.ShowIconOverridePicker(arcID, frame)
    local db = GetDB()
    local config = db and db.trackedSpells and db.trackedSpells[arcID]
    
    local currentOverrideID = nil
    if config and config.iconOverrideID then
        currentOverrideID = config.iconOverrideID
    end
    
    local dialog = StaticPopup_Show("ARCAURAS_CD_ICON_OVERRIDE")
    if dialog then
        dialog.data = {
            arcID = arcID,
            currentOverrideID = currentOverrideID,
        }
        if currentOverrideID and dialog.editBox then
            dialog.editBox:SetText(tostring(currentOverrideID))
            dialog.editBox:HighlightText()
        end
    end
end

function ArcAurasCooldown.ApplyIconOverride(arcID, overrideID)
    local db = GetDB()
    if not db or not db.trackedSpells or not db.trackedSpells[arcID] then return end
    
    local config = db.trackedSpells[arcID]
    
    -- Reset if 0 or nil
    if not overrideID or overrideID <= 0 then
        config.iconOverride = nil
        config.iconOverrideID = nil
        -- Restore original icon
        local name, originalIcon = GetSpellNameAndIcon(config.spellID)
        config.icon = originalIcon or config.icon
        
        local frame = ArcAuras.frames and ArcAuras.frames[arcID]
        if frame and frame.Icon then
            frame.Icon:SetTexture(config.icon or 134400)
        end
        print("|cff00CCFF[Arc Auras]|r Icon reset to default for " .. (config.name or arcID))
        return
    end
    
    -- Try as spell ID first, then item ID
    local newIcon = nil
    local sourceName = nil
    
    local spellInfo = C_Spell.GetSpellInfo(overrideID)
    if spellInfo and (spellInfo.iconID or spellInfo.originalIconID) then
        newIcon = spellInfo.iconID or spellInfo.originalIconID
        sourceName = spellInfo.name
    end
    
    if not newIcon then
        -- Try as item ID
        local itemIcon = C_Item.GetItemIconByID(overrideID)
        if itemIcon then
            newIcon = itemIcon
            local itemName = C_Item.GetItemNameByID(overrideID)
            sourceName = itemName or ("Item " .. overrideID)
        end
    end
    
    if not newIcon then
        print("|cff00CCFF[Arc Auras]|r Could not find icon for ID " .. overrideID)
        return
    end
    
    -- Save override
    config.iconOverride = newIcon
    config.iconOverrideID = overrideID
    
    -- Apply immediately
    local frame = ArcAuras.frames and ArcAuras.frames[arcID]
    if frame and frame.Icon then
        frame.Icon:SetTexture(newIcon)
    end
    
    print(string.format("|cff00CCFF[Arc Auras]|r Icon changed to %s (%d) for %s",
        sourceName or "?", overrideID, config.name or arcID))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FRAME LIFECYCLE (hide / show for spec changes)
-- Frame creation/destruction now handled by ArcAuras core
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.HideFrame(arcID)
    local fd = ArcAurasCooldown.spellData[arcID]
    if not fd or not fd.frame then return end
    fd.frame._arcHiddenNotInSpec = true
    -- Disable range check to stop unnecessary events while hidden
    if fd.needsRangeCheck and fd.rangeCheckSpellID and C_Spell.EnableSpellRangeCheck then
        C_Spell.EnableSpellRangeCheck(fd.rangeCheckSpellID, false)
    end
    if fd.procGlowActive then
        StopGlow(fd.frame, fd.procGlowType or "blizzard", "proc")
        fd.procGlowActive = false
        fd.procGlowType = nil
        fd.frame._arcProcGlowActive = false
        fd.frame._arcProcGlowType = nil
    end
    if fd.usableGlowActive then
        StopUsableGlow(fd.frame)
        fd.usableGlowActive = false
        fd.usableGlowType = nil
    end
    if fd.frame._arcReadyGlowActive then
        if ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
            ns.CDMEnhance.HideReadyGlow(fd.frame)
        end
    end
    -- Cache current position on frame BEFORE unregistering
    if ns.CDMGroups then
        if ns.CDMGroups.groups then
            for groupName, group in pairs(ns.CDMGroups.groups) do
                if group.members and group.members[arcID] then
                    local member = group.members[arcID]
                    fd.frame._arcSavedGroupName = groupName
                    fd.frame._arcSavedRow = member.row
                    fd.frame._arcSavedCol = member.col
                    break
                end
            end
        end
        if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
            local freeData = ns.CDMGroups.freeIcons[arcID]
            fd.frame._arcSavedFreeX = freeData.x
            fd.frame._arcSavedFreeY = freeData.y
            fd.frame._arcSavedFreeSize = freeData.iconSize
            fd.frame._arcWasFreeIcon = true
        end
        if ns.CDMGroups.UnregisterExternalFrame then
            ns.CDMGroups.UnregisterExternalFrame(arcID)
        end
    end
    fd.frame:Hide()
end

function ArcAurasCooldown.ShowFrame(arcID)
    local fd = ArcAurasCooldown.spellData[arcID]
    if not fd or not fd.frame then return end
    fd.frame._arcHiddenNotInSpec = nil
    -- Re-enable range check
    if fd.needsRangeCheck and fd.rangeCheckSpellID and C_Spell.EnableSpellRangeCheck then
        C_Spell.EnableSpellRangeCheck(fd.rangeCheckSpellID, true)
        local inRange = C_Spell.IsSpellInRange(fd.rangeCheckSpellID)
        fd.spellOutOfRange = (inRange == false)
    end
    fd.frame:Show()

    -- ── SKIP position restore during spec changes ──
    -- ShowFrame fires at 0.5s but CDMGroups hasn't loaded the new spec's
    -- savedPositions yet (happens at 0.8s). If we read savedPositions now,
    -- we get the OLD spec's data and TrackFreeIcon corrupts the DB by
    -- writing type=free over the correct type=group entry.
    -- CDMGroups.RestoreArcAurasPositions handles position restore at 0.8s+.
    local specChangeActive = ns.CDMGroups and (
        ns.CDMGroups.specChangeInProgress
        or ns.CDMGroups._pendingSpecChange
        or (ns.CDMGroups.lastSpecChangeTime and (GetTime() - ns.CDMGroups.lastSpecChangeTime) < 5)
    )

    if not specChangeActive and ns.CDMGroups then
        -- Refresh savedPositions for current spec/profile
        if ns.CDMGroups.GetProfileSavedPositions then
            ns.CDMGroups.GetProfileSavedPositions()
        end

        local saved = ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
        local restored = false

        if saved then
            if saved.type == "group" and saved.target then
                local group = ns.CDMGroups.groups and ns.CDMGroups.groups[saved.target]
                if group then
                    if group.members and group.members[arcID] then
                        group.members[arcID] = nil
                    end
                    local row = saved.row or 0
                    local col = saved.col or 0
                    if group.AddMemberAtWithFrame then
                        group:AddMemberAtWithFrame(arcID, row, col, fd.frame, nil)
                    elseif ns.CDMGroups.RegisterExternalFrame then
                        ns.CDMGroups.RegisterExternalFrame(arcID, fd.frame, "cooldown", saved.target)
                    end
                    if group.Layout then group:Layout() end
                    restored = true
                end
            elseif saved.type == "free" then
                if ns.CDMGroups.freeIcons and ns.CDMGroups.freeIcons[arcID] then
                    ns.CDMGroups.freeIcons[arcID] = nil
                end
                if ns.CDMGroups.TrackFreeIcon then
                    ns.CDMGroups.TrackFreeIcon(arcID, saved.x or 0, saved.y or 0, saved.iconSize or 36, fd.frame)
                end
                restored = true
            end
        end

        -- Fallback: frame-cached position from HideFrame
        if not restored and fd.frame._arcWasFreeIcon then
            if ns.CDMGroups.TrackFreeIcon then
                ns.CDMGroups.TrackFreeIcon(arcID, fd.frame._arcSavedFreeX or 0, fd.frame._arcSavedFreeY or 0, fd.frame._arcSavedFreeSize or 36, fd.frame)
            end
            fd.frame._arcWasFreeIcon = nil
            fd.frame._arcSavedFreeX = nil
            fd.frame._arcSavedFreeY = nil
            fd.frame._arcSavedFreeSize = nil
            restored = true
        end

        if not restored and fd.frame._arcSavedGroupName then
            local group = ns.CDMGroups.groups and ns.CDMGroups.groups[fd.frame._arcSavedGroupName]
            if group then
                if group.AddMemberAtWithFrame then
                    group:AddMemberAtWithFrame(arcID, fd.frame._arcSavedRow or 0, fd.frame._arcSavedCol or 0, fd.frame, nil)
                elseif ns.CDMGroups.RegisterExternalFrame then
                    ns.CDMGroups.RegisterExternalFrame(arcID, fd.frame, "cooldown", fd.frame._arcSavedGroupName)
                end
                if group.Layout then group:Layout() end
            else
                if ns.CDMGroups.RegisterExternalFrame then
                    ns.CDMGroups.RegisterExternalFrame(arcID, fd.frame, "cooldown", "Essential")
                end
            end
            fd.frame._arcSavedGroupName = nil
            fd.frame._arcSavedRow = nil
            fd.frame._arcSavedCol = nil
            restored = true
        end

        -- Last resort: register as new
        if not restored then
            if ns.CDMGroups.RegisterExternalFrame then
                ns.CDMGroups.RegisterExternalFrame(arcID, fd.frame, "cooldown", "Essential")
            end
        end
    end

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
    if not spellID or type(spellID) ~= "number" or spellID <= 0 then return false end
    local db = GetDB()
    if not db then return false end

    local arcID = ArcAuras.MakeSpellID(spellID)
    if db.trackedSpells[arcID] then return true end -- already tracked

    local name, icon = GetSpellNameAndIcon(spellID)
    
    db.trackedSpells[arcID] = {
        spellID = spellID,
        name = name or ("Spell " .. spellID),
        icon = icon or 134400,
        -- forceShow defaults to nil (off). User can enable via options or right-click menu
        -- for engineering enchants, items-as-spells, profession abilities, etc.
    }

    if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end

    if ArcAuras.isEnabled and ArcAurasCooldown.ShouldFrameBeVisible(db.trackedSpells[arcID], spellID) then
        local spellConfig = {
            type = "spell",
            spellID = spellID,
            name = name or ("Spell " .. spellID),
            icon = icon or 134400,
            enabled = true,
        }
        local frame = ArcAuras.CreateFrame(arcID, spellConfig)
        if frame then
            ArcAuras.LoadFramePosition(arcID, frame)
            frame:Show()
            ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
        end
    elseif not PlayerKnowsSpell(spellID) then
        -- Spell not known — inform user they can enable Always Show
        print(string.format(
            "|cff00CCFF[Arc Auras]|r %s (%d) not detected as a class spell — enable |cff00FF00Always Show|r in options or right-click to make it visible.",
            name or "Spell", spellID))
    end
    
    return true
end

function ArcAurasCooldown.RemoveTrackedSpell(arcID)
    local db = GetDB()
    if not db or not db.trackedSpells then return end
    if db.trackedSpells[arcID] then
        local name = db.trackedSpells[arcID].name or arcID
        db.trackedSpells[arcID] = nil
        -- ArcAuras.DestroyFrame handles spell cleanup (clears spellData, spellFrames, spellsByID)
        ArcAuras.DestroyFrame(arcID)
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
-- VISIBILITY CHECK
--
-- Evaluates all conditions that determine whether a custom cooldown frame
-- should be visible: spell known, spec filter, and talent conditions.
-- Used by RefreshSpecVisibility, AddTrackedSpell, and ArcAuras creation.
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)
    if not spellID then return false end

    -- forceShow bypasses the "spell known" check entirely.
    -- Used for engineering enchants, items-as-spells, and other non-class spells
    -- that return false from IsPlayerSpell/IsSpellKnown but are still usable.
    if config.forceShow then
        -- Still respect per-spell spec filter and talent conditions
    else
        -- 1) Spell must be known in current spec
        if not PlayerKnowsSpell(spellID) then return false end
    end

    -- 2) Per-spell spec filter (showOnSpecs = { 1, 3 } etc.)
    if config.showOnSpecs and #config.showOnSpecs > 0 then
        local currentSpec = GetSpecialization() or 1
        local specAllowed = false
        for _, spec in ipairs(config.showOnSpecs) do
            if spec == currentSpec then specAllowed = true break end
        end
        if not specAllowed then return false end
    end

    -- 3) Talent conditions ({nodeID, required} objects)
    if config.talentConditions and #config.talentConditions > 0 then
        if ns.TalentPicker and ns.TalentPicker.CheckTalentConditions then
            local pass = ns.TalentPicker.CheckTalentConditions(
                config.talentConditions, config.talentConditionMode or "all")
            if not pass then return false end
        end
    end

    return true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPEC / TALENT CHANGE
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.RefreshSpecVisibility()
    if not ArcAuras.isEnabled then return end
    local db = GetDB()
    if not db or not db.trackedSpells then return end

    local changed = false
    for arcID, config in pairs(db.trackedSpells) do
        local spellID = config.spellID
        local fd = ArcAurasCooldown.spellData[arcID]
        local visible = ArcAurasCooldown.ShouldFrameBeVisible(config, spellID)

        if visible then
            if not fd then
                -- New spell available in this spec — create frame + init engine
                local spellConfig = {
                    type = "spell",
                    spellID = spellID,
                    name = config.name,
                    icon = config.iconOverride or config.icon,
                    enabled = true,
                }
                local frame = ArcAuras.CreateFrame(arcID, spellConfig)
                if frame then
                    ArcAuras.LoadFramePosition(arcID, frame)
                    frame:Show()
                    ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
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
-- DesatCooldown hooks drive desaturation + state visuals from frame state.
-- ═══════════════════════════════════════════════════════════════════════════

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("SPELL_UPDATE_CHARGES")
eventFrame:RegisterEvent("SPELL_UPDATE_USES")
eventFrame:RegisterEvent("SPELL_UPDATE_USABLE")
eventFrame:RegisterEvent("SPELL_RANGE_CHECK_UPDATE")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW")
eventFrame:RegisterEvent("SPELL_ACTIVATION_OVERLAY_GLOW_HIDE")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

local specChangePending = false

eventFrame:SetScript("OnEvent", function(self, event, arg1, arg2, arg3)

    if event == "SPELL_UPDATE_COOLDOWN" then
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                local cooldownInfo = nil
                pcall(function() cooldownInfo = C_Spell.GetSpellCooldown(fd.spellID) end)
                if cooldownInfo then
                    fd.lastIsOnGCD = cooldownInfo.isOnGCD
                end
                FeedCooldown(fd)
            end
        end

    elseif event == "SPELL_UPDATE_USABLE" then
        -- No payload — resource state changed, refresh icon color for all visible frames
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
                ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
            end
        end

    elseif event == "SPELL_RANGE_CHECK_UPDATE" then
        -- arg1=spellID, arg2=inRange, arg3=checksRange
        local spellID, inRange, checksRange = arg1, arg2, arg3
        local arcID = ArcAurasCooldown.spellsByID[spellID]
        local fd = arcID and ArcAurasCooldown.spellData[arcID]
        if fd and fd.needsRangeCheck then
            fd.spellOutOfRange = (checksRange == true and inRange == false)
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
                ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
            end
        end

    elseif event == "SPELL_UPDATE_USES" then
        local spellID = arg1
        local baseSpellID = arg2
        local arcID = ArcAurasCooldown.spellsByID[spellID] or ArcAurasCooldown.spellsByID[baseSpellID]
        local fd = arcID and ArcAurasCooldown.spellData[arcID]
        if fd and fd.frame and fd.frame:IsShown() then
            FeedCooldown(fd)
        end

    elseif event == "SPELL_UPDATE_CHARGES" then
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.isChargeSpell and fd.frame and fd.frame:IsShown() then
                FeedCooldown(fd)
            end
        end

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
        local spellID = arg1
        local arcID = ArcAurasCooldown.spellsByID[spellID]
        local fd = arcID and ArcAurasCooldown.spellData[arcID]
        if fd then
            UpdateProcGlow(fd, true)
            FeedCooldown(fd)
        end

    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local spellID = arg1
        local arcID = ArcAurasCooldown.spellsByID[spellID]
        local fd = arcID and ArcAurasCooldown.spellData[arcID]
        if fd then
            UpdateProcGlow(fd, false)
            FeedCooldown(fd)
        end

    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        -- Combat state changed: re-evaluate combatOnly glows for all visible spell frames
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
                ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
            end
        end

    elseif event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        if ArcAurasCooldown.initialized and not specChangePending then
            C_Timer.After(0.5, function()
                ArcAurasCooldown.RefreshSpecVisibility()
            end)
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if not specChangePending then
            specChangePending = true
            -- CRITICAL: Must run BEFORE CDMGroups.RestoreArcAurasPositions (at 0.8s)
            -- so that _arcHiddenNotInSpec flags are correct when the restore pass
            -- decides which frames to position. Old 3.5s delay meant RestoreArcAurasPositions
            -- skipped all hidden frames, and ShowFrame at 3.5s skipped position restore
            -- because specChangeActive was still true → frames lost positions/groups.
            C_Timer.After(0.3, function()
                ArcAurasCooldown.RefreshSpecVisibility()
            end)
            -- Safety retry after CDMGroups' post-protection restore (1.7s) completes
            -- Catches frames that weren't ready at 0.3s (e.g. newly created spells)
            C_Timer.After(2.5, function()
                specChangePending = false
                ArcAurasCooldown.RefreshSpecVisibility()
                -- Catch any frames that ShowFrame showed but CDMGroups missed
                if ns.CDMGroups and ns.CDMGroups.RestoreArcAurasPositions then
                    ns.CDMGroups.RestoreArcAurasPositions("|cffff9900[ArcAurasCooldown Safety]|r")
                end
            end)
        end
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS PANEL STATE MONITOR
--
-- Spell frames are event-driven (no polling). When the options panel opens,
-- frames at readyAlpha=0 or cooldownAlpha=0 need to show at 0.35 preview.
-- When it closes, they need to return to their actual alpha.
-- This lightweight ticker checks for panel state changes every 0.5s.
-- ═══════════════════════════════════════════════════════════════════════════

local lastPanelOpenState = false
C_Timer.NewTicker(0.5, function()
    local isOpen = ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen
                   and ns.CDMEnhance.IsOptionsPanelOpen() or false
    if isOpen ~= lastPanelOpenState then
        lastPanelOpenState = isOpen
        -- Panel state changed — re-evaluate all spell frame visuals
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                -- Clear cached alpha so it re-applies with new panel state
                fd.frame._lastAppliedAlpha = nil
                local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
                ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
            end
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

    -- Catch-up: Early SPELLS_CHANGED/TRAIT_CONFIG_UPDATED events fire before
    -- initialized=true, so RefreshSpecVisibility never ran for them.
    -- Run it now to hide any frames that Enable() created but shouldn't be visible.
    C_Timer.After(0.3, function()
        ArcAurasCooldown.RefreshSpecVisibility()
    end)

    -- Delayed re-feed to catch timing issues
    C_Timer.After(1.5, function()
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() then
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
            if fd.procGlowActive then
                StopGlow(fd.frame, fd.procGlowType or "blizzard", "proc")
                fd.procGlowActive = false
                fd.procGlowType = nil
            end
            if fd.usableGlowActive then
                StopUsableGlow(fd.frame)
                fd.usableGlowActive = false
                fd.usableGlowType = nil
            end
            if fd.frame._arcReadyGlowActive then
                if ns.CDMEnhance and ns.CDMEnhance.HideReadyGlow then
                    ns.CDMEnhance.HideReadyGlow(fd.frame)
                end
            end
            if ArcAuras.ApplySettingsToFrame then ArcAuras.ApplySettingsToFrame(arcID, fd.frame) end
            FeedCooldown(fd)
            UpdateProcGlow(fd)
        end
    end
end

-- Refresh a single spell frame's visuals (called by preview toggles)
function ArcAurasCooldown.RefreshSpellVisuals(arcID)
    local fd = ArcAurasCooldown.spellData and ArcAurasCooldown.spellData[arcID]
    if not fd or not fd.frame or not fd.frame:IsShown() or fd.frame._arcHiddenNotInSpec then return end
    if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end
    local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
    ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
end

-- Refresh ALL spell frame visuals without rebuilding frame size/appearance.
-- Use for glow/tint/alpha changes that don't affect frame geometry.
function ArcAurasCooldown.RefreshAllSpellVisuals()
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
            if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end
            local isOnCD = fd.desatCooldown and fd.desatCooldown:IsShown() or false
            ArcAurasCooldown.ApplySpellStateVisuals(fd, isOnCD)
        end
    end
end

-- Force-stop all usable glows so they restart with fresh settings on next visual refresh.
-- Called by SpellUsabilityOptions when glow params change (speed, scale, color, etc.)
function ArcAurasCooldown.StopAllUsableGlows()
    for _, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.usableGlowActive and fd.frame then
            StopUsableGlow(fd.frame)
            fd.usableGlowActive = false
            fd.usableGlowType = nil
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API (for Options / CDMEnhance catalog)
-- ═══════════════════════════════════════════════════════════════════════════

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
    for arcID, config in pairs(db.trackedSpells) do
        local spellID = config.spellID
        local name, icon = GetSpellNameAndIcon(spellID)
        table.insert(spells, {
            arcID = arcID,
            spellID = spellID,
            name = name or config.name or "Unknown",
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