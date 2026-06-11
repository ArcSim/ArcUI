-- ═══════════════════════════════════════════════════════════════════════════
-- ArcUI Arc Auras Cooldown - Spell Cooldown Event Engine
-- v4.2 - Refactor: Replaced ~500 lines of local glow functions with unified
--         ns.Glows module (ArcUI_Glows.lua). No more overlays — LCG keys
--         handle simultaneous glows natively. Resize handled by module.
-- v4.1 - Fix: CDMEnhance enforcement hooks (SetDesaturated, SetVertexColor)
--         were overriding ArcAurasCooldown's visual writes after CooldownState
--         rework added _arcDesiredVertexColor/_arcForceDesatValue checks.
--         Added bypass flags matching the existing SetAlpha bypass pattern.
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
--   GCD: Passed as ignoreGCD parameter to GetSpellCooldownDuration /
--        GetSpellChargeDuration. API strips GCD at the source when
--        filtering is on — zero cached flags, zero event-timing dependencies.
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
local Track = _G.ArcUIProfiler_Track
local Track = _G.ArcUIProfiler_Track

-- ═══════════════════════════════════════════════════════════════════════════
-- LIBRARIES
-- ═══════════════════════════════════════════════════════════════════════════

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
    if not spellID or type(spellID) ~= "number" then return false end
    -- Reject secret sentinels and values outside int32 range. These crash
    -- IsSpellKnown / IsPlayerSpell ("bad argument — outside expected range").
    -- Sentinel values like -9223372036854775808 (INT64_MIN) appear when an
    -- item's ID is mis-routed through a spell API. Our frame-data loops
    -- sometimes walk over item entries (trinkets) whose arcID lives alongside
    -- spell arcIDs — guard here instead of at every caller.
    if issecretvalue and issecretvalue(spellID) then return false end
    if spellID <= 0 or spellID > 2147483647 then return false end
    if IsPlayerSpell and IsPlayerSpell(spellID) then return true end
    if IsSpellKnown and IsSpellKnown(spellID) then return true end
    return false
end

ArcAurasCooldown.PlayerKnowsSpell = PlayerKnowsSpell
ArcAurasCooldown.GetSpellNameAndIcon = GetSpellNameAndIcon

-- ═══════════════════════════════════════════════════════════════════════════
-- GLOW HELPERS
-- ═══════════════════════════════════════════════════════════════════════════
-- FORWARD DECLARATIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════
-- SHADOW-FRAME STATE DETECTION
--
-- Each tracked spell gets two hidden Cooldown frames (_arcShadowCD and
-- _arcShadowCharge) fed with ignoreGCD=true duration objects. State is
-- derived from IsShown() on each:
--
--   (main=false, charge=false) → READY           — fully castable
--   (main=true,  charge=false) → ON_COOLDOWN     — normal spell on CD
--   (main=false, charge=true ) → RECHARGING      — charge spell, 1+ avail
--   (main=true,  charge=true ) → DEPLETED        — charge spell, all gone
--
-- ignoreGCD=true strips GCD at the source, so IsShown() reflects only real
-- cooldown / real recharge state — zero isActive heuristics, zero GCD
-- contamination, zero secret-value reads.
-- ═══════════════════════════════════════════════════════════════════════════

-- Lazily create the shadow pair on first use. Shadows are offscreen/alpha=0
-- so they never render — we only read their IsShown() state.
local function EnsureShadowFrames(fd)
    if fd._arcShadowCD and fd._arcShadowCharge then return end
    local function makeShadow()
        local w = CreateFrame("Cooldown", nil, UIParent, "CooldownFrameTemplate")
        w:SetSize(1, 1)
        w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -100, -100)
        w:SetAlpha(0)
        w:EnableMouse(false)
        w:SetHideCountdownNumbers(true)
        w:SetDrawEdge(false)
        w:SetDrawBling(false)
        w:Show()
        return w
    end
    if not fd._arcShadowCD     then fd._arcShadowCD     = makeShadow() end
    if not fd._arcShadowCharge then fd._arcShadowCharge = makeShadow() end
end

-- Feed both shadows with ignoreGCD=true durObjs. Zero-span durObj = widget
-- auto-hides, which is exactly the "ready / not running" state we want.
local function FeedShadows(fd)
    if not fd or not fd.spellID then return end
    EnsureShadowFrames(fd)

    if C_Spell.GetSpellCooldownDuration then
        local dur = C_Spell.GetSpellCooldownDuration(fd.spellID, true)
        if dur then
            fd._arcShadowCD:SetCooldownFromDurationObject(dur, true)
        else
            fd._arcShadowCD:Clear()
        end
    end

    if C_Spell.GetSpellChargeDuration then
        local dur = C_Spell.GetSpellChargeDuration(fd.spellID, true)
        if dur then
            fd._arcShadowCharge:SetCooldownFromDurationObject(dur, true)
        else
            fd._arcShadowCharge:Clear()
        end
    end
end

-- GetCooldownState: returns (isOnCD, isRecharging) for FeedCooldown / visuals.
--
-- READ-ONLY. Does not feed shadows. FeedShadows is called only from
-- FeedCooldown, which itself is called only on cooldown-relevant events
-- with correct filtering (SPELL_UPDATE_COOLDOWN for our spell or bulk nil,
-- SPELL_UPDATE_CHARGES for charge spells only). Non-feed callers
-- (SPELL_UPDATE_USABLE, SPELL_RANGE_CHECK_UPDATE) read the last-known
-- shadow state — correct because those events don't change cooldown state.
--
-- Normal spells:
--   isOnCD      = mainShown       (real CD running)
--   isRecharging = false          (normals don't recharge)
--
-- Charge spells:
--   DEPLETED   (main=true,  charge=true)  → isOnCD=true,  isRecharging=false
--   RECHARGING (main=false, charge=true)  → isOnCD=false, isRecharging=true
--   READY      (main=false, charge=false) → isOnCD=false, isRecharging=false
local function GetCooldownState(spellID, isChargeSpell)
    local fd
    local arcID = ArcAurasCooldown.spellsByID and ArcAurasCooldown.spellsByID[spellID]
    if arcID and ArcAurasCooldown.spellData then
        fd = ArcAurasCooldown.spellData[arcID]
    end
    if not fd then return false, false end

    -- Custom timer frame: read state from the timer engine, not shadow frames.
    -- isOnCD = timer is running; timers never "recharge".
    if fd.isCustomTimer then
        if ns.ArcAurasTimer and ns.ArcAurasTimer.IsTimerRunning then
            return ns.ArcAurasTimer.IsTimerRunning(fd.arcID) or false, false
        end
        return false, false
    end

    if not fd._arcShadowCD or not fd._arcShadowCharge then
        return false, false
    end

    local mainShown   = fd._arcShadowCD:IsShown()     or false
    local chargeShown = fd._arcShadowCharge:IsShown() or false

    if isChargeSpell then
        local isDepleted   = mainShown and chargeShown
        local isRecharging = (not mainShown) and chargeShown
        -- isOnCD in the charge context = fully depleted
        return isDepleted, isRecharging
    end

    -- Normal spell: only main shadow matters
    return mainShown, false
end

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
--          color {r,g,b,a}, alphaOverride (number or nil), desat (boolean)
-- ═══════════════════════════════════════════════════════════════════════════

local _GUS = function(fd, settings)
    if not fd or not fd.spellID then return "usable", USABLE_COLOR, nil, false end

    local su = settings and settings.spellUsability
    local suEnabled = not su or su.enabled ~= false  -- default: enabled

    -- Range check (highest priority) — respects rangeIndicator.enabled toggle
    if fd.spellOutOfRange then
        local ri = settings and settings.rangeIndicator
        local rangeEnabled = not ri or ri.enabled ~= false
        if rangeEnabled then
            return "outOfRange", OUT_OF_RANGE_COLOR, nil, false
        end
    end

    -- Usability check — C_Spell.IsSpellUsable returns non-secret booleans
    local isUsable, notEnoughMana = C_Spell.IsSpellUsable(fd.spellID)

    if isUsable then
        return "usable", USABLE_COLOR, nil, false
    elseif not suEnabled then
        -- Usability tinting disabled — return white (no tint applied)
        return "usable", USABLE_COLOR, nil, false
    elseif notEnoughMana then
        local color = (su and su.notEnoughResourceColor) or NOT_ENOUGH_MANA
        if not color.a then color = { r = color.r, g = color.g, b = color.b, a = 1.0 } end
        local alpha = su and su.notEnoughResourceAlpha  -- nil = don't override
        local desat = su and su.notEnoughResourceDesaturate or false
        return "notEnoughResource", color, alpha, desat
    else
        local color = (su and su.notUsableColor) or NOT_USABLE_COLOR
        if not color.a then color = { r = color.r, g = color.g, b = color.b, a = 1.0 } end
        local alpha = su and su.notUsableAlpha  -- nil = don't override
        local desat = su and su.notUsableDesaturate or false
        return "notUsable", color, alpha, desat
    end
end
local GetUsabilityState = Track and Track("ArcAurasCooldown.GetUsabilityState", _GUS) or _GUS

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

local _ASV = function(fd, isOnCD, passedSettings, passedIsRecharging)
    if not fd or not fd.frame or not fd.icon then return end

    local frame = fd.frame
    local arcID = fd.arcID
    local iconTex = fd.icon

    -- Get CDMEnhance settings (READ ONLY — we decide when to apply)
    -- Accept passed settings from FeedCooldown to avoid double lookup
    local settings = passedSettings
    if not settings and ArcAuras.GetCachedSettings then
        settings = ArcAuras.GetCachedSettings(arcID)
    end

    -- Compute usability state once (used for tint, alpha, glow, desat decisions)
    local usabilityState, usabilityColor, usabilityAlpha, usabilityDesat = GetUsabilityState(fd, settings)

    -- ═══════════════════════════════════════════════════════════════
    -- STATE-CHANGE DETECTION: Skip expensive visual application
    -- if the computed state is identical to last call.
    -- Cleared on settings changes via _arcLastSpellState = nil.
    -- ═══════════════════════════════════════════════════════════════
    -- isRecharging passed from GetCooldownState (chargesInfo.isActive, non-secret, no GCD filter needed)
    local isRecharging = passedIsRecharging or false

    -- Check if glow preview is active
    local isGlowPreview = ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.IsGlowPreviewActive
                          and ns.CDMEnhanceOptions.IsGlowPreviewActive(arcID)

    -- Composite state key: all inputs that affect visual output
    -- InCombatLockdown included because combatOnly glows depend on it
    local stateKey = isOnCD
    local stateKey2 = isRecharging
    local stateKey3 = usabilityState
    local stateKey4 = isGlowPreview
    local stateKey5 = InCombatLockdown()
    local stateKey6 = frame._arcProcGlowActive or false

    local prev = frame._arcLastSpellState
    if prev
        and prev[1] == stateKey
        and prev[2] == stateKey2
        and prev[3] == stateKey3
        and prev[4] == stateKey4
        and prev[5] == stateKey5
        and prev[6] == stateKey6 then
        return  -- Nothing changed, skip all visual work
    end

    -- Cache current state for next comparison
    if not prev then
        frame._arcLastSpellState = { stateKey, stateKey2, stateKey3, stateKey4, stateKey5, stateKey6 }
    else
        prev[1] = stateKey
        prev[2] = stateKey2
        prev[3] = stateKey3
        prev[4] = stateKey4
        prev[5] = stateKey5
        prev[6] = stateKey6
    end

    -- Get state visuals from settings
    local csv = settings and settings.cooldownStateVisuals or {}
    local rs = csv.readyState or {}
    local cs = csv.cooldownState or {}

    -- Get effective state visuals from CDMEnhance (handles cascade properly)
    local stateVisuals = nil
    if ns.CDMEnhance and ns.CDMEnhance.GetEffectiveStateVisuals then
        stateVisuals = ns.CDMEnhance.GetEffectiveStateVisuals(settings)
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
        frame._arcBypassDesatHook = true
        iconTex:SetDesaturated(not noDesat)
        frame._arcBypassDesatHook = false

        -- Alpha
        local cdAlpha = (stateVisuals and stateVisuals.cooldownAlpha ~= nil) and stateVisuals.cooldownAlpha
                     or (cs.alpha ~= nil and cs.alpha or 1.0)
        -- Proc override: if a proc glow is active and the setting is enabled, show at full alpha
        if frame._arcProcGlowActive then
            local procOverride = (stateVisuals and stateVisuals.cooldownProcOverride) or cs.procOverride
            if procOverride then cdAlpha = 1.0 end
        end
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
        local parentContainer = frame:GetParent()
        local groupHidden = frame._arcGroupHidden or (parentContainer and parentContainer._arcGroupHidden)
        if preserve and not groupHidden then
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
        frame._arcBypassVertexHook = true
        if tint and tint.r then
            iconTex:SetVertexColor(tint.r, tint.g, tint.b, tint.a or 1)
        else
            -- No custom tint — apply usability-based coloring (matches CDM behavior)
            local uc = GetUsabilityColor(fd, settings)
            iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a)
        end
        frame._arcBypassVertexHook = false

    else
        -- ═══════════════════════════════════════════════════════════════
        -- READY: Desat from usability (OOM/not-usable), restore alpha
        -- ═══════════════════════════════════════════════════════════════

        -- Desaturation: user-configured readyDesaturate OR spellUsability.normalDesaturate OR usability-based desat
        local readyDesat = usabilityDesat
        local su = settings and settings.spellUsability
        if stateVisuals and stateVisuals.readyDesaturate then
            readyDesat = true  -- From cooldownStateVisuals.readyState.desaturate (aura options)
        elseif su and su.normalDesaturate then
            readyDesat = true  -- From spellUsability.normalDesaturate (cooldown options)
        end
        frame._arcBypassDesatHook = true
        iconTex:SetDesaturated(readyDesat)
        frame._arcBypassDesatHook = false

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
        local readyAlpha = (stateVisuals and stateVisuals.readyAlpha ~= nil) and stateVisuals.readyAlpha
                        or (rs.alpha ~= nil and rs.alpha or 1.0)
        -- Usability alpha override: when spell is NOT usable, override readyAlpha
        if usabilityAlpha and usabilityState ~= "usable" and usabilityState ~= "outOfRange" then
            readyAlpha = usabilityAlpha
        end
        -- Proc override: if a proc glow is active and the setting is enabled, show at full alpha
        -- This beats usability alpha too — proc takes full precedence
        if frame._arcProcGlowActive then
            local procOverride = (stateVisuals and stateVisuals.readyProcOverride) or rs.procOverride
            if procOverride then readyAlpha = 1.0 end
        end
        -- Capture the "user actually wants this hidden" intent BEFORE the
        -- options-panel preview bump. This drives the CooldownFlash bling
        -- suppression below: when the user has readyAlpha=0, we don't want
        -- the flash animation playing on top of an otherwise-invisible
        -- icon (the flash is its own frame with its own alpha and would
        -- otherwise produce a visible "ghost flash" for ~0.8s).
        local hideEverything = readyAlpha <= 0
        -- OPTIONS PANEL PREVIEW: If alpha is 0, show at 0.35 so user can see the icon while editing
        if readyAlpha <= 0 then
            if ns.CDMEnhance and ns.CDMEnhance.IsOptionsPanelOpen and ns.CDMEnhance.IsOptionsPanelOpen() then
                readyAlpha = 0.35
            end
        end
        -- Suppress / kill the CD→ready flash bling when the icon is meant
        -- to be invisible. The flag is read by the flash trigger block
        -- further down in this function (search _arcHideCooldownFlash).
        -- Also stop any flash that's already playing — this catches the
        -- case where readyAlpha was just changed in options while a flash
        -- happened to be mid-animation.
        frame._arcHideCooldownFlash = hideEverything
        if hideEverything and frame.CooldownFlash then
            local cf = frame.CooldownFlash
            if cf:IsShown() then
                cf:Hide()
                if cf.FlashAnim and cf.FlashAnim.Stop then cf.FlashAnim:Stop() end
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

        -- Tint: check cooldownStateVisuals.readyState (aura options) OR spellUsability (cooldown options)
        local readyTint = stateVisuals and stateVisuals.readyTint
        local tint = readyTint and ((stateVisuals and stateVisuals.readyTintColor) or rs.tintColor) or nil
        -- Fallback: spellUsability.useNormalColor (cooldown options "Custom Tint" toggle)
        if not tint and su and su.useNormalColor then
            tint = su.normalColor or { r = 1, g = 1, b = 1 }
        end
        frame._arcBypassVertexHook = true
        if tint and tint.r then
            iconTex:SetVertexColor(tint.r, tint.g, tint.b, tint.a or 1)
        else
            -- No custom tint — apply usability-based coloring (matches CDM behavior)
            local uc = GetUsabilityColor(fd, settings)
            iconTex:SetVertexColor(uc.r, uc.g, uc.b, uc.a)
        end
        frame._arcBypassVertexHook = false
    end

    -- ═══════════════════════════════════════════════════════════════
    -- READY GLOW — uses ns.Glows unified module.
    -- No overlays needed — LCG keys handle simultaneous glows.
    -- ═══════════════════════════════════════════════════════════════
    local shouldShowGlow = false

    if isGlowEligible then
        if isGlowPreview then
            shouldShowGlow = true
        elseif (stateVisuals and stateVisuals.readyGlow) or (rs.glow == true) then
            local combatOnly = (stateVisuals and stateVisuals.readyGlowCombatOnly)
                            or (rs.glowCombatOnly == true)
            shouldShowGlow = not combatOnly or InCombatLockdown()
        end
    end

    if shouldShowGlow then
        -- Read glow params from stateVisuals (CDMEnhance cascade) or raw settings
        local glowType = (stateVisuals and stateVisuals.readyGlowType) or rs.glowType or "button"
        local gc = (stateVisuals and stateVisuals.readyGlowColor) or rs.glowColor
        -- Only restart glow if type changed or not active
        if not fd.readyGlowActive or fd.readyGlowType ~= glowType then
            -- Stop old glow if type changed
            if fd.readyGlowActive and fd.readyGlowType then
                ns.Glows.ForceHide(frame, "ready")
            end
            ns.Glows.Start(frame, "ready", glowType, {
                color = gc,
                lines = (stateVisuals and stateVisuals.readyGlowLines) or rs.glowLines or 8,
                frequency = (stateVisuals and stateVisuals.readyGlowSpeed) or rs.glowSpeed or 0.25,
                thickness = (stateVisuals and stateVisuals.readyGlowThickness) or rs.glowThickness or 2,
                particles = (stateVisuals and stateVisuals.readyGlowParticles) or rs.glowParticles or 4,
                scale = (stateVisuals and stateVisuals.readyGlowScale) or rs.glowScale or 1,
                intensity = (stateVisuals and stateVisuals.readyGlowIntensity) or rs.glowIntensity or 1.0,
                xOffset = (stateVisuals and stateVisuals.readyGlowXOffset) or rs.glowXOffset or 0,
                yOffset = (stateVisuals and stateVisuals.readyGlowYOffset) or rs.glowYOffset or 0,
                strata = (stateVisuals and stateVisuals.readyGlowFrameStrata) or rs.glowFrameStrata,
                frameLevel = (stateVisuals and stateVisuals.readyGlowFrameLevel) or rs.glowFrameLevel,
            })
            fd.readyGlowActive = true
            fd.readyGlowType = glowType
        end
    elseif fd.readyGlowActive then
        ns.Glows.ForceHide(frame, "ready")
        fd.readyGlowActive = false
        fd.readyGlowType = nil
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
        if glowType == "blizzard" then glowType = "proc" end  -- migrate removed option
        -- Only restart glow if type changed or not active
        if not fd.usableGlowActive or fd.usableGlowType ~= glowType then
            -- Stop old glow if type changed
            if fd.usableGlowActive and fd.usableGlowType then
                ns.Glows.ForceHide(frame, "usable")
            end
            local gc = glowSu.usableGlowColor
            ns.Glows.Start(frame, "usable", glowType, {
                color = gc,
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
        ns.Glows.ForceHide(frame, "usable")
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
        
        -- Update custom label visibility on state change
        if ns.CustomLabel and ns.CustomLabel.UpdateVisibility then
            ns.CustomLabel.UpdateVisibility(frame)
        end
        
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
ArcAurasCooldown.ApplySpellStateVisuals = Track and Track("ArcAurasCooldown.ApplySpellStateVisuals", _ASV) or _ASV
local ApplySpellStateVisuals = ArcAurasCooldown.ApplySpellStateVisuals

-- ═══════════════════════════════════════════════════════════════════════════
-- FEED COOLDOWN (EVENT-DRIVEN ONLY)
--
-- This is the core engine. Called from events, NOT from OnUpdate.
-- CooldownFrameTemplate is self-animating once fed a DurationObject.
--
-- Flow:
--   1. Read noGCD setting from CDMEnhance frame flag
--   2. Feed shadow frames + derive isOnCD/isRecharging state
--   3. Feed visible Cooldown: drives swipe + countdown text (uses noGCD as
--      ignoreGCD parameter to the duration APIs — API strips GCD at source)
--   4. Update charge text
-- ═══════════════════════════════════════════════════════════════════════════

local _FeedCooldownFn
_FeedCooldownFn = function(fd)
    if not fd or not fd.frame or not fd.frame:IsShown() then return end
    if fd.frame._arcHiddenNotInSpec then return end

    local spellID = fd.spellID
    local isChargeSpell = fd.isChargeSpell

    -- Get CDMEnhance settings ONCE — passed to both UpdateChargeText and ApplySpellStateVisuals
    local settings = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(fd.arcID) or nil

    -- ───────────────────────────────────────────────────────────────────
    -- CUSTOM TIMER FRAMES: skip shadow feed + the spell-API cooldown feed.
    -- Ask the Timer engine to (re-)push its own swipe from startTime/duration,
    -- then run the standard visual pipeline (desat, glows, alpha, border)
    -- based on whether the timer is currently running.
    -- ───────────────────────────────────────────────────────────────────
    if fd.isCustomTimer then
        if ns.ArcAurasTimer and ns.ArcAurasTimer.RefreshTimerFrame then
            ns.ArcAurasTimer.RefreshTimerFrame(fd.arcID)
        end
        local isOnCD = false
        if ns.ArcAurasTimer and ns.ArcAurasTimer.IsTimerRunning then
            isOnCD = ns.ArcAurasTimer.IsTimerRunning(fd.arcID) or false
        end
        UpdateChargeText(fd, settings)
        ApplySpellStateVisuals(fd, isOnCD, settings, false)
        return
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 1. NOGCD SETTING (read from CDMEnhance frame flag, set by ApplyIconStyle)
    --    Defaults to true (filter GCD) if CDMEnhance hasn't configured it yet.
    --    Passed as ignoreGCD parameter to the duration APIs — the API strips
    --    GCD at the source, so no cached flag or event-timing dependency.
    -- ───────────────────────────────────────────────────────────────────
    local noGCD = fd.frame._arcNoGCDSwipeEnabled
    if noGCD == nil then noGCD = true end

    -- ───────────────────────────────────────────────────────────────────
    -- 2. SHADOW STATE via IsShown() on hidden Cooldown frames
    --    Feed both shadows with ignoreGCD=true durObjs, then read IsShown()
    --    via GetCooldownState. Zero-span durObj → widget auto-hides = ready.
    --    FeedShadows is called here (not inside GetCooldownState) so non-feed
    --    callers (USABLE / RANGE events) don't do redundant API work.
    -- ───────────────────────────────────────────────────────────────────
    FeedShadows(fd)
    local isOnCD, isRecharging = GetCooldownState(spellID, isChargeSpell)

    -- ───────────────────────────────────────────────────────────────────
    -- 3. FEED VISIBLE COOLDOWN (swipe + countdown)
    -- ───────────────────────────────────────────────────────────────────
    local cooldown = fd.cooldown

    if isChargeSpell then
        if isRecharging then
            -- Charge recharging: show charge timer (ignoreGCD=true — recharge
            -- is its own track, GCD isn't relevant here).
            local chargeDurObj = C_Spell.GetSpellChargeDuration(spellID, true)
            if chargeDurObj then
                cooldown:SetCooldownFromDurationObject(chargeDurObj, true)
            else
                cooldown:Clear()
            end
        elseif isOnCD then
            -- Fully depleted: show full cooldown (ignoreGCD=true — real CD, not GCD).
            local cooldownDurObj = C_Spell.GetSpellCooldownDuration(spellID, true)
            if cooldownDurObj then
                cooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
            else
                cooldown:Clear()
            end
        else
            -- Charges available, not depleted, not recharging.
            -- Let the API decide: ignoreGCD=noGCD. If noGCD=false and we're on
            -- GCD, the durObj includes GCD and swipe shows. If noGCD=true or
            -- no GCD active, durObj is zero-span and widget auto-hides. Same
            -- mechanism as the normal-spell branch — no cached isOnGCD needed.
            local cooldownDurObj = C_Spell.GetSpellCooldownDuration(spellID, noGCD and true or nil)
            if cooldownDurObj then
                cooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
            else
                cooldown:Clear()
            end
        end

        -- Swipe/edge: fully depleted = show normally, recharging/ready = apply wait flags
        local swipeWait = fd.frame._arcSwipeWaitForNoCharges
        local edgeWait = fd.frame._arcEdgeWaitForNoCharges
        local showEdge = not settings or not settings.cooldownSwipe or settings.cooldownSwipe.showEdge ~= false
        local showSwipe = not settings or not settings.cooldownSwipe or settings.cooldownSwipe.showSwipe ~= false
        fd.frame._arcBypassSwipeHook = true
        if isOnCD then
            cooldown:SetDrawSwipe(showSwipe)
            cooldown:SetDrawEdge(showEdge)
        else
            cooldown:SetDrawSwipe(showSwipe and not swipeWait)
            cooldown:SetDrawEdge(showEdge and not edgeWait)
        end
        fd.frame._arcBypassSwipeHook = false
    else
        -- Normal spell: GCD filter via noGCD flag.
        -- Use ignoreGCD=true (same mechanism as shadow frames) — API strips GCD
        -- at the source, so GCD-only returns a zero-span durObj and the widget
        -- auto-hides. Zero heuristics, zero event-timing dependencies.
        local cooldownDurObj = C_Spell.GetSpellCooldownDuration(spellID, noGCD and true or nil)
        if cooldownDurObj then
            cooldown:SetCooldownFromDurationObject(cooldownDurObj, true)
        else
            cooldown:Clear()
        end
        local showEdge = not settings or not settings.cooldownSwipe or settings.cooldownSwipe.showEdge ~= false
        fd.frame._arcBypassSwipeHook = true
        cooldown:SetDrawEdge(showEdge)
        fd.frame._arcBypassSwipeHook = false
    end

    -- ───────────────────────────────────────────────────────────────────
    -- 4. CHARGE TEXT
    -- ───────────────────────────────────────────────────────────────────
    UpdateChargeText(fd, settings)

    -- ───────────────────────────────────────────────────────────────────
    -- 5. GLOW STATE UPDATE (explicit call for ALL spells)
    --    ApplySpellStateVisuals is called every FeedCooldown with fresh isOnCD.
    --    The state-change guard prevents redundant visual restarts,
    --    so calling this every FeedCooldown is effectively free.
    -- ───────────────────────────────────────────────────────────────────
    local isOnCD, isRechargingFinal = GetCooldownState(fd.spellID, fd.isChargeSpell)
    ApplySpellStateVisuals(fd, isOnCD, settings, isRechargingFinal)
end

-- Wrap FeedCooldown for profiler visibility, then expose
FeedCooldown = Track and Track("ArcAurasCooldown.FeedCooldown", _FeedCooldownFn) or _FeedCooldownFn
FeedCooldown = Track and Track("ArcAurasCooldown.FeedCooldown", _FeedCooldownFn) or _FeedCooldownFn
-- Expose FeedCooldown for ArcAuras hooks to call
ArcAurasCooldown.FeedCooldown = FeedCooldown

-- ═══════════════════════════════════════════════════════════════════════════
-- CHARGE TEXT (non-secret, safe to read directly)
-- ═══════════════════════════════════════════════════════════════════════════

UpdateChargeText = function(fd, settings)
    if not fd or not fd.chargeText then return end

    -- Custom Icons (Arc Auras timers) own their stack text directly via
    -- ArcAurasTimer + ArcAuras.ApplyStackText. We must NOT touch it from
    -- this spell-cooldown path or it flickers — UpdateChargeText would
    -- SetText("") because timer spells aren't charge spells, then the
    -- next IncrementStack would restore it, causing visible flicker on
    -- every cooldown / cast / glow event tick.
    local arcID = fd.arcID
    if arcID then
        local db = ns.db and ns.db.char and ns.db.char.arcAuras
        if db and db.customTimers and db.customTimers[arcID] then
            return
        end
    end

    if not fd.hasChargeText then
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

    local chargeInfo = C_Spell.GetSpellCharges(fd.spellID)
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
        if C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed then
            local ok, result = pcall(C_SpellActivationOverlay.IsSpellOverlayed, spellID)
            if not ok then return end  -- pcall failed, don't change state
            isOverlayed = result
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
            ns.Glows.Stop(fd.frame, "proc")
            fd.procGlowActive = false
            fd.procGlowType = nil
        end
        return
    end

    if isOverlayed then
        if not fd.procGlowActive then
            -- Map CDMEnhance glowType names to ns.Glows names:
            --   CDMEnhance "default" → "blizzard" (ActionButtonSpellAlertTemplate)
            --   CDMEnhance "proc"    → "proc"     (LCG ProcGlow)
            --   pixel/autocast/button/ants/ach_proc pass through unchanged
            local cfgType = procCfg and procCfg.glowType or "default"
            local glowType
            if cfgType == "default" then
                glowType = "blizzard"
            else
                glowType = cfgType  -- "pixel", "autocast", "button", "proc", "ants", "ach_proc"
            end

            -- Color: nil = Blizzard default gold for blizzard type
            local gc = nil
            if procCfg and procCfg.color then
                gc = procCfg.color
            end

            ns.Glows.Start(fd.frame, "proc", glowType, {
                color = gc,
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
        ns.Glows.Stop(fd.frame, "proc")
        fd.procGlowActive = false
        fd.procGlowType = nil
        fd.frame._arcProcGlowActive = false
        fd.frame._arcProcGlowType = nil
    end
end
ArcAurasCooldown.UpdateProcGlow = UpdateProcGlow

-- 3.6.6: RefreshAllChargeText — re-render the charge-count text on every
-- registered spell frame. Called from ArcAuras.RefreshStackTextStyle when the
-- user changes a chargeText option in the CDMEnhance options panel, so the
-- updated styling immediately gets paired with a fresh value push. Without
-- this, ApplyStackTextStyle restyles the FontString but UpdateChargeText
-- isn't re-invoked until the next cooldown event, which causes the number
-- to disappear momentarily until the user closes the options panel or a
-- cooldown event fires. Custom-timer frames are skipped because their text
-- is owned by ArcAuras.ApplyStackText (not this cooldown path).
function ArcAurasCooldown.RefreshAllChargeText()
    if not ArcAurasCooldown.spellData then return end
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd and fd.chargeText and not fd.isCustomTimer then
            local settings = ArcAuras.GetCachedSettings and ArcAuras.GetCachedSettings(arcID) or nil
            UpdateChargeText(fd, settings)
        end
    end
end

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
        -- desatCooldown removed: state now via GetCooldownState() isActive booleans
        chargeText     = frame._arcStackText,
        spellID        = spellID,
        arcID          = arcID,
        spellInfo      = spellInfo,
        -- Engine state
        isChargeSpell  = false, -- set below, cached to prevent flicker
        desaturate     = true,  -- default: desaturate when on CD
        procGlowActive = false,
        procGlowType   = nil,
        -- Usability / range state
        needsRangeCheck = false,
        rangeCheckSpellID = nil,
        spellOutOfRange = false,
        -- Usable glow state
        usableGlowActive = false,
        usableGlowType = nil,
        -- Ready glow state (self-contained, no CDMEnhance delegation)
        readyGlowActive = false,
        readyGlowType = nil,
    }

    -- Store back-reference on both cooldown frames so hooks can find frameData
    -- desatCooldown removed: no frame linkback needed
    if frame.Cooldown then
        frame.Cooldown._arcFrameData = fd
    end

    -- Detect charge spell (cached once, prevents flicker).
    -- IMPORTANT: GetSpellCharges returns a non-nil table even for spells with
    -- maxCharges=1 (e.g. Crash Lightning). Those behave like normal spells and
    -- must be classified as non-charge — chargesInfo.isActive doesn't have the
    -- same meaning for max=1 as for max=2+. Only classify as a charge spell
    -- when maxCharges is genuinely > 1. maxCharges is NON-SECRET (12.0.1).
    --
    -- 3.6.6: hasChargeText is a separate flag for the "should we render the
    -- charge count?" decision. Some max=1 spells legitimately have a current
    -- charge counter the user wants to see (Blizzard sometimes uses max=1 for
    -- spells whose currentCharges can go above max via procs). We render the
    -- text for ANY spell where GetSpellCharges returned a table, even max=1,
    -- but we still gate cooldown semantics (recharging logic, glow-while-
    -- charges, etc.) on isChargeSpell to avoid mis-treating max=1 as max>1.
    local chargeInfo = C_Spell.GetSpellCharges(spellID)
    fd.isChargeSpell = (chargeInfo ~= nil)
                       and (tonumber(chargeInfo.maxCharges) or 0) > 1
    fd.hasChargeText = (chargeInfo ~= nil)

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

    -- CDMEnhance registration (Masque registration already handled by ArcAuras.CreateFrame)
    ArcAuras.RegisterWithCDMEnhance(arcID, frame)

    -- ═══════════════════════════════════════════════════════════════════
    -- ALPHA ENFORCEMENT HOOK for arc_spell frames.
    -- Arc Aura spell frames call ApplyIconStyle (not EnhanceFrame), so
    -- CDMEnhance's _arcFrameAlphaHooked SetAlpha hook is never installed.
    -- Without it, anything calling SetAlpha(1) after ApplySpellStateVisuals
    -- applies readyAlpha=0 silently overrides it (FrameController, Show
    -- hooks, group layouts). We install the same logic here directly.
    -- ═══════════════════════════════════════════════════════════════════
    if not frame._arcFrameAlphaHooked then
        frame._arcFrameAlphaHooked = true
        hooksecurefunc(frame, "SetAlpha", function(self, alpha)
            if self._arcBypassFrameAlphaHook then return end
            -- Enforce ready-state alpha (e.g. readyAlpha=0 when spell is ready)
            if self._arcEnforceReadyAlpha and self._arcReadyAlphaValue then
                self._arcBypassFrameAlphaHook = true
                self:SetAlpha(self._arcReadyAlphaValue)
                self._arcBypassFrameAlphaHook = false
                self._lastAppliedAlpha = self._arcReadyAlphaValue
                return
            end
            -- Enforce cooldown-state alpha
            if self._arcTargetAlpha ~= nil then
                self._arcBypassFrameAlphaHook = true
                self:SetAlpha(self._arcTargetAlpha)
                self._arcBypassFrameAlphaHook = false
                self._lastAppliedAlpha = self._arcTargetAlpha
                return
            end
            -- Fallback: preserve whatever we last applied
            if self._arcEnhanced and self._lastAppliedAlpha then
                self._arcBypassFrameAlphaHook = true
                self:SetAlpha(self._lastAppliedAlpha)
                self._arcBypassFrameAlphaHook = false
            end
        end)
    end

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
    
    MenuUtil.CreateContextMenu(frame, function(ownerRegion, rootDescription)
        rootDescription:CreateTitle(spellName)
        rootDescription:CreateButton("Configure in CDM Icons", function()
            if ns.CDMEnhanceOptions and ns.CDMEnhanceOptions.SelectIcon then
                ns.CDMEnhanceOptions.SelectIcon(arcID, false)
            end
        end)
        local forceLabel = isForceShow and "|cff00FF00✓|r Always Show (bypass spec check)" or "Always Show (bypass spec check)"
        rootDescription:CreateButton(forceLabel, function()
            if config then
                config.forceShow = not config.forceShow
                if config.forceShow then
                    print("|cff00CCFF[Arc Auras]|r " .. spellName .. " will now always show regardless of spec.")
                    if frame._arcHiddenNotInSpec then
                        ArcAurasCooldown.ShowFrame(arcID)
                    end
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
        end)
        rootDescription:CreateButton("Change Icon...", function()
            ArcAurasCooldown.ShowIconOverridePicker(arcID, frame)
        end)
        rootDescription:CreateButton("Remove Spell", function()
            StaticPopup_Show("ARCAURAS_CD_REMOVE_SPELL", spellName, nil, {arcID = arcID})
        end)
    end)
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
    -- Disable range check before destruction
    if fd.needsRangeCheck and fd.rangeCheckSpellID and C_Spell.EnableSpellRangeCheck then
        C_Spell.EnableSpellRangeCheck(fd.rangeCheckSpellID, false)
    end
    -- Clean up shadow detection frames. They're offscreen Cooldown frames
    -- created by EnsureShadowFrames; clear + hide before losing the reference.
    if fd._arcShadowCD then
        fd._arcShadowCD:Clear()
        fd._arcShadowCD:Hide()
        fd._arcShadowCD:SetParent(nil)
        fd._arcShadowCD = nil
    end
    if fd._arcShadowCharge then
        fd._arcShadowCharge:Clear()
        fd._arcShadowCharge:Hide()
        fd._arcShadowCharge:SetParent(nil)
        fd._arcShadowCharge = nil
    end
    -- Save position BEFORE destroy (UnregisterExternalFrame wipes savedPositions)
    local savedPos = ns.CDMGroups and ns.CDMGroups.savedPositions and ns.CDMGroups.savedPositions[arcID]
    -- Destroy the frame entirely
    ArcAuras.DestroyFrame(arcID)
    -- Restore savedPosition so re-creation on spec switch reads correct placement
    if savedPos and ns.CDMGroups and ns.CDMGroups.savedPositions then
        ns.CDMGroups.savedPositions[arcID] = savedPos
    end
end

function ArcAurasCooldown.ShowFrame(arcID)
    -- If frame already exists, nothing to do
    if ArcAurasCooldown.spellData[arcID] then return end
    
    local db = GetDB()
    if not db or not db.trackedSpells then return end
    local config = db.trackedSpells[arcID]
    if not config then return end
    
    -- Create the frame fresh. RegisterExternalFrame (called by CreateFrame)
    -- reads savedPositions and places it at the correct group/free position.
    -- If no savedPosition exists, it becomes a free icon at default position.
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
        ArcAurasCooldown.InitializeSpellFrame(arcID, frame, spellConfig)
    end
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

        if visible and not fd then
            -- Spell should be visible but no frame exists — create it
            -- RegisterExternalFrame reads savedPositions for correct placement.
            -- If no savedPosition exists, it becomes a free icon at default position.
            ArcAurasCooldown.ShowFrame(arcID)
            changed = true
        elseif not visible and fd then
            -- Spell should NOT be visible but frame exists — destroy it
            -- savedPositions persists so position is preserved for next show.
            ArcAurasCooldown.HideFrame(arcID)
            changed = true
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
_G.ArcUIArcAurasCooldownEventFrame = eventFrame  -- profiler
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
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
-- Party / raid roster changes can cascade through Blizzard's CDM and
-- silently reset our spell-cooldown frames' alpha enforcement. Without
-- handling this, frames configured with readyAlpha=0 pop back to alpha
-- 1 whenever someone joins/leaves the group. We re-run the visual
-- pipeline (via RefreshAllSpellVisuals) on a short debounce.
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

local specChangePending = false

local _onEventFn = function(self, event, arg1, arg2, arg3, arg4)

    if event == "SPELL_UPDATE_COOLDOWN" then
        -- Payload: spellID, baseSpellID, category, startRecoveryCategory
        -- Mirror CDM's NeedsCooldownUpdate filter:
        --   arg1 == nil                              — bulk update (refresh all)
        --   arg1 == our spell (or arg2 == our spell) — our spell's CD changed
        --   arg4 == GLOBAL_RECOVERY_CATEGORY         — GCD event (affects ALL
        --     tracked spells on GCD — without this filter, our charge spells
        --     miss GCD updates from other spells' casts and the swipe only
        --     shows intermittently when other events happen to trigger a feed)
        -- Custom timer frames are skipped entirely — their cooldown source is
        -- a user-defined timer, not the spell's real cooldown.
        local isBulkNil = (arg1 == nil)
        local isGCDEvent = arg4 == Constants.SpellCooldownConsts.GLOBAL_RECOVERY_CATEGORY
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if not fd.isCustomTimer and fd.frame and fd.frame:IsShown()
               and not fd.frame._arcHiddenNotInSpec then
                local isOurSpell = (arg1 == fd.spellID) or (arg2 == fd.spellID)
                if isOurSpell or isBulkNil or isGCDEvent then
                    FeedCooldown(fd)
                end
            end
        end

    elseif event == "SPELL_UPDATE_USABLE" then
        -- No payload — resource state changed, refresh icon color for all visible frames
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                local isOnCD, isRechargingV = GetCooldownState(fd.spellID, fd.isChargeSpell)
                ApplySpellStateVisuals(fd, isOnCD, nil, isRechargingV)
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
                local isOnCD, isRechargingV = GetCooldownState(fd.spellID, fd.isChargeSpell)
                ApplySpellStateVisuals(fd, isOnCD, nil, isRechargingV)
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
        -- SPELL_UPDATE_CHARGES fires ONLY meaningfully for real charge spells.
        -- Filter to fd.isChargeSpell to avoid iterating every tracked normal
        -- spell on unrelated classes' charge events (the event is global —
        -- it fires for ANY charge spell in the world, not just ours).
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.isChargeSpell and fd.frame and fd.frame:IsShown()
               and not fd.frame._arcHiddenNotInSpec then
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
        -- Combat state changed: re-feed all spell frames so shadow state is fresh
        -- and combatOnly glows evaluate correctly. FeedCooldown re-queries the
        -- spell's cooldown API and re-drives the shadow, fixing any stale state
        -- that accumulated while the old polling was no longer running.
        for arcID, fd in pairs(ArcAurasCooldown.spellData) do
            if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                fd.frame._arcLastSpellState = nil  -- Force re-eval even if state appears unchanged
                FeedCooldown(fd)
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Zone change or reload: shadow frames may have been reset.
        -- Deferred so CDM has time to rebuild its frames before we query spell state.
        C_Timer.After(1.5, function()
            for arcID, fd in pairs(ArcAurasCooldown.spellData) do
                if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                    fd.frame._arcLastSpellState = nil
                    FeedCooldown(fd)
                end
            end
        end)

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Party/raid composition changes cascade through Blizzard's CDM
        -- internals and silently reset our alpha enforcement: frames
        -- configured with readyAlpha=0 pop back to alpha 1 because the
        -- _arcEnforceReadyAlpha hook chain gets disturbed. Re-run the
        -- full visual pipeline on a short debounce so settings are
        -- re-asserted. RefreshAllSpellVisuals clears _lastAppliedAlpha
        -- (so the alpha guard doesn't short-circuit) and re-runs
        -- ApplySpellStateVisuals which re-installs all enforcement
        -- flags. Covers both spell-icon frames and timer frames since
        -- both are registered in spellData.
        C_Timer.After(0.3, function()
            if ArcAurasCooldown.initialized then
                ArcAurasCooldown.RefreshAllSpellVisuals()
            end
        end)

    elseif event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        if ArcAurasCooldown.initialized and not specChangePending then
            C_Timer.After(0.5, function()
                ArcAurasCooldown.RefreshSpecVisibility()
                -- Also refresh item visibility (items with showOnSpecs/talentConditions)
                -- Safe here because savedPositions are already correct (same spec)
                if ArcAuras and ArcAuras.RefreshVisibility then
                    ArcAuras.RefreshVisibility()
                end
                -- Fresh cooldown state pass after talent swap: spells may have changed
                -- cooldown duration, charges, or been replaced by talent variants.
                -- FeedCooldown re-queries the API and re-applies ready/cooldown visuals.
                for arcID, fd in pairs(ArcAurasCooldown.spellData) do
                    if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
                        fd.frame._arcLastSpellState = nil
                        FeedCooldown(fd)
                    end
                end
            end)
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if not specChangePending then
            specChangePending = true
            -- CRITICAL: Must run BEFORE CDMGroups.RestoreArcAurasPositions (at 0.8s)
            -- so that not-in-spec spells are destroyed before the restore pass
            -- decides which frames to position.
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
end
eventFrame:SetScript("OnEvent", Track and Track("ArcAurasCooldown.OnEvent", _onEventFn) or _onEventFn)

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS PANEL STATE MONITOR
--
-- Spell frames are event-driven (no polling). When the options panel opens,
-- frames at readyAlpha=0 or cooldownAlpha=0 need to show at 0.35 preview.
-- When it closes, they need to return to their actual alpha.
-- Uses Shared.RegisterPanelCallback (hook-based, zero polling).
-- ═══════════════════════════════════════════════════════════════════════════

local function RefreshAllSpellVisuals()
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
            fd.frame._lastAppliedAlpha = nil
            fd.frame._arcLastSpellState = nil
            local isOnCD, isRechargingV = GetCooldownState(fd.spellID, fd.isChargeSpell)
            ApplySpellStateVisuals(fd, isOnCD, nil, isRechargingV)
        end
    end
end

if ns.CDMShared and ns.CDMShared.RegisterPanelCallback then
    ns.CDMShared.RegisterPanelCallback("ArcAurasCooldown", {
        onOpen = RefreshAllSpellVisuals,
        onClose = RefreshAllSpellVisuals,
    })
end

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
                local chargeInfo = C_Spell.GetSpellCharges(fd.spellID)
                fd.isChargeSpell = (chargeInfo ~= nil)
                                   and (tonumber(chargeInfo.maxCharges) or 0) > 1
                fd.hasChargeText = (chargeInfo ~= nil)
                FeedCooldown(fd)
                UpdateProcGlow(fd)
            end
        end
    end)

    -- VISUAL FIX: Re-apply ready/cooldown state visuals after everything settles.
    -- FrameController repositions free icons and calls SetAlpha(1) at ~1-2s, which
    -- overrides any readyAlpha=0 that was set during frame creation. By 4.5s all
    -- positioning is done. RefreshAllSpellVisuals clears the alpha guard flags and
    -- re-applies the correct alpha from settings.
    C_Timer.After(4.5, function()
        if ArcAurasCooldown.initialized then
            ArcAurasCooldown.RefreshAllSpellVisuals()
        end
    end)
end

local initFrame = CreateFrame("Frame")
_G.ArcUIArcAurasCooldownInitFrame = initFrame  -- profiler
initFrame:RegisterEvent("PLAYER_LOGIN")
local _initOnEventFn = function()
    C_Timer.After(3, function()
        ArcAurasCooldown.Initialize()
    end)
end
initFrame:SetScript("OnEvent", Track and Track("ArcAurasCooldown.InitEvent", _initOnEventFn) or _initOnEventFn)

-- ═══════════════════════════════════════════════════════════════════════════
-- REFRESH ALL (called on settings change)
-- ═══════════════════════════════════════════════════════════════════════════

function ArcAurasCooldown.RefreshAllSettings()
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
            if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end
            if fd.procGlowActive or fd.usableGlowActive or fd.readyGlowActive then
                ns.Glows.ForceHideAll(fd.frame)
                fd.procGlowActive = false
                fd.procGlowType = nil
                fd.usableGlowActive = false
                fd.usableGlowType = nil
                fd.readyGlowActive = false
                fd.readyGlowType = nil
            end
            if ArcAuras.ApplySettingsToFrame then ArcAuras.ApplySettingsToFrame(arcID, fd.frame) end
            fd.frame._arcLastSpellState = nil  -- Settings changed, force re-eval
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
    fd.frame._arcLastSpellState = nil  -- Force re-eval after settings change
    -- Stop ready glow so it restarts with fresh settings
    if fd.readyGlowActive then
        ns.Glows.ForceHide(fd.frame, "ready")
        fd.readyGlowActive = false
        fd.readyGlowType = nil
    end
    local isOnCD, isRechargingV = GetCooldownState(fd.spellID, fd.isChargeSpell)
    ApplySpellStateVisuals(fd, isOnCD, nil, isRechargingV)
end

-- Refresh ALL spell frame visuals without rebuilding frame size/appearance.
-- Use for glow/tint/alpha changes that don't affect frame geometry.
function ArcAurasCooldown.RefreshAllSpellVisuals()
    for arcID, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.frame and fd.frame:IsShown() and not fd.frame._arcHiddenNotInSpec then
            if ArcAuras.InvalidateSettingsCache then ArcAuras.InvalidateSettingsCache(arcID) end
            -- Stop ready glow so it restarts with fresh settings
            if fd.readyGlowActive then
                ns.Glows.ForceHide(fd.frame, "ready")
                fd.readyGlowActive = false
                fd.readyGlowType = nil
            end
            fd.frame._arcLastSpellState = nil  -- Force re-eval (bypass state-change early return)
            -- CRITICAL: Clear _lastAppliedAlpha so the alpha guard in ApplySpellStateVisuals
            -- doesn't skip SetAlpha on reload. Without this, if readyAlpha was already applied
            -- during frame creation and hasn't changed, the guard short-circuits and the
            -- enforcement hook never gets _arcEnforceReadyAlpha set correctly.
            fd.frame._lastAppliedAlpha = nil
            local isOnCD, isRechargingV = GetCooldownState(fd.spellID, fd.isChargeSpell)
            ApplySpellStateVisuals(fd, isOnCD, nil, isRechargingV)
        end
    end
end

-- Force-stop all usable glows so they restart with fresh settings on next visual refresh.
-- Called by SpellUsabilityOptions when glow params change (speed, scale, color, etc.)
function ArcAurasCooldown.StopAllUsableGlows()
    for _, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.usableGlowActive and fd.frame then
            ns.Glows.ForceHide(fd.frame, "usable")
            fd.usableGlowActive = false
            fd.usableGlowType = nil
            fd.frame._arcLastSpellState = nil  -- Force re-eval
        end
    end
end

-- Force-stop all ready glows so they restart with fresh settings on next visual refresh.
function ArcAurasCooldown.StopAllReadyGlows()
    for _, fd in pairs(ArcAurasCooldown.spellData) do
        if fd.readyGlowActive and fd.frame then
            ns.Glows.ForceHide(fd.frame, "ready")
            fd.readyGlowActive = false
            fd.readyGlowType = nil
            fd.frame._arcLastSpellState = nil  -- Force re-eval (bypass state-change early return)
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
    local spells = {}
    if db and db.trackedSpells then
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
    end
    -- Include custom timer frames — they render as spell-like cooldown frames
    -- and need to appear in the per-icon Options picker so the user can edit
    -- size / readyAlpha / border / swipe etc. for them.
    -- Use ArcAuras.GetDB() explicitly — that's where Timer.lua stores timers.
    local adb = ns.ArcAuras and ns.ArcAuras.GetDB and ns.ArcAuras.GetDB() or nil
    local timers = adb and adb.customTimers
    if timers then
        for arcID, config in pairs(timers) do
            local spellID = config.spellID
            local name, icon = GetSpellNameAndIcon(spellID)
            table.insert(spells, {
                arcID = arcID,
                spellID = spellID,
                name = (name or "Spell " .. (spellID or "?")) .. " |cff888888(Timer)|r",
                icon = config.icon or icon or 134400,
                inCurrentSpec = true,   -- timers aren't spec-gated
                hasCustomSettings = ns.CDMEnhance and ns.CDMEnhance.HasPerIconSettings and ns.CDMEnhance.HasPerIconSettings(arcID),
                isCustomTimer = true,
            })
        end
    end
    table.sort(spells, function(a, b)
        if a.inCurrentSpec ~= b.inCurrentSpec then return a.inCurrentSpec end
        return a.name < b.name
    end)
    return spells
end

function ArcAurasCooldown.CreateCatalogEntry(cdID, frame)
    if not cdID or type(cdID) ~= "string" then return nil end
    local isSpell = cdID:match("^arc_spell_")
    local isTimer = cdID:match("^arc_timer_")
    if not isSpell and not isTimer then return nil end
    local spellID = frame and frame._arcSpellID
    local name, icon = nil, nil
    if spellID then name, icon = GetSpellNameAndIcon(spellID) end
    if not name or not icon then
        local db = GetDB()
        if isSpell and db and db.trackedSpells and db.trackedSpells[cdID] then
            name = name or db.trackedSpells[cdID].name
            icon = icon or db.trackedSpells[cdID].icon
        elseif isTimer then
            local adb = ns.ArcAuras and ns.ArcAuras.GetDB and ns.ArcAuras.GetDB() or nil
            local tcfg = adb and adb.customTimers and adb.customTimers[cdID]
            if tcfg then
                spellID = spellID or tcfg.spellID
                icon = icon or tcfg.icon
                if not name then name = GetSpellNameAndIcon(spellID) end
            end
        end
    end
    return {
        cdID = cdID, spellID = spellID,
        name = (name or ("Spell " .. (spellID or "?"))) .. (isTimer and " |cff888888(Timer)|r" or ""),
        icon = icon or 134400, frame = frame,
        isArcAura = true, isSpellCooldown = true,
        isCustomTimer = isTimer and true or nil,
        notInSpec = (isSpell and spellID and not PlayerKnowsSpell(spellID)) or false,
    }
end

function ArcAurasCooldown.GetSpellInfoForArcID(arcID)
    local db = GetDB()
    if db and db.trackedSpells and db.trackedSpells[arcID] then
        local config = db.trackedSpells[arcID]
        local name, icon = GetSpellNameAndIcon(config.spellID)
        return {
            spellID = config.spellID,
            name = name or config.name or "Unknown",
            icon = icon or config.icon or 134400,
            inCurrentSpec = PlayerKnowsSpell(config.spellID),
        }
    end
    -- Timer arcID? Resolve from customTimers via ArcAuras.GetDB (its writer).
    local adb = ns.ArcAuras and ns.ArcAuras.GetDB and ns.ArcAuras.GetDB() or nil
    local tcfg = adb and adb.customTimers and adb.customTimers[arcID]
    if tcfg then
        local name, icon = GetSpellNameAndIcon(tcfg.spellID)
        return {
            spellID = tcfg.spellID,
            name = (name or "Spell " .. (tcfg.spellID or "?")) .. " (Timer)",
            icon = tcfg.icon or icon or 134400,
            inCurrentSpec = true,
            isCustomTimer = true,
        }
    end
    return nil
end
-- Debug bridge: expose spellData for standalone debugger addons
_G.ArcUI_ArcAurasCooldown = ArcAurasCooldown
-- Register local functions for profiler visibility
if _G.ArcUIProfiler_RegisterLocals then
    local _wrapped = _G.ArcUIProfiler_RegisterLocals("ArcAurasCooldown", {
        FeedCooldown           = FeedCooldown,
        UpdateChargeText       = UpdateChargeText,
        UpdateProcGlow         = UpdateProcGlow,
        GetUsabilityState      = GetUsabilityState,
        GetUsabilityColor      = GetUsabilityColor,
        RefreshAllSpellVisuals = RefreshAllSpellVisuals,
        ApplySpellStateVisuals = ArcAurasCooldown.ApplySpellStateVisuals,
    })
    -- Swap local references so profiler wrapper is actually called
    if _wrapped then
        if _wrapped.FeedCooldown      then FeedCooldown      = _wrapped.FeedCooldown      end
        if _wrapped.UpdateChargeText  then UpdateChargeText  = _wrapped.UpdateChargeText  end
        if _wrapped.UpdateProcGlow    then UpdateProcGlow    = _wrapped.UpdateProcGlow    end
        if _wrapped.GetUsabilityState then GetUsabilityState = _wrapped.GetUsabilityState end
        if _wrapped.GetUsabilityColor then GetUsabilityColor = _wrapped.GetUsabilityColor end
        if _wrapped.RefreshAllSpellVisuals then RefreshAllSpellVisuals = _wrapped.RefreshAllSpellVisuals end
        if _wrapped.ApplySpellStateVisuals then
            ArcAurasCooldown.ApplySpellStateVisuals = _wrapped.ApplySpellStateVisuals
        end
    end
end